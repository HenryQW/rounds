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
    public let repositoryID: UUID?
    public let repositoryFolder: FolderIdentity?

    public init(changedLocations: [String], validationOutcomes: [String], checkedRevisionOrWorkingTree: String,
                risks: [String], blockers: [String], repositoryID: UUID? = nil, repositoryFolder: FolderIdentity? = nil) {
        self.changedLocations = changedLocations
        self.validationOutcomes = validationOutcomes
        self.checkedRevisionOrWorkingTree = checkedRevisionOrWorkingTree
        self.risks = risks
        self.blockers = blockers
        self.repositoryID = repositoryID
        self.repositoryFolder = repositoryFolder
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
    public let resultRevisionID: UUID?
    public let assignment: TaskAssignment
    public let result: TaskResult?
    public let progress: [TaskProgress]
    public let decisions: [TaskDecision]
    public let approvals: [ApprovalRecord]
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
    private let approvedIdentity: FolderIdentity?
    private let approval: (WorkspaceSettingsStore, WorkspaceScope)?
    private static let maximumBytes = 1_048_576

    public init(directory: URL) { self.directory = directory; self.approvedIdentity = nil; self.approval = nil }

    init(directory: URL, approvedIdentity: FolderIdentity, workspace: WorkspaceSettingsStore, scope: WorkspaceScope) {
        self.directory = directory
        self.approvedIdentity = approvedIdentity
        self.approval = (workspace, scope)
    }

    @discardableResult
    public func write(taskID: UUID, assignment: TaskAssignment, result: TaskResult? = nil,
                      progress: [TaskProgress] = [], decisions: [TaskDecision] = []) throws -> TaskDetailWriteResult {
        try write(taskID: taskID, assignment: assignment, result: result, progress: progress, decisions: decisions, approvals: [])
    }

    func write(taskID: UUID, assignment: TaskAssignment, result: TaskResult?, progress: [TaskProgress],
               decisions: [TaskDecision], approvals: [ApprovalRecord], resultRevisionID: UUID? = nil) throws -> TaskDetailWriteResult {
        try ApprovalRecord.validate(approvals, taskID: taskID)
        let revisionID = UUID()
        let revision = TaskDetailRevision(taskID: taskID, revisionID: revisionID,
                                          resultRevisionID: result.map { _ in resultRevisionID ?? revisionID }, assignment: assignment,
                                          result: result, progress: progress, decisions: decisions, approvals: approvals)
        if let (workspace, scope) = approval {
            return try workspace.withTaskDetailApproval(for: scope) { identity in
                guard identity == approvedIdentity else { throw TaskInterfaceError.storageNotReady }
                return try publish(revision)
            }
        }
        return try publish(revision)
    }

    func withPublicationApproval<T>(_ body: () throws -> T) throws -> T {
        guard let (workspace, scope) = approval else { return try body() }
        return try workspace.withTaskDetailApproval(for: scope, wait: false) { identity in
            guard identity == approvedIdentity else { throw TaskInterfaceError.storageNotReady }
            let dir = try openDirectory()
            defer { close(dir) }
            return try body()
        }
    }

    func checkRevisionSize(taskID: UUID, details: TaskDetails) throws {
        try checkRevisionSize(taskID: taskID, assignment: details.assignment, result: details.result,
                              progress: details.progress, decisions: details.decisions, approvals: details.approvals)
    }

    func checkRevisionSize(taskID: UUID, assignment: TaskAssignment, result: TaskResult?, progress: [TaskProgress],
                           decisions: [TaskDecision], approvals: [ApprovalRecord]) throws {
        try ApprovalRecord.validate(approvals, taskID: taskID)
        let id = UUID()
        let revision = TaskDetailRevision(taskID: taskID, revisionID: id, resultRevisionID: result.map { _ in id },
                                          assignment: assignment, result: result, progress: progress,
                                          decisions: decisions, approvals: approvals)
        _ = try encodedRevision(revision)
    }

    private func encodedRevision(_ revision: TaskDetailRevision) throws -> Data {
        let data = try JSONEncoder().encode(DetailDocument(revision: revision))
        guard data.count <= Self.maximumBytes else { throw TaskDetailStoreError.tooLarge }
        return data
    }

    private func publish(_ revision: TaskDetailRevision) throws -> TaskDetailWriteResult {
        let taskID = revision.taskID
        let data = try encodedRevision(revision)
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
        guard (document.revision.result == nil) == (document.revision.resultRevisionID == nil) else {
            throw TaskDetailStoreError.malformedData
        }
        do { try ApprovalRecord.validate(document.revision.approvals, taskID: taskID) }
        catch { throw TaskDetailStoreError.malformedData }
        return document.revision
    }

    // Detail links take the same lock as approvals. A nonempty lock file marks an uncertain approval save.
    func withApprovalLock<T>(taskID: UUID, wait: Bool = true, _ body: (Int32, Int32) throws -> T) throws -> T {
        let dir = try openDirectory()
        defer { close(dir) }
        let name = "\(taskID.uuidString).approval-lock"
        let fd = openat(dir, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw ApprovalError.needsInspection }
        defer { close(fd) }
        try checkDetailFile(fd)
        guard flock(fd, wait ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else {
            if !wait && errno == EWOULDBLOCK { throw TaskGraphError.changedOnDisk }
            throw ApprovalError.needsInspection
        }
        try checkIdentity(dir, name: name, fd: fd)
        if wait { try checkApprovalDirectory(dir) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == 0 else { throw ApprovalError.needsInspection }
        return try body(dir, fd)
    }

    func checkApprovalDirectory(_ directory: Int32) throws {
        try withPublicationApproval { try checkDirectoryIdentity(directory) }
    }

    func saveApproval(taskID: UUID, in directory: Int32, lock: Int32,
                      _ write: () throws -> TaskRecordWriteResult) throws -> TaskRecordWriteResult {
        try checkDirectoryIdentity(directory)
        try checkIdentity(directory, name: "\(taskID.uuidString).approval-lock", fd: lock)
        var marker: UInt8 = 1
        guard pwrite(lock, &marker, 1, 0) == 1, fcntl(lock, F_FULLFSYNC) == 0,
              fcntl(directory, F_FULLFSYNC) == 0 else { throw ApprovalError.needsInspection }
        let outcome = try write()
        guard case .saved = outcome else { throw ApprovalError.needsInspection }
        try checkDirectoryIdentity(directory)
        try checkIdentity(directory, name: "\(taskID.uuidString).approval-lock", fd: lock)
        // Both references are durable. A failed marker sync can only keep a request blocked after restart.
        guard ftruncate(lock, 0) == 0, fcntl(lock, F_FULLFSYNC) == 0 else { throw ApprovalError.needsInspection }
        return outcome
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
            if let approvedIdentity {
                guard Int64(info.st_dev) == approvedIdentity.device, UInt64(info.st_ino) == approvedIdentity.inode else {
                    throw TaskDetailStoreError.changedOnDisk
                }
            }
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
        version = 2
        self.revision = revision
        checksum = try Self.digest(revision)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == 1 || version == 2 else { throw TaskDetailStoreError.unknownVersion }
        checksum = try container.decode(String.self, forKey: .checksum)
        switch version {
        case 1:
            let original = try container.decode(OriginalRevision.self, forKey: .revision)
            guard checksum == (try Self.digest(original)) else { throw TaskDetailStoreError.integrityMismatch }
            revision = TaskDetailRevision(taskID: original.taskID, revisionID: original.revisionID,
                                          resultRevisionID: original.result.map { _ in original.revisionID }, assignment: original.assignment,
                                          result: original.result, progress: original.progress, decisions: original.decisions, approvals: [])
        case 2:
            revision = try container.decode(TaskDetailRevision.self, forKey: .revision)
            guard checksum == (try Self.digest(revision)) else { throw TaskDetailStoreError.integrityMismatch }
        default:
            throw TaskDetailStoreError.unknownVersion
        }
    }

    private struct OriginalRevision: Codable {
        let taskID: UUID
        let revisionID: UUID
        let assignment: TaskAssignment
        let result: TaskResult?
        let progress: [TaskProgress]
        let decisions: [TaskDecision]
    }

    private static func digest(_ revision: some Encodable) throws -> String {
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
