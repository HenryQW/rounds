import Foundation
import Testing
@testable import RoundsCore

private func makeDatabase(_ rows: [String]) throws -> URL {
    let url = try tempDir().appending(path: "state_5.sqlite")
    let sql = """
    CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, updated_at INTEGER NOT NULL, source TEXT NOT NULL,
      cwd TEXT NOT NULL, title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0, git_branch TEXT, updated_at_ms INTEGER,
      thread_source TEXT, name TEXT, preview TEXT NOT NULL DEFAULT '');
    \(rows.map { "INSERT INTO threads (id, rollout_path, updated_at, source, cwd, title, archived, git_branch, updated_at_ms, thread_source, name, preview) VALUES \($0);" }.joined(separator: "\n"))
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = [url.path, sql]
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    return url
}

@Test func loadsUserThreadsOnly() throws {
    let db = try makeDatabase([
        "('t1', '/r/1.jsonl', 1, 'vscode', '/Users/test/app', 'fix the login', 0, 'main', 1792987717338, 'user', 'Fix login', 'fix the login')",
        "('t2', '/r/2.jsonl', 2, 'cli', '/Users/test/api', 'add tests', 0, NULL, NULL, NULL, NULL, '')",
        "('t3', '/r/3.jsonl', 3, 'vscode', '/Users/test/app', 'old', 1, NULL, 3000, 'user', NULL, '')",
        #"('t4', '/r/4.jsonl', 4, '{"subagent":{"other":"guardian"}}', '/Users/test/app', 'Guardian review', 0, NULL, 4000, 'guardian_review', NULL, '')"#,
        "('t5', '/r/5.jsonl', 5, 'vscode', '/Users/test/app', '', 0, NULL, 5000, 'user', '', 'first prompt')",
    ])
    let threads = try loadCodexThreads(database: db).sorted { $0.id < $1.id }
    #expect(threads.map(\.id) == ["t1", "t2", "t5"])
    #expect(threads.map(\.title) == ["Fix login", "add tests", "first prompt"])
    #expect(threads[0].cwd == "/Users/test/app" && threads[0].branch == "main" && threads[1].branch == nil)
    #expect(threads[0].updatedAt == Date(timeIntervalSince1970: 1_792_987_717.338))
    #expect(threads[1].updatedAt == Date(timeIntervalSince1970: 2))
    #expect(threads[0].rolloutPath == "/r/1.jsonl")
}

@Test func loadsSubAgentThreadsUnderTheirParent() throws {
    let spawn = #"{"subagent":{"thread_spawn":{"parent_thread_id":"t1","depth":1,"agent_path":"/root/x","agent_nickname":"Kant","agent_role":null}}}"#
    let unnamed = #"{"subagent":{"thread_spawn":{"parent_thread_id":"t1","depth":1}}}"#
    let db = try makeDatabase([
        "('t1', '/r/1.jsonl', 1, 'vscode', '/Users/test/app', 'fix the login', 0, NULL, 1000, 'user', 'Fix login', '')",
        "('s1', '/r/s1.jsonl', 2, '\(spawn)', '/Users/test/app', 'check the tests', 0, NULL, 2000, 'subagent', NULL, '')",
        "('s2', '/r/s2.jsonl', 3, '\(unnamed)', '/Users/test/app', 'read docs', 0, NULL, 3000, 'subagent', NULL, '')",
        #"('g1', '/r/g.jsonl', 4, '{"subagent":{"other":"guardian"}}', '/Users/test/app', 'Guardian review', 0, NULL, 4000, 'subagent', NULL, '')"#,
    ])
    let threads = try loadCodexThreads(database: db).sorted { $0.id < $1.id }
    #expect(threads.map(\.id) == ["s1", "s2", "t1"])
    #expect(threads.map(\.title) == ["Kant", "read docs", "Fix login"])
    #expect(threads.map(\.parentId) == ["t1", "t1", nil])
    let row = SessionRow(thread: threads[0], status: SessionStatus(.finished, since: .distantPast))
    #expect(row.parentId == "codex:t1")
}

@Test func missingDatabaseThrows() throws {
    #expect(throws: CodexError.self) { try loadCodexThreads(database: try tempDir().appending(path: "none.sqlite")) }
}

private func event(_ at: String, _ type: String) -> String {
    #"{"timestamp":"\#(at)","type":"event_msg","payload":{"type":"\#(type)"}}"#
}

@Test func rolloutTailGivesLastTurnEdge() {
    let lines = [
        #"rtial line from the middle of a file"}"#,
        event("2026-10-23T13:00:00.000Z", "task_started"),
        event("2026-10-23T13:07:05.864Z", "turn_aborted"),
        event("2026-10-24T15:14:28.888Z", "thread_settings_applied"),
    ]
    let turn = parseCodexRollout(Data((lines.joined(separator: "\n") + "\n").utf8))
    #expect(turn?.kind == .aborted)
    #expect(abs((turn?.at.timeIntervalSince1970 ?? 0) - 1_792_760_825.864) < 0.001)
    #expect(parseCodexRollout(Data((event("2026-10-23T13:00:00Z", "task_started") + "\n").utf8))?.kind == .started)
    #expect(parseCodexRollout(Data((event("2026-10-23T13:00:00Z", "task_complete") + "\n").utf8))?.kind == .completed)
    #expect(parseCodexRollout(Data(#"{"type":"session_meta"}"#.utf8)) == nil)
}

private let now = Date(timeIntervalSince1970: 2_000_000)
private let thread = CodexThread(id: "t1", title: "Fix login", cwd: "/Users/test/app", branch: nil,
                                 updatedAt: now.addingTimeInterval(-600), rolloutPath: "/r/1.jsonl")
private func hook(_ event: String, _ detail: String = "", ago: TimeInterval) -> HookState {
    HookState(last: HookLine(at: now.addingTimeInterval(-ago), event: event, detail: detail, backgroundTasks: nil, cronSchedules: []))
}

@Test(arguments: [
    ("PermissionRequest", "exec", SessionState.needsInput, "Permission: exec"),
    ("PreToolUse", "apply_patch", .working, "apply_patch"),
    ("UserPromptSubmit", "", .working, "Thinking"),
    ("PostToolUse", "exec", .working, "Thinking"),
    ("Stop", "", .finished, ""),
    ("Interrupt", "", .stopped, ""),
])
func codexHookStates(event: String, detail: String, state: SessionState, shown: String) {
    let s = classifyCodex(thread, hook: hook(event, detail, ago: 30), turn: nil, live: true)
    #expect(s.state == state && s.detail == shown)
}

@Test func codexRolloutNewerThanHookWins() {
    let started = CodexTurn(kind: .started, at: now.addingTimeInterval(-10))
    #expect(classifyCodex(thread, hook: hook("Stop", ago: 60), turn: started, live: true).group == .running)
    // Within a turn the hook events come after task_started, so they keep their detail.
    let permission = classifyCodex(thread, hook: hook("PermissionRequest", "exec", ago: 5), turn: started, live: true)
    #expect(permission.detail == "Permission: exec")
    let aborted = CodexTurn(kind: .aborted, at: now.addingTimeInterval(-10))
    #expect(classifyCodex(thread, hook: nil, turn: aborted, live: true).state == .stopped)
}

@Test func codexWithoutProcessIsStale() {
    #expect(classifyCodex(thread, hook: hook("PermissionRequest", "exec", ago: 30), turn: nil, live: false).state == .offline)
    #expect(classifyCodex(thread, hook: nil, turn: CodexTurn(kind: .started, at: now), live: false).group == .quiet)
}


@Test func codexRowOpensAsCodex() {
    let row = SessionRow(thread: thread, status: SessionStatus(.finished, since: now))
    #expect(row.id == "codex:t1" && row.title == "Fix login" && row.knownAgent == .codex)
}

// MARK: - Hooks

private let helper = "/Applications/Rounds.app/Contents/Helpers/rounds-hook"

@Test func codexInstallUsesTimeoutNotAsync() {
    let d = HookSettings.install([:], helperPath: helper, target: .codex)
    let hooks = d["hooks"] as? [String: Any] ?? [:]
    #expect(Set(hooks.keys) == Set(HookTarget.codex.entries.map(\.event)))
    let handler = ((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
    #expect(handler?["timeout"] as? Int == 10 && handler?["async"] == nil)
    #expect(HookSettings.status(d, helperPath: helper, target: .codex) == .installed)
    #expect(HookSettings.status(d, helperPath: helper, target: .claude) == .missing)
}

@Test func enablingCodexHooksEditsOnlyFeatures() {
    let toml = """
    model = "gpt-5"

    [features]
    memories = true
    codex_hooks = true

    [projects."/Users/test/app"]
    hooks = false
    """
    let edited = CodexConfig.enablingHooks(toml)
    #expect(edited == """
    model = "gpt-5"

    [features]
    hooks = true
    memories = true

    [projects."/Users/test/app"]
    hooks = false
    """)
    #expect(CodexConfig.hooksEnabled(edited) && !CodexConfig.hooksEnabled(toml))
    #expect(CodexConfig.enablingHooks(edited) == edited)
    #expect(CodexConfig.enablingHooks("[features]\nhooks = false\n") == "[features]\nhooks = true\n")
    #expect(CodexConfig.enablingHooks("model = \"x\"\n") == "model = \"x\"\n\n[features]\nhooks = true\n")
    #expect(CodexConfig.enablingHooks("") == "[features]\nhooks = true\n")
}
