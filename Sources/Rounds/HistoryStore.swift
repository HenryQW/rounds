import Foundation
import RoundsCore

/// Wait history (spec 2.11): each wait in Last Call that ends is one line in the file of its day, appended at once.
/// Open waits stay in memory only. Nothing is read at launch; the History page reads its period when it opens.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()
    nonisolated static let directory = URL.applicationSupportDirectory.appending(path: "Rounds/history")

    private var tracker = WaitTracker()

    /// At launch (the first regroup): deletes the files of days more than 90 days ago.
    private init() {
        guard !Demo.isOn else { return }
        historyIO.async {
            let fm = FileManager.default, dir = Self.directory
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in HistoryFile.expired(names, now: Date(), calendar: .current) { try? fm.removeItem(at: dir.appending(path: name)) }
        }
    }

    /// The sessions of the list groups, after each regroup: appends the waits that ended. Demo mode writes nothing.
    func check(_ rows: [SessionRow], project: (SessionRow) -> String) {
        let closed = tracker.check(rows, now: Date(), project: project)
        guard !closed.isEmpty, !Demo.isOn else { return }
        historyIO.async { Self.append(closed) }
    }

    /// The waits of `period`, open ones too, read off the main thread; demo mode shows fixed history.
    func load(_ period: HistoryPeriod, done: @escaping @MainActor (HistorySummary) -> Void) {
        let now = Date(), live = tracker.live(now: now)
        historyIO.async {
            let calendar = Calendar.current
            let saved = Demo.isOn ? Demo.history(now: now) : period.fileNames(now: now, calendar: calendar).flatMap { name in
                (try? String(contentsOf: Self.directory.appending(path: name), encoding: .utf8)).map(WaitInterval.parse) ?? []
            }
            let summary = HistorySummary(saved + live, period: period, now: now, calendar: calendar)
            DispatchQueue.main.async { done(summary) }
        }
    }

    /// One `write` per file with O_APPEND, so lines from two writes never mix; the files are mode 0600.
    nonisolated private static func append(_ intervals: [WaitInterval]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let byFile = Dictionary(grouping: intervals) { HistoryFile.name(for: $0.end, calendar: .current) }
        for (name, lines) in byFile {
            let fd = open(directory.appending(path: name).path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard fd >= 0 else {
                log.error("history: cannot open \(name, privacy: .public): errno \(errno)")
                continue
            }
            let data = Data(lines.map(\.line).joined().utf8)
            if data.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) != data.count {
                log.error("history: short write to \(name, privacy: .public)")
            }
            close(fd)
        }
    }
}

/// History file reads and writes, in order.
private let historyIO = DispatchQueue(label: "com.henryqw.rounds.history", qos: .utility)
