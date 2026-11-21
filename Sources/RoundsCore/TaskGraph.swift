import Darwin
import Foundation

public enum TaskGraphError: Error, Equatable {
    case invalidDirectory, invalidFile, malformedData, unknownVersion, unknownTask, invalidGraph
    case changedOnDisk, replacementUncertain, missingGraph, graphExists
}

public enum TaskGraphState: String, Codable, Sendable, CaseIterable {
    case queued, running, waitingDependency, approval, interrupted, failed, completed, cancelled
}

public struct TaskDetailReference: Equatable, Sendable {
    public let revisionID: UUID?
    public let generation: UInt64

    public init(revisionID: UUID?, generation: UInt64) {
        self.revisionID = revisionID
        self.generation = generation
    }

    public static let empty = TaskDetailReference(revisionID: nil, generation: 0)
}

public struct GraphTask: Identifiable, Equatable, Sendable {
    public let id: UUID
    public fileprivate(set) var parentID: UUID?
    public fileprivate(set) var required: Bool
    public fileprivate(set) var dependencies: [UUID]
    public fileprivate(set) var state: TaskGraphState
    public fileprivate(set) var resultViewed: Bool
    public fileprivate(set) var detailRevisionID: UUID?
    public fileprivate(set) var detailGeneration: UInt64
    public fileprivate(set) var updatedAt: Date

    public var detailReference: TaskDetailReference {
        TaskDetailReference(revisionID: detailRevisionID, generation: detailGeneration)
    }

    public func group(now: Date = Date(), agedAfter: TimeInterval = LastCallRule().agedAfter) -> StatusGroup {
        switch state {
        case .approval, .interrupted, .failed: .yourTurn
        case .queued, .running, .waitingDependency: .running
        case .completed, .cancelled:
            if !resultViewed { .yourTurn }
            else if now.timeIntervalSince(updatedAt) > agedAfter { .older }
            else { .quiet }
        }
    }
}

/// Stores opaque IDs and states only. Even these require authorization for the destination.
/// This primitive does not enforce organization policy or authorize storage or transmission.
public struct TaskGraph: Sendable {
    public private(set) var tasks: [GraphTask] = []
    public init() {}

    @discardableResult
    public mutating func createTask(parentID: UUID? = nil, required: Bool = false, at: Date = Date()) throws -> UUID {
        let id = UUID()
        try change { $0.append(GraphTask(id: id, parentID: parentID, required: required, dependencies: [],
                                         state: .queued, resultViewed: false, detailRevisionID: nil,
                                         detailGeneration: 0, updatedAt: at)) }
        return id
    }

