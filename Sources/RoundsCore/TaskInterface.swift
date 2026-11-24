import Foundation

/// Editable detail values. A revision starts with the currently linked values.
public struct TaskDetails: Equatable, Sendable {
    public var assignment: TaskAssignment
    public var result: TaskResult?
    public var progress: [TaskProgress]
    public var decisions: [TaskDecision]
    public fileprivate(set) var approvals: [ApprovalRecord]

    public init(assignment: TaskAssignment, result: TaskResult? = nil,
                progress: [TaskProgress] = [], decisions: [TaskDecision] = []) {
        self.assignment = assignment
        self.result = result
        self.progress = progress
        self.decisions = decisions
        self.approvals = []
    }

    fileprivate init(_ revision: TaskDetailRevision) {
        self.init(assignment: revision.assignment, result: revision.result,
                  progress: revision.progress, decisions: revision.decisions)
        approvals = revision.approvals
    }
}

/// Authorizes one store-generated revision identifier and its reference update.
/// The update increments the generation and can reset viewed status when the result changes.
public struct TaskDetailLink: Equatable, Sendable {
    public let taskID: UUID
    public let previous: TaskDetailReference
    public let resultChanged: Bool
    public let updatedAt: Date
}

/// The values written by a graph edit or by the existing record store's revision link.
/// Link authority applies independently of concurrent state or dependency edits.
public enum TaskGraphValues: Sendable {
    case snapshot(TaskGraph)
    case detailLink(TaskDetailLink)
}

/// Supply authority for this call's graph and detail values at these exact destinations.
/// A detail link grant includes its generated reference, generation, timestamp, and viewed-status reset.
/// Folder readiness and remote acknowledgement cannot supply either authorization.
public struct TaskStorageAuthorization {
    public let organizationID: UUID?
    public let graphDirectory: URL
    public let detailDirectory: URL
    public let allowsGraph: (TaskGraphValues, URL) -> Bool
    public let allowsDetails: (UUID, TaskDetails, URL) -> Bool

    public init(organizationID: UUID?, graphDirectory: URL, detailDirectory: URL,
                allowsGraph: @escaping (TaskGraphValues, URL) -> Bool,
                allowsDetails: @escaping (UUID, TaskDetails, URL) -> Bool) {
        self.organizationID = organizationID
        self.graphDirectory = graphDirectory
        self.detailDirectory = detailDirectory
        self.allowsGraph = allowsGraph
        self.allowsDetails = allowsDetails
    }
}

public struct TaskRecord: Sendable {
    public let task: GraphTask
    public let details: TaskDetailRevision?
}

public enum TaskInterfaceError: Error, Equatable {
    case storageNotReady, detailDestinationMismatch, graphNotAuthorized, detailsNotAuthorized
}

/// The task can remain in the graph. Inspect it before any further action.
public struct TaskCreationError: Error {
    public let taskID: UUID
    public let underlyingError: any Error
}

public enum TaskCreationResult: Equatable, Sendable {
    case saved(taskID: UUID, revisionID: UUID)
    case graphNeedsInspection(taskID: UUID, TaskGraphWriteResult)
    case detailsNeedInspection(taskID: UUID, TaskRecordWriteResult)
}

/// Local record operations only. The caller supplies scope and value authority on every call.
/// Graph setup remains an explicit TaskGraphStore.initialize operation.
public struct TaskInterface: Sendable {
    public let bar: BarSettingsStore

    public init(bar: BarSettingsStore) { self.bar = bar }

    var writeRecord: @Sendable (TaskRecordStore, UUID, TaskDetailReference, TaskDetails, Date, GraphDirectoryIdentity, Bool, (Date) throws -> Void) throws -> TaskRecordWriteResult = {
        try $0.writeAuthorized(taskID: $1, expecting: $2, assignment: $3.assignment, result: $3.result,
                               progress: $3.progress, decisions: $3.decisions, approvals: $3.approvals, at: $4,
                               graphIdentity: .success($5), holdingApprovalLock: $6, authorizeTimestamp: $7)
    }
    var writeGraph: @Sendable (TaskGraphStore, TaskGraph, GraphSnapshot, TaskDetailStore) throws -> TaskGraphWriteResult = { store, graph, snapshot, details in
        try store.update(graph, expecting: snapshot, commit: { try details.withPublicationApproval($0) })
    }

