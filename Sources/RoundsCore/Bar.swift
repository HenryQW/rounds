import Darwin
import Foundation

public enum BarError: Error, Equatable {
    case invalidFolder, invalidName, alreadyRepository, fileExists
    case gitFailed(String), gitTimedOut, notRepository
    /// The bar is a project folder, is in one, or holds one.
    case barInProject(String)
    /// Another organization uses the folder as its bar.
    case barShared(UUID)
    case malformedData, invalidFile, changedOnDisk
}

/// Why an organization's bar cannot hold its task records yet. `message` is the sentence that Settings shows.
public enum BarProblem: Equatable, Sendable {
    case noOrganization, noOwner, noBar, unreadableSettings, inspectionFailed, folderChanged, notRepository
    /// A remote of the bar points to an account other than the organization's owner.
    case remoteNotOwned(BarRemote)
    /// `tasks/graph` or `tasks/details` in the bar is missing, a symbolic link, or open to other users.
    case taskFolderNotPrivate

    public var message: String {
        switch self {
        case .noOrganization: "The project has no organization. Classify the project in Settings > Organizations."
        case .noOwner: "Set the owner of the organization."
        case .noBar: "Choose a bar folder."
        case .unreadableSettings: "Rounds could not read the bar settings."
        case .inspectionFailed: "Rounds could not check the bar folder."
        case .folderChanged: "The bar folder was moved or replaced. Choose it again."
        case .notRepository: "The bar folder is not the root of its own repository. Choose it again."
        case .remoteNotOwned(let remote): "Remote \(remote.name) (\(remote.displayURL)) does not belong to the owner."
        case .taskFolderNotPrivate: "A task folder in the bar is missing or open to other users."
        }
    }
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

public struct BarRemote: Equatable, Sendable {
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
}

public enum BarInspection: Equatable, Sendable {
    case repository(root: String, remotes: [BarRemote])
    case noRepository
}

public let barFileName = "rounds-bar.json"
/// Task records in a bar: the graph in `tasks/graph`, the detail revisions in `tasks/details`.
public let barGraphFolder = "tasks/graph"
public let barDetailFolder = "tasks/details"

/// Finds the Git repository that holds `folder` and its remotes. Runs only local `git` commands, with no shell.
public func inspectBarFolder(_ folder: String, timeout: TimeInterval = 10) throws -> BarInspection {
    guard FolderIdentity.current(folder) != nil else { throw BarError.invalidFolder }
    let top = try runGit(["-C", folder, "rev-parse", "--show-toplevel"], timeout: timeout)
    guard top.status == 0 else {
        if top.stderr.contains("not a git repository") { return .noRepository }
        throw BarError.gitFailed(top.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let root = top.stdout.trimmingCharacters(in: .newlines)
    // `remote -v` shows the URLs that Git uses, after `insteadOf` rewrites, for fetch and push.
    let list = try runGit(["-C", root, "remote", "-v"], timeout: timeout)
    guard list.status == 0 else { throw BarError.gitFailed(list.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var remotes: [BarRemote] = []
    for line in list.stdout.split(separator: "\n") {
        guard let tab = line.firstIndex(of: "\t") else { continue }
        var url = line[line.index(after: tab)...]
        for suffix in [" (fetch)", " (push)"] where url.hasSuffix(suffix) { url = url.dropLast(suffix.count) }
        let remote = BarRemote(name: String(line[..<tab]), url: String(url))
        if !remotes.contains(remote) { remotes.append(remote) }
    }
    // A push can also go to a URL set directly in `branch.<name>.pushRemote`, `branch.<name>.remote` or
    // `remote.pushDefault`. `remote -v` does not list it.
    let pushKeys = try runGit(["-C", root, "config", "--get-regexp", #"^(branch\..*\.(pushremote|remote)|remote\.pushdefault)$"#],
                              timeout: timeout)
    guard pushKeys.status == 0 || (pushKeys.status == 1 && pushKeys.stdout.isEmpty) else {
        throw BarError.gitFailed(pushKeys.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let names = Set(remotes.map(\.name))
    for line in pushKeys.stdout.split(separator: "\n") {
        guard let space = line.firstIndex(of: " ") else { continue }
        let value = String(line[line.index(after: space)...])
        guard value != ".", !names.contains(value) else { continue }
        let remote = BarRemote(name: String(line[..<space]), url: value)
        if !remotes.contains(remote) { remotes.append(remote) }
    }
    return .repository(root: root, remotes: remotes)
}

/// Resolves a full `refs/` name in a working tree to the commit available locally at the time of lookup.
public func resolveBarSourceCommit(in repositoryRoot: String, sourceRef: String,
                                         timeout: TimeInterval = 10) throws -> String {
    try resolveBarSource(in: repositoryRoot, sourceRef: sourceRef, timeout: timeout).commit
}

private func resolveBarSource(in repositoryRoot: String, sourceRef: String,
                                    timeout: TimeInterval) throws -> (object: String, commit: String) {
    guard let root = FolderIdentity.current(repositoryRoot) else { throw BarError.invalidFolder }
    let invalidRef = BarError.gitFailed("Use a valid full Git reference name under refs/.")
    guard sourceRef.hasPrefix("refs/"), !sourceRef.utf8.contains(0) else { throw invalidRef }
    let format = try runGit(["check-ref-format", sourceRef], timeout: timeout)
    guard format.status == 0 else { throw invalidRef }

    // An explicit .git path supports linked worktrees and prevents parent discovery on every command.
    let local = ["-C", root.path, "--git-dir=.git", "--no-lazy-fetch", "--no-replace-objects"]
    let top = try runGit(local + ["rev-parse", "--show-toplevel"], timeout: timeout)
    guard top.status == 0 else {
        if top.stderr.contains("not a git repository") || top.stderr.contains("must be run in a work tree") {
            throw BarError.notRepository
        }
        throw BarError.gitFailed(top.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard let path = top.stdoutUTF8, path.utf8.last == 10,
          let workTree = String(bytes: path.utf8.dropLast(), encoding: .utf8),
          FolderIdentity.current(workTree) == root else { throw BarError.notRepository }

    let ref = try runGit(local + ["show-ref", "--verify", "--", sourceRef], timeout: timeout)
    // Foundation can normalize subprocess arguments. Check the reference spelling Git received.
    let suffix = " \(sourceRef)\n".utf8
    guard ref.status == 0, ref.stdoutBytes.suffix(suffix.count).elementsEqual(suffix) else {
        throw BarError.gitFailed("Git could not read the local source reference.")
    }
    let object = String(decoding: ref.stdoutBytes.dropLast(suffix.count), as: UTF8.self)
    guard [40, 64].contains(object.utf8.count), object.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
        throw BarError.gitFailed("Git did not return a full object identifier for the source reference.")
    }
    // Peel the captured object so a ref move between commands cannot change the lookup.
    let commit = try runGit(local + ["rev-parse", "--verify", "--end-of-options", "\(object)^{commit}"], timeout: timeout)
    guard commit.status == 0 else {
        throw BarError.gitFailed("The source reference does not resolve to a locally available commit.")
    }
    return (object, commit.stdout.trimmingCharacters(in: .newlines))
}

/// Initializes a repository in `folder` and writes `rounds-bar.json`. Call only after the user says yes.
/// Adds no remote and makes no commit. Never replaces an existing file.
public func createBarRepository(in folder: String, name: String, timeout: TimeInterval = 10) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 100, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw BarError.invalidName
    }
    guard let identity = FolderIdentity.current(folder) else { throw BarError.invalidFolder }
    guard try inspectBarFolder(identity.path, timeout: timeout) == .noRepository else { throw BarError.alreadyRepository }
    let file = identity.path + "/" + barFileName
    var info = stat()
    guard lstat(file, &info) != 0, errno == ENOENT else { throw BarError.fileExists }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(BarFile(formatVersion: 1, name: name))
    data.append(0x0A)
    let fd = open(file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
    guard fd >= 0 else { throw errno == EEXIST ? BarError.fileExists : barPOSIXError() }
    var initialized = false
    defer {
        close(fd)
        // Without a repository, the file would block a retry; remove only the file this call created.
        if !initialized { unlink(file) }
    }
    try writeAll(fd, data)
    guard fsync(fd) == 0 else { throw barPOSIXError() }
    let result = try runGit(["-C", identity.path, "init", "--quiet"], timeout: timeout)
    guard result.status == 0 else { throw BarError.gitFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    initialized = true
}

/// The only file in the bar that Rounds writes.
private struct BarFile: Encodable {
    let formatVersion: Int
    let name: String
}

/// The owner and the bar of one organization. Each is optional until the user sets it.
public struct OrganizationBar: Equatable, Sendable {
    public fileprivate(set) var owner: RemoteOwner?
    public fileprivate(set) var bar: FolderIdentity?

    public init(owner: RemoteOwner? = nil, bar: FolderIdentity? = nil) {
        self.owner = owner
        self.bar = bar
    }
}

/// Machine-specific bar choices, by organization ID. They stay in local Rounds settings, never in a bar.
public struct BarSettings: Equatable, Sendable {
    public private(set) var organizations: [UUID: OrganizationBar] = [:]

    public init() {}

    public mutating func setOwner(_ owner: RemoteOwner?, for organization: UUID) {
        organizations[organization, default: OrganizationBar()].owner = owner
        if organizations[organization] == OrganizationBar() { organizations[organization] = nil }
    }

    /// Pass the repository root, so a removed `.git` cannot make a parent repository stand in for the bar. The bar must not
    /// be a project folder, be in one or hold one, and no other organization may use it.
    public mutating func setBar(_ folder: String, for organization: UUID, projectFolders: [String]) throws {
        guard let identity = FolderIdentity.current(folder) else { throw BarError.invalidFolder }
        for project in projectFolders {
            let path = FolderIdentity.current(project)?.path ?? URL(fileURLWithPath: project).standardizedFileURL.path
            if isWithin(path, identity.path) || isWithin(identity.path, path) { throw BarError.barInProject(project) }
        }
        if let other = organizations.first(where: { $0.key != organization && $0.value.bar.map { $0.path == identity.path || $0 == identity } == true }) {
            throw BarError.barShared(other.key)
        }
        organizations[organization, default: OrganizationBar()].bar = identity
    }

    public mutating func removeBar(for organization: UUID) {
        organizations[organization]?.bar = nil
        if organizations[organization] == OrganizationBar() { organizations[organization] = nil }
    }

    /// Nil when the organization has an owner, its bar folder is the recorded one and the root of its own repository, and
    /// every remote of the bar belongs to the owner. A bar with no remote passes.
    public func barProblem(for organization: UUID?, inspection: BarInspection,
                           sshHostName: (String) -> String? = { resolveSSHHostName($0) }) -> BarProblem? {
        guard let organization else { return .noOrganization }
        guard let owner = organizations[organization]?.owner else { return .noOwner }
        guard let bar = organizations[organization]?.bar else { return .noBar }
        guard FolderIdentity.current(bar.path) == bar else { return .folderChanged }
        guard case .repository(let root, let remotes) = inspection, FolderIdentity.current(root) == bar else { return .notRepository }
        if let remote = remotes.first(where: { !remoteBelongs($0.url, to: owner, sshHostName: sshHostName) }) {
            return .remoteNotOwned(remote)
        }
        return nil
    }
}

/// `folder` is `parent` or inside it.
private func isWithin(_ parent: String, _ folder: String) -> Bool {
    folder == parent || folder.hasPrefix(parent == "/" ? "/" : parent + "/")
}

/// A task folder must be an existing directory, not a symbolic link, owned by this user with no group or other access
/// and no ACL.
func privateFolderIsUsable(_ folder: String) -> Bool {
    var link = stat()
    guard folder.hasPrefix("/"), lstat(folder, &link) == 0, link.st_mode & S_IFMT == S_IFDIR else { return false }
    let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { return false }
    if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }
    return true
}

/// Where an organization's task records go in its ready bar.
public struct BarTaskStorage: Equatable, Sendable {
    public let bar: FolderIdentity
    public let graphDirectory: URL
    public let detailDirectory: URL
    /// The detail folder when the check ran. Detail publication requires the same folder.
    public let detailIdentity: FolderIdentity
}

/// Keyed JSON with a format version. Unknown versions, keys that do not parse, and missing values fail closed.
private struct SettingsDocument: Codable {
    struct Folder: Codable {
        let path: String
        let device: Int64
        let inode: UInt64
    }

    struct Owner: Codable {
        let host: String
        let account: String
    }

    struct Organization: Codable {
        let owner: Owner?
        let bar: Folder?
    }

    let version: Int
    let organizations: [String: Organization]
}

private struct BarSnapshot: Equatable {
    let data: Data
    let device: dev_t
    let inode: ino_t
}

/// Atomic local storage for `BarSettings`. A missing file starts empty; a corrupt file throws and is not replaced.
public struct BarSettingsStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> BarSettings {
        try withLock { try decode(readSnapshot()?.data) }
    }

    /// The closure edits a fresh copy outside the lock. A concurrent change rejects the update.
    @discardableResult
    public func update(_ edit: (inout BarSettings) throws -> Void) throws -> BarSettings {
        let original = try withLock { try readSnapshot() }
        var settings = try decode(original?.data)
        try edit(&settings)
        return try withLock {
            guard try readSnapshot() == original else { throw BarError.changedOnDisk }
            try replace(with: encode(settings))
            return settings
        }
    }

    /// Nil when the organization's bar may hold its task records: the bar check after a fresh inspection, and private
    /// `tasks/graph` and `tasks/details` folders. A nil organization (an unclassified project) is never ready.
    public func storageProblem(for organization: UUID?) -> BarProblem? {
        switch Result(catching: { try taskStorage(for: organization, settings: load()) }) {
        case .success: nil
        case .failure(let error): error as? BarProblem ?? .unreadableSettings
        }
    }

    /// The task folders of the organization's bar, after the checks of `storageProblem(for:)`.
    public func taskStorage(for organization: UUID?) throws -> BarTaskStorage {
        let settings: BarSettings
        do { settings = try load() } catch { throw BarProblem.unreadableSettings }
        return try taskStorage(for: organization, settings: settings)
    }

    private func taskStorage(for organization: UUID?, settings: BarSettings) throws -> BarTaskStorage {
        guard let organization else { throw BarProblem.noOrganization }
        guard let bar = settings.organizations[organization]?.bar else {
            throw settings.organizations[organization]?.owner == nil ? BarProblem.noOwner : BarProblem.noBar
        }
        let inspection: BarInspection
        do { inspection = try inspectBarFolder(bar.path) } catch { throw BarProblem.inspectionFailed }
        if let problem = settings.barProblem(for: organization, inspection: inspection) { throw problem }
        let graph = bar.path + "/" + barGraphFolder, details = bar.path + "/" + barDetailFolder
        guard privateFolderIsUsable(bar.path + "/tasks"), privateFolderIsUsable(graph), privateFolderIsUsable(details),
              let identity = FolderIdentity.current(details), identity.path == details else { throw BarProblem.taskFolderNotPrivate }
        return BarTaskStorage(bar: bar, graphDirectory: URL(fileURLWithPath: graph, isDirectory: true),
                              detailDirectory: URL(fileURLWithPath: details, isDirectory: true), detailIdentity: identity)
    }

    /// Holds the settings lock while a cooperating task write uses the bar. The body gets the current detail folder.
    func withTaskStorage<T>(for organization: UUID, wait: Bool = true, _ body: (FolderIdentity) throws -> T) throws -> T {
        try withLock(wait: wait) {
            guard let settings = try? decode(readSnapshot()?.data),
                  let storage = try? taskStorage(for: organization, settings: settings) else { throw TaskInterfaceError.storageNotReady }
            return try body(storage.detailIdentity)
        }
    }

    private func decode(_ data: Data?) throws -> BarSettings {
        guard let data else { return BarSettings() }
        guard let document = try? JSONDecoder().decode(SettingsDocument.self, from: data), document.version == 2 else {
            throw BarError.malformedData
        }
        var settings = BarSettings()
        for (key, value) in document.organizations {
            guard let id = UUID(uuidString: key), value.owner != nil || value.bar != nil else { throw BarError.malformedData }
            var entry = OrganizationBar()
            if let owner = value.owner {
                guard let parsed = RemoteOwner(host: owner.host, account: owner.account), parsed.host == owner.host else {
                    throw BarError.malformedData
                }
                entry.owner = parsed
            }
            if let bar = value.bar {
                guard bar.path.hasPrefix("/"), !bar.path.utf8.contains(0) else { throw BarError.malformedData }
                entry.bar = FolderIdentity(path: bar.path, device: bar.device, inode: bar.inode)
            }
            settings.restore(id, entry)
        }
        return settings
    }

    private func encode(_ settings: BarSettings) throws -> Data {
        let organizations = settings.organizations.map { id, entry in
            (id.uuidString, SettingsDocument.Organization(
                owner: entry.owner.map { SettingsDocument.Owner(host: $0.host, account: $0.account) },
                bar: entry.bar.map { SettingsDocument.Folder(path: $0.path, device: $0.device, inode: $0.inode) }))
        }
        let document = SettingsDocument(version: 2, organizations: Dictionary(uniqueKeysWithValues: organizations))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    private func withLock<T>(wait: Bool = true, _ body: () throws -> T) throws -> T {
        guard url.isFileURL else { throw BarError.invalidFile }
        let lock = open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw barPOSIXError() }
        defer { close(lock) }
        guard flock(lock, wait ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else {
            if !wait && (errno == EWOULDBLOCK || errno == EAGAIN) { throw BarError.changedOnDisk }
            throw barPOSIXError()
        }
        defer { flock(lock, LOCK_UN) }
        return try body()
    }

    private func readSnapshot() throws -> BarSnapshot? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw BarError.invalidFile
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw BarError.invalidFile }
        return BarSnapshot(data: try handle.readToEnd() ?? Data(), device: info.st_dev, inode: info.st_ino)
    }

    /// Writes a private temporary file, syncs it, and renames it over the settings file.
    private func replace(with data: Data) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".rounds-bar-\(UUID().uuidString).tmp").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw barPOSIXError() }
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(temporary) }
        }
        try writeAll(fd, data)
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw barPOSIXError() }
        guard rename(temporary, url.path) == 0 else { throw barPOSIXError() }
        renamed = true
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw barPOSIXError() }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw barPOSIXError() }
    }
}

