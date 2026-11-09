import Foundation

/// One time a session waited for the user (spec 2.11): its time in Last Call in one of Needs input, Failed or Ready.
/// It starts at the state's since and ends at the first regroup where the row is no longer in Last Call with that state
/// and since.
public struct WaitInterval: Sendable, Equatable {
    /// The states that count, in the chart's stack order.
    public static let states: [SessionState] = [.needsInput, .failed, .ready]
    /// The longest title a line keeps.
    public static let titleLimit = 120

    public var start: Date
    public var end: Date
    public var state: SessionState
    /// `SessionRow.sourceName`: claude, codex, pi or a herdr agent's name.
    public var source: String
    public var rowId: String
    /// The project folder's name.
    public var project: String
    public var title: String

    public init(start: Date, end: Date, state: SessionState, source: String, rowId: String, project: String, title: String) {
        (self.start, self.end, self.state, self.source, self.rowId, self.project, self.title) = (start, end, state, source, rowId, project, title)
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// One line of a history file: `<start ms>\t<end ms>\t<state>\t<source>\t<row id>\t<project>\t<title>\n`, with no
    /// tab or line break in a text field and the title cut to `titleLimit` characters.
    public var line: String {
        [String(Self.ms(start)), String(Self.ms(end)), state.rawValue, Self.clean(source), Self.clean(rowId), Self.clean(project),
         String(Self.clean(title).prefix(Self.titleLimit))].joined(separator: "\t") + "\n"
    }

    /// nil for a malformed line.
    public init?(line: Substring) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard f.count == 7, let start = Int64(f[0]), let end = Int64(f[1]), start <= end,
              let state = SessionState(rawValue: String(f[2])), Self.states.contains(state) else { return nil }
        self.init(start: Date(timeIntervalSince1970: Double(start) / 1000), end: Date(timeIntervalSince1970: Double(end) / 1000), state: state,
                  source: String(f[3]), rowId: String(f[4]), project: String(f[5]), title: String(f[6]))
    }

    /// The intervals of a file's text; malformed lines are left out.
    public static func parse(_ text: String) -> [WaitInterval] { text.split(separator: "\n").compactMap { WaitInterval(line: $0) } }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// A space in place of each tab and line break.
    static func clean(_ text: String) -> String { String(text.map { $0 == "\t" || $0.isNewline ? " " : $0 }) }
}

/// Which waits closed since the last check (spec 2.11). A pure tracker, like `PushQueue`: the app gives it the rows of
/// each regroup and writes the intervals it returns. Open waits are kept only in memory: at quit nothing is written, and
/// after a launch a row that still waits starts again at its since, so no time counts twice.
public struct WaitTracker: Sendable {
    private struct Key: Hashable, Sendable {
        let id: String
        let state: SessionState
        let since: Date
    }

    private var open: [Key: WaitInterval] = [:]

    public init() {}

    /// `rows`: the sessions of the list groups, children too. Returns the waits that ended, oldest first, with `now` as
    /// their end. `project` names a row's project.
    public mutating func check(_ rows: [SessionRow], now: Date, project: (SessionRow) -> String) -> [WaitInterval] {
        var current: [Key: WaitInterval] = [:]
        for r in rows where r.status.group == .yourTurn && WaitInterval.states.contains(r.status.state) {
            current[Key(id: r.id, state: r.status.state, since: r.status.since)] = WaitInterval(
                start: r.status.since, end: now, state: r.status.state, source: r.sourceName, rowId: r.id, project: project(r), title: r.title)
        }
        let closed = open.filter { current[$0.key] == nil }.values.map { i in
            var i = i
            i.end = now
            return i
        }
        open = current
        return closed.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    /// The waits still open, with `now` as their end, so the time until now counts.
    public func live(now: Date) -> [WaitInterval] {
        open.values.map { i in
            var i = i
            i.end = now
            return i
        }
        .filter { $0.end > $0.start }
    }
}

/// The days the History page counts: today, or the last 7 or 30 days with today.
public enum HistoryPeriod: String, CaseIterable, Sendable {
    case today, week, month

    public var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }

    /// The start of the first day.
    public func start(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: now))!
    }

    /// The files that can hold its intervals: one per day from the first day to today. An interval is in the file of
    /// the day it ended, so one that started before the period is in one of them too.
    public func fileNames(now: Date, calendar: Calendar) -> [String] {
        (0..<days).map { HistoryFile.name(for: calendar.date(byAdding: .day, value: -$0, to: now)!, calendar: calendar) }
    }
}

/// History files: `<yyyy-MM-dd>.tsv`, by the local date an interval ended.
public enum HistoryFile {
    /// Days of history that stay.
    public static let keepDays = 90

    public static func name(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.tsv", c.year!, c.month!, c.day!)
    }