    public func create(details: TaskDetails, parentID: UUID? = nil, required: Bool = false,
                       dependencies: [UUID] = [], using authorization: TaskStorageAuthorization,
                       at: Date = Date()) throws -> TaskCreationResult {
        guard details.approvals.isEmpty else { throw ApprovalError.invalidRequest }
        let stores = try checkedStores(authorization)
        let (originalGraph, snapshot, graphIdentity) = try stores.graph.loadForRecord()
        var graph = originalGraph
        let taskID = try graph.createTask(parentID: parentID, required: required, at: at)
        for dependency in dependencies { try graph.addDependency(dependency, to: taskID) }
        let link = TaskDetailLink(taskID: taskID, previous: .empty, resultChanged: details.result != nil, updatedAt: at)
        try authorize(.snapshot(graph), using: authorization)
        try authorize(.detailLink(link), using: authorization)
        try authorize(details, taskID: taskID, using: authorization)
        let graphWrite: TaskGraphWriteResult
        do {
            graphWrite = try writeGraph(stores.graph, graph, snapshot, stores.details)
        } catch TaskGraphError.replacementUncertain {
            throw TaskCreationError(taskID: taskID, underlyingError: TaskGraphError.replacementUncertain)
        }
        guard graphWrite == .saved else { return .graphNeedsInspection(taskID: taskID, graphWrite) }
        do {
            _ = try checkedStores(authorization)
            let outcome = try writeRecord(stores, taskID, .empty, details, at, graphIdentity, false) { timestamp in
                if timestamp != at {
                    try authorize(.detailLink(TaskDetailLink(taskID: taskID, previous: .empty,
                                                              resultChanged: details.result != nil, updatedAt: timestamp)), using: authorization)
                }
            }
            if case .saved(let revisionID) = outcome { return .saved(taskID: taskID, revisionID: revisionID) }
            return .detailsNeedInspection(taskID: taskID, outcome)
        } catch {
            throw TaskCreationError(taskID: taskID, underlyingError: error)
        }
    }

    public func read(_ taskID: UUID, using authorization: TaskStorageAuthorization) throws -> TaskRecord {
        try read(taskID, using: authorization, expectingDirectory: nil)
    }

    private func read(_ taskID: UUID, using authorization: TaskStorageAuthorization,
                      expectingDirectory identity: GraphDirectoryIdentity?) throws -> TaskRecord {
        let stores = try checkedStores(authorization)
        let graph = try stores.graph.load(expectingDirectory: identity)
        try authorize(.snapshot(graph), using: authorization)
        let record = try read(taskID, from: graph, details: stores.details)
        if let revision = record.details {
            try authorize(TaskDetails(revision), taskID: taskID, using: authorization)
        }
        return record
    }

    @discardableResult
    public func revise(_ taskID: UUID, expecting reference: TaskDetailReference,
                       using authorization: TaskStorageAuthorization, at: Date = Date(),
                       _ edit: (inout TaskDetails) throws -> Void) throws -> TaskRecordWriteResult {
        try revise(taskID, expecting: reference, using: authorization, at: at, approvalLock: nil, edit)
    }

