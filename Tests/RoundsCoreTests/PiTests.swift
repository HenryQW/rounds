import Foundation
import Testing
@testable import RoundsCore

private let path = "/Users/test/.pi/agent/sessions/--Users-test-api--/2026-10-30T10-00-00-000Z_s1.jsonl"

private func entry(_ role: String, _ extra: String = "", at second: Int) -> String {
    #"{"type":"message","id":"m\#(second)","timestamp":"2026-10-30T10:00:\#(String(format: "%02d", second)).000Z","message":{"role":"\#(role)"\#(extra)}}"#
}

private func file(_ lines: [String], parent: String = "") -> Data {
    let header = #"{"type":"session","version":3,"id":"s1","timestamp":"2026-10-30T10:00:00.000Z","cwd":"/Users/test/api"\#(parent)}"#
    return Data(([header] + lines).joined(separator: "\n").utf8)
}

private func at(_ second: Int) -> Date { Date(timeIntervalSince1970: 1_793_354_400 + Double(second)) }

@Test func parsesPiSessionFile() throws {
    let data = file([
        #"{"type":"message","id":"a","timestamp":"2026-10-30T10:00:01.000Z","message":{"role":"system","content":""}}"#,
        entry("user", #","content":[{"type":"text","text":"Fix the login flow\nand more"}]"#, at: 2),
        entry("assistant", #","stopReason":"toolUse""#, at: 3),
        entry("toolResult", at: 4),
        entry("assistant", #","stopReason":"stop""#, at: 5),
    ], parent: #","parentSession":"/p/parent.jsonl""#)
    let s = try #require(parsePiSession(data, path: path, updatedAt: at(9)))
    #expect(s.id == "s1" && s.cwd == "/Users/test/api" && s.parentPath == "/p/parent.jsonl" && s.path == path)
    #expect(s.title == "Fix the login flow")
    #expect(s.turn == PiTurn(kind: .done, at: at(5)))
}

@Test func piTitleIsTheLastNameElseThePromptElseTheFolder() throws {
    let named = file([
        entry("user", #","content":"First prompt""#, at: 1),
        #"{"type":"session_info","id":"i1","timestamp":"2026-10-30T10:00:02.000Z","name":"Old name"}"#,
        #"{"type":"session_info","id":"i2","timestamp":"2026-10-30T10:00:03.000Z","name":"Company structure"}"#,
    ])
    #expect(parsePiSession(named, path: path, updatedAt: at(9))?.title == "Company structure")
    #expect(parsePiSession(file([entry("user", #","content":"First prompt""#, at: 1)]), path: path, updatedAt: at(9))?.title == "First prompt")
    #expect(parsePiSession(file([]), path: path, updatedAt: at(9))?.title == "api")
    #expect(parsePiSession(Data(#"{"type":"message"}"#.utf8), path: path, updatedAt: at(9)) == nil)
}

@Test(arguments: [
    (#","stopReason":"error","errorMessage":"Rate limited\nretry later""#, PiTurn.Kind.error, "Rate limited"),
    (#","stopReason":"aborted""#, .stopped, ""), (#","stopReason":"toolUse""#, .working, ""),
])
func piTurnFromTheLastReply(extra: String, kind: PiTurn.Kind, detail: String) throws {
    let s = try #require(parsePiSession(file([entry("user", #","content":"x""#, at: 1), entry("assistant", extra, at: 2)]), path: path, updatedAt: at(9)))
    #expect(s.turn == PiTurn(kind: kind, detail: detail, at: at(2)))
}

@Test func readsTheHeadAndTailOfALargeSessionFile() throws {
    let lines = [entry("user", #","content":"First prompt""#, at: 1)]
        + (0..<400).map { _ in #"{"type":"custom","data":"\#(String(repeating: "x", count: 1000))"}"# }
        + [entry("assistant", #","stopReason":"stop""#, at: 7)]
    let url = try tempDir().appending(path: "s1.jsonl")
    try file(lines).write(to: url)
    let data = try #require(readPiSession(url, head: 50_000, tail: 20_000))
    #expect(data.count < 80_000)
    let s = try #require(parsePiSession(data, path: url.path, updatedAt: at(9)))
    #expect(s.title == "First prompt" && s.turn?.kind == .done)
}

@Test func parsesPiStateLine() {
    let s = PiState("1793354405000\tblocked\tPick a branch\t4242\t\(path)\n")
    #expect(s == PiState(at: at(5), state: "blocked", detail: "Pick a branch", pid: 4242, sessionPath: path))
    #expect(PiState("1793354405000\tdone\t\t4242") == nil)
    #expect(PiState("x\tdone\t\t4242\t\(path)") == nil)
}

private func session(turn: PiTurn?) -> PiSession {
    PiSession(id: "s1", path: path, cwd: "/Users/test/api", parentPath: nil, title: "t", updatedAt: at(1), turn: turn)
}

private func state(_ s: String, _ detail: String = "", at second: Int) -> PiState {
    PiState(at: at(second), state: s, detail: detail, pid: 1, sessionPath: path)
}

@Test(arguments: [
    ("blocked", "Pick a branch", SessionState.needsInput), ("working", "", .working), ("done", "", .finished),
    ("error", "Rate limited", .failed), ("stopped", "", .stopped), ("idle", "", .finished),
])
func piStateFromTheExtension(raw: String, detail: String, expected: SessionState) {
    let s = classifyPi(session(turn: PiTurn(kind: .done, at: at(2))), state: state(raw, detail, at: 5), live: true)
    #expect(s.state == expected && s.detail == detail)
}

@Test func newerOfExtensionAndFileWinsAndAnAgedWaitIsOffline() {
    let working = PiTurn(kind: .working, at: at(8))
    // A prompt after the last state: the file says the turn runs (an extension that no longer loads).
    #expect(classifyPi(session(turn: working), state: state("done", at: 5), live: true).state == .working)
    #expect(classifyPi(session(turn: PiTurn(kind: .error, detail: "x", at: at(8))), state: nil, live: true).state == .failed)
    #expect(classifyPi(session(turn: nil), state: nil, live: true).state == .finished)
    // A session quiet for the Aged time is not Working, and its wait does not stay in Last Call for ever.
    #expect(classifyPi(session(turn: working), state: nil, live: true, aged: true).state == .offline)
    #expect(classifyPi(session(turn: PiTurn(kind: .done, at: at(2))), state: state("blocked", at: 5), live: true, aged: true).state == .offline)
}

@Test(arguments: ["done", "idle", "stopped", "working", "blocked", "error"])
func closedSessionLeavesTheList(raw: String) {
    // Its pi process ended: the user closed the herdr pane or the terminal, or quit pi. It does not show, and so it
    // does not reopen on a click.
    #expect(classifyPi(session(turn: PiTurn(kind: .done, at: at(2))), state: state(raw, at: 5), live: false).group == .hidden)
    #expect(classifyPi(session(turn: PiTurn(kind: .working, at: at(8))), state: nil, live: false).group == .hidden)
}

@Test func aPiProcessRunsTheSessionOfItsNewestLine() {
    // After /new or /resume the process runs another session; the session it left keeps a line with the same pid.
    let left = PiState(at: at(5), state: "idle", detail: "", pid: 7, sessionPath: "/s/a.jsonl")
    let now = PiState(at: at(9), state: "working", detail: "", pid: 7, sessionPath: "/s/b.jsonl")
    let closed = PiState(at: at(9), state: "done", detail: "", pid: 8, sessionPath: "/s/c.jsonl")
    #expect(livePiSessions(["a": left, "b": now, "c": closed], running: { $0 == 7 }) == ["b"])
}

@Test func aPiForkAlertsLikeTheUsersOwnSession() {
    let fork = PiSession(id: "s2", path: "/p/fork.jsonl", cwd: "/Users/test/api", parentPath: path, title: "Fork", updatedAt: at(1), turn: nil)
    let row = SessionRow(pi: fork, status: SessionStatus(.needsInput, since: at(1)))
    #expect(row.parentId == "pi:" + path && row.sourceName == "pi")
    #expect(group([row], query: "", rule: LastCallRule(), now: at(60)).yourTurn.map(\.id) == ["pi:/p/fork.jsonl"])
}

@Test func sessionFilePathsTakeTheLetterCaseOnDisk() throws {
    // pi names the session folder after the cwd as typed (~/Git/evermark), so herdr, the extension and a fork's
    // header can spell a folder that is "Evermark" on disk; Rounds lists the disk spelling and must match it.
    let root = try tempDir().resolvingSymlinksInPath()
    let folder = root.appending(path: "--Users-test-Evermark--")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let onDisk = folder.appending(path: "2026-10-29T12-14-59-163Z_s1.jsonl")
    try Data().write(to: onDisk)
    let typed = root.appending(path: "--Users-test-evermark--/2026-10-29T12-14-59-163Z_s1.jsonl").path

    let list = #"{"id":"1","result":{"agents":[{"agent":"pi","pane_id":"a","agent_status":"done","agent_session":{"kind":"path","value":"\#(typed)"}}]}}"#
    #expect(try parseHerdrAgents(Data(list.utf8))[0].sessionPath == onDisk.path)
    #expect(PiState("1\tdone\t\t1\t\(typed)")?.sessionPath == onDisk.path)
    #expect(parsePiSession(file([], parent: #","parentSession":"\#(typed)""#), path: path, updatedAt: at(9))?.parentPath == onDisk.path)
}

@Test func piTicketRefsComeFromTheWholeFirstPrompt() throws {
    let s = try #require(parsePiSession(file([entry("user", #","content":"Look at this\nhttps://github.com/o/r/issues/3""#, at: 1)]), path: path, updatedAt: at(9)))
    #expect(s.title == "Look at this")
    #expect(s.ticketRefs == [.github(owner: "o", repo: "r", number: 3)])
}
