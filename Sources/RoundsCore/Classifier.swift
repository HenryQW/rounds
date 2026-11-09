import Foundation

public enum StatusGroup: Int, Sendable {
    case yourTurn, running, quiet, older, hidden
}

/// The standard states (GLOSSARY.md): every source maps into these, whatever its own words. The source's wording,
/// such as a tool name, goes in `SessionStatus.detail`.
public enum SessionState: String, Sendable, Codable, CaseIterable {
    /// Blocked until the user answers: a permission, a question, a plan, MCP input.
    case needsInput
    /// The turn ended in an error.
    case failed
    /// In a turn now.
    case working
    /// No turn, but work is still scheduled: background tasks, a cron wake-up.
    case background
    /// Finished, with a result waiting for the user (a review, or a herdr agent's unseen turn).
    case ready
    /// Finished, nothing new.
    case finished
    /// The user interrupted the turn.
    case stopped
    /// Live state unknown: the app is not running, or the session runs on another machine.
    case offline

    public var title: String {
        switch self {
        case .needsInput: "Needs input"
        case .failed: "Failed"
        case .working: "Working"
        case .background: "Background"
        case .ready: "Ready"
        case .finished: "Finished"
        case .stopped: "Stopped"
        case .offline: "Offline"
        }
    }

    /// The list group (and filter tile) of a state: Your Turn, Running or Quiet; `LastCallRule` moves rows by what the user
    /// read and by time (Older), and Hidden comes from the user's marks.
    public var group: StatusGroup {
        switch self {
        case .needsInput, .failed, .ready: .yourTurn
        case .working, .background: .running
        case .finished, .stopped, .offline: .quiet
        }
    }

    /// The agent waits for the user (Needs input, Failed): it stays in Last Call until it goes on, seen or not.
    public var waits: Bool { self == .needsInput || self == .failed }
}

public struct SessionStatus: Sendable, Equatable {
    public let state: SessionState
    /// The source's own detail: "Permission: Bash", a tool name, "review"; empty when there is none.
    public let detail: String
    public let since: Date
    public let group: StatusGroup
    /// The background tasks of rule 6, from the last Stop; empty in every other state.
    public let tasks: [BackgroundTask]

    public init(_ state: SessionState, _ detail: String = "", since: Date, group: StatusGroup? = nil, tasks: [BackgroundTask] = []) {
        (self.state, self.detail, self.since, self.group, self.tasks) = (state, detail, since, group ?? state.group, tasks)
    }

    /// "Working · Bash", or the state alone.
    public var label: String { detail.isEmpty ? state.title : "\(state.title) · \(detail)" }
    /// Under a status filter the filter names the state, so only the detail shows; Failed and Ready share the Your Turn
    /// group with Needs input, and a sub-agent's state can be in another group, so these keep their word.
    public var shortLabel: String { detail.isEmpty || state == .failed || state == .ready || group != state.group ? label : detail }
}

public struct ClassifierInput: Sendable {
    public let session: DesktopSession
    public let hook: HookState?
    public let tail: LastMessage?
    public let claudeRunning: Bool
    /// When the running Claude desktop started; hook state from before it belongs to a dead process.
    public let claudeLaunchedAt: Date?
    public let now: Date

    public init(session: DesktopSession, hook: HookState?, tail: LastMessage?, claudeRunning: Bool,
                claudeLaunchedAt: Date? = nil, now: Date) {
        self.session = session
        self.hook = hook
        self.tail = tail
        self.claudeRunning = claudeRunning
        self.claudeLaunchedAt = claudeLaunchedAt
        self.now = now
    }
}

let runningEvents: Set = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "ElicitationResult", "PreCompact"]
private let failedWindow: TimeInterval = 7 * 86400
private let quietRunningWindow: TimeInterval = 15 * 60
/// A Stop with background tasks counts as Background this long without newer activity; a task that outlives it
/// (or died without a hook event) no longer keeps the row in Running.
private let backgroundWindow: TimeInterval = 2 * 3600


