import Foundation
import Testing
@testable import RoundsCore

private func row(_ id: String, _ group: StatusGroup?, activity: Double, since: Double = 0, title: String = "S", cwd: String = "/Users/test/proj", branch: String? = nil,
                 parent: String? = nil, fork: Bool = false, state: SessionState = .finished) -> SessionRow {
    var d: [String: Any] = ["sessionId": id, "cliSessionId": id, "cwd": cwd, "title": title, "isArchived": false,
                            "lastActivityAt": Int64(activity * 1000)]
    if let branch { d["branch"] = branch }
    if let parent { d["spawnedFrom"] = ["sessionId": parent, "title": "\(title) (side)", "userFork": fork] }
    let s = try! DesktopSession(json: JSONSerialization.data(withJSONObject: d))
    return SessionRow(session: s, status: SessionStatus(state, since: Date(timeIntervalSince1970: since), group: group))
}

@Test func sortOrderPerGroup() {
    let g = group([
        row("n1", .yourTurn, activity: 9, since: 300), row("n2", .yourTurn, activity: 1, since: 100),
        row("r1", .running, activity: 1), row("r2", .running, activity: 5),
        row("i1", .quiet, activity: 2), row("i2", .quiet, activity: 7),
    ], query: "")
    #expect(g.yourTurn.map(\.id) == ["n2", "n1"])
    #expect(g.running.map(\.id) == ["r2", "r1"])
    #expect(g.quiet.map(\.id) == ["i2", "i1"])
    #expect(g.yourTurn.count == 2)
}

private let now = Date(timeIntervalSince1970: 3600)

/// Last Call (spec 3.2) has every unread session in a counted state, until the user opens it; a waiting one (Needs
/// input, Failed) stays after it is opened while `keepWaiting`. The pill tells the results apart from the waits.
@Test func lastCallHasUnreadUntilOpened() {
    let rows = [row("r", nil, activity: 1, state: .ready), row("n", nil, activity: 2, state: .needsInput),
                row("f", nil, activity: 3, state: .finished), row("o", nil, activity: 4, state: .offline)]
    let g = group(rows, query: "", rule: LastCallRule(), now: now)
    #expect(g.yourTurn.map(\.id).sorted() == ["f", "n", "r"] && g.quiet.map(\.id) == ["o"])
    #expect(g.unseenYourTurn == 3 && g.unseenResults == 2)
    var marks = SessionMarks()
    for id in ["r", "n", "f"] { marks.markSeen(id, at: Date(timeIntervalSince1970: 1)) }
    let read = group(rows, query: "", marks: marks, rule: LastCallRule(), now: now)
    #expect(read.yourTurn.map(\.id) == ["n"] && read.quiet.map(\.id).sorted() == ["f", "o", "r"] && read.unseenYourTurn == 0)
    // Without keepWaiting an opened wait leaves too, to Running: its work waits to go on.
    var rule = LastCallRule()
    rule.keepWaiting = false
    #expect(group(rows, query: "", marks: marks, rule: rule, now: now).running.map(\.id) == ["n"])
    // A state left out of Last Call goes to its own tile.
    rule.states = [.needsInput]
    #expect(group(rows, query: "", rule: rule, now: now).yourTurn.map(\.id) == ["n"])
}

/// Older comes from the Aged time (Settings > Filters), not from the classifier; a waiting row never ages.
@Test func agedTimeMakesOlder() {
    let rows = [row("f", nil, activity: 0, state: .finished), row("n", nil, activity: 0, state: .needsInput)]
    var rule = LastCallRule()
    rule.agedHours = 2
    #expect(group(rows, query: "", includeOlder: true, rule: rule, now: now).older.isEmpty)
    rule.agedHours = 1
    let g = group(rows, query: "", includeOlder: true, rule: rule, now: now.addingTimeInterval(1))
    #expect(g.older.map(\.id) == ["f"] && g.yourTurn.map(\.id) == ["n"])
}

/// An unseen failure turns the pill red, over orange (spec 5.7); an opened one leaves the count.
@Test func failedCountsApart() {
    let rows = [row("x", nil, activity: 1, state: .failed), row("n", nil, activity: 2, state: .needsInput)]
    #expect(group(rows, query: "", rule: LastCallRule(), now: now).unseenFailed == 1)
    var marks = SessionMarks()
    marks.markSeen("x", at: Date(timeIntervalSince1970: 1))
    #expect(group(rows, query: "", marks: marks, rule: LastCallRule(), now: now).unseenFailed == 0)
}

/// A sub-agent never alerts: the agent that started it handles its result and asks the user itself. A waiting one keeps
/// its parent Running, since the parent's work goes on.
@Test func subAgentNeverAlerts() {
    func thread(_ id: String, _ state: SessionState, parent: String? = nil) -> SessionRow {
        SessionRow(thread: CodexThread(id: id, title: id, cwd: "/p", branch: nil, updatedAt: Date(timeIntervalSince1970: 1), rolloutPath: "",
                                       parentId: parent), status: SessionStatus(state, since: .distantPast))
    }
    let rows = [thread("main", .working), thread("a", .needsInput, parent: "main"), thread("b", .ready, parent: "main"),
                thread("c", .failed, parent: "main")]
    let g = group(rows, query: "", rule: LastCallRule(), now: Date(timeIntervalSince1970: 2))
    #expect(g.yourTurn.isEmpty && g.unseenYourTurn == 0)
    #expect(g.running.map(\.id) == ["codex:main"] && g.running[0].children.count == 3)
    // Count sub-agents (Settings > Filters): they alert like other sessions.
    var rule = LastCallRule()
    rule.subAgents = true
    #expect(group(rows, query: "", rule: rule, now: Date(timeIntervalSince1970: 2)).unseenYourTurn == 3)
}

