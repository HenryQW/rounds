import Foundation
import Testing
@testable import RoundsCore

private let listJSON = #"""
{"id":"1","result":{"agents":[
 {"agent":"pi","agent_status":"blocked","cwd":"/Users/test/work/worktree-calm-lake","pane_id":"w1:p1",
  "terminal_title_stripped":"π - Fix login flow - worktree-calm-lake",
  "agent_session":{"agent":"pi","kind":"path","source":"herdr:pi","value":"/Users/test/.pi/agent/sessions/a/s1.jsonl"}},
 {"agent":"claude","agent_status":"working","cwd":"/Users/test/api","pane_id":"w2:p3","terminal_title_stripped":""}
]}}
"""#

@Test func parsesHerdrAgentList() throws {
    let agents = try parseHerdrAgents(Data(listJSON.utf8))
    #expect(agents.map(\.id) == ["herdr:/Users/test/.pi/agent/sessions/a/s1.jsonl", "herdr:w2:p3"])
    #expect(agents.map(\.title) == ["Fix login flow", "claude"])
    #expect(agents.map(\.paneId) == ["w1:p1", "w2:p3"])
    #expect(agents[0].agent == "pi" && agents[0].agentStatus == "blocked" && agents[0].cwd == "/Users/test/work/worktree-calm-lake")
    #expect(agents[0].sessionPath == "/Users/test/.pi/agent/sessions/a/s1.jsonl" && agents[1].sessionPath == nil)
}

@Test func herdrErrorResponseThrows() {
    #expect(throws: HerdrError.self) { try parseHerdrAgents(Data(#"{"id":"1","error":{"code":"x","message":"no"}}"#.utf8)) }
}

@Test(arguments: [
    ("blocked", SessionState.needsInput), ("working", .working), ("done", .ready), ("idle", .finished), ("unknown", .finished),
])
func herdrStatusMapping(raw: String, state: SessionState) {
    let now = Date(timeIntervalSince1970: 100_000)
    let s = herdrStatus(raw, since: now.addingTimeInterval(-60))
    #expect(s.state == state && s.group == state.group && s.since == now.addingTimeInterval(-60))
}


@Test func herdrRowsGroupAndSearchWithClaudeRows() throws {
    let agent = try parseHerdrAgents(Data(listJSON.utf8))[0]
    let since = Date(timeIntervalSince1970: 50)
    let row = SessionRow(agent: agent, status: herdrStatus(agent.agentStatus, since: since))
    #expect(group([row], query: "").yourTurn.map(\.id) == [agent.id])
    #expect(group([row], query: "login").yourTurn.count == 1)
    #expect(group([row], query: "calm-lake").yourTurn.count == 1)
    var marks = SessionMarks()
    marks.markDone(row.id, at: since)
    #expect(group([row], query: "", marks: marks).yourTurn.isEmpty)
}

/// Without a session file there is no conversation (a pi never prompted, or a sub-agent another agent started):
/// such an agent shows only while it waits for the user.
@Test(arguments: [("idle", false, false), ("idle", true, true), ("done", false, false), ("working", false, false), ("blocked", false, true)])
func herdrAgentListedOnlyWithAConversation(status: String, session: Bool, listed: Bool) throws {
    let s = session ? #","agent_session":{"kind":"path","value":"/s.jsonl"}"# : ""
    let agents = try parseHerdrAgents(Data(#"{"id":"1","result":{"agents":[{"agent":"pi","pane_id":"a","agent_status":"\#(status)"\#(s)}]}}"#.utf8))
    #expect(agents[0].isListed == listed)
}

/// A sub-agent (no session file, a "d-" name) belongs to the one agent in its workspace that has a session file.
@Test(arguments: [(1, true), (0, false), (2, false)])
func herdrSubAgentParentIsTheOneSessionInItsWorkspace(sessions: Int, linked: Bool) throws {
    let parents = (0..<sessions).map { i in
        #"{"agent":"pi","pane_id":"w1:p\#(i)","agent_status":"idle","workspace_id":"w1","agent_session":{"kind":"path","value":"/s\#(i).jsonl"}}"#
    }
    let child = #"{"agent":"pi","pane_id":"w1:p9","agent_status":"working","workspace_id":"w1","name":"d-ab12","terminal_title_stripped":"π - Run the tests"}"#
    let other = #"{"agent":"pi","pane_id":"w2:p1","agent_status":"idle","workspace_id":"w2","agent_session":{"kind":"path","value":"/o.jsonl"}}"#
    let agents = try parseHerdrAgents(Data(#"{"id":"1","result":{"agents":[\#((parents + [child, other]).joined(separator: ","))]}}"#.utf8))
    let sub = try #require(agents.first { $0.paneId == "w1:p9" })
    #expect(sub.parentId == (linked ? "herdr:/s0.jsonl" : nil))
    #expect(sub.isListed == linked)
    #expect(sub.title == "Run the tests")
    #expect(agents.filter { $0.paneId != "w1:p9" }.allSatisfy { $0.parentId == nil })
    #expect(SessionRow(agent: sub, status: SessionStatus(.working, since: .distantPast)).parentId == sub.parentId)
}

@Test func herdrSubAgentWithoutTitleShowsItsName() throws {
    let agents = try parseHerdrAgents(Data(#"{"id":"1","result":{"agents":[{"agent":"pi","pane_id":"a","agent_status":"idle","name":"d-ab12","terminal_title_stripped":""}]}}"#.utf8))
    #expect(agents[0].title == "d-ab12")
    // A title that is only the folder name is no title.
    let folderOnly = try parseHerdrAgents(Data(#"{"id":"1","result":{"agents":[{"agent":"pi","pane_id":"a","agent_status":"idle","name":"d-ab12","cwd":"/w/repo","terminal_title_stripped":"π - repo"}]}}"#.utf8))
    #expect(folderOnly[0].title == "d-ab12")
}

@Test func piSessionJoinsTheHerdrPaneThatRunsIt() throws {
    let json = #"{"id":"1","result":{"agents":[{"agent":"pi","agent_status":"working","cwd":"/w","pane_id":"w8B:pAN"},{"agent":"pi","agent_status":"idle","cwd":"/w","pane_id":"w8B:pAK","agent_session":{"kind":"path","value":"/s/a.jsonl"}}]}}"#
    let agents = joiningSessions(try parseHerdrAgents(Data(json.utf8)), paneSessions: ["w8B:pAN": "/s/b.jsonl", "w8B:pAK": "/s/other.jsonl"])
    // The pane without a session file gets the one its pi process names; a reported one stays.
    #expect(agents.map(\.sessionPath) == ["/s/b.jsonl", "/s/a.jsonl"])
    #expect(agents.map(\.id) == ["herdr:/s/b.jsonl", "herdr:/s/a.jsonl"] && agents.allSatisfy(\.isListed))
}
