import Foundation

public enum HookPayloadError: Error, Equatable {
    case invalidJSON
    case badSessionId
}

/// One entry of a Stop's `background_tasks`: its type (shell, subagent, workflow, ...) and a short description.
public struct BackgroundTask: Sendable, Equatable {
    public let type: String
    public let description: String

    public init(type: String, description: String) {
        self.type = type
        self.description = description
    }
}

/// One hook event, stored as one tab-separated line (spec 2.3). Holds no prompt, tool input or message text, except
/// the short descriptions of background tasks and the rule that a permission request suggests, which holds the command.
public struct HookLine: Sendable, Equatable {
    public let at: Date
    public let event: String
    public let detail: String
    public let backgroundTasks: Int?
    public let cronSchedules: [String]
    /// The background tasks of a Stop; empty in lines from an older helper, which kept the count only.
    public let tasks: [BackgroundTask]
    /// The allow rule that Claude Code suggests for a PermissionRequest, such as `Bash(swift test)`; else empty.
    public let rule: String

    public init(at: Date, event: String, detail: String, backgroundTasks: Int?, cronSchedules: [String], tasks: [BackgroundTask] = [],
                rule: String = "") {
        self.at = at
        self.event = event
        self.detail = detail
        self.backgroundTasks = backgroundTasks
        self.cronSchedules = cronSchedules
        self.tasks = tasks
        self.rule = rule
    }

    public var encoded: String {
        let ms = Int64((at.timeIntervalSince1970 * 1000).rounded())
        let bg = backgroundTasks.map(String.init) ?? ""
        let list = tasks.map { "\($0.type):\($0.description)" }.joined(separator: ";")
        return "\(ms)\t\(event)\t\(detail)\t\(bg)\t\(cronSchedules.joined(separator: ";"))\t\(list)\t\(rule)\n"
    }

    public init?(encoded: Substring) {
        let f = encoded.split(separator: "\t", omittingEmptySubsequences: false)
        guard (5...7).contains(f.count), let ms = Int64(f[0]), !f[1].isEmpty else { return nil }
        let bg: Int?
        if f[3].isEmpty { bg = nil } else if let n = Int(f[3]) { bg = n } else { return nil }
        let tasks: [BackgroundTask] = f.count >= 6 ? f[5].split(separator: ";").map { item in
            let parts = item.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            return BackgroundTask(type: String(parts[0]), description: parts.count > 1 ? String(parts[1]) : "")
        } : []
        self.init(at: Date(timeIntervalSince1970: Double(ms) / 1000), event: String(f[1]), detail: String(f[2]),
                  backgroundTasks: bg, cronSchedules: f[4].split(separator: ";").map(String.init), tasks: tasks,
                  rule: f.count == 7 ? String(f[6]) : "")
    }

    public static func from(payload: Data, now: Date) throws(HookPayloadError) -> (sessionId: String, line: HookLine, cwd: String) {
        guard let p = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let event = p["hook_event_name"] as? String else { throw .invalidJSON }
        guard let id = p["session_id"] as? String, isValidSessionId(id) else { throw .badSessionId }
        let raw = ["tool_name", "notification_type", "mcp_server_name", "error"].lazy.compactMap { p[$0] as? String }.first ?? ""
        let isStop = event == "Stop"
        let crons = isStop ? (p["session_crons"] as? [[String: Any]] ?? []).compactMap { ($0["schedule"] as? String).map(clean) } : []
        // Monitors (artifact watches, event streams) stay open after the turn ends; they are not work in progress.
        let tasks = isStop ? (p["background_tasks"] as? [[String: Any]] ?? []).filter { $0["type"] as? String != "monitor" } : []
        let line = HookLine(at: Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded() / 1000),
                            event: clean(event), detail: clean(event == "PreToolUse" ? toolDetail(raw, input: p["tool_input"]) : raw),
                            backgroundTasks: isStop ? tasks.count : nil, cronSchedules: crons,
                            tasks: tasks.map { t in
                                // Free text up to 1000 characters: one short line for the row.
                                var text = String.UnicodeScalarView()
                                for c in (t["description"] as? String ?? "").unicodeScalars { text.append("\t\n\r".unicodeScalars.contains(c) ? " " : c) }
                                return BackgroundTask(type: clean(t["type"] as? String ?? "").filter { $0 != ":" },
                                                      description: String(clean(String(text)).prefix(120)))
                            },
                            rule: event == "PermissionRequest" ? suggestedRule(p["permission_suggestions"]) : "")
        return (id, line, p["cwd"] as? String ?? "")
    }
}

/// A tool call's name as a hook line keeps it. A "New session" offer card waits for the user's answer, so it gets
/// ":offer"; of the tool input, only `initiation` is read.
func toolDetail(_ name: String, input: Any?) -> String {
    name == "mcp__ccd_session__start_session" && (input as? [String: Any])?["initiation"] as? String == "offer" ? name + ":offer" : name
}

