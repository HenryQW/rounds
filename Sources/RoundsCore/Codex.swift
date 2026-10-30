import Foundation
import SQLite3

/// One Codex thread the user started (spec 2.6), from the `threads` table of `~/.codex/state_5.sqlite`.
public struct CodexThread: Sendable, Equatable {
    public let id: String
    public let title: String
    public let cwd: String
    public let branch: String?
    public let updatedAt: Date
    public let rolloutPath: String
    /// The thread that started this sub-agent thread; nil for a thread the user started.
    public let parentId: String?

    public init(id: String, title: String, cwd: String, branch: String?, updatedAt: Date, rolloutPath: String, parentId: String? = nil) {
        (self.id, self.title, self.cwd, self.branch, self.updatedAt, self.rolloutPath) = (id, title, cwd, branch, updatedAt, rolloutPath)
        self.parentId = parentId
    }
}

public enum CodexError: Error, Equatable {
    case database(String)
}

/// Threads that are not archived: the ones the user started (a plain `source`), and sub-agent threads, whose JSON
/// `source` names the parent thread and the agent's nickname. Reviews (`{"subagent":{"other":"guardian"}}`) stay out.
private let threadsQuery = """
    SELECT id, rollout_path, cwd, COALESCE(NULLIF(nickname, ''), NULLIF(name, ''), NULLIF(title, ''), preview), git_branch,
           COALESCE(updated_at_ms, updated_at * 1000), parent
    FROM (SELECT *, CASE WHEN json_valid(source) THEN json_extract(source, '$.subagent.thread_spawn.parent_thread_id') END AS parent,
                    CASE WHEN json_valid(source) THEN json_extract(source, '$.subagent.thread_spawn.agent_nickname') END AS nickname
          FROM threads)
    WHERE archived = 0 AND (parent IS NOT NULL OR (COALESCE(thread_source, 'user') = 'user' AND source NOT LIKE '{%'))
    """

/// Reads the threads read-only; Codex keeps writing the database while this runs.
public func loadCodexThreads(database: URL) throws(CodexError) -> [CodexThread] {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    func failure() -> CodexError { .database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open") }
    guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw failure() }
    sqlite3_busy_timeout(db, 500)
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, threadsQuery, -1, &statement, nil) == SQLITE_OK else { throw failure() }
    func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
    var threads: [CodexThread] = []
    while true {
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return threads
        case SQLITE_ROW:
            guard let id = text(0) else { continue }
            threads.append(CodexThread(id: id, title: text(3) ?? "", cwd: text(2) ?? "", branch: text(4).flatMap { $0.isEmpty ? nil : $0 },
                                       updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 5)) / 1000),
                                       rolloutPath: text(1) ?? "", parentId: text(6)))
        default: throw failure()
        }
    }
}

/// The last turn edge in a thread's rollout file.
public struct CodexTurn: Sendable, Equatable {
    public enum Kind: Sendable { case started, completed, aborted }
    public let kind: Kind
    public let at: Date

    public init(kind: Kind, at: Date) {
        self.kind = kind
        self.at = at
    }
}

private let turnEvents: [String: CodexTurn.Kind] = ["task_started": .started, "task_complete": .completed, "turn_aborted": .aborted]

/// The newest `task_started`, `task_complete` or `turn_aborted` event in the tail of a rollout file (JSON lines).
public func parseCodexRollout(_ tail: Data) -> CodexTurn? {
    for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], o["type"] as? String == "event_msg",
              let type = (o["payload"] as? [String: Any])?["type"] as? String, let kind = turnEvents[type],
              let stamp = o["timestamp"] as? String,
              let at = (try? Date(stamp, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
                ?? (try? Date(stamp, strategy: .iso8601)) else { continue }
        return CodexTurn(kind: kind, at: at)
    }
    return nil
}

/// A Codex thread's state: the newer of the last hook event and the last rollout turn edge. Hooks carry the
/// waiting state and tool names; the rollout covers threads that ran without hooks. `live`: a Codex process runs.
public func classifyCodex(_ thread: CodexThread, hook: HookState?, turn: CodexTurn?, live: Bool) -> SessionStatus {
    func quiet(_ state: SessionState) -> SessionStatus {
        SessionStatus(state, since: thread.updatedAt)
    }
    if let turn, hook.map({ turn.at > $0.last.at }) ?? true {
        switch turn.kind {
        case .started: return live ? SessionStatus(.working, "Thinking", since: turn.at) : quiet(.offline)
        case .completed: return quiet(.finished)
        case .aborted: return quiet(.stopped)
        }
    }
    guard let last = hook?.last else { return quiet(.finished) }
    if let label = blockedLabel(last) {
        return live ? SessionStatus(.needsInput, label, since: last.at) : quiet(.offline)
    }
    if runningEvents.contains(last.event) {
        return live ? SessionStatus(.working, runningLabel(last), since: last.at) : quiet(.offline)
    }
    return quiet(last.event == "Interrupt" ? .stopped : .finished)
}
