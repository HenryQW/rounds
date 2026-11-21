import Darwin
import Foundation
import Testing
@testable import RoundsCore

@Suite(.serialized) struct TaskInterfaceTests {
    private final class Fixture {
        let root: URL
        let repository: URL
        let graph: TaskGraphStore
        let details: TaskDetailStore
        let settings: WorkspaceSettingsStore
        let organizationID = UUID()
        var interface: TaskInterface { TaskInterface(workspace: settings) }

        init(initializeGraph: Bool = true) throws {
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appending(path: "task-interface-\(UUID().uuidString)")
            repository = root.appending(path: "workspace", directoryHint: .isDirectory)
            graph = TaskGraphStore(directory: root.appending(path: "graph", directoryHint: .isDirectory))
            details = TaskDetailStore(directory: root.appending(path: "details", directoryHint: .isDirectory))
            settings = WorkspaceSettingsStore(url: root.appending(path: "settings.json"))
            for directory in [root, repository, graph.directory, details.directory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try createWorkspaceRepository(in: repository.path, name: "Test workspace")
            try settings.update {
                try $0.setWorkspace(repository.path)
                try $0.approveDetailFolder(details.directory.path, for: .organization(organizationID),
                                          repositoryRoot: repository.path)
            }
            if initializeGraph { #expect(try graph.initialize() == .saved) }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func access(scope: WorkspaceScope? = nil, graphDirectory: URL? = nil, detailDirectory: URL? = nil,
                    allowsGraph: @escaping (TaskGraphValues, URL) -> Bool = { _, _ in true },
                    allowsDetails: @escaping (UUID, TaskDetails, URL) -> Bool = { _, _, _ in true }) -> TaskStorageAuthorization {
            let id: UUID?
            switch scope ?? .organization(organizationID) {
            case .organization(let organization): id = organization
            case .unclassified: id = nil
            }
            return TaskStorageAuthorization(organizationID: id, graphDirectory: graphDirectory ?? graph.directory,
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
            return try Dictionary(uniqueKeysWithValues: names.map {
                ($0, try Data(contentsOf: details.directory.appending(path: $0)))
            })
        }
    }

    private var assignment: TaskAssignment {
        TaskAssignment(objective: "Build the local fixture", scope: "Task records", target: "Temporary checkout",
                       constraints: ["Keep details local"], acceptanceConditions: ["Checks pass"])
    }

    private var values: TaskDetails { TaskDetails(assignment: assignment) }

    @Test(arguments: ["missing workspace", "malformed settings", "changed remotes", "absent approval"])
    func incompleteSetupRejectsEveryWrite(problem: String) throws {
        let f = try Fixture()
        let record = try f.create(values)
        let before = try f.graphData(), detailsBefore = try f.detailData()
        switch problem {
        case "missing workspace":
            try FileManager.default.removeItem(at: f.settings.url)
        case "malformed settings":
            try Data("broken settings".utf8).write(to: f.settings.url)
        case "changed remotes":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", f.repository.path, "remote", "add", "origin", "https://example.invalid/workspace.git"]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        default:
            try f.settings.update { $0.withdrawApproval(for: .organization(f.organizationID)) }
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

    @Test(arguments: ["missing", "replaced", "symlink", "permissions"])
    func approvedDestinationIsCheckedAgain(problem: String) throws {
        let f = try Fixture()
        let record = try f.create(values)
        let before = try f.graphData(), detailsBefore = try f.detailData()
        let original = f.root.appending(path: "original")
        if problem == "permissions" {
            #expect(chmod(f.details.directory.path, 0o750) == 0)
        } else {
            try FileManager.default.moveItem(at: f.details.directory, to: original)
            if problem == "replaced" {
                try FileManager.default.createDirectory(at: f.details.directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } else if problem == "symlink" {
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
            if problem == "replaced" { #expect(try f.detailData().isEmpty) }
        }
    }

    @Test func organizationApprovalDoesNotAuthorizeOtherScopes() throws {
        let f = try Fixture()
        let before = try f.graphData()
        for scope: WorkspaceScope in [.organization(UUID()), .unclassified] {
            #expect(throws: TaskInterfaceError.storageNotReady) {
                try f.interface.create(details: values, using: f.access(scope: scope))
            }
        }
        #expect(try f.graphData() == before)
        #expect(try f.detailData().isEmpty)
        _ = try f.create(values)
        try f.settings.update {
            try $0.approveDetailFolder(f.details.directory.path, for: .unclassified, repositoryRoot: f.repository.path)
        }
        let outcome = try f.interface.create(details: values, using: f.access(scope: .unclassified))
        guard case .saved = outcome else { Issue.record("Explicit unclassified approval was rejected"); return }
    }

    @Test func exactDestinationAndValueAuthorityAreRequired() throws {
        let f = try Fixture()
        let before = try f.graphData()
        let other = f.root.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        #expect(throws: TaskInterfaceError.detailDestinationMismatch) {
            try f.interface.create(details: values, using: f.access(detailDirectory: other))
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
            do { try f.settings.update { $0.withdrawApproval(for: .organization(f.organizationID)) } }
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
        interface.writeGraph = { store, edit in
            let outcome = try store.update(edit)
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
        interface.writeGraph = { store, edit in
            let outcome = try store.update(edit)
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
        interface.writeRecord = { store, taskID, _, details, _, _ in
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
        interface.writeRecord = { store, taskID, previous, details, at, _ in
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
        interface.writeRecord = { store, taskID, previous, details, at, _ in
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
        let scope = WorkspaceScope.organization(f.organizationID)
        var interface = f.interface
        interface.writeRecord = { store, taskID, previous, details, at, _ in
            try settings.update { $0.withdrawApproval(for: scope) }
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
                do { try f.settings.update { $0.withdrawApproval(for: .organization(f.organizationID)) } }
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
            #expect(error.underlyingError as? WorkspaceError == .changedOnDisk)
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
        let reopened = TaskInterface(workspace: WorkspaceSettingsStore(url: f.settings.url))
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
