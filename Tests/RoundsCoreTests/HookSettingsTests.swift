import Foundation
import Testing
@testable import RoundsCore

private let helper = "/Applications/Rounds.app/Contents/Helpers/rounds-hook"
private func rtkSettings() -> [String: Any] {
    ["theme": "dark", "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "rtk hook claude"]]]]]]
}
private func canonical(_ d: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]), as: UTF8.self)
}
private func groups(_ d: [String: Any], _ event: String) -> [[String: Any]] {
    ((d["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
}

@Test func installAddsAllEntriesAsync() {
    let d = HookSettings.install([:], helperPath: helper)
    #expect(HookTarget.claude.entries.count == 12)
    for (event, matcher) in HookTarget.claude.entries {
        let g = groups(d, event)
        #expect(g.count == 1)
        #expect(g.first?["matcher"] as? String == matcher)
        let hook = (g.first?["hooks"] as? [[String: Any]])?.first
        #expect(hook?["command"] as? String == "\"\(helper)\"")
        #expect(hook?["async"] as? Bool == true)
        #expect(hook?["type"] as? String == "command")
    }
    #expect(groups(d, "Notification").first?["matcher"] as? String == "permission_prompt|elicitation_dialog|elicitation_url_dialog")
    #expect(groups(d, "Stop").first?["matcher"] == nil)
}

@Test func installKeepsExistingRtkHook() {
    let d = HookSettings.install(rtkSettings(), helperPath: helper)
    #expect(groups(d, "PreToolUse").count == 2)
    #expect(groups(d, "PreToolUse").first?["matcher"] as? String == "Bash")
    #expect(d["theme"] as? String == "dark")
}

@Test func installIsIdempotent() {
    let once = HookSettings.install(rtkSettings(), helperPath: helper)
    #expect(canonical(HookSettings.install(once, helperPath: helper)) == canonical(once))
}

@Test func removeDeletesOnlyOurs() {
    #expect(canonical(HookSettings.remove(HookSettings.install(rtkSettings(), helperPath: helper))) == canonical(rtkSettings()))
    #expect(canonical(HookSettings.remove(HookSettings.install(["a": 1], helperPath: helper))) == canonical(["a": 1]))
}

@Test func statusDetectsStates() {
    #expect(HookSettings.status(rtkSettings(), helperPath: helper) == .missing)
    #expect(HookSettings.status(HookSettings.install(rtkSettings(), helperPath: helper), helperPath: helper) == .installed)
    let moved = HookSettings.install([:], helperPath: "/Users/x/Downloads/Rounds.app/Contents/Helpers/rounds-hook")
    #expect(HookSettings.status(moved, helperPath: helper) == .wrongPath(found: "/Users/x/Downloads/Rounds.app/Contents/Helpers/rounds-hook"))
}

@Test func repairReplacesTheHelperOfItsOldName() {
    let old = HookSettings.install(rtkSettings(), helperPath: "/Applications/Rounds.app/Contents/Helpers/aiecg-hook")
    #expect(HookSettings.status(old, helperPath: helper) == .wrongPath(found: "/Applications/Rounds.app/Contents/Helpers/aiecg-hook"))
    #expect(canonical(HookSettings.install(old, helperPath: helper)) == canonical(HookSettings.install(rtkSettings(), helperPath: helper)))
}

@Test func installerRefusesInvalidJSON() throws {
    let url = try tempDir().appending(path: "settings.json")
    try Data("{".utf8).write(to: url)
    let installer = HookInstaller(settingsURL: url)
    #expect(throws: HookInstallerError.self) { try installer.install(helperPath: helper) }
    #expect(try Data(contentsOf: url) == Data("{".utf8))
}

@Test func installerWritesBackupAndInstalls() throws {
    let url = try tempDir().appending(path: "settings.json")
    let original = try JSONSerialization.data(withJSONObject: rtkSettings())
    try original.write(to: url)
    let installer = HookInstaller(settingsURL: url)
    try installer.install(helperPath: helper)
    #expect(try Data(contentsOf: url.deletingLastPathComponent().appending(path: "settings.json.rounds-backup")) == original)
    #expect(try installer.status(helperPath: helper) == .installed)
    try installer.remove()
    #expect(try installer.status(helperPath: helper) == .missing)
}

@Test func installerTreatsMissingFileAsEmpty() throws {
    let url = try tempDir().appending(path: "settings.json")
    let installer = HookInstaller(settingsURL: url)
    #expect(try installer.status(helperPath: helper) == .missing)
    try installer.install(helperPath: helper)
    #expect(try installer.status(helperPath: helper) == .installed)
}
