import CryptoKit
import Darwin
import Foundation

public enum WorkspaceError: Error, Equatable {
    case invalidFolder, invalidName, alreadyRepository, fileExists
    case gitFailed(String), gitTimedOut
    case noWorkspace, folderChanged, notRepository, remotesNotAcknowledged
    case detailFolderInvalid(DetailFolderProblem)
    case malformedData, invalidFile, changedOnDisk
}

/// A folder by its resolved path and file system identity. A replaced folder at the same path has a new identity.
public struct FolderIdentity: Codable, Equatable, Sendable {
    public let path: String
    public let device: Int64
    public let inode: UInt64

    /// Nil when the path is not an existing directory.
    public static func current(_ path: String) -> FolderIdentity? {
        guard let bytes = canonicalDirectory(path), let resolved = String(bytes: bytes, encoding: .utf8) else { return nil }
        var info = stat()
        guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return FolderIdentity(path: resolved, device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

public struct WorkspaceRemote: Equatable, Sendable {
    public let name: String
    public let url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    /// The URL with any user name or password hidden, for display.
    public var displayURL: String {
        guard url.contains("://"), var components = URLComponents(string: url),
              components.user != nil || components.password != nil else { return url }
        (components.user, components.password) = ("•••", nil)
        return components.string ?? url
    }

    /// The URL without user information. A token in the URL does not change the destination it names.
    var credentialFreeURL: String {
        guard url.contains("://"), var components = URLComponents(string: url),
              components.user != nil || components.password != nil else { return url }
        (components.user, components.password) = (nil, nil)
        return components.string ?? url
    }
}

public enum WorkspaceInspection: Equatable, Sendable {
    case repository(root: String, remotes: [WorkspaceRemote])
    case noRepository
}

/// The task detail folder for one organization, or for projects that no organization rule matches.
public enum WorkspaceScope: Hashable, Sendable {
    case organization(UUID)
    case unclassified

    fileprivate var key: String {
        switch self {
        case .organization(let id): id.uuidString
        case .unclassified: "unclassified"
        }
    }

    fileprivate init?(key: String) {
        if key == "unclassified" { self = .unclassified } else if let id = UUID(uuidString: key) { self = .organization(id) } else { return nil }
    }
}

public enum DetailFolderProblem: Equatable, Sendable {
    case notApproved, missing, replaced, symlink, notOwner, notPrivate, insideRepository
}

public let workspaceFileName = "rounds-workspace.json"

/// Finds the Git repository that holds `folder` and its remotes. Runs only local `git` commands, with no shell.
public func inspectWorkspaceFolder(_ folder: String, timeout: TimeInterval = 10) throws -> WorkspaceInspection {
    guard FolderIdentity.current(folder) != nil else { throw WorkspaceError.invalidFolder }
    let top = try runGit(["-C", folder, "rev-parse", "--show-toplevel"], timeout: timeout)
    guard top.status == 0 else {
        if top.stderr.contains("not a git repository") { return .noRepository }
        throw WorkspaceError.gitFailed(top.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let root = top.stdout.trimmingCharacters(in: .newlines)
    // `remote -v` shows the URLs that Git uses, after `insteadOf` rewrites, for fetch and push.
    let list = try runGit(["-C", root, "remote", "-v"], timeout: timeout)
    guard list.status == 0 else { throw WorkspaceError.gitFailed(list.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var remotes: [WorkspaceRemote] = []
    for line in list.stdout.split(separator: "\n") {
        guard let tab = line.firstIndex(of: "\t") else { continue }
        var url = line[line.index(after: tab)...]
        for suffix in [" (fetch)", " (push)"] where url.hasSuffix(suffix) { url = url.dropLast(suffix.count) }
        let remote = WorkspaceRemote(name: String(line[..<tab]), url: String(url))
        if !remotes.contains(remote) { remotes.append(remote) }
    }
    // A push can also go to a URL set directly in `branch.<name>.pushRemote`, `branch.<name>.remote` or
    // `remote.pushDefault`. `remote -v` does not list it.
    let pushKeys = try runGit(["-C", root, "config", "--get-regexp", #"^(branch\..*\.(pushremote|remote)|remote\.pushdefault)$"#],
                              timeout: timeout)
    guard pushKeys.status == 0 || (pushKeys.status == 1 && pushKeys.stdout.isEmpty) else {
        throw WorkspaceError.gitFailed(pushKeys.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let names = Set(remotes.map(\.name))
    for line in pushKeys.stdout.split(separator: "\n") {
        guard let space = line.firstIndex(of: " ") else { continue }
        let value = String(line[line.index(after: space)...])
        guard value != ".", !names.contains(value) else { continue }
        let remote = WorkspaceRemote(name: String(line[..<space]), url: value)
        if !remotes.contains(remote) { remotes.append(remote) }
    }
    return .repository(root: root, remotes: remotes)
}

/// Initializes a repository in `folder` and writes `rounds-workspace.json`. Call only after the user says yes.
/// Adds no remote and makes no commit. Never replaces an existing file.
public func createWorkspaceRepository(in folder: String, name: String, timeout: TimeInterval = 10) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 100, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw WorkspaceError.invalidName
    }
    guard let identity = FolderIdentity.current(folder) else { throw WorkspaceError.invalidFolder }
    guard try inspectWorkspaceFolder(identity.path, timeout: timeout) == .noRepository else { throw WorkspaceError.alreadyRepository }
    let file = identity.path + "/" + workspaceFileName
    var info = stat()
    guard lstat(file, &info) != 0, errno == ENOENT else { throw WorkspaceError.fileExists }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(WorkspaceFile(formatVersion: 1, name: name))
    data.append(0x0A)
    let fd = open(file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
    guard fd >= 0 else { throw errno == EEXIST ? WorkspaceError.fileExists : workspacePOSIXError() }
    var initialized = false
    defer {
        close(fd)
        // Without a repository, the file would block a retry; remove only the file this call created.
        if !initialized { unlink(file) }
    }
    try writeAll(fd, data)
    guard fsync(fd) == 0 else { throw workspacePOSIXError() }
    let result = try runGit(["-C", identity.path, "init", "--quiet"], timeout: timeout)
    guard result.status == 0 else { throw WorkspaceError.gitFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    initialized = true
}

/// The only file in the workspace repository that Rounds writes.
private struct WorkspaceFile: Encodable {
    let formatVersion: Int
    let name: String
}

/// Machine-specific workspace choices. They stay in local Rounds settings, never in the workspace repository.
public struct WorkspaceSettings: Equatable, Sendable {
    public private(set) var workspace: FolderIdentity?
    /// SHA-256 of the acknowledged remote URLs, so a URL that holds a credential is not copied to the settings file.
    public private(set) var acknowledgedRemotes: String?
    public private(set) var detailFolders: [WorkspaceScope: FolderIdentity] = [:]

    public init() {}

    /// A different folder removes the remote acknowledgement and every detail folder approval. Pass the repository
    /// root, so a removed `.git` cannot make a parent repository stand in for the workspace.
    public mutating func setWorkspace(_ folder: String) throws {
        guard let identity = FolderIdentity.current(folder) else { throw WorkspaceError.invalidFolder }
        guard identity != workspace else { return }
        self = WorkspaceSettings()
        workspace = identity
    }

    /// The acknowledgement covers this exact set of remote URLs. Pass the URLs from a current inspection.
    public mutating func acknowledgeRemotes(_ remotes: [WorkspaceRemote]) throws {
        guard workspace != nil else { throw WorkspaceError.noWorkspace }
        acknowledgedRemotes = remoteDigest(remotes)
    }

    public mutating func withdrawAcknowledgement() { acknowledgedRemotes = nil }

    public func acknowledges(_ remotes: [WorkspaceRemote]) -> Bool {
        remotes.isEmpty || acknowledgedRemotes == remoteDigest(remotes)
    }

    /// Records the user's approval of `folder` for `scope` after the checks in `detailFolderProblem`.
    public mutating func approveDetailFolder(_ folder: String, for scope: WorkspaceScope, repositoryRoot: String) throws {
        guard workspace != nil else { throw WorkspaceError.noWorkspace }
        if let problem = checkDetailFolder(folder, repositoryRoot: repositoryRoot) { throw WorkspaceError.detailFolderInvalid(problem) }
        guard let identity = FolderIdentity.current(folder) else { throw WorkspaceError.detailFolderInvalid(.missing) }
        detailFolders[scope] = identity
    }

    public mutating func withdrawApproval(for scope: WorkspaceScope) { detailFolders[scope] = nil }

    /// Nil when the workspace folder is the recorded one and is in a repository whose remotes are acknowledged.
    public func workspaceProblem(_ inspection: WorkspaceInspection) -> WorkspaceError? {
        guard let workspace else { return .noWorkspace }
        guard FolderIdentity.current(workspace.path) == workspace else { return .folderChanged }
        guard case .repository(let root, let remotes) = inspection, FolderIdentity.current(root) == workspace else { return .notRepository }
        return acknowledges(remotes) ? nil : .remotesNotAcknowledged
    }

    /// Nil when the approved folder for `scope` is the same folder and still passes every check.
    public func detailFolderProblem(for scope: WorkspaceScope, repositoryRoot: String) -> DetailFolderProblem? {
        guard let approved = detailFolders[scope] else { return .notApproved }
        if let problem = checkDetailFolder(approved.path, repositoryRoot: repositoryRoot) { return problem }
        return FolderIdentity.current(approved.path) == approved ? nil : .replaced
    }

    /// The folder where task details for `scope` may be stored, or nil while setup is not complete for it.
    public func taskDetailFolder(for scope: WorkspaceScope, inspection: WorkspaceInspection) -> URL? {
        guard workspaceProblem(inspection) == nil, case .repository(let root, _) = inspection,
              detailFolderProblem(for: scope, repositoryRoot: root) == nil,
              let path = detailFolders[scope]?.path else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// A detail folder must be an existing directory, not a symlink, owned by this user with no group or other access
/// and no ACL, and outside the workspace repository.
public func checkDetailFolder(_ folder: String, repositoryRoot: String) -> DetailFolderProblem? {
    var link = stat()
    guard folder.hasPrefix("/"), lstat(folder, &link) == 0 else { return .missing }
    if link.st_mode & S_IFMT == S_IFLNK { return .symlink }
    guard link.st_mode & S_IFMT == S_IFDIR, let identity = FolderIdentity.current(folder) else { return .missing }
    let fd = open(identity.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { return .missing }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { return .missing }
    guard info.st_uid == geteuid() else { return .notOwner }
    guard info.st_mode & 0o077 == 0 else { return .notPrivate }
    if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
        acl_free(UnsafeMutableRawPointer(acl))
        return .notPrivate
    }
    guard let root = FolderIdentity.current(repositoryRoot)?.path else { return .insideRepository }
    if identity.path == root || identity.path.hasPrefix(root == "/" ? "/" : root + "/") { return .insideRepository }
    return nil
}

private func remoteDigest(_ remotes: [WorkspaceRemote]) -> String {
    let urls = Set(remotes.map(\.credentialFreeURL)).sorted().joined(separator: "\n")
    return SHA256.hash(data: Data(urls.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Keyed JSON with a format version. Unknown versions, keys that do not parse, and missing values fail closed.
private struct SettingsDocument: Codable {
    struct Folder: Codable {
        let path: String
        let device: Int64
        let inode: UInt64
    }

    let version: Int
    let workspace: Folder?
    let acknowledgedRemotes: String?
    let detailFolders: [String: Folder]
}

/// Atomic local storage for `WorkspaceSettings`. A missing file starts empty; a corrupt file throws and is not replaced.
public struct WorkspaceSettingsStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> WorkspaceSettings {
        try withLock { try decode(readData()) }
    }

    /// The closure edits a fresh copy. A thrown closure leaves the file unchanged.
    @discardableResult
    public func update(_ edit: (inout WorkspaceSettings) throws -> Void) throws -> WorkspaceSettings {
        try withLock {
            let original = try readData()
            var settings = try decode(original)
            try edit(&settings)
            try replace(with: encode(settings))
            return settings
        }
    }

    /// The task detail folder for `scope` after a fresh inspection, or nil while setup is not complete for it.
    public func taskDetailFolder(for scope: WorkspaceScope) -> URL? {
        guard let settings = try? load(), let workspace = settings.workspace,
              let inspection = try? inspectWorkspaceFolder(workspace.path) else { return nil }
        return settings.taskDetailFolder(for: scope, inspection: inspection)
    }

    /// False unless setup is complete for the organization, or for unclassified projects when `organizationID` is nil.
    public func mayStoreTaskDetails(for organizationID: UUID?) -> Bool {
        taskDetailFolder(for: organizationID.map(WorkspaceScope.organization) ?? .unclassified) != nil
    }

    private func decode(_ data: Data?) throws -> WorkspaceSettings {
        guard let data else { return WorkspaceSettings() }
        guard let document = try? JSONDecoder().decode(SettingsDocument.self, from: data), document.version == 1 else {
            throw WorkspaceError.malformedData
        }
        func folder(_ value: SettingsDocument.Folder) throws -> FolderIdentity {
            guard value.path.hasPrefix("/"), !value.path.utf8.contains(0) else { throw WorkspaceError.malformedData }
            return FolderIdentity(path: value.path, device: value.device, inode: value.inode)
        }
        var settings = WorkspaceSettings()
        if let workspace = document.workspace { settings.restore(workspace: try folder(workspace)) }
        if let digest = document.acknowledgedRemotes {
            guard settings.workspace != nil, digest.count == 64, digest.allSatisfy(\.isHexDigit) else { throw WorkspaceError.malformedData }
            settings.restore(acknowledgedRemotes: digest)
        }
        for (key, value) in document.detailFolders {
            guard settings.workspace != nil, let scope = WorkspaceScope(key: key) else { throw WorkspaceError.malformedData }
            settings.restore(scope, try folder(value))
        }
        return settings
    }

    private func encode(_ settings: WorkspaceSettings) throws -> Data {
        func folder(_ value: FolderIdentity) -> SettingsDocument.Folder {
            SettingsDocument.Folder(path: value.path, device: value.device, inode: value.inode)
        }
        let document = SettingsDocument(version: 1, workspace: settings.workspace.map(folder),
                                        acknowledgedRemotes: settings.acknowledgedRemotes,
                                        detailFolders: Dictionary(uniqueKeysWithValues: settings.detailFolders.map { ($0.key.key, folder($0.value)) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        guard url.isFileURL else { throw WorkspaceError.invalidFile }
        let lock = open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw workspacePOSIXError() }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw workspacePOSIXError() }
        defer { flock(lock, LOCK_UN) }
        return try body()
    }

    private func readData() throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw WorkspaceError.invalidFile
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw WorkspaceError.invalidFile }
        return try handle.readToEnd() ?? Data()
    }

    /// Writes a private temporary file, syncs it, and renames it over the settings file.
    private func replace(with data: Data) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".rounds-workspace-\(UUID().uuidString).tmp").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw workspacePOSIXError() }
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(temporary) }
        }
        try writeAll(fd, data)
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw workspacePOSIXError() }
        guard rename(temporary, url.path) == 0 else { throw workspacePOSIXError() }
        renamed = true
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw workspacePOSIXError() }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw workspacePOSIXError() }
    }
}

extension WorkspaceSettings {
    fileprivate mutating func restore(workspace: FolderIdentity) { self.workspace = workspace }
    fileprivate mutating func restore(acknowledgedRemotes: String) { self.acknowledgedRemotes = acknowledgedRemotes }
    fileprivate mutating func restore(_ scope: WorkspaceScope, _ folder: FolderIdentity) { detailFolders[scope] = folder }
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw workspacePOSIXError() }
            offset += count
        }
    }
}

private func workspacePOSIXError(_ code: Int32 = errno) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

private struct GitOutput {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Runs `/usr/bin/git` with explicit arguments, English messages and no prompts. Stops it after `timeout`.
private func runGit(_ arguments: [String], timeout: TimeInterval) throws -> GitOutput {
    let process = Process(), out = Pipe(), err = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    // Inherited GIT_* variables (GIT_DIR, GIT_CEILING_DIRECTORIES, GIT_CONFIG_*) could change the repository Git finds.
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["LC_ALL"] = "C"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    process.environment = environment
    (process.standardOutput, process.standardError, process.standardInput) = (out, err, FileHandle.nullDevice)
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { throw WorkspaceError.gitFailed("git did not start") }
    // Each pipe on its own thread, so a full pipe cannot block the command.
    nonisolated(unsafe) var stdout = Data(), stderr = Data()
    let pipes = DispatchGroup()
    DispatchQueue.global(qos: .utility).async(group: pipes) { stdout = out.fileHandleForReading.readDataToEndOfFile() }
    DispatchQueue.global(qos: .utility).async(group: pipes) { stderr = err.fileHandleForReading.readDataToEndOfFile() }
    guard exited.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        throw WorkspaceError.gitTimedOut
    }
    guard pipes.wait(timeout: .now() + 2) == .success else { throw WorkspaceError.gitTimedOut }
    return GitOutput(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
                     stderr: String(decoding: stderr, as: UTF8.self))
}
