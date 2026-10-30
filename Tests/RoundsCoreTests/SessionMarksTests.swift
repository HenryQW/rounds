import Foundation
import Testing
@testable import RoundsCore

private func row(_ id: String, _ group: StatusGroup = .quiet, activity: Double, title: String = "S", starred: Bool = false,
                 focused: Double? = nil) -> SessionRow {
    var d: [String: Any] = ["sessionId": id, "cliSessionId": id, "cwd": "/Users/test/proj", "title": title, "isArchived": false,
                            "lastActivityAt": Int64(activity * 1000), "isStarred": starred]
    if let focused { d["lastFocusedAt"] = Int64(focused * 1000) }
    let s = try! DesktopSession(json: JSONSerialization.data(withJSONObject: d))
    return SessionRow(session: s, status: SessionStatus(.finished, since: s.lastActivityAt, group: group))
}

@Test func doneHidesUntilNewActivity() {
    var marks = SessionMarks()
    marks.markDone("a", at: Date(timeIntervalSince1970: 100))
    #expect(group([row("a", activity: 90)], query: "", marks: marks).quiet.isEmpty)
    #expect(group([row("a", activity: 100)], query: "", marks: marks).quiet.isEmpty)
    #expect(group([row("a", activity: 101)], query: "", marks: marks).quiet.map(\.id) == ["a"])
}

@Test func doneRowShowsWhenSearching() {
    var marks = SessionMarks()
    marks.markDone("a", at: Date(timeIntervalSince1970: 100))
    #expect(group([row("a", .yourTurn, activity: 90, title: "Plan")], query: "plan", marks: marks).yourTurn.map(\.id) == ["a"])
}

@Test func hiddenRowsShowOnlyInSearchInTheirOwnGroup() {
    var marks = SessionMarks()
    marks.hide("a")
    let rows = [row("a", .yourTurn, activity: 1, title: "Plan"), row("b", .yourTurn, activity: 2, title: "Plan B")]
    let plain = group(rows, query: "", marks: marks)
    #expect(plain.yourTurn.map(\.id) == ["b"] && plain.hidden.isEmpty && plain.yourTurn.count == 1)
    let searched = group(rows, query: "plan", marks: marks)
    #expect(searched.hidden.map(\.id) == ["a"])
    #expect(searched.yourTurn.map(\.id) == ["b"])
    marks.unhide("a")
    #expect(group(rows, query: "", marks: marks).yourTurn.count == 2)
}

@Test func marksSurviveEncoding() throws {
    var marks = SessionMarks()
    marks.markDone("a", at: Date(timeIntervalSince1970: 100))
    marks.hide("b")
    #expect(try JSONDecoder().decode(SessionMarks.self, from: JSONEncoder().encode(marks)) == marks)
}

@Test func starredRowsGoToTheStarredGroup() {
    var marks = SessionMarks()
    marks.toggleStar("local")
    let rows = [row("claude", .older, activity: 1, starred: true), row("local", .yourTurn, activity: 2), row("plain", activity: 3)]
    let g = group(rows, query: "", marks: marks)
    // A star keeps an older session in view too.
    #expect(Set(g.starred.map(\.id)) == ["claude", "local"] && g.quiet.map(\.id) == ["plain"] && g.yourTurn.isEmpty)
    #expect(g.sessions.count { $0.status.group == .yourTurn } == 1)
    // Done still takes a starred row out of the list.
    marks.markDone("local", at: Date(timeIntervalSince1970: 10))
    #expect(group(rows, query: "", marks: marks).starred.map(\.id) == ["claude"])
    // The starred section comes first, with the starred rows of the filter's group (decided 2026-10-30).
    let sections = projectSections(g, filter: .yourTurn) { $0 }
    #expect(sections.first?.id == ProjectSection.starredId && sections.first?.rows.map(\.id) == ["local"])
}

@Test func marksFromBeforeStarsStillLoad() throws {
    let old = #"{"done":{},"hidden":["a"]}"#
    let marks = try JSONDecoder().decode(SessionMarks.self, from: Data(old.utf8))
    #expect(marks.hidden == ["a"] && marks.starred.isEmpty)
}

@Test func needInputIsSeenOnceOpenedAfterTheWaitBegan() {
    var marks = SessionMarks()
    marks.markSeen("opened", at: Date(timeIntervalSince1970: 20))
    marks.markSeen("before", at: Date(timeIntervalSince1970: 5))
    let rows = [row("opened", .yourTurn, activity: 10), row("before", .yourTurn, activity: 10),
                row("focused", .yourTurn, activity: 10, focused: 15), row("new", .yourTurn, activity: 10)]
    let g = group(rows, query: "", marks: marks)
    #expect(Set(g.yourTurn.filter(\.isSeen).map(\.id)) == ["opened", "focused"])
    // Only unseen sessions call for the user: the pill and the tile count them.
    #expect(g.unseenYourTurn == 2)
}

@Test func filteredSubtitleDropsTheStateWord() {
    #expect(SessionStatus(.needsInput, "Question", since: .distantPast).shortLabel == "Question")
    #expect(SessionStatus(.finished, since: .distantPast).shortLabel == "Finished")
    // Failed shares the Your Turn group, so it keeps its word.
    #expect(SessionStatus(.failed, "error", since: .distantPast).shortLabel == "Failed · error")
}