extension BarProblem: Error {}

extension BarSettings {
    fileprivate mutating func restore(_ organization: UUID, _ entry: OrganizationBar) { organizations[organization] = entry }
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw barPOSIXError() }
            offset += count
        }
    }
}

private func barPOSIXError(_ code: Int32 = errno) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

private struct GitOutput {
    let status: Int32
    let stdoutBytes: Data
    var stdout: String { String(decoding: stdoutBytes, as: UTF8.self) }
    var stdoutUTF8: String? { String(data: stdoutBytes, encoding: .utf8) }
    let stderr: String
}

/// Runs `/usr/bin/git` with explicit arguments, English messages and no prompts. Stops it after `timeout`.
private func runGit(_ arguments: [String], timeout: TimeInterval,
                    remoteOverride: (name: String, url: String)? = nil) throws -> GitOutput {
    let process = Process(), out = Pipe(), err = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    // Inherited GIT_* variables (GIT_DIR, GIT_CEILING_DIRECTORIES, GIT_CONFIG_*) could change the repository Git finds.
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["LC_ALL"] = "C"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    if let remoteOverride {
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "remote.\(remoteOverride.name).url"
        environment["GIT_CONFIG_VALUE_0"] = remoteOverride.url
    }
    process.environment = environment
    (process.standardOutput, process.standardError, process.standardInput) = (out, err, FileHandle.nullDevice)
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { throw BarError.gitFailed("git did not start") }
    // Each pipe on its own thread, so a full pipe cannot block the command.
    nonisolated(unsafe) var stdout = Data(), stderr = Data()
    let pipes = DispatchGroup()
    DispatchQueue.global(qos: .utility).async(group: pipes) { stdout = out.fileHandleForReading.readDataToEndOfFile() }
    DispatchQueue.global(qos: .utility).async(group: pipes) { stderr = err.fileHandleForReading.readDataToEndOfFile() }
    guard exited.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        throw BarError.gitTimedOut
    }
    guard pipes.wait(timeout: .now() + 2) == .success else { throw BarError.gitTimedOut }
    return GitOutput(status: process.terminationStatus, stdoutBytes: stdout, stderr: String(decoding: stderr, as: UTF8.self))
}