    public mutating func setParent(_ id: UUID, parentID: UUID?, required: Bool) throws {
        try change { tasks in
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw TaskGraphError.unknownTask }
            tasks[i].parentID = parentID
            tasks[i].required = required
        }
    }

    public mutating func addDependency(_ dependency: UUID, to id: UUID) throws {
        try change { tasks in
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw TaskGraphError.unknownTask }
            tasks[i].dependencies.append(dependency)
        }
    }

    public mutating func setState(_ state: TaskGraphState, for id: UUID, at: Date = Date()) throws {
        try change { tasks in
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw TaskGraphError.unknownTask }
            guard tasks[i].state != state else { return }
            tasks[i].state = state
            tasks[i].resultViewed = false
            tasks[i].updatedAt = at
        }
    }

    /// Link a revision only after its detail store confirms publication at an authorized location.
    mutating func setDetailRevision(_ revisionID: UUID, for id: UUID, expecting previous: TaskDetailReference,
                                    resultChanged: Bool, at: Date = Date()) throws {
        try change { tasks in
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw TaskGraphError.unknownTask }
            guard tasks[i].detailReference == previous else { throw TaskGraphError.changedOnDisk }
            guard tasks[i].detailGeneration < UInt64.max else { throw TaskGraphError.invalidGraph }
            tasks[i].detailRevisionID = revisionID
            tasks[i].detailGeneration += 1
            if resultChanged && (tasks[i].state == .completed || tasks[i].state == .cancelled) {
                tasks[i].resultViewed = false
            }
            tasks[i].updatedAt = max(tasks[i].updatedAt, at)
        }
    }

    public mutating func markResultViewed(_ id: UUID, expecting reference: TaskDetailReference, at: Date = Date()) throws {
        try change { tasks in
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { throw TaskGraphError.unknownTask }
            guard tasks[i].detailReference == reference else { throw TaskGraphError.changedOnDisk }
            guard tasks[i].state == .completed || tasks[i].state == .cancelled else { throw TaskGraphError.invalidGraph }
            guard !tasks[i].resultViewed else { return }
            tasks[i].resultViewed = true
            tasks[i].updatedAt = at
        }
    }

    private mutating func change(_ edit: (inout [GraphTask]) throws -> Void) throws {
        var candidate = tasks
        try edit(&candidate)
        try Self.validate(candidate)
        tasks = candidate
    }

    fileprivate init(tasks: [GraphTask]) throws {
        try Self.validate(tasks)
        self.tasks = tasks
    }

    fileprivate static func validate(_ tasks: [GraphTask]) throws {
        let ids = Set(tasks.map(\.id))
        guard ids.count == tasks.count else { throw TaskGraphError.invalidGraph }
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for task in tasks {
            guard (task.detailRevisionID == nil) == (task.detailGeneration == 0),
                  task.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  task.parentID != nil || !task.required,
                  task.parentID.map({ ids.contains($0) }) ?? true,
                  Set(task.dependencies).count == task.dependencies.count,
                  task.dependencies.allSatisfy({ ids.contains($0) }),
                  !task.resultViewed || task.state == .completed || task.state == .cancelled else {
                throw TaskGraphError.invalidGraph
            }
            if task.state == .completed && task.dependencies.contains(where: { byID[$0]?.state != .completed }) {
                throw TaskGraphError.invalidGraph
            }
            if task.required, task.state != .completed, let parentID = task.parentID,
               byID[parentID]?.state == .completed { throw TaskGraphError.invalidGraph }
            var ancestor = task.parentID
            var visited: Set<UUID> = [task.id]
            while let id = ancestor {
                guard visited.insert(id).inserted, let parent = byID[id] else { throw TaskGraphError.invalidGraph }
                ancestor = parent.parentID
            }
        }
        var visiting: Set<UUID> = [], done: Set<UUID> = []
        func visit(_ id: UUID) throws {
            if done.contains(id) { return }
            guard visiting.insert(id).inserted, let task = byID[id] else { throw TaskGraphError.invalidGraph }
            for dependency in task.dependencies { try visit(dependency) }
            for child in tasks where child.parentID == id && child.required { try visit(child.id) }
            visiting.remove(id)
            done.insert(id)
        }
        for task in tasks { try visit(task.id) }
    }
}

// Arrays reject extra fields and duplicate keys. No field accepts arbitrary text.
private struct GraphDocument: Codable {
    let tasks: [GraphTask]
    init(_ graph: TaskGraph) { tasks = graph.tasks }
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard try container.decode(Int.self) == 3 else { throw TaskGraphError.unknownVersion }
        var rows = try container.nestedUnkeyedContainer()
        var tasks: [GraphTask] = []
        while !rows.isAtEnd {
            var row = try rows.nestedUnkeyedContainer()
            let id = try row.decode(UUID.self)
            let parent = try row.decodeIfPresent(UUID.self)
            let required = try row.decode(Bool.self)
            let dependencies = try row.decode([UUID].self)
            let state = try row.decode(TaskGraphState.self)
            let viewed = try row.decode(Bool.self)
            let detail = try row.decodeIfPresent(UUID.self)
            let generation = try row.decode(UInt64.self)
            let date = try row.decode(Date.self)
            guard row.isAtEnd else { throw TaskGraphError.malformedData }
            tasks.append(GraphTask(id: id, parentID: parent, required: required, dependencies: dependencies,
                                   state: state, resultViewed: viewed, detailRevisionID: detail,
                                   detailGeneration: generation, updatedAt: date))
        }
        guard container.isAtEnd else { throw TaskGraphError.malformedData }
        self.tasks = tasks
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(3)
        var rows = container.nestedUnkeyedContainer()
        for task in tasks {
            var row = rows.nestedUnkeyedContainer()
            try row.encode(task.id)
            try row.encode(task.parentID)
            try row.encode(task.required)
            try row.encode(task.dependencies)
            try row.encode(task.state)
            try row.encode(task.resultViewed)
            try row.encode(task.detailRevisionID)
            try row.encode(task.detailGeneration)
            try row.encode(task.updatedAt)
        }
    }
}

