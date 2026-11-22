import Foundation

// The Bouncer Window's model (docs/router-workspace/slices/01-bouncer-mode.md).

public enum BouncerError: Error, Equatable {
    /// A rejection needs a reason.
    case reasonRequired
    /// The adapter does not offer this action.
    case notAvailable
}

public enum BouncerTaskState: String, Sendable { case working, needsInput, failed, finished, stopped }

public struct BouncerTask: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var repository: String?
    public var organization: String?
    public var state: BouncerTaskState
    public var updatedAt: Date
    public var archived: Bool

    public init(id: String, title: String, repository: String? = nil, organization: String? = nil, state: BouncerTaskState,
                updatedAt: Date, archived: Bool = false) {
        (self.id, self.title, self.repository, self.organization) = (id, title, repository, organization)
        (self.state, self.updatedAt, self.archived) = (state, updatedAt, archived)
    }

    /// Only a task that ended can go to the archive.
    public var canArchive: Bool { state == .finished || state == .stopped }
}

public enum BouncerTaskGrouping: String, CaseIterable, Sendable { case state = "State", repository = "Repository", organization = "Organization", none = "None" }
public enum BouncerTaskSort: String, CaseIterable, Sendable { case activity = "Last Activity", title = "Title" }

/// Sidebar order also supplies the next and previous task keys. Ties use the stable task id.
public func bouncerTaskGroups(_ tasks: [BouncerTask], archived: Bool, grouping: BouncerTaskGrouping,
                              sort: BouncerTaskSort) -> [(name: String, tasks: [BouncerTask])] {
    let ordered = tasks.filter { $0.archived == archived }.sorted {
        if sort == .activity, $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
        let comparison = $0.title.localizedStandardCompare($1.title)
        return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
    }
    if grouping == .none { return ordered.isEmpty ? [] : [("", ordered)] }
    func key(_ task: BouncerTask) -> String {
        switch grouping {
        case .state: task.state.rawValue
        case .repository: task.repository ?? "No repository"
        case .organization: task.organization ?? "No organization"
        case .none: ""
        }
    }
    let groups = Dictionary(grouping: ordered, by: key)
    let states: [BouncerTaskState] = [.needsInput, .failed, .working, .finished, .stopped]
    let keys = grouping == .state ? states.map(\.rawValue).filter { groups[$0] != nil } : groups.keys.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    }
    return keys.map { ($0, groups[$0]!) }
}

public enum BouncerAnswer: Equatable, Sendable { case option(Int), text(String), dismissed }

public struct BouncerQuestion: Identifiable, Equatable, Sendable {
    public let id: String
    public let taskID: String?
    public let title: String
    public let options: [String]
    public let recommended: Int?
    public let takesText: Bool
    public var answer: BouncerAnswer?

    public init(id: String, taskID: String? = nil, title: String, options: [String] = [], recommended: Int? = nil,
                takesText: Bool = false, answer: BouncerAnswer? = nil) {
        (self.id, self.taskID, self.title, self.options, self.recommended) = (id, taskID, title, options, recommended)
        (self.takesText, self.answer) = (takesText, answer)
    }

    public var isOpen: Bool { answer == nil }
}

public enum ApprovalCardSource: Equatable, Sendable { case demo, local }

/// An approval request that host code draws; never made from model text.
public struct ApprovalCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let taskID: String
    public let title: String
    public let actions: [String]
    public let checkedAt: Date
    public let source: ApprovalCardSource
    public let result: TaskResult?
    public var decision: ApprovalDecision?
    public var localError: String?
    public var isOpen: Bool { decision == nil && localError == nil }

    public init(id: String, taskID: String, title: String, actions: [String], checkedAt: Date, decision: ApprovalDecision? = nil) {
        (self.id, self.taskID, self.title, self.actions, self.checkedAt, self.decision) = (id, taskID, title, actions, checkedAt, decision)
        source = .demo
        result = nil
    }

    public init(local record: ApprovalRecord, result: TaskResult? = nil) {
        let request = record.request
        id = request.id.uuidString
        taskID = request.taskID.uuidString
        title = request.actions.count == 1 ? "Approve this action?" : "Approve these actions?"
        actions = request.actions.map { $0.intent.display }
        checkedAt = request.checkedAt
        source = .local
        self.result = result
        decision = record.answer?.decision
        if record.invalidatedAt != nil { localError = ApprovalError.stale.errorDescription }
    }
}