/// Spec 3.1 trigger: a turn edge newer than the last hook event, or no hook state at all.
public func needsTail(session: DesktopSession, hook: HookState?) -> Bool {
    guard !session.isRemote else { return false }
    guard let hook else { return true }
    guard let edge = session.lastTurnEdgeAt else { return false }
    return edge > hook.last.at.addingTimeInterval(0.5)
}

func blockedLabel(_ l: HookLine) -> String? {
    switch (l.event, l.detail) {
    case ("PermissionRequest", let tool): "Permission: \(toolName(tool))"
    case ("Notification", "permission_prompt"): "Permission"
    case ("Notification", _), ("Elicitation", _): "MCP input"
    case ("PreToolUse", let tool): waitingToolLabel(tool)
    default: nil
    }
}

/// A tool call (as `toolDetail` names it) that waits for the user until it returns.
func waitingToolLabel(_ tool: String) -> String? {
    switch tool {
    case "AskUserQuestion": "Question"
    case "ExitPlanMode": "Plan approval"
    case "mcp__ccd_session__start_session:offer": "New session"
    default: nil
    }
}

/// MCP tools are named "mcp__<server>__<tool>"; the tool part is the readable one.
private func toolName(_ name: String) -> String {
    guard name.hasPrefix("mcp__"), let tool = name.components(separatedBy: "__").last, !tool.isEmpty else { return name }
    return tool
}

func runningLabel(_ l: HookLine) -> String {
    switch l.event {
    case "PreToolUse": toolName(l.detail)
    case "PreCompact": "Compacting"
    default: "Thinking"
    }
}

/// Spec section 3: the desktop sidebar order, with hooks for the states the desktop keeps in memory only.
public func classify(_ input: ClassifierInput) -> SessionStatus { decide(input).status }

