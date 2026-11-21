import Foundation

/// Editable detail values. A revision starts with the currently linked values.
public struct TaskDetails: Equatable, Sendable {
    public var assignment: TaskAssignment
    public var result: TaskResult?
    public var progress: [TaskProgress]
    public var decisions: [TaskDecision]

    public init(assignment: TaskAssignment, result: TaskResult? = nil,
                progress: [TaskProgress] = [], decisions: [TaskDecision] = []) {
        self.assignment = assignment
        self.result = result
        self.progress = progress
        self.decisions = decisions
    }

    fileprivate init(_ revision: TaskDetailRevision) {
        self.init(assignment: revision.assignment, result: revision.result,
                  progress: revision.progress, decisions: revision.decisions)
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
    public let workspace: WorkspaceSettingsStore

    public init(workspace: WorkspaceSettingsStore) { self.workspace = workspace }

    var writeRecord: @Sendable (TaskRecordStore, UUID, TaskDetailReference, TaskDetails, Date) throws -> TaskRecordWriteResult = {
        try $0.write(taskID: $1, expecting: $2, assignment: $3.assignment, result: $3.result,
                     progress: $3.progress, decisions: $3.decisions, at: $4)
    }
    var writeGraph: @Sendable (TaskGraphStore, (inout TaskGraph) throws -> Void) throws -> TaskGraphWriteResult = {
        try $0.update($1)
    }

    public func create(details: TaskDetails, parentID: UUID? = nil, required: Bool = false,
                       dependencies: [UUID] = [], using authorization: TaskStorageAuthorization,
                       at: Date = Date()) throws -> TaskCreationResult {
        let stores = try checkedStores(authorization)
        var taskID = UUID()
        let graphWrite: TaskGraphWriteResult
        do {
            graphWrite = try writeGraph(stores.graph) { graph in
                taskID = try graph.createTask(parentID: parentID, required: required, at: at)
                for dependency in dependencies { try graph.addDependency(dependency, to: taskID) }
                let link = TaskDetailLink(taskID: taskID, previous: .empty, resultChanged: details.result != nil, updatedAt: at)
                try authorize(.snapshot(graph), using: authorization)
                try authorize(.detailLink(link), using: authorization)
                try authorize(details, taskID: taskID, using: authorization)
                _ = try checkedStores(authorization)
            }
        } catch TaskGraphError.replacementUncertain {
            throw TaskCreationError(taskID: taskID, underlyingError: TaskGraphError.replacementUncertain)
        }
        guard graphWrite == .saved else { return .graphNeedsInspection(taskID: taskID, graphWrite) }
        do {
            _ = try checkedStores(authorization)
            let outcome = try writeRecord(stores, taskID, .empty, details, at)
            if case .saved(let revisionID) = outcome { return .saved(taskID: taskID, revisionID: revisionID) }
            return .detailsNeedInspection(taskID: taskID, outcome)
        } catch {
            throw TaskCreationError(taskID: taskID, underlyingError: error)
        }
    }

    public func read(_ taskID: UUID, using authorization: TaskStorageAuthorization) throws -> TaskRecord {
        let stores = try checkedStores(authorization)
        let graph = try stores.graph.load()
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
        let stores = try checkedStores(authorization)
        let graph = try stores.graph.load()
        let task = try task(taskID, in: graph)
        guard task.detailReference == reference else { throw TaskGraphError.changedOnDisk }
        let record = try read(taskID, from: graph, details: stores.details)
        guard let revision = record.details else { throw TaskDetailStoreError.missingRevision }
        var values = TaskDetails(revision)
        try edit(&values)
        let link = TaskDetailLink(taskID: taskID, previous: reference,
                                  resultChanged: revision.result != values.result, updatedAt: at)
        try authorize(.detailLink(link), using: authorization)
        try authorize(values, taskID: taskID, using: authorization)
        _ = try checkedStores(authorization)
        return try writeRecord(stores, taskID, reference, values, at)
    }

    /// Uses the existing graph validation without adding a run-state policy.
    @discardableResult
    public func updateGraph(using authorization: TaskStorageAuthorization,
                            _ edit: (inout TaskGraph) throws -> Void) throws -> TaskGraphWriteResult {
        let stores = try checkedStores(authorization)
        return try writeGraph(stores.graph) { graph in
            try edit(&graph)
            try authorize(.snapshot(graph), using: authorization)
            _ = try checkedStores(authorization)
        }
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
        guard workspace.mayStoreTaskDetails(for: authorization.organizationID) else {
            throw TaskInterfaceError.storageNotReady
        }
        let scope = authorization.organizationID.map(WorkspaceScope.organization) ?? .unclassified
        guard let directory = workspace.taskDetailFolder(for: scope) else { throw TaskInterfaceError.storageNotReady }
        guard directory == authorization.detailDirectory else { throw TaskInterfaceError.detailDestinationMismatch }
        return TaskRecordStore(graph: TaskGraphStore(directory: authorization.graphDirectory),
                               details: TaskDetailStore(directory: directory))
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
