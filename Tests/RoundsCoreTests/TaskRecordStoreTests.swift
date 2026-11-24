import Foundation
import Testing
@testable import RoundsCore

@Suite struct TaskRecordStoreTests {
    private func stores() throws -> (URL, TaskGraphStore, TaskDetailStore) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: "task-record-\(UUID().uuidString)")
        let graph = root.appending(path: "graph")
        let details = root.appending(path: "details")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        for directory in [graph, details] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let graphStore = TaskGraphStore(directory: graph)
        try graphStore.initialize()
        return (root, graphStore, TaskDetailStore(directory: details))
    }

    private var assignment: TaskAssignment {
        TaskAssignment(objective: "Build fixture", scope: "Example", target: "Checkout",
                       constraints: ["Keep details local"], acceptanceConditions: ["Checks pass"])
    }

    @Test func linkPublishedDetailsAndPreserveConflictingRevision() throws {
        let (root, graph, details) = try stores()
        defer { try? FileManager.default.removeItem(at: root) }
        var task = UUID()
        try graph.update { task = try $0.createTask() }
        let records = TaskRecordStore(graph: graph, details: details)
        guard case .saved(let first) = try records.write(taskID: task, expecting: .empty, assignment: assignment) else {
            Issue.record("The first revision was not durably linked")
            return
        }
        let reopened = try TaskGraphStore(directory: graph.directory).load()
        #expect(reopened.tasks.first?.detailRevisionID == first)
        #expect(try TaskDetailStore(directory: details.directory).read(taskID: task, revisionID: first).assignment == assignment)
        do {
            _ = try records.write(taskID: task, expecting: .empty, assignment: assignment)
            Issue.record("A stale revision was linked")
        } catch let error as TaskRecordLinkError {
            #expect(error.underlyingError as? TaskGraphError == .changedOnDisk)
            #expect(try details.read(taskID: task, revisionID: error.revisionID).assignment == assignment)
        }
        #expect(try graph.load().tasks.first?.detailRevisionID == first)
    }

    @Test func linkingNewResultRestoresAttention() throws {
        let (root, graph, details) = try stores()
        defer { try? FileManager.default.removeItem(at: root) }
        var task = UUID()
        try graph.update {
            task = try $0.createTask()
            try $0.setState(.completed, for: task)
        }
        let records = TaskRecordStore(graph: graph, details: details)
        let first = TaskResult(changedLocations: [], validationOutcomes: ["Passed"],
                               checkedRevisionOrWorkingTree: "revision A", risks: [], blockers: [])
        let second = TaskResult(changedLocations: [], validationOutcomes: ["Passed"],
                                checkedRevisionOrWorkingTree: "revision B", risks: [], blockers: [])
        _ = try records.write(taskID: task, expecting: .empty, assignment: assignment, result: first)
        let viewed = try #require(graph.load().tasks.first).detailReference
        try graph.update { try $0.markResultViewed(task, expecting: viewed) }
        var current = try #require(graph.load().tasks.first)
        _ = try records.write(taskID: task, expecting: current.detailReference, assignment: assignment, result: first)
        current = try #require(graph.load().tasks.first)
        #expect(current.resultViewed)
        let previous = current.detailReference
        _ = try records.write(taskID: task, expecting: previous, assignment: assignment, result: second)
        #expect(throws: TaskGraphError.changedOnDisk) {
            try graph.update { try $0.markResultViewed(task, expecting: previous) }
        }
        current = try #require(graph.load().tasks.first)
        #expect(!current.resultViewed && current.group() == .yourTurn)
    }

    @Test func missingPriorDetailBlocksReplacement() throws {
        let (root, graph, details) = try stores()
        defer { try? FileManager.default.removeItem(at: root) }
        var task = UUID()
        try graph.update { task = try $0.createTask() }
        let records = TaskRecordStore(graph: graph, details: details)
        guard case .saved(let first) = try records.write(taskID: task, expecting: .empty, assignment: assignment) else {
            Issue.record("The first revision was not durably linked")
            return
        }
        let current = try #require(graph.load().tasks.first)
        try FileManager.default.removeItem(at: details.directory.appending(path: "\(task.uuidString)-\(first.uuidString).json"))
        do {
            _ = try records.write(taskID: task, expecting: current.detailReference, assignment: assignment)
            Issue.record("The missing prior revision was silently replaced")
        } catch let error as TaskRecordLinkError {
            #expect(error.underlyingError as? TaskDetailStoreError == .missingRevision)
            #expect(try details.read(taskID: task, revisionID: error.revisionID).assignment == assignment)
        }
        #expect(try graph.load().tasks.first?.detailReference == current.detailReference)
    }

    @Test func missingGraphLeavesPublishedDetailsForRecovery() throws {
        let (root, graph, details) = try stores()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = UUID()
        try FileManager.default.removeItem(at: graph.directory.appending(path: "graph.json"))
        do {
            _ = try TaskRecordStore(graph: graph, details: details)
                .write(taskID: task, expecting: .empty, assignment: assignment)
            Issue.record("The missing graph was silently recreated")
        } catch let error as TaskRecordLinkError {
            #expect(error.underlyingError as? TaskGraphError == .missingGraph)
            #expect(try details.read(taskID: task, revisionID: error.revisionID).assignment == assignment)
        }
        #expect(!FileManager.default.fileExists(atPath: graph.directory.appending(path: "graph.json").path))
    }
}
