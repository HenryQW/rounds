import Foundation

/// The rule that decided a state (Why This State…, spec 3.4): for Claude the rule number of spec 3; the other sources
/// have their own rules, with no number.
public struct StateRule: Sendable, Equatable, Codable {
    public let number: Int?
    public let name: String

    public init(_ number: Int?, _ name: String) {
        (self.number, self.name) = (number, name)
    }

    /// "9: Question, from the summary", or the name alone.
    public var label: String { number.map { "\($0): \(name)" } ?? name }
}

/// One signal the classifier read: a label and a value, and the time of the value when it has one. No prompt, reply or
/// title text.
public struct StateSignal: Sendable, Equatable, Codable {
    public let label: String
    public let value: String
    public let at: Date?

    public init(_ label: String, _ value: String, at: Date? = nil) {
        (self.label, self.value, self.at) = (label, value, at)
    }
}

/// Why a row has its state: the source, the rule that decided it, and the signals the classifier read.
public struct StateExplanation: Sendable, Equatable, Codable {
    /// Claude, Codex, pi or herdr.
    public let source: String
    public let rule: StateRule
    public var signals: [StateSignal]

    public init(source: String, rule: StateRule, signals: [StateSignal]) {
        (self.source, self.rule, self.signals) = (source, rule, signals)
    }

    /// "Rule 9 decided this state.", or for a source with its own rules "A pi rule decided this state."
    public var sentence: String { rule.number.map { "Rule \($0) decided this state." } ?? "A \(source) rule decided this state." }
}

/// What a classifier read for one row: enough to run it again for Why This State… and for a wrong-state report.
public enum StateInput: Sendable {
    case claude(ClassifierInput)
    case codex(CodexThread, hook: HookState?, turn: CodexTurn?, live: Bool)
    case pi(PiSession, state: PiState?, live: Bool, aged: Bool)
    case herdr(status: String, since: Date)

    /// Runs the source's classifier: the state, and the rule that decided it with the signals it read.
    public func explain() -> (status: SessionStatus, explanation: StateExplanation) {
        switch self {
        case .claude(let input):
            let (status, rule) = decide(input)
            let s = input.session
            var signals = [
                hookSignal(s.isRemote ? nil : input.hook),
                StateSignal("Summary", s.summary.map { "\($0.category), \($0.summarizesUuid == s.lastAssistantUuid ? "fresh" : "old")" } ?? "none"),
                StateSignal("Transcript tail", input.tail?.code ?? "not read"),
                StateSignal("Last turn edge", s.lastTurnEdgeAt == nil ? "none" : "", at: s.lastTurnEdgeAt),
            ]
            if s.hasWrapUp { signals.append(StateSignal("Wrap-up", s.wrapUpNeedsUser == nil ? "no question" : "asks the user")) }
            if let errorAt = s.errorAt { signals.append(StateSignal("Error", "", at: errorAt)) }
            if s.isRemote { signals.append(StateSignal("Remote", "yes")) }
            signals.append(StateSignal("Claude desktop", input.claudeRunning ? "running" : "not running"))
            return (status, StateExplanation(source: "Claude", rule: rule, signals: signals))
        case .codex(let thread, let hook, let turn, let live):
            let (status, rule) = decideCodex(thread, hook: hook, turn: turn, live: live)
            return (status, StateExplanation(source: "Codex", rule: rule, signals: [
                hookSignal(hook),
                StateSignal("Rollout turn", turn?.kind.rawValue ?? "none", at: turn?.at),
                StateSignal("Codex", live ? "running" : "not running"),
            ]))
        case .pi(let session, let state, let live, let aged):
            let (status, rule) = decidePi(session, state: state, live: live, aged: aged)
            return (status, StateExplanation(source: "pi", rule: rule, signals: [
                StateSignal("pi state line", state?.state ?? "none", at: state?.at),
                StateSignal("Last message", session.turn?.kind.rawValue ?? "none", at: session.turn?.at),
                StateSignal("pi process", live ? "running" : "not running"),
                StateSignal("Aged", aged ? "yes" : "no"),
            ]))
        case .herdr(let agentStatus, let since):
            return (herdrStatus(agentStatus, since: since), StateExplanation(source: "herdr", rule: StateRule(nil, "herdr status"), signals: [
                StateSignal("herdr status", agentStatus, at: since),
            ]))
        }
    }
}

extension StateInput {
    /// Why This State… for a row: the classifier's state and explanation, so a report replays to the state it names,
    /// with Seen. A row that shows another state says why: a result Background for its sub-agents at work (3.2), or a
    /// row from an earlier check (a menu that opened before the state changed).
    public func explain(_ row: SessionRow) -> (status: SessionStatus, explanation: StateExplanation) {
        var (status, explanation) = explain()
        if row.status.state != status.state {
            explanation.signals.append(row.subAgentsAtWork > 0
                ? StateSignal("Sub-agents at work", "\(row.subAgentsAtWork); the row shows Background (3.2)")
                : StateSignal("Row shows", "\(row.status.state.title), from an earlier check"))
        }
        explanation.signals.append(StateSignal("Seen", row.isSeen ? "yes" : "no"))
        return (status, explanation)
    }
}

/// "PreToolUse (Bash)": the event and its tool name, notification type or error kind.
private func hookSignal(_ hook: HookState?) -> StateSignal {
    guard let last = hook?.last else { return StateSignal("Last hook event", "none") }
    return StateSignal("Last hook event", last.detail.isEmpty ? last.event : "\(last.event) (\(last.detail))", at: last.at)
}

extension LastMessage {
    /// A short name for explanations and reports: "end_turn", "waiting:Question".
    public var code: String {
        switch self {
        case .interrupted: "interrupted"
        case .endTurn: "end_turn"
        case .question: "question"
        case .inProgress: "in_progress"
        case .unknown: "unknown"
        case .waiting(let label): "waiting:" + label
        }
    }

    init?(code: String) {
        switch code {
        case "interrupted": self = .interrupted
        case "end_turn": self = .endTurn
        case "question": self = .question
        case "in_progress": self = .inProgress
        case "unknown": self = .unknown
        default:
            guard code.hasPrefix("waiting:") else { return nil }
            self = .waiting(String(code.dropFirst("waiting:".count)))
        }
    }
}