public enum BouncerItem: Identifiable, Equatable, Sendable {
    case user(id: String, text: String), reply(id: String, text: String, toolSteps: Int)
    case report(id: String, taskID: String, role: String, text: String, toolSteps: [String])
    case question(BouncerQuestion), approval(ApprovalCard), note(id: String, text: String), stopped(id: String)

    /// Only task reports, questions and approvals belong to a task in slice 01.
    public var taskID: String? {
        switch self {
        case .report(_, let taskID, _, _, _): taskID
        case .question(let question): question.taskID
        case .approval(let card): card.taskID
        default: nil
        }
    }

    public var id: String {
        switch self {
        case .user(let id, _), .reply(let id, _, _), .report(let id, _, _, _, _), .note(let id, _), .stopped(let id): id
        case .question(let q): q.id
        case .approval(let a): a.id
        }
    }
}

public enum BouncerEvent: Equatable, Sendable {
    case started(model: String?, selection: String?), item(BouncerItem), textDelta(id: String, text: String), toolStep(id: String)
    case remove(id: String)
    case replying(Bool), answered(String, BouncerAnswer), tasks([BouncerTask]), banner(String?), failed(String), exited(String)
    case availableModel(String), selectedModel(model: String?, selection: String?)
}

/// The Bouncer conversation: what the window shows and what the pill counts.
public struct BouncerThread: Equatable, Sendable {
    public private(set) var items: [BouncerItem]
    public private(set) var tasks: [BouncerTask]
    public var banner: String? {
        let lines = [eventBanner].compactMap { $0 } + hostNotices.filter { $0 != eventBanner }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
    public private(set) var hostNotices: [String] = []
    public private(set) var replying: Bool
    private var eventBanner: String?
    public private(set) var localApprovalRetries: Set<UUID> = []

    public init(items: [BouncerItem] = [], tasks: [BouncerTask] = []) {
        (self.items, self.tasks, replying) = (items, tasks, false)
    }

    public mutating func apply(_ event: BouncerEvent) {
        switch event {
        case .started:
            items.removeAll { item in
                if case .approval(let card) = item { return card.source != .local }
                return true
            }
            (eventBanner, replying) = (nil, false)
        // An item with a known id replaces it during replay or streaming.
        case .item(let item):
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        case .textDelta(let id, let delta):
            guard let i = items.lastIndex(where: { $0.id == id }) else { return }
            switch items[i] {
            case .user(_, let text): items[i] = .user(id: id, text: text + delta)
            case .reply(_, let text, let steps): items[i] = .reply(id: id, text: text + delta, toolSteps: steps)
            default: break
            }
        case .toolStep(let id):
            guard let i = items.lastIndex(where: { $0.id == id }), case .reply(_, let text, let steps) = items[i] else { return }
            items[i] = .reply(id: id, text: text, toolSteps: steps + 1)
        case .remove(let id): items.removeAll { $0.id == id }
        case .replying(let on): replying = on
        case .answered(let id, let response): answer(id, response)
        case .tasks(let list): tasks = list
        case .banner(let text): eventBanner = text
        case .failed(let text): eventBanner = text
        case .exited(let text):
            (eventBanner, replying) = (text, false)
        // The window keeps the model list; the thread does not show it.
        case .availableModel, .selectedModel: break
        }
    }

    public mutating func showHostNotices(_ notices: [String], windowIsVisible: Bool) {
        guard windowIsVisible else { return }
        for notice in notices where !hostNotices.contains(notice) { hostNotices.append(notice) }
    }

    public mutating func clearHostNotices() { hostNotices.removeAll() }

    public mutating func answer(_ questionID: String, _ answer: BouncerAnswer) {
        guard let i = items.firstIndex(where: { $0.id == questionID }), case .question(var q) = items[i], q.isOpen else { return }
        q.answer = answer
        items[i] = .question(q)
    }

    public mutating func decide(_ approvalID: String, _ decision: ApprovalDecision) throws {
        if case .rejected(let reason) = decision, reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BouncerError.reasonRequired
        }
        guard let i = items.firstIndex(where: { $0.id == approvalID }), case .approval(var card) = items[i],
              card.source == .demo, card.isOpen else { return }
        card.decision = decision
        items[i] = .approval(card)
    }