    /// The day a file name gives; nil for another name.
    public static func day(of name: String, calendar: Calendar) -> Date? {
        guard name.hasSuffix(".tsv") else { return nil }
        let parts = name.dropLast(4).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// The history files of days more than `keepDays` before today. Other files stay.
    public static func expired(_ names: [String], now: Date, calendar: Calendar) -> [String] {
        let first = calendar.date(byAdding: .day, value: -keepDays, to: calendar.startOfDay(for: now))!
        return names.filter { day(of: $0, calendar: calendar).map { $0 < first } ?? false }
    }
}

/// Splits `start..<end` at each start of `component` (an hour or a day): the start of each part's bucket and its seconds.
public func buckets(_ start: Date, _ end: Date, by component: Calendar.Component, calendar: Calendar) -> [(start: Date, seconds: TimeInterval)] {
    var parts: [(start: Date, seconds: TimeInterval)] = []
    var t = start
    while t < end, let bucket = calendar.dateInterval(of: component, for: t) {
        let partEnd = min(bucket.end, end)
        parts.append((bucket.start, partEnd.timeIntervalSince(t)))
        t = partEnd
    }
    return parts
}

/// The median of `values`; 0 for none.
public func median(_ values: [TimeInterval]) -> TimeInterval {
    let v = values.sorted()
    guard !v.isEmpty else { return 0 }
    return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
}

/// What the History page shows for a period (spec 5.4): the waits that overlap it, with their time cut to it.
public struct HistorySummary: Sendable, Equatable {
    /// The time of one state in an hour (Today) or a day.
    public struct Bar: Sendable, Equatable {
        public let start: Date
        public let state: SessionState
        public let seconds: TimeInterval
    }

    /// One hour of one weekday (1 is Sunday, as `Calendar` counts): the seconds waited, or for 30 days their average per
    /// weekday.
    public struct Cell: Sendable, Equatable {
        public let weekday: Int
        public let hour: Int
        public let seconds: TimeInterval
    }

    public struct Share: Sendable, Equatable {
        public let name: String
        public let seconds: TimeInterval
    }

    /// Time waited in the period.
    public var total: TimeInterval = 0
    public var count = 0
    /// Of the whole waits, also the parts out of the period.
    public var median: TimeInterval = 0
    /// In stack order (Needs input, Failed, Ready) within each start.
    public var bars: [Bar] = []
    public var cells: [Cell] = []
    /// The 5 longest waits, longest first.
    public var longest: [WaitInterval] = []
    /// Most time first.
    public var byProject: [Share] = []
    public var byAgent: [Share] = []

    public init() {}

    public init(_ intervals: [WaitInterval], period: HistoryPeriod, now: Date, calendar: Calendar) {
        let first = period.start(now: now, calendar: calendar)
        let inPeriod = intervals.filter { $0.start < now && $0.end > first }
        count = inPeriod.count
        median = RoundsCore.median(inPeriod.map(\.duration))
        longest = Array(inPeriod.sorted { $0.duration > $1.duration }.prefix(5))
        var bars: [Date: [SessionState: TimeInterval]] = [:]
        var cells: [Int: TimeInterval] = [:]
        var projects: [String: TimeInterval] = [:], agents: [String: TimeInterval] = [:]
        for i in inPeriod {
            let start = max(i.start, first), end = min(i.end, now)
            let seconds = end.timeIntervalSince(start)
            total += seconds
            projects[i.project, default: 0] += seconds
            agents[i.source, default: 0] += seconds
            for part in buckets(start, end, by: .hour, calendar: calendar) {
                let bar = period == .today ? part.start : calendar.startOfDay(for: part.start)
                bars[bar, default: [:]][i.state, default: 0] += part.seconds
                let c = calendar.dateComponents([.weekday, .hour], from: part.start)
                cells[c.weekday! * 24 + c.hour!, default: 0] += part.seconds
            }
        }
        self.bars = bars.keys.sorted().flatMap { start in
            WaitInterval.states.compactMap { s in bars[start]?[s].map { Bar(start: start, state: s, seconds: $0) } }
        }
        // How often each weekday is in the period, for the average.
        var weekdays: [Int: Int] = [:]
        for d in 0..<period.days { weekdays[calendar.component(.weekday, from: calendar.date(byAdding: .day, value: d, to: first)!), default: 0] += 1 }
        self.cells = cells.keys.sorted().map { key in
            Cell(weekday: key / 24, hour: key % 24, seconds: cells[key]! / Double(weekdays[key / 24] ?? 1))
        }
        func shares(_ d: [String: TimeInterval]) -> [Share] {
            d.map { Share(name: $0.key, seconds: $0.value) }.sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) }
        }
        byProject = shares(projects)
        byAgent = shares(agents)
    }
}
