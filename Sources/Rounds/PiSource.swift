import Foundation
import RoundsCore

/// Local Pi files and process state. The app owns when to refresh and which rows to show.
@MainActor
final class PiSource {
    private let home: URL
    private let stateDirectory: URL
    private let isRunning: (Int32) -> Bool
    private let paneID: (Int32) -> String?
    private let sessionCache = FileCache<PiSession?>()
    private let stateCache = FileCache<PiState?>()
    private var states: [String: PiState] = [:]
    private(set) var sessions: [String: PiSession] = [:]
    /// Session files for Herdr panes that do not report them.
    private(set) var paneSessions: [String: String] = [:]

    init(home: URL = URL.homeDirectory.appending(path: ".pi/agent"), stateDirectory: URL = piStateDirectory(),
         isRunning: @escaping (Int32) -> Bool = Processes.isPi,
         paneID: @escaping (Int32) -> String? = { Processes.environment(of: $0, "HERDR_PANE_ID") }) {
        // Match the paths that Pi and Herdr report to the actual paths on disk.
        self.home = home.resolvingSymlinksInPath()
        self.stateDirectory = stateDirectory
        self.isRunning = isRunning
        self.paneID = paneID
    }

    private var sessionDirectory: URL { home.appending(path: "sessions") }
    var extensionFile: URL { home.appending(path: "extensions/rounds.ts") }
    var watchPaths: [String] { [sessionDirectory.path, stateDirectory.path] }

    func prepareStateDirectory() {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    /// `changed`: the paths of a file event; only those session files are read again. Without it (at launch and every
    /// 30 s, which also finds files that an event missed) every session folder is listed.
    func refresh(changed: [String]?, agedAfter: TimeInterval) -> SessionSnapshot? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: home.path) else {
            states = [:]
            sessions = [:]
            paneSessions = [:]
            sessionCache.keep(only: [])
            stateCache.keep(only: [])
            return nil
        }
        // Hidden files are the extension's writes in progress.
        let stateFiles = (try? fm.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        states = Dictionary(stateFiles.compactMap { url in
            stateCache.value(at: url) { PiState(String(decoding: $0, as: UTF8.self)) }.flatMap { $0.map { (url.lastPathComponent, $0) } }
        }) { $1 }
        stateCache.keep(only: Set(stateFiles))
        let running = livePiSessions(states, running: isRunning)
        // acp_delegate runs: only the files that live state lines name, read at each refresh (no events watch them).
        let delegates = livePiDelegates(states, live: running, parent: Processes.parent)
        let delegateFiles = delegates.keys.map { URL(fileURLWithPath: $0) }
        var files: [URL]
        if let changed {
            files = changed.filter { $0.hasSuffix(".jsonl") }.map { URL(fileURLWithPath: $0) }
        } else {
            let folders = (try? fm.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: nil)) ?? []
            files = folders.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: fileCacheKeys)) ?? [] }.filter { $0.pathExtension == "jsonl" }
            sessionCache.keep(only: Set(files + delegateFiles))
            sessions = [:]
        }
        // A run whose pi ended has no row and leaves no session behind.
        sessions = sessions.filter { !$0.value.isDelegate || delegates[$0.key] != nil }
        files += delegateFiles
        for url in files {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let session = modified.flatMap { modified in
                sessionCache.value(at: url, read: { readPiSession($0) }, decode: { parsePiSession($0, path: url.path, updatedAt: modified) }) ?? nil
            }
            sessions[url.path] = delegates[url.path].map { session?.started(by: $0) } ?? session
        }
        let now = Date()
        var panes: [String: String] = [:]
        let snapshot = SessionSnapshot(sessions.values) { session in
            let state = states[session.id].flatMap { $0.sessionPath == session.path ? $0 : nil }
            // The extension names the process; a session without its line runs in a pi from before the install, or not at all.
            let live = state != nil && running.contains(session.id)
            // An acp_delegate run has its parent's pane in its environment; the pane is the parent's.
            if live, !session.isDelegate, let state, let pane = paneID(state.pid) { panes[pane] = session.path }
            // A session quiet for the Aged time is Older whatever its last message says.
            let aged = now.timeIntervalSince(session.updatedAt) > agedAfter
            let status = classifyPi(session, state: state, live: live, aged: aged)
            return (SessionRow(pi: session, status: status), .pi(session, state: state, live: live, aged: aged))
        }
        paneSessions = panes
        return snapshot
    }

    /// Deletes the extension's state of sessions with no session file and no pi process (at launch only: a pi that
    /// was never prompted has no session file yet).
    func pruneStates() {
        for (id, state) in states where sessions[state.sessionPath] == nil && !isRunning(state.pid) {
            try? FileManager.default.removeItem(at: stateDirectory.appending(path: id))
        }
    }

    func pid(for session: PiSession) -> Int32? {
        guard let state = states[session.id], state.sessionPath == session.path, isRunning(state.pid) else { return nil }
        return state.pid
    }

    func pane(for pid: Int32) -> String? { paneID(pid) }
}