    public mutating func beginLocalApprovalReload(for taskID: UUID) {
        for i in items.indices {
            guard case .approval(var card) = items[i], card.source == .local,
                  card.taskID == taskID.uuidString, card.isOpen else { continue }
            card.localError = "Check this approval again before answering."
            items[i] = .approval(card)
        }
    }

    public mutating func localApprovalReloadNeedsRetry(for taskID: UUID, discardCards: Bool = false) {
        if discardCards {
            replaceLocalApprovals(for: taskID, with: [])
        } else {
            beginLocalApprovalReload(for: taskID)
        }
        localApprovalRetries.insert(taskID)
    }

    public mutating func replaceLocalApprovals(for taskID: UUID, with cards: [ApprovalCard]) {
        localApprovalRetries.remove(taskID)
        items.removeAll {
            guard case .approval(let card) = $0 else { return false }
            return card.source == .local && card.taskID == taskID.uuidString
        }
        for card in cards where card.source == .local && card.taskID == taskID.uuidString {
            apply(.item(.approval(card)))
        }
    }

    /// Archive is local presentation state. A running or waiting task cannot be hidden.
    public mutating func setArchived(_ id: String, _ archived: Bool) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), !archived || tasks[i].canArchive else { return }
        tasks[i].archived = archived
    }

    /// The Bouncer shows the active thread; a selected task shows only its own items, including archived history.
    public func visibleItems(taskID: String?) -> [BouncerItem] {
        if let taskID { return items.filter { $0.taskID == taskID } }
        let archived = Set(tasks.filter(\.archived).map(\.id))
        return items.filter { $0.taskID.map { !archived.contains($0) } ?? true }
    }

    /// Open questions and approvals, plus tasks whose approval check needs a retry.
    public var waitingCount: Int {
        items.reduce(localApprovalRetries.count) { n, item in
            switch item {
            case .question(let q) where q.isOpen: n + 1
            case .approval(let a) where a.isOpen: n + 1
            default: n
            }
        }
    }

}

public enum BouncerSetupStep: Equatable, Sendable { case chooseWorkspace, confirmRemotes }

/// The steps that the Set Up row shows, in order; empty when the Bouncer can start.
/// `isWorkspace`: the recorded folder is the workspace repository now (`WorkspaceSettings.workspaceProblem`).
/// `remotes`: nil until a check of the folder finds a repository, so no remote is confirmed before the check ends.
public func bouncerSetupSteps(workspace: WorkspaceSettings, isWorkspace: Bool, remotes: [WorkspaceRemote]?) -> [BouncerSetupStep] {
    var steps: [BouncerSetupStep] = []
    if workspace.workspace == nil || !isWorkspace { steps.append(.chooseWorkspace) }
    else if let remotes { if !workspace.acknowledges(remotes) { steps.append(.confirmRemotes) } }
    else { steps.append(.chooseWorkspace) }
    return steps
}

/// Sessions that need input or failed, children included, without the Bouncer's own session: the host note.
public func otherWaits(_ sessions: [SessionRow], bouncerSessionFile: String?) -> [SessionRow] {
    let own = bouncerSessionFile.map(sessionFilePath)
    func waits(_ row: SessionRow) -> [SessionRow] {
        var isOwn = false
        if case .pi(let session) = row.source, let own { isOwn = sessionFilePath(session.path) == own }
        let state = row.status.state
        return (!isOwn && (state == .needsInput || state == .failed) ? [row] : []) + row.children.flatMap(waits)
    }
    return sessions.flatMap(waits)
}
