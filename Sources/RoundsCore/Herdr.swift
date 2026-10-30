import Foundation

/// One agent pane that herdr (a terminal workspace manager for coding agents) reports through `agent.list` (spec 2.4).
public struct HerdrAgent: Sendable, Equatable, Identifiable {
    /// Stable across herdr restarts when the agent reports its session file; else the pane id.
    public let id: String
    public let paneId: String
    public let agent: String
    /// herdr's `agent_status`: idle, working, blocked, done or unknown.
    public let agentStatus: String
    public let title: String
    public let cwd: String
    public let sessionPath: String?
    /// For a sub-agent: the row id of the agent that started it.
    public let parentId: String?

    /// An agent without a session file gets a row only while it is blocked: it has no conversation of its own, either
    /// a pi opened and never prompted, or a sub-agent another agent started (`herdr agent start`) whose parent is not
    /// known. herdr still reports it, so the monitor keeps watching its pane.
    public var isListed: Bool { sessionPath != nil || parentId != nil || agentStatus == "blocked" }
}

public enum HerdrError: Error, Equatable {
    case invalidResponse
    case server(String)
}

/// Decodes an `agent.list` response line.
public func parseHerdrAgents(_ data: Data) throws(HerdrError) -> [HerdrAgent] {
    guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw .invalidResponse }
    if let error = response["error"] as? [String: Any] { throw .server(error["message"] as? String ?? "unknown error") }
    guard let agents = (response["result"] as? [String: Any])?["agents"] as? [[String: Any]] else { throw .invalidResponse }
    func session(_ a: [String: Any]) -> String? {
        (a["agent_session"] as? [String: Any]).flatMap { $0["kind"] as? String == "path" ? $0["value"] as? String : nil }
    }
    // A sub-agent's parent: the one agent with a session file in the same workspace; none or two leave it unknown.
    var sessionsByWorkspace: [String: [String]] = [:]
    for a in agents {
        if let workspace = a["workspace_id"] as? String, let s = session(a) { sessionsByWorkspace[workspace, default: []].append(s) }
    }
    return agents.compactMap { a in
        guard let pane = a["pane_id"] as? String, let agent = a["agent"] as? String else { return nil }
        let cwd = a["cwd"] as? String ?? ""
        let session = session(a)
        let subAgent = (a["name"] as? String).flatMap { session == nil && $0.hasPrefix("d-") ? $0 : nil }
        let parents = subAgent == nil ? [] : (a["workspace_id"] as? String).flatMap { sessionsByWorkspace[$0] } ?? []
        return HerdrAgent(id: "herdr:" + (session ?? pane), paneId: pane, agent: agent,
                          agentStatus: a["agent_status"] as? String ?? "unknown",
                          title: herdrTitle(a["terminal_title_stripped"] as? String ?? "", cwd: cwd, agent: subAgent ?? agent),
                          cwd: cwd, sessionPath: session, parentId: parents.count == 1 ? "herdr:" + parents[0] : nil)
    }
}

/// The pane of a new tab, from the response of `herdr tab create` (`result.root_pane.pane_id`).
public func herdrCreatedPane(_ data: Data) -> String? {
    let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return ((response?["result"] as? [String: Any])?["root_pane"] as? [String: Any])?["pane_id"] as? String
}

/// herdr reports the session file of some pi agents only. `paneSessions` (herdr pane id to session file, from the
/// `HERDR_PANE_ID` of each running pi process; spec 2.7) fills in the others, so a pi session in herdr shows once, as
/// its herdr agent.
public func joiningSessions(_ agents: [HerdrAgent], paneSessions: [String: String]) -> [HerdrAgent] {
    agents.map { a in
        guard a.sessionPath == nil, let path = paneSessions[a.paneId] else { return a }
        return HerdrAgent(id: "herdr:" + path, paneId: a.paneId, agent: a.agent, agentStatus: a.agentStatus, title: a.title,
                          cwd: a.cwd, sessionPath: path, parentId: a.parentId)
    }
}

/// Agents set the terminal title as "<icon> - <name> - <folder>" (pi: "π - Fix login - repo"); keep the name, else
/// `agent` (the agent name, or a sub-agent's own name).
func herdrTitle(_ terminalTitle: String, cwd: String, agent: String) -> String {
    var parts = terminalTitle.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
    if let first = parts.first, parts.count > 1, first.count <= 2 { parts.removeFirst() }
    if parts.last == URL(fileURLWithPath: cwd).lastPathComponent { parts.removeLast() }
    let title = parts.joined(separator: " - ")
    return title.isEmpty ? agent : title
}

/// herdr states map to the standard states: done is a turn the user has not looked at yet (herdr clears it when the
/// pane is focused).
public func herdrStatus(_ agentStatus: String, since: Date) -> SessionStatus {
    switch agentStatus {
    case "blocked": return SessionStatus(.needsInput, since: since)
    case "working": return SessionStatus(.working, since: since)
    default:
        return SessionStatus(agentStatus == "done" ? .ready : .finished, since: since)
    }
}
