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
                            progress: progress, decisions: decisions, at: at, authorizeTimestamp: { timestamp in
            guard timestamp == at else { throw TaskGraphError.changedOnDisk }
        })
    }

    func writeAuthorized(taskID: UUID, expecting previous: TaskDetailReference, assignment: TaskAssignment,
                         result: TaskResult?, progress: [TaskProgress], decisions: [TaskDecision], at: Date,
                         authorizeTimestamp: (Date) throws -> Void) throws -> TaskRecordWriteResult {
        let detail = try details.write(taskID: taskID, assignment: assignment, result: result,
                                       progress: progress, decisions: decisions)
        guard detail.durability == .saved else { return .detailNeedsInspection(detail) }
        let revisionID = detail.revisionID
        do {
            let snapshot = try graph.load()
            guard let current = snapshot.tasks.first(where: { $0.id == taskID }) else { throw TaskGraphError.unknownTask }
            guard current.detailReference == previous else { throw TaskGraphError.changedOnDisk }
            let timestamp = max(current.updatedAt, at)
            try authorizeTimestamp(timestamp)
            let outcome = try graph.update({ graph in
                guard let task = graph.tasks.first(where: { $0.id == taskID }) else { throw TaskGraphError.unknownTask }
                guard task.detailReference == previous else { throw TaskGraphError.changedOnDisk }
                let previousResult: TaskResult?
                if let previousID = previous.revisionID {
                    previousResult = try details.read(taskID: taskID, revisionID: previousID).result
                } else {
                    previousResult = nil
                }
                guard max(task.updatedAt, at) == timestamp else { throw TaskGraphError.changedOnDisk }
                try graph.setDetailRevision(revisionID, for: taskID, expecting: previous,
                                            resultChanged: previousResult != result, at: at)
            }, commit: { try details.withPublicationApproval($0) })
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