    private func revise(_ taskID: UUID, expecting reference: TaskDetailReference,
                        using authorization: TaskStorageAuthorization, at: Date, approvalLock: (Int32, Int32, GraphDirectoryIdentity)?,
                        _ edit: (inout TaskDetails) throws -> Void) throws -> TaskRecordWriteResult {
        let stores = try checkedStores(authorization)
        let (graph, _, loadedIdentity) = try stores.graph.loadForRecord()
        let graphIdentity = approvalLock?.2 ?? loadedIdentity
        if approvalLock != nil { _ = try stores.graph.load(expectingDirectory: graphIdentity) }
        let task = try task(taskID, in: graph)
        guard task.detailReference == reference else { throw TaskGraphError.changedOnDisk }
        let record = try read(taskID, from: graph, details: stores.details)
        guard let revision = record.details else { throw TaskDetailStoreError.missingRevision }
        var values = TaskDetails(revision)
        try edit(&values)
        if approvalLock == nil { values.approvals = revision.approvals }
        if revision.result != values.result, let last = values.approvals.indices.last { values.approvals[last].invalidate(at: at) }
        let link = TaskDetailLink(taskID: taskID, previous: reference,
                                  resultChanged: revision.result != values.result, updatedAt: max(task.updatedAt, at))
        try ApprovalRecord.validate(values.approvals, taskID: taskID)
        try authorize(.detailLink(link), using: authorization)
        try authorize(values, taskID: taskID, using: authorization)
        _ = try checkedStores(authorization)
        func write(holdingApprovalLock: Bool) throws -> TaskRecordWriteResult {
            try writeRecord(stores, taskID, reference, values, at, graphIdentity, holdingApprovalLock) { timestamp in
                if timestamp != link.updatedAt {
                    try authorize(.detailLink(TaskDetailLink(taskID: taskID, previous: reference,
                                                              resultChanged: revision.result != values.result, updatedAt: timestamp)), using: authorization)
                }
            }
        }
        if approvalLock != nil || (link.resultChanged && revision.approvals.last?.invalidatedAt == nil && !revision.approvals.isEmpty) {
            try stores.details.checkRevisionSize(taskID: taskID, details: values)
            if let (directory, lock, _) = approvalLock {
                return try stores.details.saveApproval(taskID: taskID, in: directory, lock: lock) {
                    try write(holdingApprovalLock: true)
                }
            }
            return try stores.details.withApprovalLock(taskID: taskID, wait: false) { directory, lock in
                guard try stores.graph.load(expectingDirectory: graphIdentity).tasks.first(where: { $0.id == taskID })?.detailReference == reference else {
                    throw TaskGraphError.changedOnDisk
                }
                return try stores.details.saveApproval(taskID: taskID, in: directory, lock: lock) {
                    try write(holdingApprovalLock: true)
                }
            }
        }
        return try write(holdingApprovalLock: false)
    }

    /// Uses the existing graph validation without adding a run-state policy.
    @discardableResult
    public func updateGraph(using authorization: TaskStorageAuthorization,
                            _ edit: (inout TaskGraph) throws -> Void) throws -> TaskGraphWriteResult {
        let stores = try checkedStores(authorization)
        let (originalGraph, snapshot) = try stores.graph.loadForUpdate()
        var graph = originalGraph
        try edit(&graph)
        let references = Dictionary(uniqueKeysWithValues: originalGraph.tasks.map { ($0.id, $0.detailReference) })
        guard graph.tasks.count >= references.count,
              graph.tasks.allSatisfy({ $0.detailReference == (references[$0.id] ?? .empty) }),
              Set(references.keys).isSubset(of: graph.tasks.map(\.id)) else { throw TaskGraphError.invalidGraph }
        try authorize(.snapshot(graph), using: authorization)
        return try writeGraph(stores.graph, graph, snapshot, stores.details)
    }

    @discardableResult
    public func markResultViewed(_ taskID: UUID, expecting reference: TaskDetailReference,
                                 using authorization: TaskStorageAuthorization,
                                 at: Date = Date()) throws -> TaskGraphWriteResult {
        try updateGraph(using: authorization) { graph in
            try graph.markResultViewed(taskID, expecting: reference, at: at)
        }
    }

    private func checkedStores(_ authorization: TaskStorageAuthorization) throws -> TaskRecordStore {
        guard bar.mayStoreTaskDetails(for: authorization.organizationID) else {
            throw TaskInterfaceError.storageNotReady
        }
        let scope = authorization.organizationID.map(BarScope.organization) ?? .unclassified
        guard let directory = bar.taskDetailFolder(for: scope) else { throw TaskInterfaceError.storageNotReady }
        guard directory == authorization.detailDirectory else { throw TaskInterfaceError.detailDestinationMismatch }
        guard let identity = try? bar.load().detailFolders[scope],
              identity.path == directory.path else { throw TaskInterfaceError.storageNotReady }
        return TaskRecordStore(graph: TaskGraphStore(directory: authorization.graphDirectory),
                               details: TaskDetailStore(directory: directory, approvedIdentity: identity,
                                                        bar: bar, scope: scope))
    }