/// The first allow rule of a PermissionRequest's `permission_suggestions`, as `toolName` or `toolName(ruleContent)`
/// (an MCP tool rule has no content). It keeps `;`, which commands use, and is cut to 300 characters.
func suggestedRule(_ suggestions: Any?) -> String {
    guard let entry = (suggestions as? [[String: Any]])?.first(where: { $0["type"] as? String == "addRules" && $0["behavior"] as? String == "allow" }),
          let first = (entry["rules"] as? [[String: Any]])?.first, let tool = first["toolName"] as? String else { return "" }
    return String(oneLine((first["ruleContent"] as? String).map { "\(tool)(\($0))" } ?? tool).prefix(300))
}

private func isValidSessionId(_ s: String) -> Bool {
    (1...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
}

/// Drops the characters that frame a line and its lists (tab, CR, LF, `;`).
private func clean(_ s: String) -> String { oneLine(s).filter { $0 != ";" } }

/// Drops tabs, CR and LF by scalar, so a CRLF pair (one Character) goes too.
private func oneLine(_ s: String) -> String { String(s.unicodeScalars.filter { $0 != "\t" && $0 != "\r" && $0 != "\n" }) }

/// Latest hook state of one session: the newest line. Claude compacts an idle session between turns (a PreCompact,
/// maybe a StopFailure, after a Stop and no prompt); that changes nothing, so the Stop stays the newest line.
public struct HookState: Sendable, Equatable {
    public let last: HookLine

    public init(last: HookLine) {
        self.last = last
    }

    public static func parse(_ contents: String) -> HookState? {
        let lines = contents.split(separator: "\n").compactMap(HookLine.init(encoded:)).sorted { $0.at < $1.at }
        guard let last = lines.last else { return nil }
        if let stop = lines.lastIndex(where: { $0.event == "Stop" }), stop < lines.count - 1,
           lines[stop + 1].event == "PreCompact", lines[(stop + 1)...].allSatisfy({ ["PreCompact", "StopFailure"].contains($0.event) }) {
            return HookState(last: lines[stop])
        }
        return HookState(last: last)
    }
}

/// `~/Library/Application Support/Rounds/state`; `ROUNDS_STATE_DIR` overrides it (tests only).
public func hookStateDirectory() -> URL {
    if let dir = ProcessInfo.processInfo.environment["ROUNDS_STATE_DIR"] { return URL(fileURLWithPath: dir) }
    return URL.applicationSupportDirectory.appending(path: "Rounds/state")
}

/// The rule of the request that the newest line approved, else nil. The newest line (the last) is a PostToolUse or
/// PostToolUseFailure of tool T; the request is the latest PermissionRequest for T with a rule in the 64 lines before
/// it, with no PreToolUse, PostToolUse or PostToolUseFailure of T between (a PreToolUse there is a new call after a denial).
public func approvedRule(_ lines: [HookLine]) -> String? {
    guard let newest = lines.last, ["PostToolUse", "PostToolUseFailure"].contains(newest.event) else { return nil }
    // A PreToolUse detail can carry a suffix, such as ":offer".
    for l in lines.dropLast().suffix(64).reversed() where l.detail == newest.detail || l.detail.hasPrefix(newest.detail + ":") {
        if l.event == "PermissionRequest", !l.rule.isEmpty { return l.rule }
        if ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(l.event) { return nil }
    }
    return nil
}

/// `~/Library/Application Support/Rounds/approvals`; `ROUNDS_APPROVALS_DIR` overrides it (tests only).
public func approvalsDirectory() -> URL {
    if let dir = ProcessInfo.processInfo.environment["ROUNDS_APPROVALS_DIR"] { return URL(fileURLWithPath: dir) }
    return URL.applicationSupportDirectory.appending(path: "Rounds/approvals")
}

/// One line of the approvals log (spec 2.3): `<unix-ms>\t<session_id>\t<cwd>\t<rule>\n`.
public func approvalLine(at: Date, sessionId: String, cwd: String, rule: String) -> String {
    "\(Int64((at.timeIntervalSince1970 * 1000).rounded()))\t\(sessionId)\t\(oneLine(cwd))\t\(rule)\n"
}

public func loadHookStates(dir: URL, cache: FileCache<HookState?> = FileCache()) -> [String: HookState] {
    var states: [String: HookState] = [:]
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: fileCacheKeys)) ?? []
    for file in files {
        if let state = cache.value(at: file, decode: { HookState.parse(String(decoding: $0, as: UTF8.self)) }) ?? nil {
            states[file.lastPathComponent] = state
        }
    }
    cache.keep(only: Set(files))
    return states
}

/// Deletes state files of sessions not in `liveIds` (nil: delete nothing, the session list is not reliable)
/// and rewrites files over `maxBytes` to their last line.
public func pruneStateFiles(dir: URL, liveIds: Set<String>?, maxBytes: Int = 65_536) {
    let fm = FileManager.default
    for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
        if let liveIds, !liveIds.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
            continue
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > maxBytes, let text = try? String(contentsOf: file, encoding: .utf8), let state = HookState.parse(text) {
            try? state.last.encoded.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
