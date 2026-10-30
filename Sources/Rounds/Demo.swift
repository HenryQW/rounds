import AppKit
import RoundsCore

/// The app's settings store: `UserDefaults.standard`, or in demo mode a store that reads nothing and saves nothing, so
/// a demo run shows the default settings and never changes the user's. UserDefaults is thread-safe.
nonisolated(unsafe) let appDefaults: UserDefaults = Demo.isOn ? EmptyDefaults(suiteName: "com.henryqw.rounds.demo")! : movedFromOldName()

/// Rounds was AI ECG (bundle id `com.henryqw.aiecg`) until 2026-10-30. On the first launch under the new id, its settings
/// (window frame names with Rounds in place of AIECG) and its hook state folder move over once.
private func movedFromOldName() -> UserDefaults {
    let standard = UserDefaults.standard
    if let id = Bundle.main.bundleIdentifier, standard.persistentDomain(forName: id) == nil,
       let old = standard.persistentDomain(forName: "com.henryqw.aiecg") {
        standard.setPersistentDomain(Dictionary(uniqueKeysWithValues: old.map { ($0.key.replacing("AIECG", with: "Rounds"), $0.value) }),
                                     forName: id)
        let support = URL.applicationSupportDirectory
        try? FileManager.default.moveItem(at: support.appending(path: "AI ECG"), to: support.appending(path: "Rounds"))
    }
    return standard
}