/// A non-saved result means replacement occurred, but durability or directory identity needs inspection.
public enum TaskGraphWriteResult: Equatable, Sendable {
    case saved, committedNotDurable, committedIdentityChanged, committedNotDurableAndIdentityChanged
}

/// The caller supplies a dedicated, existing, private directory authorized for every stored ID and state.
/// Cooperating processes use the lock. Noncooperating writers can race any filesystem check.
public struct TaskGraphStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// Create an empty graph only as an explicit setup action. Never overwrite an existing snapshot.
    @discardableResult
    public func initialize() throws -> TaskGraphWriteResult {
        try withLock { directory, lock in
            guard try readSnapshot(directory, "graph.json") == nil else { throw TaskGraphError.graphExists }
            let data = try JSONEncoder().encode(GraphDocument(TaskGraph()))
            return try replace(directory, path: self.directory, lock: lock, original: nil, data: data)
        }
    }

    public func load() throws -> TaskGraph {
        try load(expectingDirectory: nil)
    }

    func load(expectingDirectory identity: GraphDirectoryIdentity?) throws -> TaskGraph {
        try withLock { directory, _ in
            try identity?.check(directory)
            let graph = try decode(readSnapshot(directory, "graph.json")?.data)
            try checkGraphDirectoryIdentity(self.directory, directory)
            return graph
        }
    }

    func pinDirectory() throws -> GraphDirectoryIdentity {
        try withLock { directory, _ in
            try checkGraphDirectoryIdentity(self.directory, directory)
            return try GraphDirectoryIdentity(directory)
        }
    }

    /// The edit runs outside the lock. A concurrent graph change rejects the write.
    @discardableResult
    public func update(_ edit: (inout TaskGraph) throws -> Void) throws -> TaskGraphWriteResult {
        let (original, snapshot) = try loadForUpdate()
        var candidate = original
        try edit(&candidate)
        return try update(candidate, expecting: snapshot, commit: { try $0() })
    }

    func update(_ edit: (inout TaskGraph) throws -> Void,
                expectingDirectory identity: GraphDirectoryIdentity? = nil,
                commit: (() throws -> TaskGraphWriteResult) throws -> TaskGraphWriteResult) throws -> TaskGraphWriteResult {
        try withLock { directory, lock in
            try identity?.check(directory)
            let original = try readSnapshot(directory, "graph.json")
            var graph = try decode(original?.data)
            try edit(&graph)
            try TaskGraph.validate(graph.tasks)
            let data = try JSONEncoder().encode(GraphDocument(graph))
            return try commit { try replace(directory, path: self.directory, lock: lock, original: original, data: data) }
        }
    }

    func loadForUpdate() throws -> (TaskGraph, GraphSnapshot) {
        let (graph, snapshot, _) = try loadForRecord()
        return (graph, snapshot)
    }

    func loadForRecord() throws -> (TaskGraph, GraphSnapshot, GraphDirectoryIdentity) {
        try withLock { directory, _ in
            guard let snapshot = try readSnapshot(directory, "graph.json") else { throw TaskGraphError.missingGraph }
            let graph = try decode(snapshot.data)
            try checkGraphDirectoryIdentity(self.directory, directory)
            return (graph, snapshot, try GraphDirectoryIdentity(directory))
        }
    }

    func update(_ candidate: TaskGraph, expecting snapshot: GraphSnapshot,
                commit: (() throws -> TaskGraphWriteResult) throws -> TaskGraphWriteResult) throws -> TaskGraphWriteResult {
        try withLock { directory, lock in
            guard try readSnapshot(directory, "graph.json") == snapshot else { throw TaskGraphError.changedOnDisk }
            try TaskGraph.validate(candidate.tasks)
            let data = try JSONEncoder().encode(GraphDocument(candidate))
            return try commit { try replace(directory, path: self.directory, lock: lock, original: snapshot, data: data) }
        }
    }

    private func decode(_ data: Data?) throws -> TaskGraph {
        guard let data else { throw TaskGraphError.missingGraph }
        do { return try TaskGraph(tasks: JSONDecoder().decode(GraphDocument.self, from: data).tasks) }
        catch TaskGraphError.unknownVersion { throw TaskGraphError.unknownVersion }
        catch { throw TaskGraphError.malformedData }
    }

    private func withLock<T>(_ body: (Int32, Int32) throws -> T) throws -> T {
        let dir = try openGraphDirectory(directory)
        defer { close(dir) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw TaskGraphError.invalidDirectory }
        guard try noExtendedACL(dir) else { throw TaskGraphError.invalidDirectory }
        let lock = openat(dir, "graph.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw TaskGraphError.invalidFile }
        defer { close(lock) }
        try checkFile(lock)
        guard flock(lock, LOCK_EX) == 0 else { throw graphPOSIXError() }
        defer { flock(lock, LOCK_UN) }
        try checkLock(dir, lock)
        return try body(dir, lock)
    }
}

