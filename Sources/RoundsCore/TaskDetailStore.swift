import CryptoKit
import Darwin
import Foundation

public struct TaskAssignment: Codable, Equatable, Sendable {
    public let objective: String
    public let scope: String
    public let target: String
    public let constraints: [String]
    public let acceptanceConditions: [String]

    public init(objective: String, scope: String, target: String, constraints: [String], acceptanceConditions: [String]) {
        self.objective = objective
        self.scope = scope
        self.target = target
        self.constraints = constraints
        self.acceptanceConditions = acceptanceConditions
    }
}

public struct TaskResult: Codable, Equatable, Sendable {
    public let changedLocations: [String]
    public let validationOutcomes: [String]
    public let checkedRevisionOrWorkingTree: String
    public let risks: [String]
    public let blockers: [String]

    public init(changedLocations: [String], validationOutcomes: [String], checkedRevisionOrWorkingTree: String,
                risks: [String], blockers: [String]) {
        self.changedLocations = changedLocations
        self.validationOutcomes = validationOutcomes
        self.checkedRevisionOrWorkingTree = checkedRevisionOrWorkingTree
        self.risks = risks
        self.blockers = blockers
    }
}

public struct TaskProgress: Codable, Equatable, Sendable {
    public let summary: String
    public let actor: String
    public let time: Date

    public init(summary: String, actor: String, time: Date) {
        self.summary = summary
        self.actor = actor
        self.time = time
    }
}

public struct TaskDecision: Codable, Equatable, Sendable {
    public let decision: String
    public let reason: String
    public let actor: String
    public let time: Date

    public init(decision: String, reason: String, actor: String, time: Date) {
        self.decision = decision
        self.reason = reason
        self.actor = actor
        self.time = time
    }
}

public struct TaskDetailRevision: Codable, Equatable, Sendable {
    public let taskID: UUID
    public let revisionID: UUID
    public let assignment: TaskAssignment
    public let result: TaskResult?
    public let progress: [TaskProgress]
    public let decisions: [TaskDecision]
}

public enum TaskDetailStoreError: Error, Equatable {
    case invalidDirectory, invalidFile, missingRevision, malformedData, unknownVersion, identityMismatch
    case changedOnDisk, tooLarge, integrityMismatch
}

/// A published revision can exist even if its directory entry was not durably synced.
public enum TaskDetailDurability: Equatable, Sendable {
    case saved, publishedNotDurable, publishedIdentityChanged, publishedNotDurableAndIdentityChanged
}

public struct TaskDetailWriteResult: Equatable, Sendable {
    public let revisionID: UUID
    public let durability: TaskDetailDurability
}

/// The caller must authorize every value for this exact existing private directory before use.
/// Even an ID or title may be restricted. Git remote visibility does not grant permission.
/// Publish a detail revision before recording its ID in a separately authorized graph. A revision
/// without a graph reference is a recoverable orphan. This is not a transaction across stores,
/// action approval, protection against same-user adversaries, or complete recovery.
/// Failed writes can leave private temporary files for inspection; this store does not clean them up.
/// Each encoded revision is limited to 1 MiB. The checksum detects accidental content changes;
/// it does not authenticate the file against someone who can modify it.
public struct TaskDetailStore: Sendable {
    public let directory: URL
    private static let maximumBytes = 1_048_576

    public init(directory: URL) { self.directory = directory }

