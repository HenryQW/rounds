import Foundation

public enum HookInstallStatus: Sendable, Equatable {
    case installed, missing, wrongPath(found: String)
}

public enum HookInstallerError: Error, Equatable {
    case invalidJSON(String)
    /// `config.toml` sets `features` in a form a line edit cannot change: a dotted key or an inline table.
    case unsupportedConfig(String)
    /// The file exists but cannot be read.
    case unreadable(String)
    /// A symlink whose target is missing: a write would put a file where the user keeps a link.
    case danglingLink(String)
}

/// The file a settings path names: a symlink resolves to its target, so a write changes the target and keeps the link.
func resolvedSettingsFile(_ url: URL) throws(HookInstallerError) -> URL {
    let resolved = url.resolvingSymlinksInPath()
    // A dangling link does not resolve: the path is still a link.
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: resolved.path)) != nil { throw .danglingLink(resolved.path) }
    return resolved
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
    private static let helperSuffix = "/Contents/Helpers/rounds-hook"

    /// Our helper path inside a hook group, if the group runs it.
    private static func ourPath(_ group: [String: Any]) -> String? {
        (group["hooks"] as? [[String: Any]] ?? []).lazy.compactMap(helperPath(of:)).first
    }

    private static func helperPath(of hook: [String: Any]) -> String? {
        let path = (hook["command"] as? String ?? "").replacingOccurrences(of: "\"", with: "")
        return path.hasSuffix(helperSuffix) ? path : nil
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
            // A group can also hold the user's hooks: take out only our entries, and the group only when it is then empty.
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let others = entries.filter { helperPath(of: $0) == nil }
                if others.count == entries.count { return group }
                return others.isEmpty ? nil : group.merging(["hooks": others]) { $1 }
            }
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
        let data: Data
        do {
            data = try Data(contentsOf: try resolvedSettingsFile(settingsURL))
        } catch let error as HookInstallerError {
            throw error
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            throw .unreadable(error.localizedDescription)
        }
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

/// Copies the old file to `<name>.rounds-backup`, then replaces it atomically. A symlink keeps pointing to the new file.
func writeKeepingBackup(_ data: Data, to link: URL) throws {
    let url = try resolvedSettingsFile(link)
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
        ((try? featureLines(toml)) ?? []).contains { isKey($0.text, "hooks") && $0.text.replacingOccurrences(of: " ", with: "") == "hooks=true" }
    }

    public static func enablingHooks(_ toml: String) throws(HookInstallerError) -> String {
        let features = try featureLines(toml)
        let switchLine = features.first { isKey($0.text, "hooks") }?.index
        let oldNames = Set(features.filter { isKey($0.text, "codex_hooks") }.map(\.index))
        var lines: [String] = []
        var written = switchLine != nil
        for (index, line) in toml.components(separatedBy: "\n").enumerated() where !oldNames.contains(index) {
            lines.append(index == switchLine ? "hooks = true" : line)
            if !written, tableHeader(line) == "[features]" {
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
        let edited = try enablingHooks(toml)
        if edited != toml { try writeKeepingBackup(Data(edited.utf8), to: url) }
    }

    /// Lines of the top-level `[features]` table, with their line numbers. Throws when the top level sets `features`
    /// as a dotted key or an inline table: a second `[features]` table would make the file invalid.
    private static func featureLines(_ toml: String) throws(HookInstallerError) -> [(index: Int, text: String)] {
        var inFeatures = false, atTop = true
        var result: [(Int, String)] = []
        for (index, line) in toml.components(separatedBy: "\n").enumerated() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let header = tableHeader(text) {
                (inFeatures, atTop) = (header == "[features]", false)
            } else if inFeatures {
                result.append((index, text))
            } else if atTop, text.contains("=") {
                let key = text.prefix { $0 != "=" }.filter { $0 != " " && $0 != "\t" }
                if key == "features" || key.hasPrefix("features.") {
                    throw .unsupportedConfig("config.toml sets features as a dotted key or inline table; change it to a [features] table")
                }
            }
        }
        return result
    }

    /// A table header without its comment and inner spaces (`[ features ] # c` is `[features]`); nil for other lines.
    private static func tableHeader(_ line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("[") else { return nil }
        return String(text.prefix { $0 != "#" }.filter { $0 != " " && $0 != "\t" })
    }

    private static func isKey(_ line: String, _ key: String) -> Bool {
        line.hasPrefix(key) && line.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }
}