    private func authorize(_ values: TaskGraphValues, using authorization: TaskStorageAuthorization) throws {
        guard authorization.allowsGraph(values, authorization.graphDirectory) else { throw TaskInterfaceError.graphNotAuthorized }
    }

    private func authorize(_ details: TaskDetails, taskID: UUID, using authorization: TaskStorageAuthorization) throws {
        guard authorization.allowsDetails(taskID, details, authorization.detailDirectory) else {
            throw TaskInterfaceError.detailsNotAuthorized
        }
    }

    private func task(_ taskID: UUID, in graph: TaskGraph) throws -> GraphTask {
        guard let task = graph.tasks.first(where: { $0.id == taskID }) else { throw TaskGraphError.unknownTask }
        return task
    }

    private func read(_ taskID: UUID, from graph: TaskGraph, details: TaskDetailStore) throws -> TaskRecord {
        let task = try task(taskID, in: graph)
        let revision = try task.detailRevisionID.map { try details.read(taskID: taskID, revisionID: $0) }
        return TaskRecord(task: task, details: revision)
    }
}

extension TaskInterface {
    /// Only the local host calls this with the exact result, repository and proposed intents.
    public func requestApproval(for taskID: UUID, expecting reference: TaskDetailReference,
                                repositoryID: UUID, repository: URL, sourceRef: String, remote: String,
                                actions: [ApprovalAction], using authorization: TaskStorageAuthorization,
                                harnessBinding: ApprovalHarnessBinding? = nil,
                                verifyBoundTaskEnded: (ApprovalHarnessBinding) throws -> Bool = { _ in false }) throws -> ApprovalRecord {
        try withApprovals(for: taskID, using: authorization) { record, lock in
            guard record.task.detailReference == reference else { throw TaskGraphError.changedOnDisk }
            guard let details = record.details, let result = details.result, let resultRevisionID = details.resultRevisionID else {
                throw ApprovalError.resultMismatch
            }
            guard !details.approvals.contains(where: { $0.execution?.last == .started }) else {
                throw ApprovalError.executionUncertain
            }
            guard details.approvals.last.map({ $0.invalidatedAt != nil }) ?? true else { throw ApprovalError.invalidRequest }
            let bindings = details.approvals.compactMap(\.request.harnessBinding)
            guard !bindings.contains(where: { $0.taskID == harnessBinding?.taskID }),
                  try bindings.last.map(verifyBoundTaskEnded) != false else { throw ApprovalError.boundTaskUnverified }
            guard result.repositoryID == repositoryID, let authorizedFolder = result.repositoryFolder else {
                throw ApprovalError.resultMismatch
            }
            let createdAt = Date()
            let snapshot = try inspectApprovalSnapshot(repository: repository, sourceRef: sourceRef, remote: remote)
            guard result.checkedRevisionOrWorkingTree == snapshot.revision, authorizedFolder == snapshot.folder else {
                throw ApprovalError.resultMismatch
            }
            let request = ApprovalRequest(id: UUID(), taskID: taskID, repositoryID: repositoryID,
                                          organizationID: authorization.organizationID, resultRevisionID: resultRevisionID,
                                          resultDigest: try approvalResultDigest(result), snapshot: snapshot, actions: actions,
                                          createdAt: createdAt, checkedAt: max(createdAt, Date()), harnessBinding: harnessBinding)
            try request.validate(taskID: taskID)
            let approval = ApprovalRecord(request: request)
            try saveApprovals(record, using: authorization, lock: lock, at: request.checkedAt) { $0.append(approval) }
            return approval
        }
    }