private func openGraphDirectory(_ directory: URL) throws -> Int32 {
    guard directory.isFileURL, directory.host == nil || directory.host == "",
          directory.path.hasPrefix("/") else { throw TaskGraphError.invalidDirectory }
    var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard current >= 0 else { throw TaskGraphError.invalidDirectory }
    for component in directory.pathComponents where component != "/" && component != "." {
        guard component != "..", !component.contains("/"), !component.utf8.contains(0) else {
            close(current)
            throw TaskGraphError.invalidDirectory
        }
        let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        close(current)
        guard next >= 0 else { throw TaskGraphError.invalidDirectory }
        current = next
    }
    return current
}

private func checkGraphDirectoryIdentity(_ path: URL, _ dir: Int32) throws {
    let current = try openGraphDirectory(path)
    defer { close(current) }
    var held = stat(), found = stat()
    guard fstat(dir, &held) == 0, fstat(current, &found) == 0,
          found.st_uid == geteuid(), found.st_mode & S_IFMT == S_IFDIR,
          found.st_mode & 0o077 == 0, try noExtendedACL(current),
          held.st_dev == found.st_dev, held.st_ino == found.st_ino else { throw TaskGraphError.changedOnDisk }
}

/// Holds the original directory open until the record operation ends.
final class GraphDirectoryIdentity: @unchecked Sendable {
    private let handle: FileHandle

    init(_ directory: Int32) throws {
        let duplicate = fcntl(directory, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw graphPOSIXError() }
        handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
    }

    func check(_ directory: Int32) throws {
        var original = stat(), current = stat()
        guard fstat(handle.fileDescriptor, &original) == 0, fstat(directory, &current) == 0,
              original.st_dev == current.st_dev, original.st_ino == current.st_ino else {
            throw TaskGraphError.changedOnDisk
        }
    }
}

struct GraphSnapshot: Equatable {
    let data: Data
    let device: dev_t
    let inode: ino_t
    let directoryDevice: dev_t
    let directoryInode: ino_t
}

private func graphPOSIXError(_ code: Int32 = errno) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }

private func noExtendedACL(_ fd: Int32) throws -> Bool {
    if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }
    guard errno == ENOENT else { throw graphPOSIXError() }
    return true
}

private func checkFile(_ fd: Int32) throws {
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw graphPOSIXError() }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
          info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
          try noExtendedACL(fd) else { throw TaskGraphError.invalidFile }
}

private func checkLock(_ dir: Int32, _ lock: Int32) throws {
    try checkFile(lock)
    var held = stat(), current = stat()
    guard fstat(lock, &held) == 0, fstatat(dir, "graph.lock", &current, AT_SYMLINK_NOFOLLOW) == 0,
          held.st_dev == current.st_dev, held.st_ino == current.st_ino else { throw TaskGraphError.changedOnDisk }
}

