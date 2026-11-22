import Foundation

/// The revision remains on disk when linking fails. Inspect both stores before retrying.
public struct TaskRecordLinkError: Error {
    public let revisionID: UUID
    public let underlyingError: any Error
}

public enum TaskRecordWriteResult: Equatable, Sendable {
    case saved(UUID)
    case detailNeedsInspection(TaskDetailWriteResult)
    case graphNeedsInspection(UUID, TaskGraphWriteResult)
}

/// The caller must authorize the graph and detail destinations separately for every value.
/// Publish the immutable detail first. A crash or failed graph update can leave an orphan;
/// neither store removes it. This type does not authorize storage, dispatch, or approval.
/// The public write rejects a link when the existing task time is later than its authorized time.
public struct TaskRecordStore: Sendable {
    public let graph: TaskGraphStore
    public let details: TaskDetailStore

    public init(graph: TaskGraphStore, details: TaskDetailStore) {
        self.graph = graph
        self.details = details
    }

    @discardableResult
    public func write(taskID: UUID, expecting previous: TaskDetailReference, assignment: TaskAssignment,
                      result: TaskResult? = nil, progress: [TaskProgress] = [],
                      decisions: [TaskDecision] = [], at: Date = Date()) throws -> TaskRecordWriteResult {
        try writeAuthorized(taskID: taskID, expecting: previous, assignment: assignment, result: result,
                            progress: progress, decisions: decisions, approvals: nil, at: at,
                            graphIdentity: Result { try graph.pinDirectory() }, authorizeTimestamp: { timestamp in
            guard timestamp == at else { throw TaskGraphError.changedOnDisk }
        })
    }

    func writeAuthorized(taskID: UUID, expecting previous: TaskDetailReference, assignment: TaskAssignment,
                         result: TaskResult?, progress: [TaskProgress], decisions: [TaskDecision], approvals: [ApprovalRecord]?, at: Date,
                         graphIdentity: Result<GraphDirectoryIdentity, any Error>, holdingApprovalLock: Bool = false,
                         authorizeTimestamp: (Date) throws -> Void) throws -> TaskRecordWriteResult {
        if previous != .empty && !holdingApprovalLock {
            return try details.withApprovalLock(taskID: taskID, wait: false) { directory, lock in
                let original = Result { try previous.revisionID.map { try details.read(taskID: taskID, revisionID: $0) } }
                if let prior = try? original.get(), prior.result != result,
                   prior.approvals.last.map({ $0.invalidatedAt == nil }) == true {
                    var nextApprovals = approvals ?? prior.approvals
                    if let last = nextApprovals.indices.last { nextApprovals[last].invalidate(at: at) }
                    try details.checkRevisionSize(taskID: taskID, assignment: assignment, result: result,
                                                  progress: progress, decisions: decisions, approvals: nextApprovals)
                    return try details.saveApproval(taskID: taskID, in: directory, lock: lock) {
                        try writeLocked(taskID: taskID, expecting: previous, assignment: assignment, result: result,
                                        progress: progress, decisions: decisions, approvals: approvals, at: at,
                                        graphIdentity: graphIdentity, original: original, authorizeTimestamp: authorizeTimestamp)
                    }
                }
                return try writeLocked(taskID: taskID, expecting: previous, assignment: assignment, result: result,
                                       progress: progress, decisions: decisions, approvals: approvals, at: at,
                                       graphIdentity: graphIdentity, original: original, authorizeTimestamp: authorizeTimestamp)
            }
        }
        return try writeLocked(taskID: taskID, expecting: previous, assignment: assignment, result: result,
                               progress: progress, decisions: decisions, approvals: approvals, at: at,
                               graphIdentity: graphIdentity, authorizeTimestamp: authorizeTimestamp)
    }

    private func writeLocked(taskID: UUID, expecting previous: TaskDetailReference, assignment: TaskAssignment,
                             result: TaskResult?, progress: [TaskProgress], decisions: [TaskDecision], approvals: [ApprovalRecord]?, at: Date,
                             graphIdentity: Result<GraphDirectoryIdentity, any Error>,
                             original: Result<TaskDetailRevision?, any Error>? = nil,
                             authorizeTimestamp: (Date) throws -> Void) throws -> TaskRecordWriteResult {
        let original = original ?? Result { try previous.revisionID.map { try details.read(taskID: taskID, revisionID: $0) } }
        let prior = try? original.get()
        let resultChanged = prior?.result != result
        var nextApprovals = approvals ?? prior?.approvals ?? []
        if resultChanged, let last = nextApprovals.indices.last { nextApprovals[last].invalidate(at: at) }
        let detail = try details.write(taskID: taskID, assignment: assignment, result: result,
                                       progress: progress, decisions: decisions, approvals: nextApprovals,
                                       resultRevisionID: resultChanged ? nil : prior?.resultRevisionID)
        guard detail.durability == .saved else { return .detailNeedsInspection(detail) }
        let revisionID = detail.revisionID
        do {
            let identity = try graphIdentity.get()
            let snapshot = try graph.load(expectingDirectory: identity)
            guard let current = snapshot.tasks.first(where: { $0.id == taskID }) else { throw TaskGraphError.unknownTask }
            guard current.detailReference == previous else { throw TaskGraphError.changedOnDisk }
            _ = try original.get()
            let timestamp = max(current.updatedAt, at)
            try authorizeTimestamp(timestamp)
            let outcome = try graph.update({ graph in
                guard let task = graph.tasks.first(where: { $0.id == taskID }) else { throw TaskGraphError.unknownTask }
                guard task.detailReference == previous else { throw TaskGraphError.changedOnDisk }
                guard max(task.updatedAt, at) == timestamp else { throw TaskGraphError.changedOnDisk }
                try graph.setDetailRevision(revisionID, for: taskID, expecting: previous,
                                            resultChanged: resultChanged, at: at)
            }, expectingDirectory: identity, commit: { try details.withPublicationApproval($0) })
            switch outcome {
            case .saved: return .saved(revisionID)
            case .committedNotDurable, .committedIdentityChanged, .committedNotDurableAndIdentityChanged:
                return .graphNeedsInspection(revisionID, outcome)
            }
        } catch {
            throw TaskRecordLinkError(revisionID: revisionID, underlyingError: error)
        }
    }
}