    /// Reads only the detail linked from the graph. Rechecks even a previously answered request.
    public func reloadApprovals(for taskID: UUID, using authorization: TaskStorageAuthorization) throws -> TaskRecord {
        try withApprovals(for: taskID, using: authorization) { record, lock in
            if let approval = record.details?.approvals.last, approval.invalidatedAt == nil,
               try !recheck(approval, in: record, using: authorization, lock: lock) {
                return try read(taskID, using: authorization, expectingDirectory: lock.2)
            }
            let current = try read(taskID, using: authorization, expectingDirectory: lock.2)
            guard current.task.detailReference == record.task.detailReference else { throw TaskGraphError.changedOnDisk }
            return current
        }
    }

    /// The first successfully linked answer is final. Answer authority comes from the local card response.
    public func answerApproval(_ requestID: UUID, for taskID: UUID, decision: ApprovalDecision,
                               using authorization: TaskStorageAuthorization,
                               authorizeAnswer: (UUID, UUID, ApprovalDecision) -> Bool = { _, _, _ in false }) throws -> ApprovalRecord {
        let decision = try decision.normalized()
        guard authorizeAnswer(taskID, requestID, decision) else { throw ApprovalError.userAnswerNotAuthorized }
        return try withApprovals(for: taskID, using: authorization) { record, lock in
            guard let approval = record.details?.approvals.first(where: { $0.id == requestID }) else {
                throw ApprovalError.unknownRequest
            }
            guard try recheck(approval, in: record, using: authorization, lock: lock) else { throw ApprovalError.stale }
            guard approval.answer == nil else { throw ApprovalError.alreadyAnswered }
            let at = max(Date(), approval.request.checkedAt)
            let answer = ApprovalAnswer(requestID: requestID, decision: decision, actor: .user, answeredAt: at)
            var saved = approval
            saved.answer = answer
            try saveApprovals(record, using: authorization, lock: lock, at: at) { $0[$0.count - 1] = saved }
            return saved
        }
    }

    /// Reads an answer for the exact call after the same local recheck used for the card.
    public func verifiedApprovalAnswer(_ requestID: UUID, for taskID: UUID, binding: ApprovalHarnessBinding,
                                       using authorization: TaskStorageAuthorization) throws -> ApprovalAnswer? {
        try withApprovals(for: taskID, using: authorization) { record, lock in
            guard let approval = record.details?.approvals.last, approval.id == requestID,
                  approval.request.harnessBinding == binding else { throw ApprovalError.boundTaskUnverified }
            guard try recheck(approval, in: record, using: authorization, lock: lock) else { throw ApprovalError.stale }
            let current = try read(taskID, using: authorization, expectingDirectory: lock.2)
            guard current.task.detailReference == record.task.detailReference else { throw TaskGraphError.changedOnDisk }
            return approval.answer
        }
    }

    /// The trusted executor verifies live permissions, targets and recovery before running the stored action.
    /// Its return confirms the external result. A thrown or interrupted execution stays blocked for inspection.
    func executeApprovedAction(_ actionID: UUID, requestID: UUID, taskID: UUID,
                               using authorization: TaskStorageAuthorization,
                               verify: (ApprovalRequest, ApprovalAction) throws -> Bool,
                               execute: (ApprovalAction) throws -> Void) throws {
        try withApprovals(for: taskID, using: authorization) { record, lock in
            guard let approval = record.details?.approvals.last, approval.id == requestID else {
                throw ApprovalError.unknownRequest
            }
            guard approval.execution?.last != .started else { throw ApprovalError.executionUncertain }
            let next = approval.execution?.count ?? 0
            guard approval.answer?.decision == .approved, approval.request.actions.indices.contains(next) else {
                throw ApprovalError.actionNotApproved
            }
            let action = approval.request.actions[next]
            guard action.id == actionID,
                  try recheck(approval, in: record, using: authorization, lock: lock),
                  try verify(approval.request, action) else { throw ApprovalError.actionNotApproved }

            var started = approval
            started.execution = (approval.execution ?? []) + [.started]
            try saveApprovals(record, using: authorization, lock: lock, at: Date()) { $0[$0.count - 1] = started }
            let current: TaskRecord
            do {
                current = try read(taskID, using: authorization, expectingDirectory: lock.2)
                guard current.details?.approvals.last == started,
                      try recheck(started, in: current, using: authorization, lock: lock),
                      try verify(started.request, action) else { throw ApprovalError.actionNotApproved }
            } catch {
                // No executor ran. Keep any invalidation that the final check saved.
                do {
                    let latest = try read(taskID, using: authorization, expectingDirectory: lock.2)
                    guard let saved = latest.details?.approvals.last, saved.id == requestID,
                          saved.execution == started.execution else { throw ApprovalError.executionUncertain }
                    try saveApprovals(latest, using: authorization, lock: lock, at: Date()) {
                        $0[$0.count - 1].execution = approval.execution
                    }
                } catch { throw ApprovalError.executionUncertain }
                throw error
            }
            do {
                try execute(action)
                var completed = started
                completed.execution?[next] = .completed
                try saveApprovals(current, using: authorization, lock: lock, at: Date()) { $0[$0.count - 1] = completed }
            } catch {
                throw ApprovalError.executionUncertain
            }
        }
    }