/// `classify` with the rule that decided the state (Why This State…, spec 3.4).
func decide(_ input: ClassifierInput) -> (status: SessionStatus, rule: StateRule) {
    let s = input.session
    let now = input.now
    if s.isArchived { return (SessionStatus(.finished, since: s.lastActivityAt, group: .hidden), StateRule(0, "Archived")) }

    let hook = s.isRemote ? nil : input.hook
    let launchedLater = input.claudeLaunchedAt.map { launched in (hook?.last.at ?? launched) < launched } ?? false
    let live = input.claudeRunning && hook?.last.event != "SessionEnd" && !launchedLater
    func quiet(_ state: SessionState, _ detail: String = "") -> SessionStatus {
        SessionStatus(state, detail, since: s.lastActivityAt)
    }
    // Rule 1: no live process, so a wait or a turn in progress is Offline.
    let offline = (status: quiet(.offline), rule: StateRule(1, !input.claudeRunning ? "Claude desktop is not running"
        : hook?.last.event == "SessionEnd" ? "The session ended" : "Hook from before Claude started"))

    // Rule 3: blocked on the user (memory-only desktop state, seen through hooks). A denial sends no hook, but ends the
    // turn: a turn edge with the interrupt marker ends the wait (3.1).
    let denied = needsTail(session: s, hook: hook) && input.tail == .interrupted
    if let last = hook?.last, let label = blockedLabel(last), !denied {
        return live ? (SessionStatus(.needsInput, label, since: last.at), StateRule(3, "Waits for the user")) : offline
    }
    // Rule 4.
    if s.interruptedAwaitingPerson {
        return (SessionStatus(.needsInput, "Interrupted", since: s.lastActivityAt), StateRule(4, "Interrupted when Claude quit"))
    }

    // Rule 5 with the 3.1 reconcile.
    var running: (label: String, since: Date, rule: String)?
    var turnEnded = hook.map { ["Stop", "StopFailure", "SessionEnd"].contains($0.last.event) } ?? true
    if let last = hook?.last, runningEvents.contains(last.event) { running = (runningLabel(last), last.at, "Running") }
    if needsTail(session: s, hook: hook), let tail = input.tail {
        switch tail {
        case .interrupted:
            return (quiet(.stopped), StateRule(10, "Stopped by you, from the transcript"))
        case .waiting(let label):
            return live ? (SessionStatus(.needsInput, label, since: s.lastActivityAt), StateRule(3, "Waits for the user, from the transcript")) : offline
        case .endTurn, .question:
            running = nil
            turnEnded = true
        case .inProgress:
            if hook != nil || now.timeIntervalSince(s.lastActivityAt) <= quietRunningWindow {
                running = ("Thinking", s.lastTurnEdgeAt ?? s.lastActivityAt, "Running, from the transcript")
                turnEnded = false
            }
        case .unknown:
            break
        }
    }
    if let running {
        return live ? (SessionStatus(.working, running.label, since: running.since), StateRule(5, running.rule)) : offline
    }

    let stop = hook?.last.event == "Stop" ? hook?.last : nil
    // Rule 6.
    if live, let stop, let n = stop.backgroundTasks, n > 0, now.timeIntervalSince(stop.at) <= backgroundWindow {
        // A line from an older helper has the count only; one line then stands for all tasks.
        let tasks = stop.tasks.count == n ? stop.tasks : [BackgroundTask(type: "", description: n == 1 ? "1 background task" : "\(n) background tasks")]
        return (SessionStatus(.background, n == 1 ? "1 task" : "\(n) tasks", since: stop.at, tasks: tasks), StateRule(6, "Background tasks"))
    }
    // Rule 7.
    let summary = s.summary.flatMap { $0.summarizesUuid == s.lastAssistantUuid && turnEnded ? $0 : nil }
    if let last = hook?.last, last.event == "StopFailure" {
        return (SessionStatus(.failed, last.detail.isEmpty ? "error" : last.detail, since: last.at), StateRule(7, "Failed, from the hook"))
    }
    if let errorAt = s.errorAt, now.timeIntervalSince(errorAt) < failedWindow {
        return (SessionStatus(.failed, "error", since: errorAt), StateRule(7, "Failed, error in the last 7 days"))
    }
    if summary?.category == "failed" {
        return (SessionStatus(.failed, "error", since: s.lastActivityAt), StateRule(7, "Failed, from the summary"))
    }
    // Rule 8.
    if live, let stop, let fire = stop.cronSchedules.compactMap({ nextCronFire($0, within: 15, from: now) }).min() {
        let minutes = Int((fire.timeIntervalSince(now) / 60).rounded(.up))
        return (SessionStatus(.background, "Wakes in \(minutes) min", since: stop.at), StateRule(8, "Cron wakes within 15 min"))
    }
    // Rule 9.
    // A turn that a side session's report started passes on that session's wait; the side session's row shows it.
    let blockedSummary = s.sideSessionWakes == 0 && summary.map { ["blocked", "need_input"].contains($0.category) } ?? false
    // A wrap-up without a question turns a blocked summary into review, unless the summary names a step for the user.
    let reviewReady = summary?.category == "review_ready"
        || (s.hasWrapUp && s.wrapUpNeedsUser == nil && blockedSummary && summary?.needsAction.isEmpty == true)
    let question = s.wrapUpNeedsUser != nil ? "Question, from the wrap-up"
        : turnEnded && input.tail == .question ? "Question, from the transcript"
        : blockedSummary && !reviewReady ? "Question, from the summary" : nil
    if let question {
        return (SessionStatus(.needsInput, "Question", since: s.lastActivityAt), StateRule(9, question))
    }
    // Rules 2 and 10.
    if s.isRemote { return (quiet(.offline, "remote"), StateRule(2, "Remote session")) }
    if reviewReady { return (quiet(.ready, "review"), StateRule(10, "Review ready")) }
    if s.lastAssistantUuid == nil { return (quiet(.finished, "new"), StateRule(10, "New, no reply yet")) }
    return (quiet(.finished), StateRule(10, "Finished"))
}