private func readSnapshot(_ dir: Int32, _ name: String) throws -> GraphSnapshot? {
    let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if fd < 0 {
        if errno == ENOENT { return nil }
        throw TaskGraphError.invalidFile
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try checkFile(fd)
    var info = stat(), directoryInfo = stat()
    guard fstat(fd, &info) == 0, fstat(dir, &directoryInfo) == 0 else { throw graphPOSIXError() }
    return try GraphSnapshot(data: handle.readToEnd() ?? Data(), device: info.st_dev, inode: info.st_ino,
                             directoryDevice: directoryInfo.st_dev, directoryInode: directoryInfo.st_ino)
}

private func replace(_ dir: Int32, path: URL, lock: Int32, original: GraphSnapshot?, data: Data) throws -> TaskGraphWriteResult {
    let temporary = ".graph-\(UUID().uuidString).tmp"
    let fd = openat(dir, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw graphPOSIXError() }
    var temporaryInfo = stat()
    guard fstat(fd, &temporaryInfo) == 0 else { close(fd); throw graphPOSIXError() }
    var cleanupDevice = temporaryInfo.st_dev
    var cleanupInode = temporaryInfo.st_ino
    var removeTemporary = true
    defer {
        close(fd)
        var current = stat()
        if removeTemporary, fstatat(dir, temporary, &current, AT_SYMLINK_NOFOLLOW) == 0,
           current.st_dev == cleanupDevice, current.st_ino == cleanupInode {
            _ = unlinkat(dir, temporary, 0)
        }
    }
    try checkFile(fd)
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            guard written > 0 else { throw graphPOSIXError() }
            offset += written
        }
    }
    guard fcntl(fd, F_FULLFSYNC) == 0 else { throw graphPOSIXError() }
    try checkFile(fd)
    guard fstat(fd, &temporaryInfo) == 0 else { throw graphPOSIXError() }
    guard let written = try readSnapshot(dir, temporary), written.data == data,
          written.device == temporaryInfo.st_dev, written.inode == temporaryInfo.st_ino else { throw TaskGraphError.changedOnDisk }
    try checkLock(dir, lock)
    try checkGraphDirectoryIdentity(path, dir)
    guard try readSnapshot(dir, "graph.json") == original else { throw TaskGraphError.changedOnDisk }
    if let original {
        guard renameatx_np(dir, temporary, dir, "graph.json", UInt32(RENAME_SWAP)) == 0 else {
            if errno == ENOENT { throw TaskGraphError.changedOnDisk }
            throw graphPOSIXError()
        }
        removeTemporary = false
        guard (try? readSnapshot(dir, temporary)) == original else {
            // Restore the displaced external file only if our replacement is still in place.
            if (try? readSnapshot(dir, "graph.json")) == written,
               renameatx_np(dir, temporary, dir, "graph.json", UInt32(RENAME_SWAP)) == 0 {
                cleanupDevice = written.device
                cleanupInode = written.inode
                removeTemporary = true
                guard fcntl(dir, F_FULLFSYNC) == 0 else { throw TaskGraphError.replacementUncertain }
                throw TaskGraphError.changedOnDisk
            }
            throw TaskGraphError.replacementUncertain
        }
        cleanupDevice = original.device
        cleanupInode = original.inode
        removeTemporary = true
    } else {
        guard renameatx_np(dir, temporary, dir, "graph.json", UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw TaskGraphError.changedOnDisk }
            throw graphPOSIXError()
        }
        removeTemporary = false
    }
    let synced = fcntl(dir, F_FULLFSYNC) == 0
    let identityOK = (try? checkGraphDirectoryIdentity(path, dir)) != nil
    switch (synced, identityOK) {
    case (true, true): return .saved
    case (false, true): return .committedNotDurable
    case (true, false): return .committedIdentityChanged
    case (false, false): return .committedNotDurableAndIdentityChanged
    }
}
