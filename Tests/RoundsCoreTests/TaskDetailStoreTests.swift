import CryptoKit
import Darwin
import Foundation
import Testing
@testable import RoundsCore

@Suite struct TaskDetailStoreTests {
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        let url = root.appending(path: "task-details-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    private var assignment: TaskAssignment {
        TaskAssignment(objective: "Build fixture", scope: "Example", target: "Checkout",
                       constraints: ["Keep data local"], acceptanceConditions: ["Checks pass"])
    }

    private func file(_ directory: URL, _ task: UUID, _ revision: UUID) -> URL {
        directory.appending(path: "\(task.uuidString)-\(revision.uuidString).json")
    }

    @Test func restartAndMultipleRevisions() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = UUID()
        let store = TaskDetailStore(directory: dir)
        let first = try store.write(taskID: task, assignment: assignment)
        let result = TaskResult(changedLocations: ["Sources/example"], validationOutcomes: ["Passed"],
                                checkedRevisionOrWorkingTree: "working tree", risks: ["Example risk"], blockers: [])
        let progress = TaskProgress(summary: "Checked the fixture", actor: "Bartender",
                                    time: Date(timeIntervalSince1970: 40))
        let decision = TaskDecision(decision: "Use fixture", reason: "Test", actor: "Agent",
                                    time: Date(timeIntervalSince1970: 42))
        let second = try store.write(taskID: task, assignment: assignment, result: result,
                                     progress: [progress], decisions: [decision])
        #expect(first.durability == .saved)
        #expect(second.durability == .saved)
        #expect(first.revisionID != second.revisionID)
        let reopened = TaskDetailStore(directory: dir)
        let loadedFirst = try reopened.read(taskID: task, revisionID: first.revisionID)
        let loadedSecond = try reopened.read(taskID: task, revisionID: second.revisionID)
        #expect(loadedFirst.taskID == task && loadedFirst.revisionID == first.revisionID)
        #expect(loadedFirst.assignment == assignment && loadedFirst.result == nil && loadedFirst.progress.isEmpty && loadedFirst.decisions.isEmpty)
        #expect(loadedSecond.assignment == assignment && loadedSecond.result == result)
        #expect(loadedSecond.progress == [progress] && loadedSecond.decisions == [decision])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
    }

    @Test func corruptUnknownAndMismatchedRecordsStayUntouched() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = UUID(), revision = UUID()
        let url = file(dir, task, revision)
        let store = TaskDetailStore(directory: dir)
        for (data, error) in [(Data("broken".utf8), TaskDetailStoreError.malformedData),
                              (Data("{\"version\":3}".utf8), TaskDetailStoreError.unknownVersion)] {
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #expect(throws: error) { try store.read(taskID: task, revisionID: revision) }
            #expect(try Data(contentsOf: url) == data)
        }
        let other = try store.write(taskID: UUID(), assignment: assignment)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let otherName = try #require(names.first { $0.contains(other.revisionID.uuidString) })
        let data = try Data(contentsOf: dir.appending(path: otherName))
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(throws: TaskDetailStoreError.identityMismatch) { try store.read(taskID: task, revisionID: revision) }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func verifiesOriginalChecksumBeforeUpgradingVersionOne() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = UUID(), revision = UUID()
        let legacy = """
        {"assignment":{"acceptanceConditions":[],"constraints":[],"objective":"Legacy fixture","scope":"Local","target":"Checkout"},"decisions":[],"progress":[],"result":{"blockers":[],"changedLocations":[],"checkedRevisionOrWorkingTree":"fixture revision","risks":[],"validationOutcomes":[]},"revisionID":"\(revision.uuidString)","taskID":"\(task.uuidString)"}
        """
        let checksum = SHA256.hash(data: Data(legacy.utf8)).map { String(format: "%02x", $0) }.joined()
        let original = "{\"version\":1,\"checksum\":\"\(checksum)\",\"revision\":\(legacy)}"
        let url = file(dir, task, revision)
        try Data(original.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let store = TaskDetailStore(directory: dir)
        let loaded = try store.read(taskID: task, revisionID: revision)
        #expect(loaded.approvals.isEmpty && loaded.resultRevisionID == revision)
        #expect(loaded.assignment.objective == "Legacy fixture")
        try Data(original.replacingOccurrences(of: "Legacy fixture", with: "Changed fixture").utf8).write(to: url)
        #expect(throws: TaskDetailStoreError.integrityMismatch) { try store.read(taskID: task, revisionID: revision) }
    }

    @Test func rejectsValidButAlteredRevision() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = UUID()
        let store = TaskDetailStore(directory: dir)
        let saved = try store.write(taskID: task, assignment: assignment)
        let url = file(dir, task, saved.revisionID)
        let original = try String(contentsOf: url, encoding: .utf8)
        let changed = original.replacingOccurrences(of: "Build fixture", with: "Build altered")
        #expect(changed != original)
        try Data(changed.utf8).write(to: url)
        #expect(throws: TaskDetailStoreError.integrityMismatch) {
            try store.read(taskID: task, revisionID: saved.revisionID)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == changed)
    }

    @Test func rejectLinksAndUnsafeDirectories() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = UUID(), revision = UUID()
        let target = dir.appending(path: "fixture")
        let data = Data("fixture".utf8)
        try data.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let url = file(dir, task, revision)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let store = TaskDetailStore(directory: dir)
        #expect(throws: TaskDetailStoreError.invalidFile) { try store.read(taskID: task, revisionID: revision) }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.linkItem(at: target, to: url)
        #expect(throws: TaskDetailStoreError.invalidFile) { try store.read(taskID: task, revisionID: revision) }
        #expect(try Data(contentsOf: target) == data)
        let link = dir.appending(path: "directory-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        #expect(throws: TaskDetailStoreError.invalidDirectory) {
            try TaskDetailStore(directory: link).write(taskID: task, assignment: assignment)
        }
        let unsafe = dir.appending(path: "unsafe")
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        #expect(throws: TaskDetailStoreError.invalidDirectory) {
            try TaskDetailStore(directory: unsafe).write(taskID: task, assignment: assignment)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: unsafe.path).isEmpty)
    }

    @Test func encodedSeparatorCannotEscapeDirectory() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["child", "allowed"] {
            try FileManager.default.createDirectory(at: dir.appending(path: name), withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let escaped = try #require(URL(string: dir.absoluteString + "/child/..%2Fallowed"))
        #expect(throws: TaskDetailStoreError.invalidDirectory) {
            try TaskDetailStore(directory: escaped).write(taskID: UUID(), assignment: assignment)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "allowed").path).isEmpty)
    }

    @Test func concurrentWritersPublishIndependentRevisions() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TaskDetailStore(directory: dir)
        let task = UUID()
        let assignment = self.assignment
        let writes = try await withThrowingTaskGroup(of: TaskDetailWriteResult.self) { group in
            for _ in 0..<8 {
                group.addTask { try store.write(taskID: task, assignment: assignment) }
            }
            var results: [TaskDetailWriteResult] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(writes.count == 8)
        #expect(Set(writes.map(\.revisionID)).count == 8)
        for write in writes {
            #expect(write.durability == .saved)
            #expect(try store.read(taskID: task, revisionID: write.revisionID).assignment == assignment)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 8)
    }

    @Test func missingDirectoryDoesNotCreateAnything() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appending(path: "missing")
        let store = TaskDetailStore(directory: missing)
        #expect(throws: TaskDetailStoreError.invalidDirectory) { try store.write(taskID: UUID(), assignment: assignment) }
        #expect(throws: TaskDetailStoreError.invalidDirectory) { try store.read(taskID: UUID(), revisionID: UUID()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        let target = dir.appending(path: "target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let saved = try TaskDetailStore(directory: target).write(taskID: UUID(), assignment: assignment)
        #expect(saved.durability == .saved)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["target"])
    }

    @Test func oversizedRevisionDoesNotCreateFiles() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let large = TaskAssignment(objective: String(repeating: "x", count: 1_048_577), scope: "", target: "",
                                   constraints: [], acceptanceConditions: [])
        #expect(throws: TaskDetailStoreError.tooLarge) { try TaskDetailStore(directory: dir).write(taskID: UUID(), assignment: large) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
