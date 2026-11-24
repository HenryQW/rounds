import Darwin
import Foundation
import os
import Testing
@testable import RoundsCore

@Suite(.serialized) struct TaskInterfaceTests {
    private final class Fixture {
        let root: URL
        let repository: URL
        let graph: TaskGraphStore
        let details: TaskDetailStore
        let settings: BarSettingsStore
        let organizationID = UUID()
        var interface: TaskInterface { TaskInterface(bar: settings) }

        init(initializeGraph: Bool = true) throws {
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appending(path: "task-interface-\(UUID().uuidString)")
            repository = root.appending(path: "bar", directoryHint: .isDirectory)
            graph = TaskGraphStore(directory: repository.appending(path: barGraphFolder, directoryHint: .isDirectory))
            details = TaskDetailStore(directory: repository.appending(path: barDetailFolder, directoryHint: .isDirectory))
            settings = BarSettingsStore(url: root.appending(path: "settings.json"))
            try Self.makeBar(repository)
            try settings.update {
                $0.setOwner(RemoteOwner("github.com/fixture"), for: organizationID)
                try $0.setBar(repository.path, for: organizationID, projectFolders: [])
            }
            if initializeGraph { #expect(try graph.initialize() == .saved) }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// A bar with private task folders: `tasks/graph` and `tasks/details`.
        static func makeBar(_ repository: URL) throws {
            for directory in [repository.deletingLastPathComponent(), repository] {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                         attributes: [.posixPermissions: 0o700])
            }
            try createBarRepository(in: repository.path, name: "Test bar")
            for folder in ["tasks", barGraphFolder, barDetailFolder] {
                try FileManager.default.createDirectory(at: repository.appending(path: folder), withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
        }

        func access(graphDirectory: URL? = nil, detailDirectory: URL? = nil,
                    allowsGraph: @escaping (TaskGraphValues, URL) -> Bool = { _, _ in true },
                    allowsDetails: @escaping (UUID, TaskDetails, URL) -> Bool = { _, _, _ in true }) -> TaskStorageAuthorization {
            access(as: organizationID, graphDirectory: graphDirectory, detailDirectory: detailDirectory,
                   allowsGraph: allowsGraph, allowsDetails: allowsDetails)
        }

        func access(as id: UUID?, graphDirectory: URL? = nil, detailDirectory: URL? = nil,
                    allowsGraph: @escaping (TaskGraphValues, URL) -> Bool = { _, _ in true },
                    allowsDetails: @escaping (UUID, TaskDetails, URL) -> Bool = { _, _, _ in true }) -> TaskStorageAuthorization {
            TaskStorageAuthorization(organizationID: id, graphDirectory: graphDirectory ?? graph.directory,
                                             detailDirectory: detailDirectory ?? details.directory,
                                             allowsGraph: allowsGraph, allowsDetails: allowsDetails)
        }

        func create(_ values: TaskDetails) throws -> TaskRecord {
            let outcome = try interface.create(details: values, using: access())
            guard case .saved(let taskID, let revisionID) = outcome else {
                Issue.record("Creation did not confirm durable publication")
                throw TaskGraphError.replacementUncertain
            }
            let record = try interface.read(taskID, using: access())
            #expect(record.task.detailRevisionID == revisionID)
            return record
        }

        func graphData() throws -> Data { try Data(contentsOf: graph.directory.appending(path: "graph.json")) }

        func detailData() throws -> [String: Data] {
            let names = try FileManager.default.contentsOfDirectory(atPath: details.directory.path)
            return try Dictionary(uniqueKeysWithValues: names.filter { !$0.hasSuffix(".approval-lock") }.map {
                ($0, try Data(contentsOf: details.directory.appending(path: $0)))
            })
        }
    }

    private var assignment: TaskAssignment {
        TaskAssignment(objective: "Build the local fixture", scope: "Task records", target: "Temporary checkout",
                       constraints: ["Keep details local"], acceptanceConditions: ["Checks pass"])
    }

    private var values: TaskDetails { TaskDetails(assignment: assignment) }

    private struct ApprovalFixture {
        let store: Fixture
        let checkout: URL
        let repositoryID = UUID()
        let sourceRef = "refs/heads/main"
        let initial: TaskRecord
        let actions: [ApprovalAction]

        init(bound: Bool = true) throws {
            let store = try Fixture()
            self.store = store
            checkout = store.root.appending(path: "source")
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: false)
            try Self.git(checkout, "init", "--quiet", "--initial-branch=main")
            let revision = try Self.advanceRef(checkout)
            try Self.git(checkout, "config", "remote.origin.url", "https://fixture-user:\(Self.password)@example.invalid/team/repo.git")
            let result = TaskResult(changedLocations: ["example"], validationOutcomes: ["Passed"],
                                    checkedRevisionOrWorkingTree: revision, risks: [], blockers: [],
                                    repositoryID: bound ? repositoryID : nil,
                                    repositoryFolder: bound ? try #require(FolderIdentity.current(checkout.path)) : nil)
            initial = try store.create(TaskDetails(assignment: TaskAssignment(objective: "Check a local approval", scope: "Fixture",
                                                                                 target: "Local source", constraints: [], acceptanceConditions: []),
                                                   result: result))
            actions = [
                ApprovalAction(intent: .push(sourceRef: sourceRef, revision: revision, remote: "origin",
                                             urls: ["https://example.invalid/team/repo.git"], destinationRef: "refs/heads/result")),
                ApprovalAction(intent: .draftPullRequest(repository: "example.invalid/team/repo", baseRef: "refs/heads/main",
                                                         headRef: "refs/heads/result", revision: revision,
                                                         draft: ApprovalDraft(title: "Local fixture", body: "Check only")))
            ]
        }

        var taskID: UUID { initial.task.id }

        func request(expecting reference: TaskDetailReference? = nil, actions: [ApprovalAction]? = nil,
                     using access: TaskStorageAuthorization? = nil, sourceRef: String? = nil) throws -> ApprovalRecord {
            try store.interface.requestApproval(for: taskID, expecting: reference ?? initial.task.detailReference,
                                                repositoryID: repositoryID, repository: checkout, sourceRef: sourceRef ?? self.sourceRef,
                                                remote: "origin", actions: actions ?? self.actions, using: access ?? store.access())
        }

        func reload() throws -> TaskRecord { try store.interface.reloadApprovals(for: taskID, using: store.access()) }

        func answer(_ id: UUID, _ decision: ApprovalDecision, using interface: TaskInterface? = nil) throws -> ApprovalRecord {
            try (interface ?? store.interface).answerApproval(id, for: taskID, decision: decision, using: store.access()) {
                $0 == taskID && $1 == id && $2 == (try? decision.normalized())
            }
        }

        @discardableResult
        static func git(_ directory: URL, _ args: String...) throws -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory.path] + args
            process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        }

        static let password = UUID().uuidString

        @discardableResult
        static func advanceRef(_ directory: URL) throws -> String {
            let tree = try git(directory, "hash-object", "-w", "-t", "tree", "/dev/null")
            let revision = try git(directory, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                                   "-c", "commit.gpgSign=false", "commit-tree", tree, "-m", UUID().uuidString)
            try git(directory, "update-ref", "refs/heads/main", revision)
            return revision
        }
    }

    @Test func localApprovalRejectsRepositorySubstitutionsAndUnboundResult() throws {
        let legacy = try ApprovalFixture(bound: false)
        #expect(throws: ApprovalError.resultMismatch) { try legacy.request() }
        let fixture = try ApprovalFixture()
        func request(repositoryID: UUID, repository: URL) throws -> ApprovalRecord {
            try fixture.store.interface.requestApproval(for: fixture.taskID, expecting: fixture.initial.task.detailReference,
                                                        repositoryID: repositoryID, repository: repository,
                                                        sourceRef: fixture.sourceRef, remote: "origin", actions: fixture.actions,
                                                        using: fixture.store.access())
        }
        #expect(throws: ApprovalError.resultMismatch) { try request(repositoryID: UUID(), repository: fixture.checkout) }
        let otherFixture = try ApprovalFixture()
        let other = otherFixture.store.root.appending(path: "other")
        try ApprovalFixture.git(otherFixture.store.root, "clone", "--quiet", "--local", otherFixture.checkout.path, other.path)
        let remoteURL = try ApprovalFixture.git(otherFixture.checkout, "config", "remote.origin.url")
        try ApprovalFixture.git(other, "config", "remote.origin.url", remoteURL)
        #expect(throws: ApprovalError.resultMismatch) {
            try otherFixture.store.interface.requestApproval(for: otherFixture.taskID, expecting: otherFixture.initial.task.detailReference,
                                                            repositoryID: otherFixture.repositoryID, repository: other,
                                                            sourceRef: otherFixture.sourceRef, remote: "origin", actions: otherFixture.actions,
                                                            using: otherFixture.store.access())
        }
    }