    @discardableResult
    public func write(taskID: UUID, assignment: TaskAssignment, result: TaskResult? = nil,
                      progress: [TaskProgress] = [], decisions: [TaskDecision] = []) throws -> TaskDetailWriteResult {
        let revision = TaskDetailRevision(taskID: taskID, revisionID: UUID(), assignment: assignment,
                                          result: result, progress: progress, decisions: decisions)
        let data = try JSONEncoder().encode(DetailDocument(revision: revision))
        guard data.count <= Self.maximumBytes else { throw TaskDetailStoreError.tooLarge }
        let dir = try openDirectory()
        defer { close(dir) }
        let name = filename(taskID, revision.revisionID)
        let temporary = ".\(taskID.uuidString)-\(revision.revisionID.uuidString).tmp"
        let fd = openat(dir, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw detailPOSIXError() }
        defer { close(fd) }
        try checkDetailFile(fd)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw detailPOSIXError() }
                offset += count
            }
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw detailPOSIXError() }
        try checkDetailFile(fd)
        guard lseek(fd, 0, SEEK_SET) == 0, try readDetailData(fd, limit: Self.maximumBytes) == data else {
            throw TaskDetailStoreError.changedOnDisk
        }
        try checkIdentity(dir, name: temporary, fd: fd)
        try checkDirectoryIdentity(dir)
        guard renameatx_np(dir, temporary, dir, name, UInt32(RENAME_EXCL)) == 0 else { throw detailPOSIXError() }
        let synced = fcntl(dir, F_FULLFSYNC) == 0
        guard (try? checkDirectoryIdentity(dir)) != nil,
              (try? checkDetailFile(fd)) != nil,
              (try? checkIdentity(dir, name: name, fd: fd)) != nil else {
            return TaskDetailWriteResult(revisionID: revision.revisionID,
                                         durability: synced ? .publishedIdentityChanged : .publishedNotDurableAndIdentityChanged)
        }
        return TaskDetailWriteResult(revisionID: revision.revisionID, durability: synced ? .saved : .publishedNotDurable)
    }

    public func read(taskID: UUID, revisionID: UUID) throws -> TaskDetailRevision {
        let dir = try openDirectory()
        defer { close(dir) }
        let name = filename(taskID, revisionID)
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { throw TaskDetailStoreError.missingRevision }
            throw TaskDetailStoreError.invalidFile
        }
        defer { close(fd) }
        try checkDetailFile(fd)
        try checkIdentity(dir, name: name, fd: fd)
        let data = try readDetailData(fd, limit: Self.maximumBytes)
        try checkDetailFile(fd)
        try checkIdentity(dir, name: name, fd: fd)
        try checkDirectoryIdentity(dir)
        let document: DetailDocument
        do { document = try JSONDecoder().decode(DetailDocument.self, from: data) }
        catch TaskDetailStoreError.unknownVersion { throw TaskDetailStoreError.unknownVersion }
        catch TaskDetailStoreError.integrityMismatch { throw TaskDetailStoreError.integrityMismatch }
        catch { throw TaskDetailStoreError.malformedData }
        guard document.revision.taskID == taskID, document.revision.revisionID == revisionID else {
            throw TaskDetailStoreError.identityMismatch
        }
        return document.revision
    }

    private func filename(_ taskID: UUID, _ revisionID: UUID) -> String {
        "\(taskID.uuidString)-\(revisionID.uuidString).json"
    }

    private func openDirectory() throws -> Int32 {
        guard directory.isFileURL, directory.host == nil || directory.host == "",
              directory.path.hasPrefix("/"), !directory.pathComponents.contains("..") else {
            throw TaskDetailStoreError.invalidDirectory
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { throw TaskDetailStoreError.invalidDirectory }
        for component in directory.pathComponents where component != "/" && component != "." {
            guard component != "..", !component.contains("/"), !component.utf8.contains(0) else {
                close(current)
                throw TaskDetailStoreError.invalidDirectory
            }
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(current)
            guard next >= 0 else { throw TaskDetailStoreError.invalidDirectory }
            current = next
        }
        do {
            var info = stat()
            guard fstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
                  try detailNoACL(current) else { throw TaskDetailStoreError.invalidDirectory }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private func checkDirectoryIdentity(_ dir: Int32) throws {
        let current = try openDirectory()
        defer { close(current) }
        var held = stat(), found = stat()
        guard fstat(dir, &held) == 0, fstat(current, &found) == 0,
              held.st_dev == found.st_dev, held.st_ino == found.st_ino else { throw TaskDetailStoreError.changedOnDisk }
    }
}

private struct DetailDocument: Codable {
    let version: Int
    let revision: TaskDetailRevision
    let checksum: String

    init(revision: TaskDetailRevision) throws {
        version = 1
        self.revision = revision
        checksum = try Self.digest(revision)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else { throw TaskDetailStoreError.unknownVersion }
        revision = try container.decode(TaskDetailRevision.self, forKey: .revision)
        checksum = try container.decode(String.self, forKey: .checksum)
        guard checksum == (try Self.digest(revision)) else { throw TaskDetailStoreError.integrityMismatch }
    }

    private static func digest(_ revision: TaskDetailRevision) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try SHA256.hash(data: encoder.encode(revision)).map { String(format: "%02x", $0) }.joined()
    }
}

private func readDetailData(_ fd: Int32, limit: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw detailPOSIXError() }
        if count == 0 { return data }
        data.append(contentsOf: buffer.prefix(count))
        guard data.count <= limit else { throw TaskDetailStoreError.tooLarge }
    }
}

private func detailPOSIXError(_ code: Int32 = errno) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

private func detailNoACL(_ fd: Int32) throws -> Bool {
    if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }
    guard errno == ENOENT else { throw detailPOSIXError() }
    return true
}

private func checkDetailFile(_ fd: Int32) throws {
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw detailPOSIXError() }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
          info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
          try detailNoACL(fd) else { throw TaskDetailStoreError.invalidFile }
}

private func checkIdentity(_ dir: Int32, name: String, fd: Int32) throws {
    var held = stat(), found = stat()
    guard fstat(fd, &held) == 0, fstatat(dir, name, &found, AT_SYMLINK_NOFOLLOW) == 0,
          held.st_dev == found.st_dev, held.st_ino == found.st_ino else { throw TaskDetailStoreError.changedOnDisk }
}
