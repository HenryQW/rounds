import Foundation
import Testing
@testable import RoundsCore

private func row(_ state: SessionState, id: String = "s1", since: Double = 0, title: String = "Fix login") -> SessionRow {
    let d: [String: Any] = ["sessionId": id, "cliSessionId": id, "cwd": "/Users/test/atlas", "title": title, "isArchived": false,
                            "lastActivityAt": since * 1000]
    return SessionRow(session: try! DesktopSession(json: JSONSerialization.data(withJSONObject: d)),
                      status: SessionStatus(state, since: Date(timeIntervalSince1970: since)))
}

private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }
private func project(_ r: SessionRow) -> String { URL(fileURLWithPath: r.cwd).lastPathComponent }
/// The rows as the app checks them: placed by `LastCallRule` (a seen result leaves Last Call).
private func placed(_ rows: [SessionRow], seen: [String: Double] = [:], now: Double) -> [SessionRow] {
    var marks = SessionMarks()
    for (id, t) in seen { marks.markSeen(id, at: at(t)) }
    return group(rows, query: "", marks: marks, rule: LastCallRule(), now: at(now)).sessions
}

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

// MARK: - Lines

@Test func lineRoundTrip() {
    let i = WaitInterval(start: Date(timeIntervalSince1970: 1_700_000_000.123), end: Date(timeIntervalSince1970: 1_700_000_300.456),
                         state: .needsInput, source: "claude", rowId: "s1", project: "atlas", title: "Fix login")
    #expect(i.line == "1700000000123\t1700000300456\tneedsInput\tclaude\ts1\tatlas\tFix login\n")
    #expect(WaitInterval.parse(i.line) == [i])
}

@Test func lineCleansText() {
    let i = WaitInterval(start: at(0), end: at(1), state: .ready, source: "co\tdex", rowId: "a\nb", project: "p\r\nq",
                         title: "Line one\nline\ttwo" + String(repeating: "x", count: 200))
    let fields = i.line.dropLast().split(separator: "\t", omittingEmptySubsequences: false)
    #expect(fields.count == 7)
    #expect(fields[3] == "co dex" && fields[4] == "a b" && fields[5] == "p q")
    #expect(fields[6].count == WaitInterval.titleLimit)
    #expect(fields[6].hasPrefix("Line one line two"))
}

@Test func malformedLinesAreSkipped() {
    let text = """
        1000\t2000\tfailed\tcodex\tcodex:t\tharbor\tRetry
        1000\t2000\tfailed\tcodex
        x\t2000\tfailed\tcodex\tid\tp\tt
        3000\t2000\tfailed\tcodex\tid\tp\tt
        1000\t2000\tworking\tcodex\tid\tp\tt

        """
    #expect(WaitInterval.parse(text).map(\.rowId) == ["codex:t"])
}

// MARK: - Tracker

@Test func waitOpensAndCloses() {
    var t = WaitTracker()
    #expect(t.check(placed([row(.needsInput, since: 100)], now: 150), now: at(150), project: project).isEmpty)
    #expect(t.live(now: at(160)).map(\.duration) == [60])
    let closed = t.check(placed([row(.working, since: 200)], now: 200), now: at(200), project: project)
    #expect(closed == [WaitInterval(start: at(100), end: at(200), state: .needsInput, source: "claude", rowId: "s1", project: "atlas", title: "Fix login")])
    #expect(t.live(now: at(210)).isEmpty)
}

@Test func stateChangeInLastCallClosesAndOpens() {
    var t = WaitTracker()
    _ = t.check(placed([row(.needsInput, since: 100)], now: 150), now: at(150), project: project)
    let closed = t.check(placed([row(.failed, since: 180)], now: 190), now: at(190), project: project)
    #expect(closed.map(\.state) == [.needsInput])
    #expect(closed.map(\.duration) == [90])
    #expect(t.live(now: at(200)).map(\.state) == [.failed])
    #expect(t.live(now: at(200)).map(\.start) == [at(180)])
}

