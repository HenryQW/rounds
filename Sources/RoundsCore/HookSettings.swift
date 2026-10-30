import Foundation

public enum HookInstallStatus: Sendable, Equatable {
    case installed, missing, wrongPath(found: String)
}

public enum HookInstallerError: Error, Equatable {
    case invalidJSON(String)
}

/// A hooks file Rounds writes its entries into, or the pi extension file it installs.
public enum HookTarget: Sendable, Identifiable {
    /// `~/.claude/settings.json`: async hooks, so no session waits for the helper.
    case claude
    /// `~/.codex/hooks.json` (spec 2.6): Codex runs hooks in line; the helper ends in milliseconds.
    case codex
    /// `~/.pi/agent/extensions/rounds.ts` (spec 2.7): an extension pi loads at start, not a hooks file; `entries` are
    /// the pi events it follows.
    case pi

    public var id: Self { self }

    /// What Settings installs: "Hooks" or "Extension".
    public var noun: String { self == .pi ? "Extension" : "Hooks" }

    public var entries: [(event: String, matcher: String?)] {
        switch self {
        case .claude: [
            ("UserPromptSubmit", nil), ("PreToolUse", "*"), ("PostToolUse", "*"), ("PostToolUseFailure", "*"),
            ("PermissionRequest", "*"), ("Notification", "permission_prompt|elicitation_dialog|elicitation_url_dialog"),
            ("Elicitation", "*"), ("ElicitationResult", "*"), ("PreCompact", "*"), ("Stop", nil), ("StopFailure", "*"),
            ("SessionEnd", "*"),
        ]
        case .codex: ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact", "Stop", "Interrupt", "SessionEnd"]
            .map { ($0, nil) }
        case .pi: ["session_start", "agent_start", "message_end", "agent_settled", "session_before_compact", "session_compact",
                   "session_compact_failed", "ui_prompt_start", "ui_prompt_end", "session_shutdown"].map { ($0, nil) }
        }
    }

    /// Handler fields beside type and command.
    var handler: [String: Any] {
        switch self {
        case .claude: ["async": true]
        case .codex: ["timeout": 10]
        case .pi: [:]
        }
    }
}

/// Pure edits of a hooks dictionary (spec 2.4): Claude Code `settings.json` or Codex `hooks.json` share the shape.
public enum HookSettings {
    /// The helper's name, and its name before 2026-10-30 (`aiecg-hook`), so Repair Hooks replaces the old entries.
    private static let helperSuffixes = ["/Contents/Helpers/rounds-hook", "/Contents/Helpers/aiecg-hook"]

    /// Our helper path inside a hook group, if the group runs it.
    private static func ourPath(_ group: [String: Any]) -> String? {
        for hook in group["hooks"] as? [[String: Any]] ?? [] {
            let path = (hook["command"] as? String ?? "").replacingOccurrences(of: "\"", with: "")
            if helperSuffixes.contains(where: path.hasSuffix) { return path }
        }
        return nil
    }

    public static func status(_ settings: [String: Any], helperPath: String, target: HookTarget = .claude) -> HookInstallStatus {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let paths = hooks.values.flatMap { ($0 as? [[String: Any]] ?? []).compactMap(ourPath) }
        if let other = paths.first(where: { $0 != helperPath }) { return .wrongPath(found: other) }
        let complete = target.entries.allSatisfy { e in (hooks[e.event] as? [[String: Any]] ?? []).contains { ourPath($0) == helperPath } }
        return complete ? .installed : .missing
    }

    public static func install(_ settings: [String: Any], helperPath: String, target: HookTarget = .claude) -> [String: Any] {
        var result = remove(settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        let handler = target.handler.merging(["type": "command", "command": "\"\(helperPath)\""]) { $1 }
        for (event, matcher) in target.entries {
            var group: [String: Any] = ["hooks": [handler]]
            if let matcher { group["matcher"] = matcher }
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
        }
        result["hooks"] = hooks
        return result
    }

    public static func remove(_ settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { ourPath($0) == nil }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        var result = settings
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }
}

/// Reads and writes a hooks file: backup first, then an atomic replace.
public struct HookInstaller: Sendable {
    public let settingsURL: URL
    public let target: HookTarget

    public init(settingsURL: URL, target: HookTarget = .claude) {
        self.settingsURL = settingsURL
        self.target = target
    }

    private func read() throws(HookInstallerError) -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .invalidJSON(error.localizedDescription)
        }
        guard let dict = object as? [String: Any] else { throw .invalidJSON("top level is not an object") }
        return dict
    }

    private func write(_ settings: [String: Any]) throws {
        try writeKeepingBackup(JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                               to: settingsURL)
    }

    public func status(helperPath: String) throws(HookInstallerError) -> HookInstallStatus {
        HookSettings.status(try read(), helperPath: helperPath, target: target)
    }

    public func install(helperPath: String) throws {
        try write(HookSettings.install(try read(), helperPath: helperPath, target: target))
    }

    public func remove() throws {
        try write(HookSettings.remove(try read()))
    }
}

/// Copies the old file to `<name>.rounds-backup`, then replaces it atomically.
func writeKeepingBackup(_ data: Data, to url: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
        let backup = url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".rounds-backup")
        try? fm.removeItem(at: backup)
        try fm.copyItem(at: url, to: backup)
    }
    try data.write(to: url, options: .atomic)
}

/// Codex reads `hooks.json` only with `hooks = true` in the top-level `[features]` table of `config.toml` (spec 2.6).
/// A line edit keeps the user's comments and order; `codex_hooks` is the old name of the same switch.
public enum CodexConfig {
    public static func hooksEnabled(_ toml: String) -> Bool {
        featureLines(toml).contains { isKey($0.text, "hooks") && $0.text.replacingOccurrences(of: " ", with: "") == "hooks=true" }
    }

    public static func enablingHooks(_ toml: String) -> String {
        let features = featureLines(toml)
        let switchLine = features.first { isKey($0.text, "hooks") }?.index
        let oldNames = Set(features.filter { isKey($0.text, "codex_hooks") }.map(\.index))
        var lines: [String] = []
        var written = switchLine != nil
        for (index, line) in toml.components(separatedBy: "\n").enumerated() where !oldNames.contains(index) {
            lines.append(index == switchLine ? "hooks = true" : line)
            if !written, line.trimmingCharacters(in: .whitespaces) == "[features]" {
                lines.append("hooks = true")
                written = true
            }
        }
        if written { return lines.joined(separator: "\n") }
        let body = toml.trimmingCharacters(in: .newlines)
        return (body.isEmpty ? "" : body + "\n\n") + "[features]\nhooks = true\n"
    }

    /// Turns the switch on in the file (a missing file is empty), keeping a backup; no write when it is already on.
    public static func enableHooks(at url: URL) throws {
        let toml: String
        do {
            toml = try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            toml = ""
        }
        let edited = enablingHooks(toml)
        if edited != toml { try writeKeepingBackup(Data(edited.utf8), to: url) }
    }

    /// Lines of the top-level `[features]` table, with their line numbers.
    private static func featureLines(_ toml: String) -> [(index: Int, text: String)] {
        var inFeatures = false
        var result: [(Int, String)] = []
        for (index, line) in toml.components(separatedBy: "\n").enumerated() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") {
                inFeatures = text == "[features]"
            } else if inFeatures {
                result.append((index, text))
            }
        }
        return result
    }

    private static func isKey(_ line: String, _ key: String) -> Bool {
        line.hasPrefix(key) && line.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }
}
