import Darwin
import Foundation
import Testing
@testable import RoundsCore

@Suite struct TaskGraphTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appending(path: "task-graph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test func completionRequiresChildrenAndDependencies() throws {
        var graph = TaskGraph()
        let parent = try graph.createTask()
        let child = try graph.createTask(parentID: parent, required: true)
        let dependency = try graph.createTask()
        try graph.addDependency(dependency, to: parent)
        #expect(throws: TaskGraphError.invalidGraph) { try graph.setState(.completed, for: parent) }
        try graph.setState(.completed, for: child)
        try graph.setState(.cancelled, for: dependency)
        #expect(throws: TaskGraphError.invalidGraph) { try graph.setState(.completed, for: parent) }
        try graph.setState(.completed, for: dependency)
        try graph.setState(.completed, for: parent)
        #expect(throws: TaskGraphError.invalidGraph) { try graph.setState(.running, for: child) }
        #expect(throws: TaskGraphError.invalidGraph) { try graph.createTask(parentID: child, required: true) }
        #expect(throws: TaskGraphError.invalidGraph) { try graph.setState(.running, for: dependency) }
        #expect(graph.tasks.first(where: { $0.id == parent })?.state == .completed)
    }

    @Test func optionalBranchesDoNotBlockCompletedAncestors() throws {
        var graph = TaskGraph()
        let root = try graph.createTask()
        let optional = try graph.createTask(parentID: root)
        let required = try graph.createTask(parentID: optional, required: true)
        try graph.setState(.completed, for: root)
        #expect(throws: TaskGraphError.invalidGraph) { try graph.setState(.completed, for: optional) }
        try graph.setState(.completed, for: required)
        try graph.setState(.completed, for: optional)
    }

    @Test func rejectCyclesAndMissingReferences() throws {
        var graph = TaskGraph()
        let first = try graph.createTask()
        let second = try graph.createTask(parentID: first)
        #expect(throws: TaskGraphError.invalidGraph) { try graph.setParent(first, parentID: second, required: false) }
        try graph.addDependency(second, to: first)
        #expect(throws: TaskGraphError.invalidGraph) { try graph.addDependency(first, to: second) }
        #expect(throws: TaskGraphError.invalidGraph) { try graph.addDependency(UUID(), to: first) }
        var linked = TaskGraph()
        let root = try linked.createTask()
        let required = try linked.createTask(parentID: root, required: true)
        #expect(throws: TaskGraphError.invalidGraph) { try linked.addDependency(root, to: required) }
    }

    @Test func persistenceContainsOnlyGraphFields() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TaskGraphStore(directory: dir)
        try store.initialize()
        var id = UUID()
        #expect(try store.update { id = try $0.createTask(at: Date(timeIntervalSince1970: 42)) } == .saved)
        let reloaded = try TaskGraphStore(directory: dir).load()
        #expect(reloaded.tasks.count == 1)
        #expect(reloaded.tasks[0].id == id)
        let data = try Data(contentsOf: dir.appending(path: "graph.json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [Any])
        let rows = try #require(json[1] as? [[Any]])
        #expect(json.count == 2)
        #expect(rows.count == 1 && rows[0].count == 9)
        #expect(rows[0][0] as? String == id.uuidString)
        #expect(rows[0][4] as? String == "queued")
    }

    @Test func missingGraphRequiresExplicitInitialization() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TaskGraphStore(directory: dir)
        #expect(throws: TaskGraphError.missingGraph) { try store.load() }
        #expect(throws: TaskGraphError.missingGraph) { try store.update { _ = try $0.createTask() } }
        try store.initialize()
        #expect(throws: TaskGraphError.graphExists) { try store.initialize() }
        try store.update { _ = try $0.createTask() }
        try FileManager.default.removeItem(at: dir.appending(path: "graph.json"))
        #expect(throws: TaskGraphError.missingGraph) { try store.load() }
        #expect(throws: TaskGraphError.missingGraph) { try store.update { _ = try $0.createTask() } }
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "graph.json").path))
    }

    @Test func invalidSnapshotsStayUntouched() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "graph.json")
        let store = TaskGraphStore(directory: dir)
        let id = UUID().uuidString
        let missing = UUID().uuidString
        let documents = ["[4,[]]", "broken", "[3,[],0]", "[3,[[\"\(id)\",null,false,[],\"queued\",false,null,0,0],[\"\(id)\",null,false,[],\"queued\",false,null,0,0]]]", "[3,[[\"\(id)\",\"\(missing)\",true,[],\"queued\",false,null,0,0]]]"]
        for document in documents {
            let data = Data(document.utf8)
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #expect(throws: (any Error).self) { try store.update { _ = try $0.createTask() } }
            if document == "[4,[]]" { #expect(throws: TaskGraphError.unknownVersion) { try store.load() } }
            #expect(try Data(contentsOf: url) == data)
        }
    }

    @Test func externalModificationAndUnsafeFilesArePreserved() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TaskGraphStore(directory: dir)
        try store.initialize()
        try store.update { _ = try $0.createTask() }
        let url = dir.appending(path: "graph.json")
        let external = Data("external change".utf8)
        #expect(throws: TaskGraphError.changedOnDisk) {
            try store.update { graph in
                _ = try graph.createTask()
                try external.write(to: url)
            }
        }
        #expect(try Data(contentsOf: url) == external)
        try FileManager.default.removeItem(at: url)
        let other = dir.appending(path: "other")
        try external.write(to: other)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: other) == external)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: other.path)
        try FileManager.default.linkItem(at: other, to: url)
        #expect(throws: TaskGraphError.invalidFile) { try store.load() }
        #expect(try Data(contentsOf: other) == external)
        let missing = dir.appending(path: "missing")
        #expect(throws: TaskGraphError.invalidDirectory) { try TaskGraphStore(directory: missing).update { _ = try $0.createTask() } }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let unsafe = dir.appending(path: "unsafe")
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        #expect(throws: TaskGraphError.invalidDirectory) { try TaskGraphStore(directory: unsafe).update { _ = try $0.createTask() } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: unsafe.path).isEmpty)
        let unsafeLockDir = try directory()
        defer { try? FileManager.default.removeItem(at: unsafeLockDir) }
        try FileManager.default.createSymbolicLink(at: unsafeLockDir.appending(path: "graph.lock"), withDestinationURL: other)
        #expect(throws: TaskGraphError.invalidFile) { try TaskGraphStore(directory: unsafeLockDir).load() }
        #expect(try Data(contentsOf: other) == external)
    }

    @Test func staleReferenceFailsAfterRevisionIsRestored() throws {
        var graph = TaskGraph()
        let task = try graph.createTask()
        let a = UUID(), b = UUID()
        try graph.setDetailRevision(a, for: task, expecting: .empty, resultChanged: false)
        let stale = try #require(graph.tasks.first).detailReference
        try graph.setDetailRevision(b, for: task, expecting: stale, resultChanged: false)
        let current = try #require(graph.tasks.first).detailReference
        try graph.setDetailRevision(a, for: task, expecting: current, resultChanged: false)
        #expect(throws: TaskGraphError.changedOnDisk) {
            try graph.setDetailRevision(UUID(), for: task, expecting: stale, resultChanged: false)
        }
        #expect(graph.tasks.first?.detailGeneration == 3)
    }

    @Test func graphRejectsEncodedSeparatorsAndDirectoryLinks() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["child", "allowed"] {
            try FileManager.default.createDirectory(at: dir.appending(path: name), withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let escaped = try #require(URL(string: dir.absoluteString + "/child/..%2Fallowed"))
        #expect(throws: TaskGraphError.invalidDirectory) { try TaskGraphStore(directory: escaped).initialize() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "allowed").path).isEmpty)
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appending(path: "allowed"))
        #expect(throws: TaskGraphError.invalidDirectory) { try TaskGraphStore(directory: link).initialize() }
    }

    @Test func competingProcessUpdatesAreNotLost() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TaskGraphStore(directory: dir)
        try store.initialize()
        try store.update { _ = try $0.createTask() }
        let externalID = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import fcntl, json, os, sys, time
        directory, task = sys.argv[1:]
        with open(os.path.join(directory, 'graph.lock'), 'r+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            print('locked', flush=True)
            time.sleep(0.3)
            snapshot = os.path.join(directory, 'graph.json')
            with open(snapshot) as file:
                document = json.load(file)
            document[1].append([task, None, False, [], 'queued', False, None, 0, 0])
            temporary = os.path.join(directory, 'external.tmp')
            with open(temporary, 'w') as file:
                os.chmod(temporary, 0o600)
                json.dump(document, file)
            os.replace(temporary, snapshot)
        """, dir.path, externalID.uuidString]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let signal = output.fileHandleForReading.readData(ofLength: 7)
        #expect(String(data: signal, encoding: .utf8) == "locked\n")
        var localID = UUID()
        try store.update { localID = try $0.createTask() }
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let ids = Set(try store.load().tasks.map(\.id))
        #expect(ids.count == 3 && ids.contains(externalID) && ids.contains(localID))
    }

    @Test func groupsAndAgeBoundary() throws {
        var graph = TaskGraph()
        let id = try graph.createTask(at: Date(timeIntervalSince1970: 0))
        let now = Date(timeIntervalSince1970: 100_000)
        for state: TaskGraphState in [.approval, .interrupted, .failed] {
            try graph.setState(state, for: id, at: .distantPast)
            #expect(graph.tasks[0].group(now: now) == .yourTurn)
        }
        for state: TaskGraphState in [.queued, .running, .waitingDependency] {
            try graph.setState(state, for: id, at: .distantPast)
            #expect(graph.tasks[0].group(now: now) == .running)
        }
        for state: TaskGraphState in [.completed, .cancelled] {
            try graph.setState(state, for: id, at: .distantPast)
            #expect(graph.tasks[0].group(now: now) == .yourTurn)
            try graph.markResultViewed(id, expecting: .empty, at: now.addingTimeInterval(-86_400))
            try graph.setState(state, for: id, at: now)
            try graph.markResultViewed(id, expecting: .empty, at: now)
            #expect(graph.tasks[0].resultViewed)
            #expect(graph.tasks[0].updatedAt == now.addingTimeInterval(-86_400))
            #expect(graph.tasks[0].group(now: now) == .quiet)
            #expect(graph.tasks[0].group(now: now.addingTimeInterval(0.01)) == .older)
        }
    }
}
