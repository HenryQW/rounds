import Charts
import Observation
import RoundsCore
import SwiftUI

/// The History page's choices, kept across openings, and its data, held only while the page shows (spec 5.4).
@MainActor @Observable
final class HistoryState {
    static let shared = HistoryState()

    enum ChartTab: String { case minutes, slowHours }
    enum Split: String { case project, agent }

    var period = HistoryPeriod(rawValue: appDefaults.string(forKey: "historyPeriod") ?? "") ?? .week {
        didSet {
            appDefaults.set(period.rawValue, forKey: "historyPeriod")
            if period != oldValue, summary != nil { load() }
        }
    }
    /// The tab the user picked; Today shows Minutes Waited whatever it is (`shownChart`).
    var chart = ChartTab(rawValue: appDefaults.string(forKey: "historyChart") ?? "") ?? .minutes {
        didSet { appDefaults.set(chart.rawValue, forKey: "historyChart") }
    }
    var split = Split(rawValue: appDefaults.string(forKey: "historySplit") ?? "") ?? .project {
        didSet { appDefaults.set(split.rawValue, forKey: "historySplit") }
    }
    /// nil while the page is closed.
    private(set) var summary: HistorySummary?
    /// The hour or day under the pointer in Minutes Waited.
    var selectedBar: Date?
    /// The Longest waits row under the pointer, which then shows the grey hover fill.
    var hoveredWait: Int?
    /// A newer load drops the result of an older one.
    @ObservationIgnored private var generation = 0

    var shownChart: ChartTab { period == .today ? .minutes : chart }

    func open() { load() }

    /// Releases the data.
    func close() {
        generation += 1
        (summary, selectedBar, hoveredWait) = (nil, nil, nil)
    }

    private func load() {
        generation += 1
        let g = generation
        HistoryStore.shared.load(period) { [weak self] summary in
            guard let self, generation == g else { return }
            self.summary = summary
        }
    }
}

/// When agents waited for the user (spec 5.4): the period, the numbers, one chart at a time, the longest waits and the
/// time by project or agent.
struct HistorySections: View {
    let model: AppModel
    @Bindable var state: HistoryState

    private static let colors: [Color] = [.orange, .red, .green]

    var body: some View {
        let s = state.summary ?? HistorySummary()
        Section {
            Picker(selection: $state.period) {
                Text("Today").tag(HistoryPeriod.today)
                Text("7 Days").tag(HistoryPeriod.week)
                Text("30 Days").tag(HistoryPeriod.month)
            } label: {
                described("Period", "The days to count.")
            }
            .pickerStyle(.segmented)
        }
        Section {
            LabeledContent { Text(Self.duration(s.total)).monospacedDigit() } label: { described("Time waited", "Needs input, Failed or Ready.") }
            LabeledContent { Text("\(s.count)").monospacedDigit() } label: { described("Waits", "Times a session waited.") }
            LabeledContent { Text(Self.duration(s.median)).monospacedDigit() } label: { described("Median wait", "Half the waits were shorter.") }
        } header: {
            Text("Waits")
        }
        Section {
            Picker("", selection: Binding(get: { state.shownChart }, set: { state.chart = $0 })) {
                Text("Minutes Waited").tag(HistoryState.ChartTab.minutes)
                Text("Slow Hours").tag(HistoryState.ChartTab.slowHours).selectionDisabled(state.period == .today)
            }
            .pickerStyle(.segmented).labelsHidden().buttonSizing(.flexible)
            VStack(alignment: .leading, spacing: 8) {
                if state.period == .today { Text("Slow Hours needs 7 days or more.").font(.callout).foregroundStyle(.secondary) }
                switch state.shownChart {
                case .minutes: minutesChart(s)
                case .slowHours: slowHours(s)
                }
            }
        } header: {
            Text("Chart")
        }
        Section {
            if s.longest.isEmpty { Text("No waits in this period.").foregroundStyle(.secondary) }
            ForEach(Array(s.longest.enumerated()), id: \.offset) { i, wait in longestRow(i, wait) }
        } header: {
            Text("Longest waits")
        }
        Section {
            Picker("", selection: $state.split) {
                Text("Project").tag(HistoryState.Split.project)
                Text("Agent").tag(HistoryState.Split.agent)
            }
            .pickerStyle(.segmented).labelsHidden().buttonSizing(.flexible)
            let shares = Array((state.split == .project ? s.byProject : s.byAgent).prefix(8))
            if shares.isEmpty { Text("No waits in this period.").foregroundStyle(.secondary) }
            ForEach(shares, id: \.name) { share in shareRow(share, top: shares[0].seconds) }
        } header: {
            Text("Time waited by")
        }
    }