@Test func olderOnlyWhenSearching() {
    let rows = [row("o1", .older, activity: 1, title: "Old thing"), row("i1", .quiet, activity: 2, title: "New thing")]
    #expect(group(rows, query: "").older.isEmpty)
    #expect(group(rows, query: "old").older.map(\.id) == ["o1"])
    #expect(group(rows, query: "old").quiet.isEmpty)
}

@Test func searchMatchesTitleFolderBranch() {
    let rows = [row("a", .quiet, activity: 1, title: "Café plan", cwd: "/x/one"), row("b", .quiet, activity: 2, cwd: "/Users/test/proj"),
                row("c", .quiet, activity: 3, cwd: "/x/other", branch: "feat/ecg")]
    #expect(group(rows, query: "cafe").quiet.map(\.id) == ["a"])
    #expect(group(rows, query: "PROJ").quiet.map(\.id) == ["b"])
    #expect(group(rows, query: "ECG").quiet.map(\.id) == ["c"])
}

@Test func hiddenNeverShown() {
    let g = group([row("h", .hidden, activity: 1, title: "match")], query: "match")
    #expect(g.yourTurn.isEmpty && g.running.isEmpty && g.quiet.isEmpty && g.older.isEmpty)
}

@Test func childThatNeedsInputLiftsItsParent() {
    let rows = [row("p", .quiet, activity: 5, title: "Plan"), row("c", .yourTurn, activity: 4, since: 10, title: "Fix", parent: "p"),
                row("r", .running, activity: 1, cwd: "/x/other", parent: nil)]
    let g = group(rows, query: "")
    #expect(g.yourTurn.map(\.id) == ["p"] && g.yourTurn[0].children.map(\.id) == ["c"])
    #expect(g.quiet.isEmpty && g.running.map(\.id) == ["r"])
    // Counts are of sessions: the child counts in Your Turn, its parent in Quiet.
    #expect(g.sessions.count { $0.status.group == .yourTurn } == 1 && g.sessions.count { $0.status.group == .quiet } == 1)
    #expect(projectSections(g, filter: .all) { $0 }.map(\.id) == ["/Users/test/proj", "/x/other"])
    #expect(projectSections(g, filter: .yourTurn) { $0 }.flatMap(\.rows).map(\.id) == ["p"])
}

@Test func childWithoutAListedParentIsARowOfItsOwn() {
    let parent = row("p", .quiet, activity: 5), child = row("c", .quiet, activity: 4, parent: "p")
    #expect(group([child], query: "").quiet.map(\.id) == ["c"])
    var marks = SessionMarks()
    marks.hide("p")
    #expect(group([parent, child], query: "", marks: marks).quiet.map(\.id) == ["c"])
    marks = SessionMarks()
    marks.markDone("p", at: Date(timeIntervalSince1970: 5))
    #expect(group([parent, child], query: "", marks: marks).quiet.map(\.id) == ["c"])
    // A child marked done leaves its parent.
    marks = SessionMarks()
    marks.markDone("c", at: Date(timeIntervalSince1970: 4))
    let g = group([parent, child], query: "", marks: marks)
    #expect(g.quiet.map(\.id) == ["p"] && g.quiet[0].children.isEmpty)
}

@Test func searchMatchesChildTitles() {
    let rows = [row("p", .quiet, activity: 5, title: "Plan"), row("c1", .quiet, activity: 4, title: "Fix tests", parent: "p"),
                row("c2", .quiet, activity: 3, title: "Read docs", parent: "p")]
    let byChild = group(rows, query: "fix")
    #expect(byChild.quiet.map(\.id) == ["p"] && byChild.quiet[0].children.map(\.id) == ["c1"])
    let byParent = group(rows, query: "plan")
    #expect(byParent.quiet.map(\.id) == ["p"] && byParent.quiet[0].children.map(\.id) == ["c1", "c2"])
}

@Test func grandchildJoinsItsRootSession() {
    let rows = [row("p", .quiet, activity: 5), row("c", .quiet, activity: 4, parent: "p"), row("g", .quiet, activity: 3, parent: "c")]
    let g = group(rows, query: "")
    #expect(g.quiet.map(\.id) == ["p"] && g.quiet[0].children.map(\.id) == ["c", "g"])
}

/// A side session or fork that kept its parent's title shows as "Fork", or as the title it was started with.
@Test func childWithItsParentsTitleGetsItsOwnName() {
    let rows = [row("p", .quiet, activity: 5, title: "Plan"), row("f", .quiet, activity: 4, title: "Plan", parent: "p", fork: true),
                row("s", .quiet, activity: 3, title: "Plan", parent: "p"), row("o", .quiet, activity: 2, title: "Other", parent: "p")]
    #expect(group(rows, query: "").quiet[0].children.map(\.title) == ["Fork", "Plan (side)", "Other"])
}

/// A child in its parent's folder is direct; one in another folder (a worktree) is isolated.
@Test func childInAnotherFolderIsIsolated() {
    let rows = [row("p", .quiet, activity: 5), row("d", .quiet, activity: 4, cwd: "/Users/test/proj/", parent: "p"),
                row("i", .quiet, activity: 3, cwd: "/Users/test/.worktrees/green-harbor", parent: "p")]
    #expect(group(rows, query: "").quiet[0].children.map(\.isIsolated) == [false, true])
}