    private func withApprovals<T>(for taskID: UUID, using authorization: TaskStorageAuthorization,
                                  _ body: (TaskRecord, (Int32, Int32, GraphDirectoryIdentity)) throws -> T) throws -> T {
        let stores = try checkedStores(authorization)
        let (graph, _, identity) = try stores.graph.loadForRecord()
        try authorize(.snapshot(graph), using: authorization)
        let first = try read(taskID, from: graph, details: stores.details)
        if let revision = first.details { try authorize(TaskDetails(revision), taskID: taskID, using: authorization) }
        return try stores.details.withApprovalLock(taskID: taskID, wait: false) { directory, lock in
            let graph = try stores.graph.load(expectingDirectory: identity)
            try authorize(.snapshot(graph), using: authorization)
            let record = try read(taskID, from: graph, details: stores.details)
            if let revision = record.details { try authorize(TaskDetails(revision), taskID: taskID, using: authorization) }
            try stores.details.checkApprovalDirectory(directory)
            let result = try body(record, (directory, lock, identity))
            _ = try stores.graph.load(expectingDirectory: identity)
            try stores.details.checkApprovalDirectory(directory)
            return result
        }
    }

    private func recheck(_ approval: ApprovalRecord, in record: TaskRecord, using authorization: TaskStorageAuthorization,
                         lock: (Int32, Int32, GraphDirectoryIdentity)) throws -> Bool {
        guard approval.invalidatedAt == nil else { return false }
        let request = approval.request
        guard request.organizationID == authorization.organizationID else { throw ApprovalError.invalidRequest }
        let original = request.snapshot
        let resultMatches = try record.details?.resultRevisionID == request.resultRevisionID &&
            record.details?.result.map(approvalResultDigest) == request.resultDigest &&
            record.details?.result?.repositoryID == request.repositoryID &&
            record.details?.result?.repositoryFolder == original.folder
        let repository = URL(fileURLWithPath: original.folder.path, isDirectory: true)
        guard let folder = FolderIdentity.current(original.folder.path) else { throw ApprovalError.snapshotUnavailable }
        let snapshotMatches = try resultMatches && folder == original.folder &&
            inspectApprovalSnapshot(repository: repository, sourceRef: original.sourceRef, remote: original.remote) == original
        guard snapshotMatches else {
            let at = Date()
            try saveApprovals(record, using: authorization, lock: lock, at: at) { $0[$0.count - 1].invalidate(at: at) }
            return false
        }
        return true
    }

    private func saveApprovals(_ record: TaskRecord, using authorization: TaskStorageAuthorization,
                               lock: (Int32, Int32, GraphDirectoryIdentity), at: Date, _ edit: (inout [ApprovalRecord]) -> Void) throws {
        _ = try revise(record.task.id, expecting: record.task.detailReference, using: authorization, at: at, approvalLock: lock) {
            edit(&$0.approvals)
        }
    }
}