    // MARK: - Minutes Waited

    private var unit: Calendar.Component { state.period == .today ? .hour : .day }

    /// One bar per hour of today, or per day, split by state (Needs input at the bottom, then Failed, then Ready).
    private func minutesChart(_ s: HistorySummary) -> some View {
        let calendar = Calendar.current, now = Date()
        let first = state.period == .today
            // From 08:00 at the latest, so the hours before now show.
            ? min(s.bars.first?.start ?? now, calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now)!, calendar.dateInterval(of: .hour, for: now)!.start)
            : state.period.start(now: now, calendar: calendar)
        let last = calendar.dateInterval(of: unit, for: now)!.end
        let selected = state.selectedBar.flatMap { calendar.dateInterval(of: unit, for: $0)?.start }
        return VStack(alignment: .leading, spacing: 8) {
            Text(state.period == .today ? "Each hour of today, split by state." : "Each day, split by state.")
                .font(.callout).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(s.bars.enumerated()), id: \.offset) { _, bar in
                    BarMark(x: .value("Time", bar.start, unit: unit), y: .value("Minutes", bar.seconds / 60))
                        .foregroundStyle(by: .value("State", bar.state.title))
                }
                if let selected, s.bars.contains(where: { $0.start == selected }) {
                    RuleMark(x: .value("Time", selected, unit: unit))
                        .foregroundStyle(Color.primary.opacity(0.08))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            barTip(s.bars.filter { $0.start == selected }, at: selected)
                        }
                }
            }
            .chartForegroundStyleScale(domain: WaitInterval.states.map(\.title), range: Self.colors)
            .chartLegend(position: .top, alignment: .leading)
            .chartXScale(domain: first...last)
            .chartXAxis {
                switch state.period {
                case .today:
                    AxisMarks(values: .stride(by: .hour, count: 2)) { _ in AxisValueLabel(format: .dateTime.hour(), centered: true) }
                case .week:
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel(centered: true) {
                            if let day = value.as(Date.self) { Text(calendar.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.abbreviated))) }
                        }
                    }
                case .month:
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) }
                }
            }
            .chartXSelection(value: $state.selectedBar)
            .frame(height: 150)
        }
    }

    /// The minutes of each state in the bar under the pointer.
    private func barTip(_ bars: [HistorySummary.Bar], at start: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.minutes(bars.map(\.seconds).reduce(0, +))).font(.caption.weight(.semibold)).monospacedDigit()
            Text(state.period == .today ? start.formatted(date: .omitted, time: .shortened) : Self.day(start))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(bars, id: \.state) { bar in
                HStack(spacing: 6) {
                    Circle().fill(Self.colors[WaitInterval.states.firstIndex(of: bar.state)!]).frame(width: 7, height: 7)
                    Text(Self.minutes(bar.seconds)).monospacedDigit()
                    Text(bar.state.title).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Slow Hours

    /// Monday first.
    private static let weekdays = [2, 3, 4, 5, 6, 7, 1]

    /// An hour by weekday grid in one grey: the minutes of each hour (7 Days), or their average per weekday (30 Days).
    private func slowHours(_ s: HistorySummary) -> some View {
        let names = Calendar.current.shortWeekdaySymbols
        let seconds = Dictionary(uniqueKeysWithValues: s.cells.map { ($0.weekday * 24 + $0.hour, $0.seconds) })
        let top = s.cells.map(\.seconds).max() ?? 0
        // Work hours at least, wider when a wait came earlier or later.
        let hours = min(8, s.cells.map(\.hour).min() ?? 8)...max(18, s.cells.map(\.hour).max() ?? 18)
        func label(_ hour: Int) -> String { String(format: "%02d", hour) }
        func shade(_ value: TimeInterval) -> Color { .gray.opacity(0.08 + (top > 0 ? 0.82 * value / top : 0)) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(state.period == .week ? "Minutes waited per hour of each day of the last 7 days." : "Average minutes waited per hour of each weekday.")
                .font(.callout).foregroundStyle(.secondary)
            // Numeric bands: Monday is the top row, each hour a column, with a small gap around each cell.
            Chart {
                ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { row, weekday in
                    ForEach(Array(hours), id: \.self) { hour in
                        RectangleMark(xStart: .value("Hour", Double(hour) + 0.05), xEnd: .value("Hour", Double(hour) + 0.95),
                                      yStart: .value("Day", Double(6 - row) + 0.08), yEnd: .value("Day", Double(7 - row) - 0.08))
                            .foregroundStyle(shade(seconds[weekday * 24 + hour] ?? 0))
                            .cornerRadius(2)
                    }
                }
            }
            .chartXScale(domain: Double(hours.lowerBound)...Double(hours.upperBound + 1))
            .chartYScale(domain: 0...7)
            .chartXAxis {
                AxisMarks(values: hours.filter { $0 % 2 == 0 }.map { Double($0) + 0.5 }) { value in
                    AxisValueLabel { Text(label(Int(value.as(Double.self) ?? 0))) }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: (0..<7).map { Double($0) + 0.5 }) { value in
                    AxisValueLabel { Text(names[Self.weekdays[6 - Int(value.as(Double.self) ?? 0)] - 1]) }
                }
            }
            .frame(height: 150)
            HStack(spacing: 4) {
                Text("0 min")
                ForEach(0..<5, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(shade(top * Double($0) / 4)).frame(width: 12, height: 8) }
                Text(Self.minutes(top))
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    // MARK: - Rows

    /// A click opens the session while it is still listed; only then does the row show the grey hover fill.
    private func longestRow(_ i: Int, _ wait: WaitInterval) -> some View {
        let row = model.allGroups.all.first { $0.id == wait.rowId }
        return Button { if let row { model.open(row) } } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(wait.title).lineLimit(1)
                    Text("\(wait.project) · \(Self.agent(wait.source)) · \(wait.state.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.minutes(wait.duration)).monospacedDigit()
                    Text(Self.when(wait.start)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding(4)
            .background(Color.primary.opacity(row != nil && state.hoveredWait == i ? 0.08 : 0), in: .rect(cornerRadius: 6))
            .padding(-4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(row == nil)
        .onHover { if $0 { state.hoveredWait = i } else if state.hoveredWait == i { state.hoveredWait = nil } }
        .help(row == nil ? "This session is no longer in the list." : "Open the session")
    }

    private func shareRow(_ share: HistorySummary.Share, top: TimeInterval) -> some View {
        HStack(spacing: 8) {
            if state.split == .project { Badge(icon: nil, name: share.name, size: 16, letterScale: 0.65) } else { Badge.origin(share.name, size: 16) }
            Text(state.split == .project ? share.name : Self.agent(share.name)).lineLimit(1).frame(width: 120, alignment: .leading)
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 2).fill(.gray.opacity(0.6))
                    .frame(width: max(3, g.size.width * share.seconds / max(top, 1)), height: 6)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            Text(Self.minutes(share.seconds)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 56, alignment: .trailing)
        }
    }

    // MARK: - Words

    static func agent(_ source: String) -> String { KnownAgent(rawValue: source)?.displayName ?? source }

    /// "12 min", or "< 1 min" for a short wait.
    static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        return seconds > 0 && m == 0 ? "< 1 min" : "\(m) min"
    }

    /// "3 h 28 min" from an hour.
    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        return m < 60 ? minutes(seconds) : "\(m / 60) h \(m % 60) min"
    }

    /// "Today", the weekday in the last 7 days, else the date.
    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        return days < 7 ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// The day and the time a wait began.
    static func when(_ date: Date) -> String { "\(day(date)) \(date.formatted(date: .omitted, time: .shortened))" }
}