    @Test(arguments: ["unbound", "missing ID", "missing folder", "wrong ID", "wrong folder"])
    func localApprovalReloadInvalidatesUnboundOrMismatchedResult(binding: String) throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        let record = try fixture.store.interface.read(fixture.taskID, using: fixture.store.access())
        let details = try #require(record.details)
        let originalResult = try #require(details.result)
        let otherFolder = try #require(FolderIdentity.current(fixture.store.repository.path))
        let result = TaskResult(changedLocations: originalResult.changedLocations, validationOutcomes: originalResult.validationOutcomes,
                                checkedRevisionOrWorkingTree: originalResult.checkedRevisionOrWorkingTree,
                                risks: originalResult.risks, blockers: originalResult.blockers,
                                repositoryID: binding == "unbound" || binding == "missing ID" ? nil :
                                    (binding == "wrong ID" ? UUID() : fixture.repositoryID),
                                repositoryFolder: binding == "unbound" || binding == "missing folder" ? nil :
                                    (binding == "wrong folder" ? otherFolder : originalResult.repositoryFolder))
        let old = pending.request
        let request = ApprovalRequest(id: old.id, taskID: old.taskID, repositoryID: old.repositoryID,
                                      organizationID: old.organizationID, resultRevisionID: old.resultRevisionID,
                                      resultDigest: try approvalResultDigest(result), snapshot: old.snapshot, actions: old.actions,
                                      createdAt: old.createdAt, checkedAt: old.checkedAt, harnessBinding: old.harnessBinding)
        let revision = try fixture.store.details.write(taskID: fixture.taskID, assignment: details.assignment, result: result,
                                                       progress: details.progress, decisions: details.decisions,
                                                       approvals: [ApprovalRecord(request: request)], resultRevisionID: old.resultRevisionID)
        try fixture.store.graph.update {
            try $0.setDetailRevision(revision.revisionID, for: fixture.taskID, expecting: record.task.detailReference, resultChanged: false)
        }
        let reloaded = try fixture.reload()
        #expect(reloaded.details?.approvals.first?.invalidatedAt != nil)
        #expect(throws: ApprovalError.stale) { try fixture.answer(pending.id, .approved) }
    }

    @Test func localApprovalRejectsGraphDirectoryReplacementDuringAuthorization() throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        let graph = fixture.store.graph.directory
        let original = fixture.store.root.appending(path: "original-graph")
        var replaced = false
        let access = fixture.store.access(allowsGraph: { _, _ in
            guard !replaced else { return true }
            replaced = true
            do {
                try FileManager.default.moveItem(at: graph, to: original)
                try FileManager.default.copyItem(at: original, to: graph)
                return true
            } catch { Issue.record(error); return false }
        })
        #expect(throws: (any Error).self) {
            try fixture.store.interface.answerApproval(pending.id, for: fixture.taskID, decision: .approved, using: access) { _, _, _ in true }
        }
        #expect(try fixture.store.interface.read(fixture.taskID, using: fixture.store.access()).details?.approvals.last?.answer == nil)
    }

    @Test func localApprovalReloadConflictOffersRetryAndBlocksOldCards() throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        let card = ApprovalCard(local: pending)
        var thread = BouncerThread()
        thread.beginLocalApprovalReload(for: fixture.taskID)
        thread.localApprovalReloadNeedsRetry(for: fixture.taskID)
        #expect(thread.localApprovalRetries.contains(fixture.taskID))
        #expect(thread.items.isEmpty && thread.waitingCount == 1)
        thread.replaceLocalApprovals(for: fixture.taskID, with: [card])
        #expect(!thread.localApprovalRetries.contains(fixture.taskID))
        #expect(thread.waitingCount == 1)
        thread.beginLocalApprovalReload(for: fixture.taskID)
        #expect(thread.waitingCount == 0)
        thread.localApprovalReloadNeedsRetry(for: fixture.taskID)
        #expect(thread.localApprovalRetries.contains(fixture.taskID) && thread.waitingCount == 1)
        guard case .approval(let blocked) = try #require(thread.items.first) else { throw ApprovalError.invalidRequest }
        #expect(!blocked.isOpen && blocked.decision == nil)
        thread.replaceLocalApprovals(for: fixture.taskID, with: [card])
        #expect(!thread.localApprovalRetries.contains(fixture.taskID) && thread.waitingCount == 1)
    }

    @Test func failedLocalApprovalReloadHidesCardsAndKeepsAttention() throws {
        let fixture = try ApprovalFixture()
        let card = ApprovalCard(local: try fixture.request())
        var thread = BouncerThread()
        thread.replaceLocalApprovals(for: fixture.taskID, with: [card])

        thread.localApprovalReloadNeedsRetry(for: fixture.taskID, discardCards: true)
        #expect(thread.items.isEmpty)
        #expect(thread.localApprovalRetries == [fixture.taskID])
        #expect(thread.waitingCount == 1)

        thread.replaceLocalApprovals(for: fixture.taskID, with: [])
        #expect(thread.localApprovalRetries.isEmpty)
        #expect(thread.waitingCount == 0)
    }

    @Test func contendedApprovalCanRetryAfterRecheck() throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        try fixture.store.details.withApprovalLock(taskID: fixture.taskID, wait: false) { _, _ in
            #expect(throws: TaskGraphError.changedOnDisk) { try fixture.answer(pending.id, .approved) }
        }
        #expect(try fixture.reload().details?.approvals.last == pending)
        #expect(try fixture.answer(pending.id, .approved).answer?.decision == .approved)
    }

    @Test func directOversizedResultDoesNotLeaveInspectionMarker() throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        let record = try fixture.reload()
        let oversized = TaskResult(changedLocations: [String(repeating: "x", count: 1_200_000)], validationOutcomes: [],
                                   checkedRevisionOrWorkingTree: "other", risks: [], blockers: [])
        #expect(throws: TaskDetailStoreError.tooLarge) {
            try TaskRecordStore(graph: fixture.store.graph, details: fixture.store.details)
                .write(taskID: fixture.taskID, expecting: record.task.detailReference,
                       assignment: try #require(record.details).assignment, result: oversized)
        }
        #expect(try fixture.reload().details?.approvals.last == pending)
        #expect(try fixture.answer(pending.id, .approved).answer?.decision == .approved)
    }

    @Test func approvalReloadRejectsTemporaryGraphReplacement() throws {
        let fixture = try ApprovalFixture()
        _ = try fixture.request()
        let graph = fixture.store.graph.directory
        let alternate = fixture.store.root.appending(path: "alternate-graph")
        let original = fixture.store.root.appending(path: "original-graph")
        try FileManager.default.copyItem(at: graph, to: alternate)
        _ = try TaskGraphStore(directory: alternate).update { try $0.setState(.running, for: fixture.taskID) }
        var detailReads = 0, switched = false
        func restore() throws {
            guard switched else { return }
            try FileManager.default.moveItem(at: graph, to: alternate)
            try FileManager.default.moveItem(at: original, to: graph)
            switched = false
        }
        defer { try? restore() }
        let access = fixture.store.access(allowsGraph: { _, _ in
            do { try restore(); return true } catch { Issue.record(error); return false }
        }, allowsDetails: { _, _, _ in
            detailReads += 1
            guard detailReads == 2 else { return true }
            do {
                try FileManager.default.moveItem(at: graph, to: original)
                try FileManager.default.moveItem(at: alternate, to: graph)
                switched = true
                return true
            } catch { Issue.record(error); return false }
        })
        #expect(throws: (any Error).self) {
            try fixture.store.interface.reloadApprovals(for: fixture.taskID, using: access)
        }
    }

    @Test func staleApprovalReloadRejectsTemporaryGraphReplacement() throws {
        let fixture = try ApprovalFixture()
        _ = try fixture.request()
        try ApprovalFixture.git(fixture.checkout, "config", "remote.origin.pushurl", "https://example.invalid/changed.git")
        let graph = fixture.store.graph.directory, taskID = fixture.taskID
        let alternate = fixture.store.root.appending(path: "alternate-after-save")
        let original = fixture.store.root.appending(path: "original-after-save")
        let switched = OSAllocatedUnfairLock(initialState: false)
        var interface = fixture.store.interface
        let writer = interface.writeRecord
        interface.writeRecord = { store, id, reference, details, at, identity, holding, grant in
            let result = try writer(store, id, reference, details, at, identity, holding, grant)
            try FileManager.default.copyItem(at: graph, to: alternate)
            _ = try TaskGraphStore(directory: alternate).update { try $0.setState(.running, for: taskID) }
            try FileManager.default.moveItem(at: graph, to: original)
            try FileManager.default.moveItem(at: alternate, to: graph)
            switched.withLock { $0 = true }
            return result
        }
        func restore() throws {
            guard switched.withLock({ $0 }) else { return }
            try FileManager.default.moveItem(at: graph, to: alternate)
            try FileManager.default.moveItem(at: original, to: graph)
            switched.withLock { $0 = false }
        }
        defer { try? restore() }
        let access = fixture.store.access(allowsGraph: { _, _ in
            do { try restore(); return true } catch { Issue.record(error); return false }
        })
        #expect(throws: (any Error).self) { try interface.reloadApprovals(for: taskID, using: access) }
    }

    @Test func directResultReplacementRequiresInspectionAfterFailedLink() throws {
        let fixture = try ApprovalFixture()
        _ = try fixture.request()
        let record = try fixture.reload()
        let result = TaskResult(changedLocations: [], validationOutcomes: [], checkedRevisionOrWorkingTree: "other", risks: [], blockers: [])
        #expect(throws: (any Error).self) {
            try TaskRecordStore(graph: fixture.store.graph, details: fixture.store.details)
                .write(taskID: fixture.taskID, expecting: record.task.detailReference,
                       assignment: try #require(record.details).assignment, result: result, at: .distantPast)
        }
        #expect(throws: ApprovalError.needsInspection) { try fixture.reload() }
    }

    @Test func reentrantApprovalAuthorizationDoesNotBlock() throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        let interface = fixture.store.interface, taskID = fixture.taskID
        let graph = fixture.store.graph.directory, details = fixture.store.details.directory, scope = fixture.store.organizationID
        let access = fixture.store.access(allowsDetails: { _, _, _ in
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                let nested = TaskStorageAuthorization(organizationID: scope, graphDirectory: graph, detailDirectory: details,
                                                      allowsGraph: { _, _ in true }, allowsDetails: { _, _, _ in true })
                _ = try? interface.reloadApprovals(for: taskID, using: nested)
                done.signal()
            }
            return done.wait(timeout: .now() + 1) == .success
        })
        let saved = try fixture.store.interface.answerApproval(pending.id, for: fixture.taskID, decision: .approved, using: access) { _, _, _ in true }
        #expect(saved.answer?.decision == .approved)
    }

    @Test func localApprovalPersistsOneAnswerAndKeepsResultIdentity() throws {
        let fixture = try ApprovalFixture()
        let taskID = fixture.taskID
        try fixture.store.interface.revise(taskID, expecting: fixture.initial.task.detailReference, using: fixture.store.access()) {
            $0.progress.append(TaskProgress(summary: "Saved before requesting", actor: "Fixture", time: Date()))
        }
        let reference = try fixture.reload().task.detailReference
        let pending = try fixture.request(expecting: reference)
        let reopened = try fixture.reload()
        #expect(reopened.details?.approvals == [pending])
        #expect(pending.request.resultRevisionID == fixture.initial.details?.revisionID)
        #expect(pending.request.resultRevisionID != reference.revisionID && pending.request.resultRevisionID != reopened.details?.revisionID)
        let localCard = ApprovalCard(local: pending)
        var thread = BouncerThread(items: [.approval(localCard), .user(id: "old-turn", text: "Previous turn")])
        thread.apply(.started(model: nil, selection: nil))
        #expect(thread.items == [.approval(localCard)])
        #expect(thread.waitingCount == 1)
        try thread.decide(pending.id.uuidString, .approved)
        #expect(thread.waitingCount == 1)
        let saved = try fixture.answer(pending.id, .rejected(reason: "  Check the base. \n"))
        #expect(saved.answer?.decision == .rejected(reason: "Check the base."))
        #expect(saved.answer?.actor == .user)
        #expect(throws: ApprovalError.alreadyAnswered) { try fixture.answer(pending.id, .approved) }
        let answered = try fixture.reload()
        thread.replaceLocalApprovals(for: taskID, with: answered.details?.approvals.map { ApprovalCard(local: $0) } ?? [])
        let card = ApprovalCard(local: saved)
        #expect(thread.items == [.approval(card)] && thread.waitingCount == 0)
        #expect(card.source == .local && card.taskID == taskID.uuidString && card.decision == saved.answer?.decision)
        #expect(card.actions.first?.hasPrefix("Push ") == true && card.actions.last?.hasPrefix("Open a draft pull request ") == true)
        #expect(answered.task.state == fixture.initial.task.state)
        #expect(!card.actions.joined().contains(ApprovalFixture.password))
        #expect(try fixture.store.detailData().values.allSatisfy { !String(decoding: $0, as: UTF8.self).contains(ApprovalFixture.password) })
        try fixture.store.interface.revise(taskID, expecting: answered.task.detailReference, using: fixture.store.access()) {
            $0.progress.append(TaskProgress(summary: "Checked the outcome", actor: "Fixture", time: Date()))
        }
        #expect(try fixture.reload().details?.approvals == [saved])
    }

    @Test func localApprovalBindsTheAnswerToOneHarnessCall() throws {
        let fixture = try ApprovalFixture()
        let binding = ApprovalHarnessBinding(taskID: 42, conversationID: 7, callID: "tool-1")
        let request = try fixture.store.interface.requestApproval(for: fixture.taskID, expecting: fixture.initial.task.detailReference,
                                                                  repositoryID: fixture.repositoryID, repository: fixture.checkout,
                                                                  sourceRef: fixture.sourceRef, remote: "origin", actions: fixture.actions,
                                                                  using: fixture.store.access(), harnessBinding: binding).request
        func read(_ binding: ApprovalHarnessBinding) throws -> ApprovalAnswer? {
            try fixture.store.interface.verifiedApprovalAnswer(request.id, for: fixture.taskID, binding: binding,
                                                               using: fixture.store.access())
        }
        #expect(try read(binding) == nil)
        _ = try fixture.answer(request.id, .approved)
        #expect(try read(binding)?.decision == .approved)
        let wrong = ApprovalHarnessBinding(taskID: binding.taskID, conversationID: binding.conversationID, callID: "tool-2")
        #expect(throws: ApprovalError.boundTaskUnverified) { _ = try read(wrong) }
        try ApprovalFixture.git(fixture.checkout, "remote", "set-url", "origin", "https://example.invalid/other/repo.git")
        #expect(throws: ApprovalError.stale) { _ = try read(binding) }
        let current = try fixture.reload()
        #expect(current.details?.approvals.last?.invalidatedAt != nil)
        #expect(throws: ApprovalError.boundTaskUnverified) {
            _ = try fixture.request(expecting: current.task.detailReference)
        }
    }

    @Test func localApprovalExecutesOnlyTheNextStoredAction() throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        let request = pending.request
        let first = request.actions[0], second = request.actions[1]
        var executed: [ApprovalAction] = []
        func run(_ id: UUID, verified: Bool = true) throws {
            try fixture.store.interface.executeApprovedAction(id, requestID: request.id, taskID: fixture.taskID,
                                                              using: fixture.store.access(), verify: { _, _ in verified }) {
                executed.append($0)
            }
        }
        #expect(throws: ApprovalError.actionNotApproved) { try run(first.id) }
        _ = try fixture.answer(request.id, .approved)
        #expect(throws: ApprovalError.actionNotApproved) { try run(second.id) }
        #expect(throws: ApprovalError.actionNotApproved) { try run(first.id, verified: false) }
        var checks = 0
        #expect(throws: ApprovalError.actionNotApproved) {
            try fixture.store.interface.executeApprovedAction(first.id, requestID: request.id, taskID: fixture.taskID,
                                                              using: fixture.store.access(), verify: { _, _ in
                checks += 1
                return checks == 1
            }) { executed.append($0) }
        }
        #expect(checks == 2)
        #expect(executed.isEmpty)
        #expect(try fixture.reload().details?.approvals.last?.execution == nil)
        try run(first.id)
        #expect(throws: ApprovalError.actionNotApproved) { try run(first.id) }
        try run(second.id)
        #expect(executed == [first, second])
        #expect(try fixture.reload().details?.approvals.last?.execution == [.completed, .completed])
    }

    @Test func localApprovalBlocksReplayAfterUncertainExecution() throws {
        let fixture = try ApprovalFixture()
        let request = try fixture.request().request
        let action = request.actions[0]
        _ = try fixture.answer(request.id, .approved)
        var calls = 0
        for _ in 0..<2 {
            #expect(throws: ApprovalError.executionUncertain) {
                try fixture.store.interface.executeApprovedAction(action.id, requestID: request.id, taskID: fixture.taskID,
                                                                  using: fixture.store.access(), verify: { _, _ in true }) { _ in
                    calls += 1
                    throw ApprovalError.snapshotUnavailable
                }
            }
        }
        #expect(calls == 1)
        #expect(try fixture.reload().details?.approvals.last?.execution == [.started])
    }

    @Test func localApprovalRejectsUnauthorizedMalformedAndUnknownInputs() throws {
        let fixture = try ApprovalFixture()
        let initial = try fixture.store.detailData()
        #expect(throws: ApprovalError.invalidRequest) { try fixture.request(actions: []) }
        #expect(throws: ApprovalError.invalidRequest) { try fixture.request(actions: [fixture.actions[0], fixture.actions[0]]) }
        let invalid = ApprovalAction(intent: .push(sourceRef: fixture.sourceRef, revision: String(repeating: "a", count: 40),
                                                  remote: "origin", urls: ["https://example.invalid/team/repo.git"],
                                                  destinationRef: "refs/heads/result"))
        #expect(throws: ApprovalError.invalidRequest) { try fixture.request(actions: [invalid]) }
        #expect(throws: TaskInterfaceError.graphNotAuthorized) {
            try fixture.request(using: fixture.store.access(allowsGraph: { values, _ in
                if case .detailLink = values { return false }
                return true
            }))
        }
        #expect(throws: TaskInterfaceError.detailsNotAuthorized) {
            try fixture.request(using: fixture.store.access(allowsDetails: { _, details, _ in details.approvals.isEmpty }))
        }
        #expect(try fixture.store.detailData().filter { $0.key.hasSuffix(".json") } == initial)
        let pending = try fixture.request()
        #expect(throws: ApprovalError.unknownRequest) { try fixture.answer(UUID(), .approved) }
        #expect(throws: BouncerError.reasonRequired) { try fixture.answer(pending.id, .rejected(reason: " \t\n")) }
        #expect(try fixture.reload().details?.approvals == [pending])
        try fixture.store.settings.update { $0.setOwner(nil, for: fixture.store.organizationID) }
        #expect(throws: TaskInterfaceError.storageNotReady) { try fixture.answer(pending.id, .approved) }
        #expect(throws: TaskInterfaceError.storageNotReady) { try fixture.reload() }
    }

    @Test func localApprovalInvalidationSurvivesTheOriginalSnapshotReturning() throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        try ApprovalFixture.git(fixture.checkout, "update-ref", "-d", fixture.sourceRef)
        #expect(throws: ApprovalError.snapshotUnavailable) { try fixture.reload() }
        #expect(throws: ApprovalError.snapshotUnavailable) { try fixture.answer(pending.id, .approved) }
        #expect(try fixture.store.interface.read(fixture.taskID, using: fixture.store.access()).details?.approvals == [pending])
        try ApprovalFixture.git(fixture.checkout, "update-ref", fixture.sourceRef, pending.request.snapshot.revision)
        try ApprovalFixture.advanceRef(fixture.checkout)
        #expect(throws: ApprovalError.stale) { try fixture.answer(pending.id, .approved) }
        try ApprovalFixture.git(fixture.checkout, "update-ref", fixture.sourceRef, pending.request.snapshot.revision)
        let stale = try fixture.reload()
        let staleRecord = try #require(stale.details?.approvals.first)
        #expect(staleRecord.invalidatedAt != nil && staleRecord.answer == nil)
        #expect(!ApprovalCard(local: staleRecord).isOpen)
        let fresh = try fixture.request(expecting: stale.task.detailReference)
        #expect(fresh.id != pending.id && fresh.answer == nil)
        #expect(try fixture.reload().details?.approvals == [staleRecord, fresh])
    }

    @Test func localApprovalResultEditsInvalidateEvenWhenRevertedBeforeReload() throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        let record = try fixture.reload()
        let result = try #require(record.details?.result)
        try fixture.store.interface.revise(fixture.taskID, expecting: record.task.detailReference, using: fixture.store.access()) {
            $0.result = nil
        }
        let changed = try fixture.store.interface.read(fixture.taskID, using: fixture.store.access())
        try fixture.store.interface.revise(fixture.taskID, expecting: changed.task.detailReference, using: fixture.store.access()) {
            $0.result = result
        }
        #expect(try fixture.reload().details?.approvals.first?.invalidatedAt != nil)
        #expect(throws: ApprovalError.stale) { try fixture.answer(pending.id, .approved) }
    }

    @Test func oversizedAnswerDoesNotBlockAValidRetry() throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        #expect(throws: TaskDetailStoreError.tooLarge) {
            try fixture.answer(pending.id, .rejected(reason: String(repeating: "a", count: 1_200_000)))
        }
        #expect(try fixture.reload().details?.approvals == [pending])
        #expect(try fixture.answer(pending.id, .approved).answer?.decision == .approved)
    }

    @Test func graphOnlyEditsCannotRestoreAnUnansweredRevision() throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        let oldGraph = try fixture.store.graph.load()
        let saved = try fixture.answer(pending.id, .approved)
        #expect(throws: TaskGraphError.invalidGraph) {
            try fixture.store.interface.updateGraph(using: fixture.store.access()) { $0 = oldGraph }
        }
        #expect(try fixture.reload().details?.approvals == [saved])
    }

    @Test func localApprovalRejectsAnAccountRelativeRemote() throws {
        let fixture = try ApprovalFixture()
        try ApprovalFixture.git(fixture.checkout, "config", "remote.origin.url", "fixture@example.invalid:team/repo.git")
        #expect(throws: ApprovalError.snapshotUnavailable) { try fixture.request() }
    }

    @Test(arguments: [false, true])
    func localApprovalInvalidatesWhenOnlySSHLoginChanges(usesURL: Bool) throws {
        let fixture = try ApprovalFixture()
        let originalLogin = "rounds-original-login", changedLogin = "rounds-changed-login"
        let httpsLogin = "rounds-https-login", password = ApprovalFixture.password
        let host = "example.invalid", path = "/team/repo.git"
        let destination = usesURL ? "ssh://\(host)\(path)" : "\(host):\(path)"
        func remoteURL(login: String) -> String {
            usesURL ? "ssh://\(login)@\(host)\(path)" : "\(login)@\(destination)"
        }
        try ApprovalFixture.git(fixture.checkout, "config", "remote.backup.url", "https://%FF\(httpsLogin):%FF\(password)@\(host)\(path)")
        let revision = try #require(fixture.initial.details?.result?.checkedRevisionOrWorkingTree)
        let push = ApprovalAction(intent: .push(sourceRef: fixture.sourceRef, revision: revision, remote: "origin",
                                               urls: [destination], destinationRef: "refs/heads/result"))
        if usesURL {
            try ApprovalFixture.git(fixture.checkout, "config", "remote.origin.url", "ssh://\(originalLogin):\(password)@\(host)\(path)")
            #expect(throws: ApprovalError.snapshotUnavailable) { try fixture.request(actions: [push]) }
        }
        try ApprovalFixture.git(fixture.checkout, "config", "remote.origin.url", remoteURL(login: originalLogin))
        let pending = try fixture.request(actions: [push])
        try ApprovalFixture.git(fixture.checkout, "config", "remote.backup.url", "https://\(httpsLogin):\(password)@\(host)\(path)")
        #expect(try fixture.reload().details?.approvals == [pending])
        let actions = ApprovalCard(local: pending).actions.joined()
        #expect(actions.contains(destination))

        try ApprovalFixture.git(fixture.checkout, "config", "remote.origin.url", remoteURL(login: changedLogin))
        if usesURL { #expect(try fixture.reload().details?.approvals.last?.invalidatedAt != nil) }
        #expect(throws: ApprovalError.stale) { try fixture.answer(pending.id, .approved) }
        let invalidated = try #require(try fixture.reload().details?.approvals.last)
        #expect(invalidated.id == pending.id && invalidated.invalidatedAt != nil && invalidated.answer == nil)
        #expect(!ApprovalCard(local: invalidated).isOpen)

        let saved = try fixture.store.detailData().values.map { String(decoding: $0, as: UTF8.self) }
            + [String(decoding: try fixture.store.graphData(), as: UTF8.self)]
        for credential in [originalLogin, changedLogin, httpsLogin, password] {
            #expect(!actions.contains(credential))
            #expect(saved.allSatisfy { !$0.contains(credential) })
        }
    }

    @Test func concurrentLocalAnswersKeepTheFirstSavedDecision() throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        let interface = fixture.store.interface
        let checkoutTask = fixture.taskID
        let scope = fixture.store.organizationID
        let graph = fixture.store.graph.directory, details = fixture.store.details.directory
        let decisions: [ApprovalDecision] = [.approved, .rejected(reason: "Recheck the result.")]
        let outcomes = OSAllocatedUnfairLock(initialState: [Result<ApprovalRecord, any Error>]())
        DispatchQueue.concurrentPerform(iterations: decisions.count) { index in
            let access = TaskStorageAuthorization(organizationID: scope, graphDirectory: graph, detailDirectory: details,
                                                  allowsGraph: { _, _ in true }, allowsDetails: { _, _, _ in true })
            let outcome = Result {
                try interface.answerApproval(pending.id, for: checkoutTask, decision: decisions[index], using: access) {
                    $0 == checkoutTask && $1 == pending.id && $2 == decisions[index]
                }
            }
            outcomes.withLock { $0.append(outcome) }
        }
        let results = outcomes.withLock { $0 }
        let saved = results.compactMap { try? $0.get() }
        #expect(saved.count == 1)
        #expect(results.contains {
            if case .failure(let error) = $0 {
                return error as? ApprovalError == .alreadyAnswered || error as? TaskGraphError == .changedOnDisk
            }
            return false
        })
        #expect(try fixture.reload().details?.approvals == saved)
    }

    @Test func localApprovalRechecksTheAnnotatedTagObject() throws {
        let fixture = try ApprovalFixture()
        let root = fixture.checkout
        let tag = "refs/tags/result"
        func tagResult(_ message: String) throws -> String {
            try ApprovalFixture.git(root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                                    "tag", "--no-sign", "-f", "-a", "result", "-m", message)
            return try ApprovalFixture.git(root, "rev-parse", tag)
        }
        let first = try tagResult("First tag object")
        let before = try inspectApprovalSnapshot(repository: root, sourceRef: tag, remote: "origin")
        func push(_ revision: String) -> ApprovalAction {
            ApprovalAction(intent: .push(sourceRef: tag, revision: revision, remote: before.remote,
                                         urls: before.pushURLs, destinationRef: tag))
        }
        #expect(before.pushRevision == first)
        #expect(throws: ApprovalError.invalidRequest) { try fixture.request(actions: [push(before.revision)], sourceRef: tag) }
        let pending = try fixture.request(expecting: fixture.reload().task.detailReference, actions: [push(first)], sourceRef: tag)
        let second = try tagResult("Second tag object")
        let after = try inspectApprovalSnapshot(repository: root, sourceRef: tag, remote: "origin")
        #expect(first != second)
        #expect(before.revision == after.revision && after.pushRevision == second)
        #expect(throws: ApprovalError.stale) { try fixture.answer(pending.id, .approved) }
        #expect(try fixture.reload().details?.approvals.last?.invalidatedAt != nil)
    }

    @Test func localApprovalComparesDestinationBytes() throws {
        let fixture = try ApprovalFixture()
        let composed = "https://example.invalid/team/caf\u{e9}.git"
        let decomposed = "https://example.invalid/team/cafe\u{301}.git"
        let config = fixture.checkout.appending(path: ".git/config")
        let original = try Data(contentsOf: config)
        func setPushURL(_ url: String) throws {
            let credentialURL = url.replacingOccurrences(of: "https://", with: "https://fixture:\(ApprovalFixture.password)@")
            try (original + Data("\n[remote \"origin\"]\npushurl = \(credentialURL)\n".utf8)).write(to: config, options: .atomic)
        }
        try setPushURL(composed)
        let revision = try #require(fixture.initial.details?.result?.checkedRevisionOrWorkingTree)
        func push(_ url: String) -> ApprovalAction {
            ApprovalAction(intent: .push(sourceRef: fixture.sourceRef, revision: revision, remote: "origin",
                                         urls: [url], destinationRef: "refs/heads/result"))
        }
        #expect(throws: ApprovalError.invalidRequest) { try fixture.request(actions: [push(decomposed)]) }
        let pending = try fixture.request(expecting: fixture.reload().task.detailReference, actions: [push(composed)])
        #expect(try #require(pending.request.snapshot.pushURLs.first).utf8.elementsEqual(composed.utf8))
        try setPushURL(decomposed)
        #expect(throws: ApprovalError.stale) { try fixture.answer(pending.id, .approved) }
        let invalidated = try fixture.reload()
        #expect(invalidated.details?.approvals.last?.invalidatedAt != nil)

        // A direct branch address passes through the subprocess environment for Git rewrites.
        try (original + Data("\n[branch \"main\"]\npushRemote = \(composed)\n".utf8)).write(to: config, options: .atomic)
        #expect(throws: ApprovalError.snapshotUnavailable) {
            try fixture.request(expecting: invalidated.task.detailReference)
        }
    }

    @Test func localApprovalRejectsInvalidDestinationEncoding() throws {
        let fixture = try ApprovalFixture()
        let config = try FileHandle(forWritingTo: fixture.checkout.appending(path: ".git/config"))
        defer { try? config.close() }
        try config.seekToEnd()
        try config.write(contentsOf: Data("\n[remote \"origin\"]\npushurl = https://example.invalid/".utf8) + Data([0xFF, 0x0A]))
        #expect(throws: ApprovalError.snapshotUnavailable) { try fixture.request() }
    }

    @Test(arguments: [false, true])
    func localApprovalRejectsLocalSymlinkDestinations(fileURL: Bool) throws {
        let fixture = try ApprovalFixture()
        let target = fixture.store.root.appending(path: "target.git")
        let link = fixture.checkout.appending(path: "link.git")
        try ApprovalFixture.git(fixture.store.root, "init", "--bare", target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let destination = fileURL ? link.absoluteString : "./link.git"
        try ApprovalFixture.git(fixture.checkout, "config", "remote.origin.pushurl", destination)
        let revision = try #require(fixture.initial.details?.result?.checkedRevisionOrWorkingTree)
        let push = ApprovalAction(intent: .push(sourceRef: fixture.sourceRef, revision: revision, remote: "origin",
                                               urls: [destination], destinationRef: "refs/heads/result"))
        #expect(throws: ApprovalError.snapshotUnavailable) { try fixture.request(actions: [push]) }
    }

    @Test func localApprovalRejectsCredentialAddressesInFreeText() throws {
        let fixture = try ApprovalFixture()
        let revision = try #require(fixture.initial.details?.result?.checkedRevisionOrWorkingTree)
        let address = "https://fixture:\(ApprovalFixture.password)@example.invalid/path"
        let draft = ApprovalAction(intent: .draftPullRequest(repository: "example.invalid/team/repo", baseRef: "refs/heads/other",
                                                             headRef: fixture.sourceRef, revision: revision,
                                                             draft: ApprovalDraft(title: "Fixture", body: "See [this link](\(address)).")))
        #expect(throws: ApprovalError.credentialAddressInText) { try fixture.request(actions: [draft]) }
        let pending = try fixture.request(expecting: fixture.reload().task.detailReference)
        #expect(throws: ApprovalError.credentialAddressInText) {
            try fixture.answer(pending.id, .rejected(reason: "Review `\(address)` first."))
        }
        let reason = "  Review git@example.invalid and ssh://git@example.invalid/path.\nKeep this line.  "
        let saved = try fixture.answer(pending.id, .rejected(reason: reason))
        #expect(saved.answer?.decision == .rejected(reason: "Review git@example.invalid and ssh://git@example.invalid/path.\nKeep this line."))
    }

    @Test func localApprovalStorageGrantAloneCannotAnswer() throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        #expect(throws: ApprovalError.userAnswerNotAuthorized) {
            try fixture.store.interface.answerApproval(pending.id, for: fixture.taskID, decision: .approved, using: fixture.store.access())
        }
        #expect(throws: ApprovalError.userAnswerNotAuthorized) {
            try fixture.store.interface.answerApproval(pending.id, for: fixture.taskID, decision: .approved, using: fixture.store.access()) {
                $0 == fixture.taskID && $1 == pending.id && $2 == .rejected(reason: "A different answer")
            }
        }
        #expect(try fixture.reload().details?.approvals == [pending])
    }

    @Test(arguments: [false, true])
    func localApprovalSerializesProgressBeforeLinkingAnswer(directRecordWriter: Bool) throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        let record = try fixture.reload()
        let checkoutTask = fixture.taskID, reference = record.task.detailReference
        let graph = fixture.store.graph, detailStore = fixture.store.details, settings = fixture.store.settings
        let organizationID = fixture.store.organizationID
        let progress = TaskProgress(summary: "Competing progress", actor: "Fixture", time: Date())
        var interface = fixture.store.interface
        let writer = interface.writeRecord
        interface.writeRecord = { store, taskID, previous, details, at, identity, holdingLock, grant in
            #expect(throws: TaskGraphError.changedOnDisk) {
                if directRecordWriter {
                    try TaskRecordStore(graph: graph, details: detailStore)
                        .write(taskID: checkoutTask, expecting: reference, assignment: details.assignment, result: details.result,
                               progress: [progress], at: at)
                } else {
                    let access = TaskStorageAuthorization(organizationID: organizationID, graphDirectory: graph.directory,
                                                          detailDirectory: detailStore.directory,
                                                          allowsGraph: { _, _ in true }, allowsDetails: { _, _, _ in true })
                    try TaskInterface(bar: settings).revise(checkoutTask, expecting: reference, using: access, at: at) {
                        $0.progress.append(progress)
                    }
                }
            }
            return try writer(store, taskID, previous, details, at, identity, holdingLock, grant)
        }
        let saved = try fixture.answer(pending.id, .approved, using: interface)
        let current = try fixture.reload()
        #expect(current.details?.approvals == [saved] && current.details?.progress.isEmpty == true)
        try fixture.store.interface.revise(checkoutTask, expecting: current.task.detailReference, using: fixture.store.access()) {
            $0.progress.append(progress)
        }
        #expect(try fixture.reload().details?.approvals == [saved])
    }

    @Test func localApprovalRechecksRemoteOrderPushURLsAndOverrides() throws {
        let fixture = try ApprovalFixture()
        let root = fixture.checkout
        try ApprovalFixture.git(root, "remote", "add", "backup", "https://example.invalid/archive/repo.git")
        let pending = try fixture.request()
        try ApprovalFixture.git(root, "config", "--remove-section", "remote.origin")
        try ApprovalFixture.git(root, "remote", "add", "origin", "https://other-user@example.invalid/team/repo.git")
        #expect(try fixture.reload().details?.approvals == [pending])

        try ApprovalFixture.git(root, "config", "remote.backup.pushurl", "https://example.invalid/archive/other.git")
        let changedPush = try fixture.reload()
        #expect(changedPush.details?.approvals.last?.invalidatedAt != nil)
        let second = try fixture.request(expecting: changedPush.task.detailReference)
        try ApprovalFixture.git(root, "config", "branch.main.pushRemote", "backup")
        let changedOverride = try fixture.reload()
        #expect(changedOverride.details?.approvals.last?.id == second.id)
        #expect(changedOverride.details?.approvals.last?.invalidatedAt != nil)
        let third = try fixture.request(expecting: changedOverride.task.detailReference)
        try ApprovalFixture.git(root, "config", "url.https://example.invalid/changed/.pushInsteadOf", "https://other-user@example.invalid/team/")
        let changedRewrite = try fixture.reload()
        #expect(changedRewrite.details?.approvals.last?.id == third.id)
        #expect(changedRewrite.details?.approvals.last?.invalidatedAt != nil)
    }

    @Test(arguments: [false, true])
    func localApprovalIncompleteSaveRequiresInspectionAfterReload(linked: Bool) throws {
        let fixture = try ApprovalFixture()
        let pending = try fixture.request()
        let before = try fixture.reload()
        var interface = fixture.store.interface
        let writer = interface.writeRecord
        interface.writeRecord = { store, taskID, reference, details, at, identity, holdingLock, grant in
            if linked {
                let outcome = try writer(store, taskID, reference, details, at, identity, holdingLock, grant)
                guard case .saved(let revisionID) = outcome else { return outcome }
                return .graphNeedsInspection(revisionID, .committedNotDurable)
            }
            let orphan = try store.details.write(taskID: taskID, assignment: details.assignment, result: details.result,
                                                progress: details.progress, decisions: details.decisions, approvals: details.approvals,
                                                resultRevisionID: before.details?.resultRevisionID)
            throw TaskRecordLinkError(revisionID: orphan.revisionID, underlyingError: TaskGraphError.changedOnDisk)
        }
        #expect(throws: (any Error).self) { try fixture.answer(pending.id, .approved, using: interface) }
        let stored = try fixture.store.interface.read(fixture.taskID, using: fixture.store.access())
        #expect((stored.task.detailReference != before.task.detailReference) == linked)
        #expect(throws: ApprovalError.needsInspection) { try fixture.reload() }
        #expect(throws: ApprovalError.needsInspection) { try fixture.answer(pending.id, .approved) }
        #expect(throws: ApprovalError.needsInspection) {
            try fixture.store.interface.revise(fixture.taskID, expecting: stored.task.detailReference, using: fixture.store.access()) {
                $0.progress.append(TaskProgress(summary: "Competing progress", actor: "Fixture", time: Date()))
            }
        }
        let after = try fixture.store.interface.read(fixture.taskID, using: fixture.store.access())
        #expect(after.task.detailReference == stored.task.detailReference && after.details == stored.details)
    }

    @Test(arguments: ["missing bar", "malformed settings", "changed remotes", "no owner"])
    func incompleteSetupRejectsEveryWrite(problem: String) throws {
        let f = try Fixture()
        let record = try f.create(values)
        let before = try f.graphData(), detailsBefore = try f.detailData()
        switch problem {
        case "missing bar":
            try FileManager.default.removeItem(at: f.settings.url)
        case "malformed settings":
            try Data("broken settings".utf8).write(to: f.settings.url)
        case "changed remotes":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", f.repository.path, "remote", "add", "origin", "https://example.invalid/bar.git"]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        default:
            try f.settings.update { $0.setOwner(nil, for: f.organizationID) }
        }
        #expect(throws: TaskInterfaceError.storageNotReady) { try f.interface.create(details: values, using: f.access()) }
        #expect(throws: TaskInterfaceError.storageNotReady) {
            try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: f.access()) { $0.result = nil }
        }
        #expect(throws: TaskInterfaceError.storageNotReady) {
            try f.interface.updateGraph(using: f.access()) { try $0.setState(.completed, for: record.task.id) }
        }
        #expect(throws: TaskInterfaceError.storageNotReady) {
            try f.interface.markResultViewed(record.task.id, expecting: record.task.detailReference, using: f.access())
        }
        #expect(try f.graphData() == before)
        #expect(try f.detailData() == detailsBefore)
        if problem == "malformed settings" { #expect(try Data(contentsOf: f.settings.url) == Data("broken settings".utf8)) }
    }

    @Test(arguments: ["missing", "symlink", "permissions"])
    func approvedDestinationIsCheckedAgain(problem: String) throws {
        let f = try Fixture()
        let record = try f.create(values)
        let before = try f.graphData(), detailsBefore = try f.detailData()
        let original = f.root.appending(path: "original")
        if problem == "permissions" {
            #expect(chmod(f.details.directory.path, 0o750) == 0)
        } else {
            try FileManager.default.moveItem(at: f.details.directory, to: original)
            if problem == "symlink" {
                try FileManager.default.createSymbolicLink(at: f.details.directory, withDestinationURL: original)
            }
        }
        #expect(throws: TaskInterfaceError.storageNotReady) { try f.interface.create(details: values, using: f.access()) }
        #expect(throws: TaskInterfaceError.storageNotReady) {
            try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: f.access()) { $0.progress = [] }
        }
        #expect(try f.graphData() == before)
        if problem == "permissions" {
            #expect(try f.detailData() == detailsBefore)
        } else {
            let names = try FileManager.default.contentsOfDirectory(atPath: original.path)
            #expect(Set(names) == Set(detailsBefore.keys))
            for name in names { #expect(try Data(contentsOf: original.appending(path: name)) == detailsBefore[name]) }
        }
    }

    @Test func replacingGraphDirectoryWithIdenticalGraphRejectsDetailLink() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let before = try f.graphData()
        let original = f.root.appending(path: "original-graph")
        let access = f.access(allowsDetails: { _, _, _ in
            do {
                try FileManager.default.moveItem(at: f.graph.directory, to: original)
                try FileManager.default.createDirectory(at: f.graph.directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: original.appending(path: "graph.json"),
                                                 to: f.graph.directory.appending(path: "graph.json"))
                return true
            } catch { Issue.record(error); return false }
        })
        do {
            _ = try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: access) {
                $0.assignment = TaskAssignment(objective: "Revised objective", scope: "Task records", target: "Temporary checkout",
                                               constraints: ["Keep details local"], acceptanceConditions: ["Checks pass"])
            }
            Issue.record("A detail was linked in the replacement graph")
        } catch let error as TaskRecordLinkError {
            #expect(error.underlyingError as? TaskGraphError == .changedOnDisk)
            #expect(try f.details.read(taskID: record.task.id, revisionID: error.revisionID).assignment.objective == "Revised objective")
        }
        #expect(try f.graphData() == before)
        #expect(try Data(contentsOf: original.appending(path: "graph.json")) == before)
    }

    @Test func replacingGraphAfterCreationRejectsDetailLink() throws {
        let f = try Fixture()
        let directory = f.graph.directory
        let original = f.root.appending(path: "original-graph")
        var interface = f.interface
        let writeRecord = interface.writeRecord
        interface.writeRecord = { store, taskID, previous, details, at, identity, holdingLock, authorize in
            try FileManager.default.moveItem(at: directory, to: original)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: original.appending(path: "graph.json"),
                                             to: directory.appending(path: "graph.json"))
            return try writeRecord(store, taskID, previous, details, at, identity, holdingLock, authorize)
        }
        do {
            _ = try interface.create(details: values, using: f.access())
            Issue.record("A created task linked details in the replacement graph")
        } catch let error as TaskCreationError {
            let linkError = try #require(error.underlyingError as? TaskRecordLinkError)
            #expect(linkError.underlyingError as? TaskGraphError == .changedOnDisk)
            #expect(try f.details.read(taskID: error.taskID, revisionID: linkError.revisionID).assignment == assignment)
            #expect(try f.graph.load().tasks.first?.detailReference == .empty)
            #expect(try f.graphData() == Data(contentsOf: original.appending(path: "graph.json")))
        }
    }

    @Test func replacingGraphAfterTimestampAuthorizationRejectsDetailLink() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let requestTime = Date().addingTimeInterval(60)
        let later = requestTime.addingTimeInterval(60)
        let original = f.root.appending(path: "original-graph")
        let access = f.access(allowsGraph: { value, _ in
            guard case .detailLink(let link) = value else { return false }
            if link.updatedAt == later {
                do {
                    try FileManager.default.moveItem(at: f.graph.directory, to: original)
                    try FileManager.default.createDirectory(at: f.graph.directory, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    try FileManager.default.copyItem(at: original.appending(path: "graph.json"),
                                                     to: f.graph.directory.appending(path: "graph.json"))
                } catch { Issue.record(error); return false }
            }
            return true
        }, allowsDetails: { _, _, _ in
            do { try f.graph.update { try $0.setState(.running, for: record.task.id, at: later) }; return true }
            catch { Issue.record(error); return false }
        })
        do {
            _ = try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: access, at: requestTime) {
                $0.progress.append(TaskProgress(summary: "Retain as orphan", actor: "Test", time: requestTime))
            }
            Issue.record("A detail was linked after the graph directory changed")
        } catch let error as TaskRecordLinkError {
            #expect(error.underlyingError as? TaskGraphError == .changedOnDisk)
            #expect(try f.details.read(taskID: record.task.id, revisionID: error.revisionID).progress.count == 1)
        }
        #expect(try f.graph.load().tasks.first?.detailReference == record.task.detailReference)
        #expect(try f.graphData() == Data(contentsOf: original.appending(path: "graph.json")))
    }

    @Test func graphAuthorizationCanReadGraphAndSettings() throws {
        let f = try Fixture()
        let graph = f.graph
        let settings = f.settings
        let access = f.access(allowsGraph: { _, _ in
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                if (try? graph.load()) != nil, (try? settings.load()) != nil { completed.signal() }
            }
            return completed.wait(timeout: .now() + 2) == .success
        })
        #expect(try f.interface.updateGraph(using: access) { _ = try $0.createTask() } == .saved)
    }

    @Test func settingsCallbackCanUpdateGraph() throws {
        let f = try Fixture()
        let interface = f.interface
        let graph = f.graph.directory
        let details = f.details.directory
        let organizationID = f.organizationID
        let completed = DispatchSemaphore(value: 0)
        var completedWhileEditing = false
        try f.settings.update { _ in
            DispatchQueue.global().async {
                let access = TaskStorageAuthorization(organizationID: organizationID, graphDirectory: graph,
                                                      detailDirectory: details, allowsGraph: { _, _ in true },
                                                      allowsDetails: { _, _, _ in true })
                if (try? interface.updateGraph(using: access) { _ = try $0.createTask() }) == .saved {
                    completed.signal()
                }
            }
            completedWhileEditing = completed.wait(timeout: .now() + 2) == .success
        }
        if !completedWhileEditing { _ = completed.wait(timeout: .now() + 5) }
        #expect(completedWhileEditing)
    }

    @Test func concurrentGraphEditRejectsAuthorizedStaleSnapshot() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let graph = f.graph
        var authorizationCalls = 0
        let access = f.access(allowsGraph: { _, _ in
            authorizationCalls += 1
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                if (try? graph.update { try $0.setState(.completed, for: record.task.id) }) == .saved { completed.signal() }
            }
            return completed.wait(timeout: .now() + 2) == .success
        })
        #expect(throws: TaskGraphError.changedOnDisk) {
            try f.interface.updateGraph(using: access) { try $0.setState(.running, for: record.task.id) }
        }
        #expect(authorizationCalls == 1)
        #expect(try f.graph.load().tasks.first?.state == .completed)
    }

    @Test func concurrentSettingsEditRejectsStaleSnapshot() throws {
        let f = try Fixture()
        let settings = f.settings
        let organizationID = f.organizationID
        var calls = 0
        #expect(throws: BarError.changedOnDisk) {
            try settings.update { _ in
                calls += 1
                let completed = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    if (try? settings.update { $0.setOwner(nil, for: organizationID) }) != nil { completed.signal() }
                }
                guard completed.wait(timeout: .now() + 2) == .success else {
                    Issue.record("Concurrent settings update was blocked")
                    throw BarError.changedOnDisk
                }
            }
        }
        #expect(calls == 1)
        #expect(try settings.load().organizations[organizationID]?.owner == nil)
    }

    @Test func replacementGraphDirectoryRejectsStaleSnapshot() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let original = f.root.appending(path: "original-graph")
        let access = f.access(allowsGraph: { _, _ in
            do {
                try FileManager.default.moveItem(at: f.graph.directory, to: original)
                try FileManager.default.createDirectory(at: f.graph.directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.moveItem(at: original.appending(path: "graph.json"),
                                                 to: f.graph.directory.appending(path: "graph.json"))
                return true
            } catch { Issue.record(error); return false }
        })
        #expect(throws: TaskGraphError.changedOnDisk) {
            try f.interface.updateGraph(using: access) { try $0.setState(.running, for: record.task.id) }
        }
        #expect(try f.graph.load().tasks.first?.state == .queued)
    }

    @Test func graphStoreCallbackCanReadGraph() throws {
        let f = try Fixture()
        let graph = f.graph
        try graph.update { _ in
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                if (try? graph.load()) != nil { completed.signal() }
            }
            #expect(completed.wait(timeout: .now() + 2) == .success)
        }
    }

    @Test func organizationBarDoesNotServeOtherOrganizations() throws {
        let f = try Fixture()
        let before = try f.graphData()
        // An unclassified project (nil) and an organization with no bar cannot store tasks.
        for id: UUID? in [UUID(), nil] {
            #expect(throws: TaskInterfaceError.storageNotReady) {
                try f.interface.create(details: values, using: f.access(as: id))
            }
        }
        #expect(try f.graphData() == before)
        #expect(try f.detailData().isEmpty)

        // A second organization with its own ready bar cannot write in the first bar.
        let other = UUID(), otherBar = f.root.appending(path: "other-bar", directoryHint: .isDirectory)
        try Fixture.makeBar(otherBar)
        try f.settings.update {
            $0.setOwner(RemoteOwner("github.com/other"), for: other)
            try $0.setBar(otherBar.path, for: other, projectFolders: [])
        }
        #expect(throws: TaskInterfaceError.destinationMismatch) {
            try f.interface.create(details: values, using: f.access(as: other))
        }
        #expect(try f.graphData() == before)
        let otherGraph = TaskGraphStore(directory: otherBar.appending(path: barGraphFolder, directoryHint: .isDirectory))
        #expect(try otherGraph.initialize() == .saved)
        let outcome = try f.interface.create(details: values, using: f.access(
            as: other, graphDirectory: otherGraph.directory,
            detailDirectory: otherBar.appending(path: barDetailFolder, directoryHint: .isDirectory)))
        guard case .saved = outcome else { Issue.record("The second organization's own bar was rejected"); return }
        #expect(try f.graphData() == before)
        #expect(try f.detailData().isEmpty)
    }

    @Test func exactDestinationAndValueAuthorityAreRequired() throws {
        let f = try Fixture()
        let before = try f.graphData()
        let other = f.root.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        #expect(throws: TaskInterfaceError.destinationMismatch) {
            try f.interface.create(details: values, using: f.access(detailDirectory: other))
        }
        #expect(throws: TaskInterfaceError.destinationMismatch) {
            try f.interface.create(details: values, using: f.access(graphDirectory: other))
        }
        #expect(throws: TaskInterfaceError.graphNotAuthorized) {
            try f.interface.create(details: values, using: f.access(allowsGraph: { values, destination in
                guard case .snapshot(let graph) = values else { Issue.record("Missing graph values"); return false }
                #expect(graph.tasks.count == 1 && graph.tasks[0].state == .queued)
                #expect(destination == f.graph.directory)
                return false
            }))
        }
        #expect(throws: TaskInterfaceError.detailsNotAuthorized) {
            try f.interface.create(details: values, using: f.access(allowsDetails: { taskID, details, destination in
                #expect(details.assignment == assignment)
                #expect(destination == f.details.directory)
                #expect(taskID != f.organizationID)
                return false
            }))
        }
        let record = try f.create(values)
        let linked = try f.graphData(), detailData = try f.detailData()
        #expect(throws: TaskInterfaceError.detailsNotAuthorized) {
            try f.interface.revise(record.task.id, expecting: record.task.detailReference,
                                   using: f.access(allowsDetails: { _, _, _ in false })) { $0.assignment = assignment }
        }
        #expect(throws: TaskInterfaceError.graphNotAuthorized) {
            try f.interface.updateGraph(using: f.access(allowsGraph: { _, _ in false })) {
                try $0.setState(.running, for: record.task.id)
            }
        }
        #expect(linked != before)
        #expect(try f.graphData() == linked && f.detailData() == detailData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    @Test func generatedDetailLinksRequireGraphAuthorityBeforeEitherWrite() throws {
        let f = try Fixture()
        let access = f.access(allowsGraph: { values, _ in
            if case .detailLink = values { return false }
            return true
        })
        let emptyGraph = try f.graphData()
        #expect(throws: TaskInterfaceError.graphNotAuthorized) {
            try f.interface.create(details: values, using: access)
        }
        #expect(try f.graphData() == emptyGraph && f.detailData().isEmpty)
        let record = try f.create(values)
        try f.interface.updateGraph(using: f.access()) { try $0.setState(.completed, for: record.task.id) }
        try f.interface.markResultViewed(record.task.id, expecting: record.task.detailReference, using: f.access())
        let before = try f.graphData(), detailsBefore = try f.detailData()
        let time = Date().addingTimeInterval(60)
        let reviseAccess = f.access(allowsGraph: { values, destination in
            guard case .detailLink(let link) = values else { Issue.record("Missing detail link authority"); return false }
            #expect(destination == f.graph.directory)
            #expect(link == TaskDetailLink(taskID: record.task.id, previous: record.task.detailReference,
                                          resultChanged: true, updatedAt: time))
            return false
        })
        #expect(throws: TaskInterfaceError.graphNotAuthorized) {
            try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: reviseAccess, at: time) {
                $0.result = TaskResult(changedLocations: [], validationOutcomes: [], checkedRevisionOrWorkingTree: "new result",
                                       risks: [], blockers: [])
            }
        }
        #expect(try f.graphData() == before && f.detailData() == detailsBefore)
    }

    @Test func withdrawalDuringAuthorizationRejectsBeforePublication() throws {
        let f = try Fixture()
        let before = try f.graphData()
        let access = f.access(allowsDetails: { _, _, _ in
            do { try f.settings.update { $0.setOwner(nil, for: f.organizationID) } }
            catch { Issue.record(error); return false }
            return true
        })
        #expect(throws: TaskInterfaceError.storageNotReady) { try f.interface.create(details: values, using: access) }
        #expect(try f.graphData() == before)
        #expect(try f.detailData().isEmpty)
    }

    @Test func missingGraphNeverInitializesOrRemovesRecoveryEvidence() throws {
        let f = try Fixture(initializeGraph: false)
        let evidence = f.graph.directory.appending(path: ".graph-recovery.tmp")
        try Data("recovery evidence".utf8).write(to: evidence)
        let taskID = UUID()
        #expect(throws: TaskGraphError.missingGraph) { try f.interface.create(details: values, using: f.access()) }
        #expect(throws: TaskGraphError.missingGraph) { try f.interface.read(taskID, using: f.access()) }
        #expect(throws: TaskGraphError.missingGraph) {
            try f.interface.revise(taskID, expecting: .empty, using: f.access()) { $0.result = nil }
        }
        #expect(throws: TaskGraphError.missingGraph) { try f.interface.updateGraph(using: f.access()) { _ = try $0.createTask() } }
        #expect(!FileManager.default.fileExists(atPath: f.graph.directory.appending(path: "graph.json").path))
        #expect(try Data(contentsOf: evidence) == Data("recovery evidence".utf8))
        #expect(try f.detailData().isEmpty)
    }

    @Test func unknownTaskAndStaleReferenceDoNotPublish() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let before = try f.graphData(), detailsBefore = try f.detailData()
        let unknown = UUID()
        #expect(throws: TaskGraphError.unknownTask) { try f.interface.read(unknown, using: f.access()) }
        #expect(throws: TaskGraphError.unknownTask) {
            try f.interface.revise(unknown, expecting: .empty, using: f.access()) { $0.result = nil }
        }
        #expect(throws: TaskGraphError.unknownTask) {
            try f.interface.markResultViewed(unknown, expecting: .empty, using: f.access())
        }
        #expect(throws: TaskGraphError.changedOnDisk) {
            try f.interface.revise(record.task.id, expecting: .empty, using: f.access()) { $0.result = nil }
        }
        #expect(try f.graphData() == before && f.detailData() == detailsBefore)
    }

    @Test func failedCreationReportsTheTaskWithoutRecreatingDetails() throws {
        let f = try Fixture()
        let large = TaskAssignment(objective: String(repeating: "x", count: 1_048_577), scope: "", target: "",
                                   constraints: [], acceptanceConditions: [])
        do {
            _ = try f.interface.create(details: TaskDetails(assignment: large), using: f.access())
            Issue.record("An oversized revision was accepted")
        } catch let error as TaskCreationError {
            #expect(error.underlyingError as? TaskDetailStoreError == .tooLarge)
            let record = try f.interface.read(error.taskID, using: f.access())
            #expect(record.task.state == .queued && record.task.detailReference == .empty && record.details == nil)
            #expect(try f.graph.load().tasks.count == 1)
            #expect(throws: TaskDetailStoreError.missingRevision) {
                try f.interface.revise(error.taskID, expecting: .empty, using: f.access()) { $0.assignment = assignment }
            }
        }
        #expect(try f.detailData().isEmpty)
    }

    @Test func uncertainInitialGraphWriteRetainsTheTaskIdentifier() throws {
        let f = try Fixture()
        var interface = f.interface
        interface.writeGraph = { store, graph, snapshot, details in
            let outcome = try store.update(graph, expecting: snapshot, commit: { try details.withPublicationApproval($0) })
            #expect(outcome == .saved)
            throw TaskGraphError.replacementUncertain
        }
        do {
            _ = try interface.create(details: values, using: f.access())
            Issue.record("An uncertain graph write was reported as saved")
        } catch let error as TaskCreationError {
            #expect(error.underlyingError as? TaskGraphError == .replacementUncertain)
            #expect(try f.graph.load().tasks.map(\.id) == [error.taskID])
            #expect(try f.interface.read(error.taskID, using: f.access()).task.detailReference == .empty)
        }
        #expect(try f.detailData().isEmpty)
    }

    @Test(arguments: [TaskGraphWriteResult.committedNotDurable, .committedIdentityChanged,
                      .committedNotDurableAndIdentityChanged])
    func initialGraphInspectionDoesNotPublishDetails(status: TaskGraphWriteResult) throws {
        let f = try Fixture()
        var interface = f.interface
        interface.writeGraph = { store, graph, snapshot, details in
            let outcome = try store.update(graph, expecting: snapshot, commit: { try details.withPublicationApproval($0) })
            #expect(outcome == .saved)
            return status
        }
        let outcome = try interface.create(details: values, using: f.access())
        guard case .graphNeedsInspection(let taskID, let actual) = outcome else {
            Issue.record("An uncertain graph write was reported as saved"); return
        }
        #expect(try actual == status && f.graph.load().tasks.map(\.id) == [taskID])
        #expect(try f.detailData().isEmpty)
    }

    @Test(arguments: [TaskDetailDurability.publishedNotDurable, .publishedIdentityChanged,
                      .publishedNotDurableAndIdentityChanged])
    func detailInspectionRetainsThePublishedRevision(status: TaskDetailDurability) throws {
        let f = try Fixture()
        var interface = f.interface
        interface.writeRecord = { store, taskID, _, details, _, _, _, _ in
            let published = try store.details.write(taskID: taskID, assignment: details.assignment,
                                                    result: details.result, progress: details.progress, decisions: details.decisions)
            #expect(published.durability == .saved)
            return .detailNeedsInspection(TaskDetailWriteResult(revisionID: published.revisionID, durability: status))
        }
        let outcome = try interface.create(details: values, using: f.access())
        guard case .detailsNeedInspection(let taskID, .detailNeedsInspection(let publication)) = outcome else {
            Issue.record("An uncertain detail publication was reported as saved"); return
        }
        #expect(publication.durability == status)
        #expect(try f.details.read(taskID: taskID, revisionID: publication.revisionID).assignment == assignment)
        #expect(try f.interface.read(taskID, using: f.access()).task.detailReference == .empty)
        #expect(try f.detailData().count == 1)
        let record = try f.create(values)
        let revised = try interface.revise(record.task.id, expecting: record.task.detailReference, using: f.access()) {
            $0.progress.append(TaskProgress(summary: "Needs inspection", actor: "Test", time: .distantPast))
        }
        guard case .detailNeedsInspection(let revision) = revised else { Issue.record("Inspection outcome was lost"); return }
        #expect(revision.durability == status && revision.revisionID != record.details?.revisionID)
        #expect(try f.details.read(taskID: record.task.id, revisionID: revision.revisionID).progress.first?.summary == "Needs inspection")
        #expect(try f.interface.read(record.task.id, using: f.access()).task.detailReference == record.task.detailReference)
        #expect(try f.detailData().count == 3)
    }

    @Test(arguments: [TaskGraphWriteResult.committedNotDurable, .committedIdentityChanged,
                      .committedNotDurableAndIdentityChanged])
    func linkedGraphInspectionRetainsTheRevision(status: TaskGraphWriteResult) throws {
        let f = try Fixture()
        var interface = f.interface
        interface.writeRecord = { store, taskID, previous, details, at, _, _, _ in
            let outcome = try store.write(taskID: taskID, expecting: previous, assignment: details.assignment,
                                          result: details.result, progress: details.progress, decisions: details.decisions, at: at)
            guard case .saved(let revisionID) = outcome else { Issue.record("Fixture write failed"); return outcome }
            return .graphNeedsInspection(revisionID, status)
        }
        let outcome = try interface.create(details: values, using: f.access())
        guard case .detailsNeedInspection(let taskID, .graphNeedsInspection(let revisionID, let actual)) = outcome else {
            Issue.record("An uncertain link was reported as saved"); return
        }
        #expect(actual == status)
        let record = try f.interface.read(taskID, using: f.access())
        #expect(record.task.detailRevisionID == revisionID && record.details?.assignment == assignment)
        let revised = try interface.revise(taskID, expecting: record.task.detailReference, using: f.access()) {
            $0.progress.append(TaskProgress(summary: "Linked but uncertain", actor: "Test", time: .distantPast))
        }
        guard case .graphNeedsInspection(let newRevisionID, let revisedStatus) = revised else {
            Issue.record("Link inspection outcome was lost"); return
        }
        #expect(revisedStatus == status && newRevisionID != revisionID)
        #expect(try f.interface.read(taskID, using: f.access()).task.detailRevisionID == newRevisionID)
        #expect(try f.detailData().count == 2)
    }

    @Test func missingLinkedRevisionIsNotRecreated() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let revision = try #require(record.details)
        let file = f.details.directory.appending(path: "\(record.task.id.uuidString)-\(revision.revisionID.uuidString).json")
        try FileManager.default.removeItem(at: file)
        let before = try f.graphData()
        #expect(throws: TaskDetailStoreError.missingRevision) { try f.interface.read(record.task.id, using: f.access()) }
        #expect(throws: TaskDetailStoreError.missingRevision) {
            try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: f.access()) { $0.result = nil }
        }
        #expect(try f.graphData() == before && f.detailData().isEmpty)
    }

    @Test func concurrentRevisionReportsThePublishedOrphan() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let concurrentResult = TaskResult(changedLocations: ["concurrent"], validationOutcomes: ["Passed"],
                                          checkedRevisionOrWorkingTree: "revision B", risks: [], blockers: [])
        var concurrentReference: TaskDetailReference?
        let access = f.access(allowsDetails: { _, _, _ in
            do {
                let outcome = try TaskRecordStore(graph: f.graph, details: f.details)
                    .write(taskID: record.task.id, expecting: record.task.detailReference,
                           assignment: assignment, result: concurrentResult)
                guard case .saved = outcome else { Issue.record("Concurrent write was not saved"); return false }
                concurrentReference = try f.graph.load().tasks.first?.detailReference
                return true
            } catch { Issue.record(error); return false }
        })
        do {
            _ = try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: access) {
                $0.progress.append(TaskProgress(summary: "Stale edit", actor: "Test", time: .distantPast))
            }
            Issue.record("A concurrent reference was overwritten")
        } catch let error as TaskRecordLinkError {
            #expect(error.underlyingError as? TaskGraphError == .changedOnDisk)
            let orphan = try f.details.read(taskID: record.task.id, revisionID: error.revisionID)
            #expect(orphan.progress.first?.summary == "Stale edit")
            #expect(try f.detailData().count == 3)
        }
        let current = try f.interface.read(record.task.id, using: f.access())
        #expect(current.task.detailReference == concurrentReference)
        #expect(current.details?.result == concurrentResult)
    }

    @Test func replacementAfterReadinessCannotReceiveDetails() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let directory = f.details.directory
        let original = f.root.appending(path: "original")
        var interface = f.interface
        interface.writeRecord = { store, taskID, previous, details, at, _, _, _ in
            try FileManager.default.moveItem(at: directory, to: original)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            return try store.write(taskID: taskID, expecting: previous, assignment: details.assignment,
                                   result: details.result, progress: details.progress, decisions: details.decisions, at: at)
        }
        #expect(throws: (any Error).self) {
            try interface.revise(record.task.id, expecting: record.task.detailReference, using: f.access()) {
                $0.progress.append(TaskProgress(summary: "Private", actor: "Test", time: .distantPast))
            }
        }
        #expect(try f.detailData().isEmpty)
        #expect(try f.graph.load().tasks.first?.detailReference == record.task.detailReference)
    }

    @Test func withdrawalBeforePublicationRejectsDetails() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let settings = f.settings
        let organizationID = f.organizationID
        var interface = f.interface
        interface.writeRecord = { store, taskID, previous, details, at, _, _, _ in
            try settings.update { $0.setOwner(nil, for: organizationID) }
            return try store.write(taskID: taskID, expecting: previous, assignment: details.assignment,
                                   result: details.result, progress: details.progress, decisions: details.decisions, at: at)
        }
        #expect(throws: TaskInterfaceError.storageNotReady) {
            try interface.revise(record.task.id, expecting: record.task.detailReference, using: f.access()) {
                $0.progress.append(TaskProgress(summary: "Private", actor: "Test", time: .distantPast))
            }
        }
        #expect(try f.detailData().count == 1)
        #expect(try f.graph.load().tasks.first?.detailReference == record.task.detailReference)
    }

    @Test func concurrentAcknowledgementKeepsItsTimestampAndAuthorizesLink() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let requestTime = Date().addingTimeInterval(60)
        let later = requestTime.addingTimeInterval(60)
        var grants: [TaskDetailLink] = []
        let access = f.access(allowsGraph: { value, _ in
            guard case .detailLink(let link) = value else { return false }
            grants.append(link)
            return true
        }, allowsDetails: { _, _, _ in
            do {
                try f.graph.update {
                    try $0.setState(.completed, for: record.task.id, at: later)
                    try $0.markResultViewed(record.task.id, expecting: record.task.detailReference, at: later)
                }
                return true
            } catch { Issue.record(error); return false }
        })
        let outcome = try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: access, at: requestTime) {
            $0.progress.append(TaskProgress(summary: "Progress", actor: "Test", time: requestTime))
        }
        guard case .saved = outcome else { Issue.record("Revision was not saved"); return }
        let task = try #require(f.graph.load().tasks.first)
        #expect(task.state == .completed && task.resultViewed && task.updatedAt == later)
        #expect(grants.contains { $0.updatedAt == later })
    }

    @Test func withdrawalAfterPublicationPreventsLink() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let requestTime = Date().addingTimeInterval(60)
        let later = requestTime.addingTimeInterval(60)
        let access = f.access(allowsGraph: { value, _ in
            guard case .detailLink(let link) = value else { return false }
            if link.updatedAt == later {
                do { try f.settings.update { $0.setOwner(nil, for: f.organizationID) } }
                catch { Issue.record(error); return false }
            }
            return true
        }, allowsDetails: { _, _, _ in
            do { try f.graph.update { try $0.setState(.running, for: record.task.id, at: later) }; return true }
            catch { Issue.record(error); return false }
        })
        do {
            _ = try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: access, at: requestTime) {
                $0.progress.append(TaskProgress(summary: "Published before withdrawal", actor: "Test", time: requestTime))
            }
            Issue.record("A revision was linked after withdrawal")
        } catch let error as TaskRecordLinkError {
            #expect(error.underlyingError as? TaskInterfaceError == .storageNotReady)
            #expect(try f.details.read(taskID: record.task.id, revisionID: error.revisionID).progress.count == 1)
        }
        let task = try #require(f.graph.load().tasks.first)
        #expect(task.state == .running && task.updatedAt == later && task.detailReference == record.task.detailReference)
    }

    @Test func authorizesExistingLaterTimestampInsteadOfRequestTime() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let requestTime = Date().addingTimeInterval(60)
        let later = requestTime.addingTimeInterval(60)
        try f.graph.update { try $0.setState(.running, for: record.task.id, at: later) }
        let access = f.access(allowsGraph: { value, _ in
            guard case .detailLink(let link) = value else { return false }
            return link.updatedAt == later
        })
        let outcome = try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: access, at: requestTime) {
            $0.progress.append(TaskProgress(summary: "Progress", actor: "Test", time: requestTime))
        }
        guard case .saved = outcome else { Issue.record("Revision was not saved"); return }
        #expect(try f.graph.load().tasks.first?.updatedAt == later)
    }

    @Test func busySettingsLockLeavesPublishedDetailForInspection() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let requestTime = Date().addingTimeInterval(60)
        let later = requestTime.addingTimeInterval(60)
        var heldLock: Int32 = -1
        defer { if heldLock >= 0 { close(heldLock) } }
        let access = f.access(allowsGraph: { value, _ in
            guard case .detailLink(let link) = value else { return false }
            if link.updatedAt == later {
                heldLock = open(f.settings.url.appendingPathExtension("lock").path, O_RDWR)
                guard heldLock >= 0, flock(heldLock, LOCK_EX | LOCK_NB) == 0 else { return false }
            }
            return true
        }, allowsDetails: { _, _, _ in
            do { try f.graph.update { try $0.setState(.running, for: record.task.id, at: later) }; return true }
            catch { Issue.record(error); return false }
        })
        do {
            _ = try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: access, at: requestTime) {
                $0.progress.append(TaskProgress(summary: "Published before contention", actor: "Test", time: requestTime))
            }
            Issue.record("A link succeeded while settings were locked")
        } catch let error as TaskRecordLinkError {
            #expect(error.underlyingError as? BarError == .changedOnDisk)
            #expect(try f.details.read(taskID: record.task.id, revisionID: error.revisionID).progress.count == 1)
        }
        #expect(try f.graph.load().tasks.first?.detailReference == record.task.detailReference)
    }

    @Test func deniedConcurrentTimestampLeavesGraphUnchanged() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let requestTime = Date().addingTimeInterval(60)
        let later = requestTime.addingTimeInterval(60)
        let access = f.access(allowsGraph: { value, _ in
            guard case .detailLink(let link) = value else { return false }
            return link.updatedAt == requestTime
        }, allowsDetails: { _, _, _ in
            do {
                try f.graph.update {
                    try $0.setState(.completed, for: record.task.id, at: later)
                    try $0.markResultViewed(record.task.id, expecting: record.task.detailReference, at: later)
                }
                return true
            } catch { Issue.record(error); return false }
        })
        do {
            _ = try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: access, at: requestTime) {
                $0.progress.append(TaskProgress(summary: "Progress", actor: "Test", time: requestTime))
            }
            Issue.record("An unauthorized timestamp was linked")
        } catch let error as TaskRecordLinkError {
            #expect(error.underlyingError as? TaskInterfaceError == .graphNotAuthorized)
            #expect(try f.details.read(taskID: record.task.id, revisionID: error.revisionID).progress.count == 1)
        }
        let task = try #require(f.graph.load().tasks.first)
        #expect(task.state == .completed && task.resultViewed && task.updatedAt == later)
        #expect(task.detailReference == record.task.detailReference)
    }

    @Test func linkAuthorityPreservesConcurrentGraphEdits() throws {
        let f = try Fixture()
        let record = try f.create(values)
        let time = Date().addingTimeInterval(60)
        var grants: [TaskDetailLink] = []
        let access = f.access(allowsGraph: { values, _ in
            guard case .detailLink(let link) = values else { Issue.record("Unexpected graph replacement authority"); return false }
            grants.append(link)
            return true
        }, allowsDetails: { _, _, _ in
            do {
                _ = try f.graph.update { try $0.setState(.running, for: record.task.id) }
                return true
            } catch { Issue.record(error); return false }
        })
        let outcome = try f.interface.revise(record.task.id, expecting: record.task.detailReference, using: access, at: time) {
            $0.progress.append(TaskProgress(summary: "Concurrent progress", actor: "Test", time: time))
        }
        guard case .saved(let revisionID) = outcome else { Issue.record("Authorized link was not saved"); return }
        #expect(grants == [TaskDetailLink(taskID: record.task.id, previous: record.task.detailReference,
                                        resultChanged: false, updatedAt: time)])
        let current = try f.interface.read(record.task.id, using: f.access())
        #expect(current.task.state == .running && current.task.detailRevisionID == revisionID)
        #expect(current.task.updatedAt == time && current.details?.progress.first?.summary == "Concurrent progress")
    }

    @Test func graphMutationsPreserveCycleAndCompletionChecks() throws {
        let f = try Fixture()
        let parent = try f.create(values), dependency = try f.create(values)
        let outcome = try f.interface.create(details: values, parentID: parent.task.id, required: true, using: f.access())
        guard case .saved(let childID, _) = outcome else { Issue.record("Child was not saved"); return }
        try f.interface.updateGraph(using: f.access()) { try $0.addDependency(dependency.task.id, to: parent.task.id) }
        let before = try f.graphData(), detailsBefore = try f.detailData()
        #expect(throws: TaskGraphError.invalidGraph) {
            try f.interface.updateGraph(using: f.access()) { try $0.addDependency(parent.task.id, to: childID) }
        }
        #expect(throws: TaskGraphError.invalidGraph) {
            try f.interface.updateGraph(using: f.access()) { try $0.addDependency(parent.task.id, to: dependency.task.id) }
        }
        #expect(throws: TaskGraphError.invalidGraph) {
            try f.interface.updateGraph(using: f.access()) { try $0.setParent(parent.task.id, parentID: childID, required: false) }
        }
        #expect(throws: TaskGraphError.invalidGraph) {
            try f.interface.updateGraph(using: f.access()) { try $0.setState(.completed, for: parent.task.id) }
        }
        #expect(try f.graphData() == before && f.detailData() == detailsBefore)
        try f.interface.updateGraph(using: f.access()) { try $0.setState(.completed, for: childID) }
        #expect(throws: TaskGraphError.invalidGraph) {
            try f.interface.updateGraph(using: f.access()) { try $0.setState(.completed, for: parent.task.id) }
        }
        try f.interface.updateGraph(using: f.access()) {
            try $0.setState(.completed, for: dependency.task.id)
            try $0.setState(.completed, for: parent.task.id)
        }
        let complete = try f.graphData()
        #expect(throws: TaskGraphError.invalidGraph) {
            try f.interface.create(details: values, parentID: parent.task.id, required: true, using: f.access())
        }
        #expect(try f.graphData() == complete && f.detailData() == detailsBefore)
    }

    @Test(arguments: [TaskGraphState.completed, .cancelled])
    func acknowledgementRequiresTerminalStateAndDisplayedReference(terminal: TaskGraphState) throws {
        let f = try Fixture()
        let first = try f.create(values)
        #expect(throws: TaskGraphError.invalidGraph) {
            try f.interface.markResultViewed(first.task.id, expecting: first.task.detailReference, using: f.access())
        }
        try f.interface.updateGraph(using: f.access()) { try $0.setState(terminal, for: first.task.id) }
        try f.interface.markResultViewed(first.task.id, expecting: first.task.detailReference, using: f.access())
        #expect(try f.interface.read(first.task.id, using: f.access()).task.resultViewed)
        try f.interface.revise(first.task.id, expecting: first.task.detailReference, using: f.access()) {
            $0.result = TaskResult(changedLocations: ["Sources/example"], validationOutcomes: ["Passed"],
                                   checkedRevisionOrWorkingTree: "revision C", risks: [], blockers: [])
        }
        #expect(throws: TaskGraphError.changedOnDisk) {
            try f.interface.markResultViewed(first.task.id, expecting: first.task.detailReference, using: f.access())
        }
        let current = try f.interface.read(first.task.id, using: f.access())
        #expect(!current.task.resultViewed && current.task.group() == .yourTurn)
        try f.interface.markResultViewed(first.task.id, expecting: current.task.detailReference, using: f.access())
        #expect(try f.interface.read(first.task.id, using: f.access()).task.resultViewed)
    }

    @Test func createReviseAndReopenPreserveUnchangedDetails() throws {
        let f = try Fixture()
        let result = TaskResult(changedLocations: ["Sources/fixture"], validationOutcomes: ["Passed"],
                                checkedRevisionOrWorkingTree: "revision A", risks: ["Fixture risk"], blockers: [])
        let progress = TaskProgress(summary: "Checked fixture", actor: "Test", time: Date(timeIntervalSince1970: 42))
        let decision = TaskDecision(decision: "Use local records", reason: "Scope", actor: "Test", time: progress.time)
        let original = TaskDetails(assignment: assignment, result: result, progress: [progress], decisions: [decision])
        let first = try f.create(original)
        #expect(first.task.state == .queued && first.task.detailGeneration == 1)
        let revisedAssignment = TaskAssignment(objective: "Revise the fixture", scope: assignment.scope,
                                              target: assignment.target, constraints: assignment.constraints,
                                              acceptanceConditions: assignment.acceptanceConditions)
        let write = try f.interface.revise(first.task.id, expecting: first.task.detailReference, using: f.access()) {
            $0.assignment = revisedAssignment
        }
        guard case .saved(let revisionID) = write else { Issue.record("Revision was not saved"); return }
        let reopened = TaskInterface(bar: BarSettingsStore(url: f.settings.url))
        let current = try reopened.read(first.task.id, using: f.access())
        #expect(current.task.detailRevisionID == revisionID && current.task.detailGeneration == 2)
        #expect(current.details?.assignment == revisedAssignment && current.details?.result == result)
        #expect(current.details?.progress == [progress] && current.details?.decisions == [decision])
        #expect(try f.details.read(taskID: first.task.id, revisionID: #require(first.details).revisionID) == first.details)
        try reopened.revise(first.task.id, expecting: current.task.detailReference, using: f.access()) { $0.result = nil }
        let cleared = try reopened.read(first.task.id, using: f.access())
        #expect(cleared.details?.result == nil && cleared.details?.assignment == revisedAssignment)
        #expect(cleared.details?.progress == [progress] && cleared.details?.decisions == [decision])
        let graphJSON = try String(data: f.graphData(), encoding: .utf8)
        for text in [assignment.objective, revisedAssignment.objective, result.checkedRevisionOrWorkingTree, progress.summary, decision.decision] {
            #expect(graphJSON?.contains(text) == false)
        }
    }
}