/// Reads the exact source and the effective fetch and push destinations of every local remote.
public func inspectApprovalSnapshot(repository: URL, sourceRef: String, remote: String,
                                    timeout: TimeInterval = 10) throws -> ApprovalSnapshot {
    guard repository.isFileURL, repository.host == nil || repository.host == "",
          let folder = FolderIdentity.current(repository.path), validApprovalRemoteName(remote) else {
        throw ApprovalError.snapshotUnavailable
    }
    do {
        let source = try resolveBarSource(in: folder.path, sourceRef: sourceRef, timeout: timeout)
        let local = ["-C", folder.path, "--git-dir=.git", "--no-lazy-fetch"]
        func output(_ args: [String], allowEmpty: Bool = false,
                    remoteOverride: (name: String, url: String)? = nil) throws -> String {
            let result = try runGit(local + args, timeout: timeout, remoteOverride: remoteOverride)
            guard result.status == 0 || (allowEmpty && result.status == 1 && result.stdoutBytes.isEmpty),
                  let text = result.stdoutUTF8 else {
                throw ApprovalError.snapshotUnavailable
            }
            return text
        }
        func destinations(_ name: String, push: Bool) throws -> [String] {
            let args = ["remote", "get-url", "--all"] + (push ? ["--push"] : []) + ["--", name]
            let lines = try output(args).split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count > 1, lines.last?.isEmpty == true else { throw ApprovalError.snapshotUnavailable }
            return try lines.dropLast().map { try cleanDestination(String($0)) }
        }
        // Preserve login positions in the same order as the inspected destinations.
        var sshLogins: [String?] = []
        func cleanDestination(_ raw: String) throws -> String {
            guard let destination = approvalDestination(raw) else { throw ApprovalError.snapshotUnavailable }
            sshLogins.append(destination.sshLogin)
            return destination.url
        }
        // Detect configuration changes during the read. Keep the raw values in memory only.
        let configArgs = ["config", "--null", "--list"]
        let config = try output(configArgs)
        // A custom remote helper can change the transport without changing the destination URLs.
        guard try output(["config", "--null", "--get-regexp", #"^remote\..*\.vcs$"#], allowEmpty: true).isEmpty else {
            throw ApprovalError.snapshotUnavailable
        }
        let urlConfig = try output(["config", "--null", "--get-regexp", #"^(remote\..*\.(url|pushurl)|url\..*\.(insteadof|pushinsteadof))$"#],
                                   allowEmpty: true)
        // Git prints effective URLs one per line. Reject multiline configuration before parsing that output.
        guard urlConfig.split(separator: "\0").allSatisfy({ $0.filter { $0 == "\n" }.count == 1 }) else {
            throw ApprovalError.snapshotUnavailable
        }
        let names = try output(["remote"]).split(separator: "\n").map(String.init).sorted()
        guard names.allSatisfy(validApprovalRemoteName) else { throw ApprovalError.snapshotUnavailable }
        let remotes = try names.map { name in
            let fetch = try destinations(name, push: false)
            let push = try destinations(name, push: true)
            return ApprovalSnapshot.Remote(name: name, fetch: fetch, push: push)
        }
        let keys = try output(["config", "--null", "--get-regexp", #"^(branch\..*\.(pushremote|remote)|remote\.pushdefault)$"#],
                              allowEmpty: true)
        let overrides = try keys.split(separator: "\0").flatMap { item -> [ApprovalSnapshot.Override] in
            let fields = item.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw ApprovalError.snapshotUnavailable }
            let key = String(fields[0]), value = String(fields[1])
            if key.hasPrefix("branch.") {
                let branch = key.dropFirst("branch.".count).dropLast(key.hasSuffix(".pushremote") ? ".pushremote".count : ".remote".count)
                guard validApprovalRef("refs/heads/\(branch)") else { throw ApprovalError.snapshotUnavailable }
            }
            if value == "." || names.contains(value) { return [.init(key: key, value: value)] }
            let clean = try cleanDestination(value)
            let name = "rounds-\(UUID().uuidString)"
            let override = (name, value)
            let actual = try output(["config", "--null", "--get", "remote.\(name).url"], remoteOverride: override)
            guard actual.utf8.elementsEqual("\(value)\0".utf8) else { throw ApprovalError.snapshotUnavailable }
            // Git applies its own longest-prefix rewrite rules to this in-memory remote.
            let listing = try output(["remote", "-v"], remoteOverride: override)
            let prefix = "\(name)\t", suffix = " (push)"
            let effective = try listing.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
                return try cleanDestination(String(line.dropFirst(prefix.count).dropLast(suffix.count)))
            }
            guard !effective.isEmpty else { throw ApprovalError.snapshotUnavailable }
            return [.init(key: key, value: clean)] + effective.map { .init(key: key, value: $0) }
        }
        guard try output(configArgs).utf8.elementsEqual(config.utf8), FolderIdentity.current(repository.path) == folder,
              try resolveBarSource(in: folder.path, sourceRef: sourceRef, timeout: timeout) == source else {
            throw ApprovalError.snapshotUnavailable
        }
        let sshLoginDigest = try sshLogins.contains { $0 != nil } ? approvalDigest(JSONEncoder().encode(sshLogins)) : nil
        return ApprovalSnapshot(folder: folder, sourceRef: sourceRef, revision: source.commit,
                                annotatedSourceObject: source.object == source.commit ? nil : source.object, remote: remote,
                                remotes: remotes, overrides: overrides, sshLoginDigest: sshLoginDigest)
    } catch {
        // Git can put raw configuration values in diagnostics.
        throw ApprovalError.snapshotUnavailable
    }
}

/// Returns a credential-free address and the transient SSH login. An empty login means SSH uses its default.
func approvalDestination(_ raw: String) -> (url: String, sshLogin: String?)? {
    guard !raw.isEmpty, !raw.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { return nil }
    if let separator = raw.range(of: "://"), !raw[..<separator.lowerBound].contains("/") {
        guard let original = URLComponents(string: raw), let scheme = original.scheme?.lowercased(),
              ["http", "https", "ssh", "git", "git+ssh", "ssh+git", "ftp", "ftps"].contains(scheme),
              original.host?.isEmpty == false, original.query == nil, original.fragment == nil else { return nil }
        let isSSH = ["ssh", "git+ssh", "ssh+git"].contains(scheme)
        let login = original.user
        if isSSH {
            // Git passes SSH user information as a login, including any password separator.
            guard original.percentEncodedPassword == nil, original.host?.contains("@") == false,
                  original.percentEncodedUser == nil || login.map(validApprovalSSHLogin) == true,
                  !original.path.isEmpty, !original.path.hasPrefix("/~") else { return nil }
        }
        let sshLogin = isSSH ? login ?? "" : nil
        guard original.percentEncodedUser != nil || original.percentEncodedPassword != nil else { return (raw, sshLogin) }
        // Remove only user information. Rebuilding a URL can change the spelling of the destination.
        let authority = raw[separator.upperBound...].prefix { $0 != "/" }
        guard let at = authority.lastIndex(of: "@") else { return nil }
        return (String(raw[..<separator.upperBound]) + raw[raw.index(after: at)...], sshLogin)
    }
    // A local path with a slash before the first colon is not SCP syntax.
    if let colon = raw.firstIndex(of: ":"), !raw[..<colon].contains("/") {
        let authority = raw[..<colon]
        let separator = authority.lastIndex(of: "@")
        let login = separator.map { String(authority[..<$0]) }
        let host = separator.map { authority[authority.index(after: $0)...] } ?? authority
        guard login.map(validApprovalSSHLogin) != false,
              !host.isEmpty, host.utf8.allSatisfy({ "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_".utf8.contains($0) }),
              !raw[raw.index(after: colon)...].isEmpty,
              !raw[raw.index(after: colon)...].hasPrefix(":"),
              !raw[raw.index(after: colon)...].prefix(while: { $0 != "/" }).contains("@") else { return nil }
        let path = raw[raw.index(after: colon)...]
        guard path.hasPrefix("/") else { return nil }
        return ("\(host)\(raw[colon...])", login ?? "")
    }
    // A local path can resolve to a different repository without changing the Git configuration.
    return nil
}

private func validApprovalSSHLogin(_ login: String) -> Bool {
    !login.isEmpty && !login.utf8.contains { $0 <= 32 || $0 == 127 || ":/".utf8.contains($0) }
}
