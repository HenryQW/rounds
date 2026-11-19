import Foundation

// The Bouncer Window's model (docs/router-workspace/slices/01-bouncer-mode.md). Nothing in the app uses it yet.

public enum BouncerError: Error, Equatable {
    /// A rejection needs a reason.
    case reasonRequired
    /// The adapter has no such action: Pi never makes an approval card.
    case notAvailable
    /// The Bouncer process does not run.
    case notRunning
    /// The question is answered or closed, or Pi never asked it.
    case unknownQuestion
    /// Pi did not accept the command; Pi's error text.
    case rejected(String)
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

public enum BouncerAnswer: Equatable, Sendable { case option(Int), text(String), confirmed(Bool), dismissed }

public struct BouncerQuestion: Identifiable, Equatable, Sendable {
    public let id: String
    public let taskID: String?
    public let title: String
    public let options: [String]
    public let recommended: Int?
    public let takesText: Bool
    /// A Pi `confirm` dialog: option 0 is Yes and option 1 is No, and Pi wants `confirmed`, not the option text.
    public let confirms: Bool
    public var answer: BouncerAnswer?
    /// Pi resolved the question itself (its timeout), or Pi stopped.
    public var closedByPi: Bool

    public init(id: String, taskID: String? = nil, title: String, options: [String] = [], recommended: Int? = nil,
                takesText: Bool = false, confirms: Bool = false, answer: BouncerAnswer? = nil, closedByPi: Bool = false) {
        (self.id, self.taskID, self.title, self.options, self.recommended) = (id, taskID, title, options, recommended)
        (self.takesText, self.confirms, self.answer, self.closedByPi) = (takesText, confirms, answer, closedByPi)
    }

    public var isOpen: Bool { answer == nil && !closedByPi }
}

public enum ApprovalDecision: Equatable, Sendable { case approved, rejected(reason: String) }

/// An approval request that host code draws; never made from model text or a Pi dialog.
public struct ApprovalCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let taskID: String
    public let title: String
    public let actions: [String]
    public let checkedAt: Date
    public var decision: ApprovalDecision?

    public init(id: String, taskID: String, title: String, actions: [String], checkedAt: Date, decision: ApprovalDecision? = nil) {
        (self.id, self.taskID, self.title, self.actions, self.checkedAt, self.decision) = (id, taskID, title, actions, checkedAt, decision)
    }
}

public enum BouncerItem: Identifiable, Equatable, Sendable {
    case user(id: String, text: String), reply(id: String, text: String, toolSteps: Int)
    case report(id: String, taskID: String, role: String, text: String, toolSteps: [String])
    case question(BouncerQuestion), approval(ApprovalCard), note(id: String, text: String), stopped(id: String)

    public var id: String {
        switch self {
        case .user(let id, _), .reply(let id, _, _), .report(let id, _, _, _, _), .note(let id, _), .stopped(let id): id
        case .question(let q): q.id
        case .approval(let a): a.id
        }
    }
}

public enum BouncerEvent: Equatable, Sendable {
    case started(sessionFile: String?, isNew: Bool), item(BouncerItem), textDelta(String), toolStep(String)
    case replying(Bool), closed(questionID: String), tasks([BouncerTask]), banner(String?), failed(String), exited(String)
}

/// The Bouncer conversation: what the window shows and what the pill counts.
public struct BouncerThread: Equatable, Sendable {
    public private(set) var items: [BouncerItem]
    public private(set) var tasks: [BouncerTask]
    public private(set) var banner: String?
    public private(set) var replying: Bool

    public init(items: [BouncerItem] = [], tasks: [BouncerTask] = []) {
        (self.items, self.tasks, banner, replying) = (items, tasks, nil, false)
    }

    public mutating func apply(_ event: BouncerEvent) {
        switch event {
        case .started: banner = nil
        // An item with a known id replaces it: `get_messages` after a restart gives the ids of the live stream.
        case .item(let item):
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        case .textDelta(let text): growReply { $0.text += text }
        case .toolStep: growReply { $0.steps += 1 }
        // Only `agent_settled` ends a reply; `agent_end` can be followed by a retry.
        case .replying(let on): replying = on
        case .closed(let id): closeQuestions { $0.id == id }
        case .tasks(let list): tasks = list
        case .banner(let text): banner = text
        case .failed(let text): banner = text
        case .exited(let text):
            (banner, replying) = (text, false)
            closeQuestions { _ in true }
        }
    }

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
              card.decision == nil else { return }
        card.decision = decision
        items[i] = .approval(card)
    }

    /// Open questions and undecided approvals: the number on the pill.
    public var waitingCount: Int {
        items.reduce(0) { n, item in
            switch item {
            case .question(let q) where q.isOpen: n + 1
            case .approval(let a) where a.decision == nil: n + 1
            default: n
            }
        }
    }

    /// The last reply grows; without one, a new reply starts.
    private mutating func growReply(_ change: (inout (text: String, steps: Int)) -> Void) {
        let last = items.lastIndex { if case .reply = $0 { true } else { false } }
        var reply: (id: String, text: String, steps: Int) = ("reply-\(items.count)", "", 0)
        if let last, case .reply(let id, let text, let steps) = items[last] { reply = (id, text, steps) }
        var body = (text: reply.text, steps: reply.steps)
        change(&body)
        let item = BouncerItem.reply(id: reply.id, text: body.text, toolSteps: body.steps)
        if let last { items[last] = item } else { items.append(item) }
    }

    private mutating func closeQuestions(_ matches: (BouncerQuestion) -> Bool) {
        for i in items.indices {
            guard case .question(var q) = items[i], q.isOpen, matches(q) else { continue }
            q.closedByPi = true
            items[i] = .question(q)
        }
    }
}

public enum BouncerSetupStep: Equatable, Sendable { case chooseWorkspace, confirmRemotes, installPi }

/// The steps that the Set Up row shows, in order; empty when the Bouncer can start.
/// `isWorkspace`: the recorded folder is the workspace repository now (`WorkspaceSettings.workspaceProblem`).
public func bouncerSetupSteps(workspace: WorkspaceSettings, isWorkspace: Bool, remotes: [WorkspaceRemote], piPath: String?) -> [BouncerSetupStep] {
    var steps: [BouncerSetupStep] = []
    if workspace.workspace == nil || !isWorkspace { steps.append(.chooseWorkspace) }
    else if !workspace.acknowledges(remotes) { steps.append(.confirmRemotes) }
    if piPath?.isEmpty ?? true { steps.append(.installPi) }
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