@Test func goneRowCloses() {
    var t = WaitTracker()
    _ = t.check(placed([row(.failed, since: 100), row(.ready, id: "s2", since: 120)], now: 150), now: at(150), project: project)
    let closed = t.check(placed([row(.ready, id: "s2", since: 120)], now: 170), now: at(170), project: project)
    #expect(closed.map(\.rowId) == ["s1"])
    #expect(t.live(now: at(170)).map(\.rowId) == ["s2"])
}

@Test func seenReadyCloses() {
    var t = WaitTracker()
    let ready = row(.ready, since: 100)
    _ = t.check(placed([ready], now: 150), now: at(150), project: project)
    // The user opens it at 160: it leaves Last Call, so its wait ends at the next check.
    let closed = t.check(placed([ready], seen: ["s1": 160], now: 165), now: at(165), project: project)
    #expect(closed.map(\.duration) == [65])
}

@Test func seenWaitStaysOpen() {
    var t = WaitTracker()
    let wait = row(.needsInput, since: 100)
    _ = t.check(placed([wait], now: 150), now: at(150), project: project)
    #expect(t.check(placed([wait], seen: ["s1": 160], now: 165), now: at(165), project: project).isEmpty)
}

@Test func sinceMoveInTheSameStateKeepsOneWait() {
    // A Notification (permission_prompt) after a PermissionRequest moves the since; the wait stays one.
    var t = WaitTracker()
    _ = t.check(placed([row(.needsInput, since: 100)], now: 150), now: at(150), project: project)
    #expect(t.check(placed([row(.needsInput, since: 120)], now: 160), now: at(160), project: project).isEmpty)
    #expect(t.live(now: at(170)).map(\.start) == [at(100)])
    let closed = t.check(placed([row(.working, since: 200)], now: 200), now: at(200), project: project)
    #expect(closed.map(\.start) == [at(100)])
    #expect(closed.map(\.duration) == [100])
}

@Test func returnWithTheSameSinceStartsWhenItComesBack() {
    // Mark as Done, then undo: the row leaves Last Call and comes back with the same since. No minute counts twice,
    // and the time out of Last Call does not count.
    var t = WaitTracker()
    let wait = row(.needsInput, since: 100)
    _ = t.check(placed([wait], now: 150), now: at(150), project: project)
    #expect(t.check([], now: at(200), project: project).map(\.start) == [at(100)])
    #expect(t.check(placed([wait], now: 300), now: at(300), project: project).isEmpty)
    #expect(t.live(now: at(310)).map(\.start) == [at(300)])
    let closed = t.check(placed([row(.working, since: 400)], now: 400), now: at(400), project: project)
    #expect(closed.map(\.start) == [at(300)])
}

@Test func seenFailedCloses() {
    // A Failed wait measures attention: it ends when the user opens it, though it stays in Last Call.
    var t = WaitTracker()
    let failed = row(.failed, since: 100)
    _ = t.check(placed([failed], now: 150), now: at(150), project: project)
    let closed = t.check(placed([failed], seen: ["s1": 160], now: 165), now: at(165), project: project)
    #expect(closed.map(\.duration) == [65])
    #expect(t.check(placed([failed], seen: ["s1": 160], now: 200), now: at(200), project: project).isEmpty)
    #expect(t.live(now: at(210)).isEmpty)
}

@Test func seenFailedAtLaunchDoesNotCount() {
    // A Failed from a week ago that the user already opened adds no time.
    var t = WaitTracker()
    let failed = row(.failed, since: 0)
    _ = t.check(placed([failed], seen: ["s1": 10], now: 7 * 86400), now: at(7 * 86400), project: project)
    #expect(t.live(now: at(7 * 86400 + 60)).isEmpty)
}

@Test func firstCheckAfterLaunchStartsAtSince() {
    // Rows that waited before the launch start at their since and do not close.
    var t = WaitTracker()
    #expect(t.check(placed([row(.needsInput, since: 100), row(.ready, id: "s2", since: 50)], now: 1000), now: at(1000), project: project).isEmpty)
    #expect(Set(t.live(now: at(1000)).map(\.start)) == [at(100), at(50)])
}

@Test func finishedInLastCallDoesNotCount() {
    var t = WaitTracker()
    _ = t.check(placed([row(.finished, since: 100)], now: 150), now: at(150), project: project)
    #expect(t.live(now: at(160)).isEmpty)
}