/// The typed getters and setters of `UserDefaults` all go through these two.
private final class EmptyDefaults: UserDefaults {
    override func object(forKey defaultName: String) -> Any? { nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}

/// Demo mode, for the screenshots of the docs site (`scripts/screenshots.sh`). `--demo` shows fixed placeholder
/// sessions and reads no source, hook file or setting; every source is on. `--demo-scene <name>` opens one window after
/// launch, with no key or pointer events; `--demo-appearance light|dark` sets the appearance.
enum Demo {
    static let isOn = CommandLine.arguments.contains("--demo")
    private static let scene = argument("--demo-scene")
    /// Scenes with no session in Your Turn: the running pill, and windows that open on Last Call with the Another round?
    /// banner. window-turn starts so, and after 2 s two sessions need the user, for `scripts/watch-frames.sh` (the banner
    /// goes as the rows come); window-slide does so 0.1 s into the opening slide.
    private static var quiet: Bool { ["window-quiet", "pill-running", "window-turn", "window-slide"].contains(scene) }

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        return args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    /// Called once the app has finished launching. Pill scenes need no window: the drawer shows the pill.
    @MainActor static func start() {
        guard isOn else { return }
        switch argument("--demo-appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        // After the first layout pass, so the window opens at its fitted height.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                let page: SettingsPage? = switch scene {
                case "settings-general": .general
                case "settings-pill": .pill
                case "settings-filters": .filters
                case "settings-sources": .sources
                case "settings-keys": .keys
                default: nil
                }
                if let page {
                    SettingsState.shared.page = page
                    // SwiftUI opens the Settings scene only from its own controls; the app menu's Settings… item is one.
                    let item = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.keyEquivalent == "," }
                    if let item, let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
                } else if scene?.hasPrefix("window") == true {
                    if scene == "window-children" { PanelController.shared.state.expanded = ["demo-parser", "demo-notes"] }
                    if quiet { PanelController.shared.state.filter = .yourTurn }
                    NSApp.activate(ignoringOtherApps: true)
                    PanelController.shared.show()
                    if scene == "window-turn" || scene == "window-slide" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + (scene == "window-turn" ? 2 : 0.1)) { AppModel.shared.setDemoRows(rows(quiet: false)) }
                    }
                }
            }
        }
    }

    /// The placeholder sessions: every state, a Ready row the user opened (seen), a starred row, a parent with a direct and an isolated child, background
    /// tasks, one and two PRs, and rows from Claude, Codex and herdr (pi). Neutral titles and folders only. `quiet`: no
    /// session in Your Turn, so Ready ones are Finished; pill-ready keeps Ready but no session that needs input;
    /// pill-attention has no failure (the orange pill), pill-failed has one (the red pill).
    static func rows(now: Date = Date(), quiet: Bool = quiet) -> (claude: [SessionRow], codex: [SessionRow], herdr: [SessionRow]) {
        let ready: SessionState = quiet ? .finished : .ready
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let root = "/Users/demo/Projects/"
        func claude(_ id: String, _ title: String, _ folder: String, _ status: SessionStatus, prs: [(Int, String)] = [],
                    starred: Bool = false, parent: String? = nil, focused: Date? = nil) -> SessionRow {
            var json: [String: Any] = [
                "sessionId": id, "cliSessionId": id, "cwd": root + folder, "title": title, "isArchived": false, "isStarred": starred,
                "lastActivityAt": status.since.timeIntervalSince1970 * 1000, "branch": "main",
                "prs": prs.map { ["prNumber": $0.0, "state": $0.1, "url": "https://github.com/example/\(folder)/pull/\($0.0)"] },
            ]
            if let focused { json["lastFocusedAt"] = focused.timeIntervalSince1970 * 1000 }
            if let parent { json["spawnedFrom"] = ["sessionId": parent, "title": "", "userFork": false] }
            return SessionRow(session: try! DesktopSession(json: JSONSerialization.data(withJSONObject: json)), status: status)
        }
        let yourTurn = quiet || scene == "pill-ready" ? [] : [
            claude("demo-search", "Add search to the docs", "atlas", SessionStatus(.needsInput, "Permission: Bash", since: ago(3))),
        ] + (scene == "pill-attention" ? [] : [
            claude("demo-login", "Fix login redirect", "harbor", SessionStatus(.failed, "error", since: ago(7))),
        ])
        let claudeRows = yourTurn + [
            claude("demo-parser", "Refactor the parser", "atlas", SessionStatus(.working, "Edit", since: ago(1)), prs: [(42, "OPEN")]),
            claude("demo-parser-tests", "Write parser tests", "atlas", SessionStatus(.working, "Bash", since: ago(2)), parent: "demo-parser"),
            claude("demo-tokenizer", "Try a faster tokenizer", "atlas-tokenizer", SessionStatus(ready, "review", since: ago(9)), parent: "demo-parser"),
            claude("demo-notes", "Update the release notes", "notes", SessionStatus(.background, "2 tasks", since: ago(4), tasks: [
                BackgroundTask(type: "shell", description: "Build the site"),
                BackgroundTask(type: "subagent", description: "Check for broken links"),
            ])),
            claude("demo-dark", "Add dark mode to settings", "harbor", SessionStatus(ready, "review", since: ago(25)), prs: [(118, "MERGED"), (121, "OPEN")],
                   focused: ago(20)),
            claude("demo-flags", "Clean up old flags", "harbor", SessionStatus(.stopped, since: ago(48)), prs: [(97, "CLOSED")]),
            claude("demo-cache", "Tune the cache settings", "harbor", SessionStatus(.offline, "remote", since: ago(95))),
            claude("demo-plan", "Plan the next release", "notes", SessionStatus(.finished, since: ago(130)), prs: [(110, "MERGED")], starred: true),
        ]
        let codexRows = [
            SessionRow(thread: CodexThread(id: "demo-tests", title: "Speed up the test suite", cwd: root + "harbor", branch: "main",
                                           updatedAt: ago(1), rolloutPath: ""), status: SessionStatus(.working, "Thinking", since: ago(1))),
            SessionRow(thread: CodexThread(id: "demo-guide", title: "Write the upgrade guide", cwd: root + "notes", branch: "main",
                                           updatedAt: ago(60), rolloutPath: ""), status: SessionStatus(.finished, since: ago(60))),
        ]
        // herdr reports agents only through its socket; the same JSON gives the same rows.
        let agents: [[String: Any]] = [
            ["pane_id": "p1", "agent": "pi", "agent_status": "working", "terminal_title_stripped": "π - Fix flaky upload test - atlas",
             "cwd": root + "atlas", "agent_session": ["kind": "path", "value": "/Users/demo/.pi/upload.jsonl"]],
            ["pane_id": "p2", "agent": "pi", "agent_status": quiet ? "idle" : "done", "terminal_title_stripped": "π - Review the API changes - notes",
             "cwd": root + "notes", "agent_session": ["kind": "path", "value": "/Users/demo/.pi/api.jsonl"]],
        ]
        let response = try! JSONSerialization.data(withJSONObject: ["result": ["agents": agents]])
        let herdrRows = try! parseHerdrAgents(response).enumerated().map { i, agent in
            SessionRow(agent: agent, status: herdrStatus(agent.agentStatus, since: ago(i == 0 ? 2 : 15)))
        }
        return (claudeRows, codexRows, herdrRows)
    }
}
