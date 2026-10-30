import AppKit
import RoundsCore
import Observation
import os

let log = Logger(subsystem: "com.henryqw.rounds", category: "app")
/// Each size change of the session window and its cause, at debug level, for `scripts/watch-frames.sh`.
let frameLog = Logger(subsystem: "com.henryqw.rounds", category: "frame")

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var query = "" { didSet { regroup() } }
    /// The panel's Older filter: older rows join the panel's groups without a search.
    var includeOlder = false { didSet { if includeOlder != oldValue { regroup() } } }
    /// A wait the user opened since it began stops the pill's ringing, and a result the user opened leaves Last Call
    /// (Settings > Pill); off, no session counts as opened.
    var seenStopsAlert = appDefaults.object(forKey: "seenStopsAlert") as? Bool ?? true {
        didSet {
            appDefaults.set(seenStopsAlert, forKey: "seenStopsAlert")
            regroup()
        }
    }
    /// Settings > Filters: what Last Call counts and when a session is Older (spec 3.2).
    var lastCall = AppModel.loadLastCall() {
        didSet {
            guard lastCall != oldValue else { return }
            appDefaults.set(lastCall.subAgents, forKey: "countSubAgents")
            appDefaults.set(lastCall.agedHours, forKey: "agedHours")
            regroup()
        }
    }
    /// The panel's groups (follow the search).
    private(set) var groups = GroupedSessions()
    /// All groups without the search: the filter counts.
    private(set) var allGroups = GroupedSessions()
    /// The pill's counts of sessions (children too), from `allGroups`; set only when they change, so other row changes
    /// do not redraw the pill. `yourTurnCount` is the Last Call count, the number on the pill.
    private(set) var yourTurnCount = 0
    /// The waits among them (Needs input, Failed): the pill is orange while one waits, else green for the results.
    private(set) var waitCount = 0
    /// The Failed ones: the pill is red with a broken glass.
    private(set) var failedCount = 0
    /// The waits the user has not opened since they began: only these make the pill ring (grow and peek).
    private(set) var unseenWaitCount = 0
    private(set) var runningCount = 0
    var ringing: Bool { unseenWaitCount > 0 }
    private(set) var marks = AppModel.loadMarks()
    private(set) var banner: String?
    private(set) var hookStatus: HookInstallStatus = .missing
    private(set) var hookError: String?

    let helperPath = Bundle.main.bundleURL.appending(path: "Contents/Helpers/rounds-hook").path
    private let sessionsRoot = URL.applicationSupportDirectory.appending(path: "Claude/claude-code-sessions")
    private let projectsRoot = URL.homeDirectory.appending(path: ".claude/projects")
    private let stateDir = hookStateDirectory()
    private var rows: [SessionRow] = []
    /// The last hook event of each session or thread, by id; read again when the state folder changes.
    @ObservationIgnored private var states: [String: HookState] = [:]
    /// Codex threads (spec 2.6), from Codex's database; state from hooks and the rollout tail.
    private var codexRows: [SessionRow] = []
    /// The threads Codex lists; nil when Codex is not installed or its database did not load.
    @ObservationIgnored private var codexThreads: [CodexThread]?
    /// Modification dates and sizes of the database and its write-ahead log when `codexThreads` was read.
    @ObservationIgnored private var codexStamp: [Double] = []
    private(set) var codexInstalled = false
    private(set) var codexHookStatus: HookInstallStatus = .missing
    private(set) var codexError: String?
    private(set) var codexHookError: String?
    let codexHome = URL.homeDirectory.appending(path: ".codex")
    @ObservationIgnored private let turnCache = FileCache<CodexTurn?>()
    /// pi sessions (spec 2.7), from pi's session files; state from the Rounds pi extension and the file's last message.
    private var piRows: [SessionRow] = []
    /// The extension's last state of each pi session, by session id.
    @ObservationIgnored private var piStates: [String: PiState] = [:]
    private(set) var piInstalled = false
    private(set) var piExtensionStatus: HookInstallStatus = .missing
    let piHome = URL.homeDirectory.appending(path: ".pi/agent")
    private var piExtension: URL { piHome.appending(path: "extensions/rounds.ts") }
    private let piStateDir = piStateDirectory()
    @ObservationIgnored private let piCache = FileCache<PiSession?>()
    @ObservationIgnored private let piStateCache = FileCache<PiState?>()
    /// herdr agents (spec 2.4), kept apart because they update from the socket, not from files.
    private var herdrRows: [SessionRow] = []
    private(set) var herdrConnection: HerdrMonitor.Status = .notRunning
    /// Agent id to its last status and when that status began (herdr reports no times).
    @ObservationIgnored private var herdrSince: [String: (status: String, since: Date)] = [:]
    @ObservationIgnored private var herdr: HerdrMonitor?
    @ObservationIgnored private var roots: [String: String] = [:]
    private var lastFailures: Set<URL> = []
    @ObservationIgnored private let tailCache = FileCache<LastMessage>()
    @ObservationIgnored private let sessionCache = FileCache<Result<DesktopSession, DesktopSessionError>>()
    @ObservationIgnored private let stateCache = FileCache<HookState?>()
    @ObservationIgnored private var watchers: [DirectoryWatcher] = []
    @ObservationIgnored private var timer: Timer?

    private init() {
        // Demo mode: fixed rows, every source on, and no watcher, timer or herdr connection.
        if Demo.isOn {
            (hookStatus, codexInstalled, codexHookStatus, herdrConnection) = (.installed, true, .installed, .connected(Demo.rows().herdr.count))
            (piInstalled, piExtensionStatus) = (true, .installed)
            setDemoRows(Demo.rows())
            return
        }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: piStateDir, withIntermediateDirectories: true)
        refreshAll()
        prunePiStates()
        // Delete state of archived or unknown sessions only when both session lists loaded without failures.
        let reliable = !rows.isEmpty && lastFailures.isEmpty && (!codexInstalled || codexThreads != nil)
        let claudeIds = rows.compactMap(\.session).filter { !$0.isArchived }.map(\.cliSessionId)
        pruneStateFiles(dir: stateDir, liveIds: reliable ? Set(claudeIds).union(codexThreads?.map(\.id) ?? []) : nil)
        // Each watcher reads only its own source.
        watchers = [
            DirectoryWatcher(paths: [sessionsRoot.path]) { [weak self] _ in MainActor.assumeIsolated { self?.refresh(codex: false) } },
            DirectoryWatcher(paths: [stateDir.path]) { [weak self] paths in MainActor.assumeIsolated { self?.hookStatesChanged(paths) } },
            // Rollout files change on every Codex event; a longer latency keeps the reads rare.
            DirectoryWatcher(paths: [codexHome.appending(path: "sessions").path], latency: 1) { [weak self] _ in MainActor.assumeIsolated { self?.refresh(claude: false, pi: false) } },
            // pi writes its session file on every message, as Codex does its rollout.
            DirectoryWatcher(paths: [piHome.appending(path: "sessions").path, piStateDir.path], latency: 1) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(claude: false, codex: false) }
            },
        ]
        herdr = HerdrMonitor { [weak self] agents, status in self?.updateHerdr(agents, status) }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAll()
                self?.herdr?.refresh()
            }
        }
        timer?.tolerance = 5
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        }
    }

    /// Hook states, every source and the hook install status: at launch and every 30 s (for the time windows).
    private func refreshAll() {
        readHookStates()
        refresh()
        refreshHookStatus()
    }

    /// Reads the sources again, then regroups.
    private func refresh(claude: Bool = true, codex: Bool = true, pi: Bool = true) {
        if claude { refreshClaude() }
        if codex { refreshCodex() }
        if pi { refreshPi() }
        regroup()
    }

    /// A state file names its session or thread; a file of neither (a new session) refreshes both sources.
    private func hookStatesChanged(_ paths: [String]) {
        readHookStates()
        let ids = Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })
        let claudeIds = Set(rows.compactMap(\.session?.cliSessionId))
        refresh(claude: !ids.isSubset(of: codexThreads?.map(\.id) ?? []), codex: !ids.isSubset(of: claudeIds), pi: false)
    }

    /// Shortens large state files, then reads the last hook event of each session.
    private func readHookStates() {
        pruneStateFiles(dir: stateDir, liveIds: nil)
        states = loadHookStates(dir: stateDir, cache: stateCache)
    }

    private func refreshClaude() {
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            banner = "Claude desktop session data not found at \(sessionsRoot.path)"
            rows = []
            return
        }
        let (sessions, failures) = loadDesktopSessions(root: sessionsRoot, cache: sessionCache)
        let failed = Set(failures.map(\.url))
        // A failure that survives a second read is real; a single one can be a write in progress.
        let persistent = failed.intersection(lastFailures)
        for f in failures where persistent.contains(f.url) { log.error("unreadable session \(f.url.path, privacy: .public): \(String(describing: f.error), privacy: .public)") }
        lastFailures = failed
        banner = persistent.isEmpty ? nil : "\(persistent.count) sessions unreadable: Claude desktop format may have changed"

        let claude = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first
        let now = Date()
        rows = sessions.map { s in
            let hook = states[s.cliSessionId]
            // A wrap-up without `needsUser` can still have asked a question; only the transcript holds it.
            let wrapUpQuestion = s.hasWrapUp && s.wrapUpNeedsUser == nil
            let tail = !s.isArchived && (needsTail(session: s, hook: hook) || wrapUpQuestion) ? cachedTail(s) : nil
            return SessionRow(session: s, status: classify(ClassifierInput(session: s, hook: hook, tail: tail, claudeRunning: claude != nil, claudeLaunchedAt: claude?.launchDate, now: now)))
        }
    }

    private func cachedTail(_ s: DesktopSession) -> LastMessage? {
        guard let url = transcriptURL(cwd: s.cwd, cliSessionId: s.cliSessionId, projectsRoot: projectsRoot) else { return nil }
        return tailCache.value(at: url, read: { readTail($0) }, decode: LastMessage.parse)
    }

    private func refreshCodex() {
        codexInstalled = FileManager.default.fileExists(atPath: codexHome.path)
        guard codexInstalled else {
            (codexRows, codexThreads, codexError) = ([], nil, nil)
            return
        }
        do {
            // The thread query runs again only when the database or its write-ahead log changed.
            let database = codexHome.appending(path: "state_5.sqlite")
            let stamp = [database, codexHome.appending(path: "state_5.sqlite-wal")].flatMap { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return [values?.contentModificationDate?.timeIntervalSince1970 ?? 0, Double(values?.fileSize ?? 0)]
            }
            let threads = try codexThreads.flatMap { stamp == codexStamp ? $0 : nil } ?? loadCodexThreads(database: database)
            (codexThreads, codexStamp) = (threads, stamp)
            let live = Processes.isRunning("codex")
            let now = Date()
            codexRows = threads.map { t in
                // A thread quiet for the Aged time is Older whatever its rollout says; skip reading the file.
                let rollout = URL(fileURLWithPath: t.rolloutPath)
                let aged = now.timeIntervalSince(t.updatedAt) > lastCall.agedAfter
                let turn = aged ? nil : turnCache.value(at: rollout, read: { readTail($0) }, decode: parseCodexRollout) ?? nil
                return SessionRow(thread: t, status: classifyCodex(t, hook: states[t.id], turn: turn, live: live))
            }
            codexError = nil
        } catch {
            if codexError == nil { log.error("Codex threads unreadable: \(String(describing: error), privacy: .public)") }
            (codexRows, codexThreads) = ([], nil)
            codexError = "Codex threads are unreadable (\(error)); the Codex format may have changed."
        }
    }

    private func refreshPi() {
        piInstalled = FileManager.default.fileExists(atPath: piHome.path)
        guard piInstalled else {
            (piRows, piStates) = ([], [:])
            return
        }
        let fm = FileManager.default
        // Hidden files are the extension's writes in progress.
        let stateFiles = (try? fm.contentsOfDirectory(at: piStateDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        piStates = Dictionary(stateFiles.compactMap { url in
            piStateCache.value(at: url) { PiState(String(decoding: $0, as: UTF8.self)) }.flatMap { $0.map { (url.lastPathComponent, $0) } }
        }) { $1 }
        piStateCache.keep(only: Set(stateFiles))
        let folders = (try? fm.contentsOfDirectory(at: piHome.appending(path: "sessions"), includingPropertiesForKeys: nil)) ?? []
        let files = folders.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.filter { $0.pathExtension == "jsonl" }
        let anyPi = Processes.isRunning("pi")
        let now = Date()
        piRows = files.compactMap { url -> SessionRow? in
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  let session = piCache.value(at: url, read: { readPiSession($0) }, decode: { parsePiSession($0, path: url.path, updatedAt: modified) }) ?? nil
            else { return nil }
            let state = piStates[session.id].flatMap { $0.sessionPath == session.path ? $0 : nil }
            // The extension names the process; without it, any pi process may run the session.
            let live = state.map { kill($0.pid, 0) == 0 && Processes.name(of: $0.pid) == "pi" } ?? anyPi
            // A session quiet for the Aged time is Older whatever its last message says.
            let aged = now.timeIntervalSince(modified) > lastCall.agedAfter
            return SessionRow(pi: session, status: classifyPi(session, state: state, live: live && !aged))
        }
        piCache.keep(only: Set(files))
    }

    /// Deletes the extension's state of sessions with no session file and no pi process (at launch only: a pi that
    /// was never prompted has no session file yet).
    private func prunePiStates() {
        let paths = Set(piRows.compactMap { if case .pi(let s) = $0.source { s.path } else { nil } })
        for (id, state) in piStates where !paths.contains(state.sessionPath) && Processes.name(of: state.pid) != "pi" {
            try? FileManager.default.removeItem(at: piStateDir.appending(path: id))
        }
    }

    /// Hook install status: at launch, every 30 s, and when Settings opens or changes the hooks; not on file events.
    /// A change turns a source on or off, so the rows are grouped again.
    func refreshHookStatus() {
        guard !Demo.isOn else { return }
        defer { regroup() }
        do {
            hookStatus = try installer(.claude).status(helperPath: helperPath)
            hookError = nil
        } catch {
            hookError = "settings.json is not valid JSON: \(error)"
        }
        // The pi extension is installed when the file is the one this app ships; another copy needs an update.
        let installedExtension = try? Data(contentsOf: piExtension)
        piExtensionStatus = installedExtension.map { $0 == bundledPiExtension ? .installed : .wrongPath(found: piExtension.path) } ?? .missing
        guard codexInstalled else {
            codexHookError = nil
            return
        }
        do {
            let status = try installer(.codex).status(helperPath: helperPath)
            let enabled = (try? String(contentsOf: codexHome.appending(path: "config.toml"), encoding: .utf8)).map(CodexConfig.hooksEnabled) ?? false
            codexHookStatus = status == .installed && !enabled ? .missing : status
            codexHookError = nil
        } catch {
            codexHookError = "hooks.json is not valid JSON: \(error)"
        }
    }

    private func installer(_ target: HookTarget) -> HookInstaller {
        switch target {
        case .claude: HookInstaller(settingsURL: URL.homeDirectory.appending(path: ".claude/settings.json"))
        case .codex: HookInstaller(settingsURL: codexHome.appending(path: "hooks.json"), target: .codex)
        case .pi: fatalError("pi has an extension file, not a hooks file")
        }
    }

    /// `Resources/rounds-pi.ts` in the app bundle.
    private var bundledPiExtension: Data? {
        Bundle.main.url(forResource: "rounds-pi.ts", withExtension: nil).flatMap { try? Data(contentsOf: $0) }
    }

    func hookStatus(_ target: HookTarget) -> HookInstallStatus {
        switch target {
        case .claude: hookStatus
        case .codex: codexHookStatus
        case .pi: piExtensionStatus
        }
    }

    /// A source is on while it can report live state (spec 2): Claude and Codex with hooks (a wrong helper path still
    /// counts, as the old helper runs until Repair Hooks), pi with its extension (an older copy still counts), herdr
    /// while connected. The window shows only sources that are on.
    var claudeOn: Bool { hookStatus != .missing }
    var codexOn: Bool { codexInstalled && codexHookStatus != .missing }
    var herdrOn: Bool { if case .connected = herdrConnection { true } else { false } }
    var piOn: Bool { piInstalled && piExtensionStatus != .missing }

    /// The apps "Another Round?" can start a session in: the sources that are on.
    var newSessionApps: [NewSessionApp] { [claudeOn ? .claude : nil, codexOn ? .codex : nil, herdrOn ? .herdr : nil].compactMap { $0 } }

    /// A new Claude Code session (`claude://code/new`); Codex has no link for a new thread, so its app opens; herdr
    /// comes to the front, where the user starts an agent.
    func startNewSession(_ app: NewSessionApp) {
        switch app {
        case .claude: NSWorkspace.shared.open(URL(string: "claude://code/new")!)
        case .codex: NSWorkspace.shared.open(URL(string: "codex://")!)
        case .herdr: herdr?.show()
        }
    }

    /// Writes the Rounds entries; for Codex it also turns on `[features] hooks` in `~/.codex/config.toml`.
    /// pi: copies the extension to `~/.pi/agent/extensions/rounds.ts`; a pi that runs loads it at its next start.
    func installHooks(_ target: HookTarget) throws {
        if target == .pi {
            guard let data = bundledPiExtension else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.createDirectory(at: piExtension.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try data.write(to: piExtension, options: .atomic)
        }
        try installer(target).install(helperPath: helperPath)
        if target == .codex { try CodexConfig.enableHooks(at: codexHome.appending(path: "config.toml")) }
    }

    func removeHooks(_ target: HookTarget) throws {
        if target == .pi { return try FileManager.default.removeItem(at: piExtension) }
        try installer(target).remove()
    }

    private func updateHerdr(_ agents: [HerdrAgent], _ status: HerdrMonitor.Status) {
        herdrConnection = status
        let now = Date()
        var since: [String: (status: String, since: Date)] = [:]
        herdrRows = agents.filter(\.isListed).map { a in
            let start: Date
            if let previous = herdrSince[a.id] {
                start = previous.status == a.agentStatus ? previous.since : now
            } else {
                // First sight (launch or a new pane): the agent's session file shows its last activity. A quiet
                // agent without one has no known activity, so it counts as old; a busy one starts now.
                let modified = a.sessionPath.flatMap { try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                start = modified ?? (a.agentStatus == "working" || a.agentStatus == "blocked" ? now : .distantPast)
            }
            since[a.id] = (a.agentStatus, start)
            return SessionRow(agent: a, status: herdrStatus(a.agentStatus, since: start))
        }
        herdrSince = since
        regroup()
    }

    /// The project folder of a session folder (its git repository's main checkout), cached per folder.
    func root(for cwd: String) -> String {
        if let hit = roots[cwd] { return hit }
        let root = projectRoot(for: cwd)
        roots[cwd] = root
        return root
    }

    /// Claude sessions and Codex threads open through their app's link (spec 5.5), which also brings the app to the
    /// front; herdr agents are focused in herdr.
    func open(_ row: SessionRow) {
        updateMarks { $0.markSeen(row.id, at: Date()) }
        switch row.source {
        case .claude(let session):
            NSWorkspace.shared.open(URL(string: "claude://code/continue")!.appending(queryItems: [URLQueryItem(name: "session", value: session.id)]))
        case .codex(let thread):
            if let url = URL(string: "codex://threads/\(thread.id)") { NSWorkspace.shared.open(url) }
        case .herdr(let agent): herdr?.focus(agent)
        case .pi(let session): openPi(session)
        }
    }

    /// A running pi session: its terminal (in rootshell, its pane). Else a new terminal window resumes it.
    private func openPi(_ session: PiSession) {
        let pid = piStates[session.id].flatMap { $0.sessionPath == session.path && Processes.name(of: $0.pid) == "pi" ? $0.pid : nil }
        let quote = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        TerminalOpener.show(pid.flatMap(TerminalOpener.client(above:)), command: "cd \(quote(session.cwd)) && pi --session \(quote(session.path))")
    }

    /// Demo mode only: new placeholder rows (`Demo`'s window-turn scene).
    /// The demo's quiet sessions are seen, so they show in Served and Last Call has only what wants the user.
    func setDemoRows(_ r: (claude: [SessionRow], codex: [SessionRow], herdr: [SessionRow])) {
        (rows, codexRows, herdrRows) = r
        for row in r.claude + r.codex + r.herdr where row.status.state.group == .quiet { marks.markSeen(row.id, at: Date()) }
        regroup()
    }

    private func regroup() {
        // A pi session that runs in herdr shows once, as the herdr agent, which can focus its pane.
        let inHerdr = Set(herdrRows.compactMap { if case .herdr(let a) = $0.source { a.sessionPath } else { nil } })
        let pi = piOn ? piRows.filter { if case .pi(let s) = $0.source { !inHerdr.contains(s.path) } else { true } } : []
        let rows = (claudeOn ? rows : []) + (codexOn ? codexRows : []) + pi + herdrRows
        let now = Date()
        groups = group(rows, query: query, marks: marks, includeOlder: includeOlder, trackSeen: seenStopsAlert, rule: lastCall, now: now)
        allGroups = group(rows, query: "", marks: marks, trackSeen: seenStopsAlert, rule: lastCall, now: now)
        let sessions = allGroups.sessions
        // The pill shows the Last Call count; it rings only for a wait the user has not opened.
        let g = allGroups, running = sessions.count { $0.status.group == .running }
        if yourTurnCount != g.lastCallCount { yourTurnCount = g.lastCallCount }
        if waitCount != g.waitCount { waitCount = g.waitCount }
        if failedCount != g.failedCount { failedCount = g.failedCount }
        if unseenWaitCount != g.unseenWaitCount { unseenWaitCount = g.unseenWaitCount }
        if runningCount != running { runningCount = running }
    }

    private static func loadLastCall() -> LastCallRule {
        var rule = LastCallRule()
        rule.subAgents = appDefaults.object(forKey: "countSubAgents") as? Bool ?? rule.subAgents
        rule.agedHours = appDefaults.object(forKey: "agedHours") as? Int ?? rule.agedHours
        return rule
    }

    /// Mark All as Seen (the Last Call tile's menu): every unseen Last Call session is seen now, so a result leaves Last
    /// Call and a wait stops the pill's ringing.
    func markAllSeen() {
        let now = Date()
        updateMarks { marks in
            for r in allGroups.sessions where r.status.group == .yourTurn && !r.isSeen { marks.markSeen(r.id, at: now) }
        }
    }

    // Local marks: Rounds only. Claude desktop has no safe way to archive a session from outside.
    func markDone(_ row: SessionRow) { updateMarks { $0.markDone(row.id, at: Date()) } }
    func hide(_ row: SessionRow) { updateMarks { $0.hide(row.id) } }
    func unhide(_ row: SessionRow) { updateMarks { $0.unhide(row.id) } }
    func isHidden(_ row: SessionRow) -> Bool { marks.hidden.contains(row.id) }
    func toggleStar(_ row: SessionRow) { updateMarks { $0.toggleStar(row.id) } }
    /// Puts back marks saved before a change (undo and redo).
    func restoreMarks(_ saved: SessionMarks) { updateMarks { $0 = saved } }

    private static let marksKey = "marks"

    private static func loadMarks() -> SessionMarks {
        appDefaults.data(forKey: marksKey).flatMap { try? JSONDecoder().decode(SessionMarks.self, from: $0) } ?? SessionMarks()
    }

    private func updateMarks(_ change: (inout SessionMarks) -> Void) {
        change(&marks)
        appDefaults.set(try? JSONEncoder().encode(marks), forKey: Self.marksKey)
        regroup()
    }
}

enum NewSessionApp {
    case claude, codex, herdr

    /// The source whose icon the "Another round?" banner shows.
    var sourceName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .herdr: "herdr"
        }
    }

    /// The icon button's hint and VoiceOver label.
    var menuTitle: String {
        switch self {
        case .claude: "New Claude Code Session"
        case .codex: "Open Codex"
        case .herdr: "Open herdr"
        }
    }
}
