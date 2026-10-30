import Foundation
import Testing
@testable import RoundsCore

@Test func decodesFullFixture() throws {
    let s = try DesktopSession(json: fixture("session_full.json"))
    #expect(s.id == "local_00000000-0000-4000-8000-000000000001")
    #expect(s.cliSessionId == "00000000-0000-4000-8000-0000000000aa")
    #expect(s.title == "Sample session")
    #expect(s.cwd == "/Users/test/proj")
    #expect(s.branch == "feature/x")
    #expect(s.pullRequests == [PullRequestLink(number: 412, url: URL(string: "https://github.com/example/api/pull/412")!, state: .merged)])
    #expect(s.isArchived == false)
    #expect(s.lastActivityAt == Date(timeIntervalSince1970: 1792986997.683))
    #expect(s.lastTurnEdgeAt == Date(timeIntervalSince1970: 1792986990))
    #expect(s.lastAssistantUuid == "u-2")
    #expect(s.hasWrapUp)
    #expect(s.wrapUpNeedsUser == "Pick A or B?")
    #expect(s.summary == PostTurnSummary(category: "blocked", needsAction: "pick A or B", summarizesUuid: "u-2"))
    #expect(s.errorAt == Date(timeIntervalSince1970: 1792980000))
    #expect(s.interruptedAwaitingPerson)
    #expect(s.isRemote)
}

@Test func minimalFixtureHasEmptyOptionals() throws {
    let s = try DesktopSession(json: fixture("session_minimal.json"))
    #expect(s.isArchived)
    #expect(s.branch == nil && s.lastTurnEdgeAt == nil && s.summary == nil && s.errorAt == nil)
    #expect(!s.hasWrapUp && s.wrapUpNeedsUser == nil)
    #expect(!s.interruptedAwaitingPerson && !s.isRemote)
}

@Test(arguments: ["sessionId", "cliSessionId", "cwd", "title", "isArchived", "lastActivityAt"])
func missingRequiredKeyNamesIt(key: String) throws {
    var dict = try #require(JSONSerialization.jsonObject(with: fixture("session_minimal.json")) as? [String: Any])
    dict.removeValue(forKey: key)
    let data = try JSONSerialization.data(withJSONObject: dict)
    #expect(throws: DesktopSessionError.missingKey(key)) { try DesktopSession(json: data) }
}

@Test func invalidJSONThrows() {
    #expect(throws: DesktopSessionError.invalidJSON) { try DesktopSession(json: Data("{".utf8)) }
}

@Test func emptyTitleFallsBackToCwdFolder() throws {
    var dict = try #require(JSONSerialization.jsonObject(with: fixture("session_minimal.json")) as? [String: Any])
    dict["title"] = ""
    let s = try DesktopSession(json: JSONSerialization.data(withJSONObject: dict))
    #expect(s.title == "proj")
}

@Test func loadSkipsAndReportsBadFiles() throws {
    let root = try tempDir()
    let dir = root.appending(path: "acct/org")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try fixture("session_full.json").write(to: dir.appending(path: "local_good.json"))
    try Data("{\"sessionId\":".utf8).write(to: dir.appending(path: "local_bad.json"))
    try Data("{}".utf8).write(to: dir.appending(path: "scheduled-tasks.json"))
    let result = loadDesktopSessions(root: root)
    #expect(result.sessions.map(\.title) == ["Sample session"])
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.url.lastPathComponent == "local_bad.json")
}

@Test func sideSessionLinksToItsParent() throws {
    var dict = try #require(JSONSerialization.jsonObject(with: fixture("session_minimal.json")) as? [String: Any])
    dict["spawnedFrom"] = ["sessionId": "local_parent", "taskId": "task_1", "title": "Plan (fork)", "sideSession": true, "userFork": true, "btw": true]
    let s = try DesktopSession(json: JSONSerialization.data(withJSONObject: dict))
    #expect(s.spawnedFrom == SpawnedFrom(sessionId: "local_parent", title: "Plan (fork)", userFork: true))
    #expect(SessionRow(session: s, status: SessionStatus(.finished, since: .distantPast)).parentId == "local_parent")
    let plain = try DesktopSession(json: fixture("session_minimal.json"))
    #expect(plain.spawnedFrom == nil && SessionRow(session: plain, status: SessionStatus(.finished, since: .distantPast)).parentId == nil)
}
