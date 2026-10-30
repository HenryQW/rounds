import Foundation

public enum StatusGroup: Int, Sendable {
    case yourTurn, running, quiet, older, hidden
}

/// The standard states (GLOSSARY.md): every source maps into these, whatever its own words. The source's wording,
/// such as a tool name, goes in `SessionStatus.detail`.
public enum SessionState: String, Sendable {
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
    case ("PreToolUse", "AskUserQuestion"): "Question"
    case ("PreToolUse", "ExitPlanMode"): "Plan approval"
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
public func classify(_ input: ClassifierInput) -> SessionStatus {
    let s = input.session
    let now = input.now
    if s.isArchived { return SessionStatus(.finished, since: s.lastActivityAt, group: .hidden) }

    let hook = s.isRemote ? nil : input.hook
    let live = input.claudeRunning && hook?.last.event != "SessionEnd"
        && (input.claudeLaunchedAt.map { launched in (hook?.last.at ?? launched) >= launched } ?? true)
    func quiet(_ state: SessionState, _ detail: String = "") -> SessionStatus {
        SessionStatus(state, detail, since: s.lastActivityAt)
    }

    // Rule 3: blocked on the user (memory-only desktop state, seen through hooks).
    if let last = hook?.last, let label = blockedLabel(last) {
        return live ? SessionStatus(.needsInput, label, since: last.at) : quiet(.offline)
    }
    // Rule 4.
    if s.interruptedAwaitingPerson {
        return SessionStatus(.needsInput, "Interrupted", since: s.lastActivityAt)
    }

    // Rule 5 with the 3.1 reconcile.
    var running: (label: String, since: Date)?
    var turnEnded = hook.map { ["Stop", "StopFailure", "SessionEnd"].contains($0.last.event) } ?? true
    if let last = hook?.last, runningEvents.contains(last.event) { running = (runningLabel(last), last.at) }
    if needsTail(session: s, hook: hook), let tail = input.tail {
        switch tail {
        case .interrupted:
            return quiet(.stopped)
        case .endTurn, .question:
            running = nil
            turnEnded = true
        case .inProgress:
            if hook != nil || now.timeIntervalSince(s.lastActivityAt) <= quietRunningWindow {
                running = ("Thinking", s.lastTurnEdgeAt ?? s.lastActivityAt)
                turnEnded = false
            }
        case .unknown:
            break
        }
    }
    if let running {
        return live ? SessionStatus(.working, running.label, since: running.since) : quiet(.offline)
    }

    let stop = hook?.last.event == "Stop" ? hook?.last : nil
    // Rule 6.
    if live, let stop, let n = stop.backgroundTasks, n > 0, now.timeIntervalSince(stop.at) <= backgroundWindow {
        // A line from an older helper has the count only; one line then stands for all tasks.
        let tasks = stop.tasks.count == n ? stop.tasks : [BackgroundTask(type: "", description: n == 1 ? "1 background task" : "\(n) background tasks")]
        return SessionStatus(.background, n == 1 ? "1 task" : "\(n) tasks", since: stop.at, tasks: tasks)
    }
    // Rule 7.
    let summary = s.summary.flatMap { $0.summarizesUuid == s.lastAssistantUuid && turnEnded ? $0 : nil }
    if let last = hook?.last, last.event == "StopFailure" {
        return SessionStatus(.failed, last.detail.isEmpty ? "error" : last.detail, since: last.at)
    }
    if let errorAt = s.errorAt, now.timeIntervalSince(errorAt) < failedWindow {
        return SessionStatus(.failed, "error", since: errorAt)
    }
    if summary?.category == "failed" {
        return SessionStatus(.failed, "error", since: s.lastActivityAt)
    }
    // Rule 8.
    if live, let stop, let fire = stop.cronSchedules.compactMap({ nextCronFire($0, within: 15, from: now) }).min() {
        let minutes = Int((fire.timeIntervalSince(now) / 60).rounded(.up))
        return SessionStatus(.background, "Wakes in \(minutes) min", since: stop.at)
    }
    // Rule 9.
    let blockedSummary = summary.map { ["blocked", "need_input"].contains($0.category) } ?? false
    // A wrap-up without a question turns a blocked summary into review, unless the summary names a step for the user.
    let reviewReady = summary?.category == "review_ready"
        || (s.hasWrapUp && s.wrapUpNeedsUser == nil && blockedSummary && summary?.needsAction.isEmpty == true)
    if s.wrapUpNeedsUser != nil || (turnEnded && input.tail == .question) || (blockedSummary && !reviewReady) {
        return SessionStatus(.needsInput, "Question", since: s.lastActivityAt)
    }
    // Rules 10 and 11.
    if s.isRemote { return quiet(.offline, "remote") }
    if reviewReady { return quiet(.ready, "review") }
    if s.lastAssistantUuid == nil { return quiet(.finished, "new") }
    return quiet(.finished)
}