// MARK: - Buckets and summary

@Test func bucketsSplitAtHour() {
    let start = utc.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9, minute: 50))!
    let parts = buckets(start, start.addingTimeInterval(25 * 60), by: .hour, calendar: utc)
    #expect(parts.map(\.seconds) == [600, 900])
    #expect(parts.map { utc.component(.hour, from: $0.start) } == [9, 10])
}

@Test func bucketsSplitAtMidnight() {
    let start = utc.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 23, minute: 45))!
    let parts = buckets(start, start.addingTimeInterval(30 * 60), by: .day, calendar: utc)
    #expect(parts.map(\.seconds) == [900, 900])
    #expect(parts.map { utc.component(.day, from: $0.start) } == [8, 9])
}

@Test func medianOfOddEvenAndNone() {
    #expect(median([300, 60, 120]) == 120)
    #expect(median([60, 120, 180, 600]) == 150)
    #expect(median([]) == 0)
}

@Test func summaryCutsToPeriodAndSplitsByDay() {
    let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
    let midnight = utc.startOfDay(for: now)
    func wait(_ state: SessionState, _ from: Date, minutes: Double, project: String = "atlas") -> WaitInterval {
        WaitInterval(start: from, end: from.addingTimeInterval(minutes * 60), state: state, source: "claude", rowId: "r", project: project, title: "T")
    }
    let across = wait(.needsInput, midnight.addingTimeInterval(-15 * 60), minutes: 30)
    let failed = wait(.failed, now.addingTimeInterval(-3600), minutes: 10, project: "harbor")
    let old = wait(.ready, midnight.addingTimeInterval(-3 * 86400), minutes: 60)

    let today = HistorySummary([across, failed, old], period: .today, now: now, calendar: utc)
    #expect(today.count == 2)
    #expect(today.total == 25 * 60)
    #expect(today.median == 20 * 60)
    #expect(today.bars.map(\.seconds) == [15 * 60, 10 * 60])
    #expect(today.longest.map(\.state) == [.needsInput, .failed])
    #expect(today.byProject.map(\.name) == ["atlas", "harbor"])

    let week = HistorySummary([across, failed, old], period: .week, now: now, calendar: utc)
    #expect(week.count == 3 && week.total == 100 * 60)
    #expect(week.bars.map { utc.component(.day, from: $0.start) } == [6, 8, 9, 9])
    #expect(week.bars.filter { utc.component(.day, from: $0.start) == 9 }.map(\.state) == [.needsInput, .failed])
    // Each weekday is in 7 days once: the cells hold minutes.
    #expect(week.cells.filter { $0.hour == 23 } == [HistorySummary.Cell(weekday: 1, hour: 23, seconds: 15 * 60)])
}

@Test func monthCellsAverageByWeekday() {
    let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!  // a Monday
    let monday = utc.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 10))!
    let i = WaitInterval(start: monday, end: monday.addingTimeInterval(20 * 60), state: .needsInput, source: "codex", rowId: "r", project: "p", title: "T")
    let month = HistorySummary([i], period: .month, now: now, calendar: utc)
    // 30 days back from Monday 9 November hold 5 Mondays.
    #expect(month.cells == [HistorySummary.Cell(weekday: 2, hour: 10, seconds: 4 * 60)])
}

// MARK: - Files

@Test func fileNamesOfPeriod() {
    let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 1))!
    #expect(HistoryPeriod.today.fileNames(now: now, calendar: utc) == ["2026-11-02.tsv"])
    #expect(HistoryPeriod.week.fileNames(now: now, calendar: utc).suffix(2) == ["2026-10-28.tsv", "2026-10-27.tsv"])
    #expect(HistoryPeriod.month.fileNames(now: now, calendar: utc).count == 30)
}

@Test func retentionKeeps90Days() {
    let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 8))!
    let names = ["2026-11-09.tsv", "2026-08-11.tsv", "2026-08-10.tsv", "2025-01-01.tsv", "notes.txt", "2026-xx-01.tsv"]
    #expect(HistoryFile.expired(names, now: now, calendar: utc) == ["2026-08-10.tsv", "2025-01-01.tsv"])
}
