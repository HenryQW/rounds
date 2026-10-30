import Foundation

/// Sources Rounds supports by name. Each one ships an icon in `Resources/<name>.svg` (a test checks it);
/// other herdr agents show the first letter of their name.
public enum KnownAgent: String, CaseIterable, Sendable {
    /// herdr itself is not a row source (its agents are), but its icon names it in Settings and the Another round? banner.
    case claude, pi, codex, herdr

    public var iconFile: String { "\(rawValue).svg" }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .pi: "pi"
        case .herdr: "herdr"
        }
    }
}

extension SessionRow {
    /// The source filter's key: claude, codex, or the herdr agent's name (pi, droid, ...).
    public var sourceName: String {
        switch source {
        case .claude: KnownAgent.claude.rawValue
        case .codex: KnownAgent.codex.rawValue
        case .herdr(let agent): agent.agent
        }
    }

    public var knownAgent: KnownAgent? {
        switch source {
        case .claude: .claude
        case .codex: .codex
        case .herdr(let agent): KnownAgent(rawValue: agent.agent)
        }
    }
}
