import Foundation
import Testing
@testable import RoundsCore

private let sid = "00000000-0000-4000-8000-0000000000aa"
private let now = Date(timeIntervalSince1970: 1792986997.683)

private func payload(_ fields: [String: Any]) throws -> Data {
    var p: [String: Any] = ["session_id": sid, "transcript_path": "/tmp/t.jsonl", "cwd": "/Users/test/proj"]
    p.merge(fields) { $1 }
    return try JSONSerialization.data(withJSONObject: p)
}

@Test func stopPayloadCarriesBackgroundAndCrons() throws {
    let data = try payload([
        "hook_event_name": "Stop", "stop_hook_active": false, "last_assistant_message": "secret text",
        "background_tasks": [["id": "a"], ["id": "b"]],
        "session_crons": [["id": "c1", "schedule": "*/5 * * * *", "recurring": true, "prompt": "secret prompt"]],
    ])
    let (id, line) = try HookLine.from(payload: data, now: now)
    #expect(id == sid)
    #expect(line.event == "Stop")
    #expect(line.backgroundTasks == 2)
    #expect(line.cronSchedules == ["*/5 * * * *"])
    #expect(line.encoded == "1792986997683\tStop\t\t2\t*/5 * * * *\t:;:\n")
    #expect(!line.encoded.contains("secret"))
}

@Test func stopIgnoresMonitorTasks() throws {
    // An artifact watch is an ambient monitor that stays open after the turn; it is not work in progress.
    let data = try payload([
        "hook_event_name": "Stop",
        "background_tasks": [["id": "m", "type": "monitor", "status": "running"], ["id": "s", "type": "shell", "status": "running"]],
    ])
    #expect(try HookLine.from(payload: data, now: now).line.backgroundTasks == 1)
}

@Test func stopKeepsTaskTypesAndShortDescriptions() throws {
    let long = String(repeating: "x", count: 1000)
    let data = try payload([
        "hook_event_name": "Stop",
        "background_tasks": [["id": "s", "type": "shell", "status": "running", "description": "npm test;\tlong: run"],
                             ["id": "m", "type": "monitor", "description": "watch"],
                             ["id": "a", "type": "subagent", "description": long]],
    ])
    let line = try HookLine.from(payload: data, now: now).line
    #expect(line.backgroundTasks == 2)
    #expect(line.tasks == [BackgroundTask(type: "shell", description: "npm test long: run"),
                           BackgroundTask(type: "subagent", description: String(repeating: "x", count: 120))])
    #expect(HookLine(encoded: line.encoded.dropLast()) == line)
}

/// A line from an older helper has five fields: the count is known, the task list is not.
@Test func oldLineHasCountOnly() throws {
    let line = try #require(HookLine(encoded: "100\tStop\t\t2\t"))
    #expect(line.backgroundTasks == 2 && line.tasks.isEmpty)
}

@Test(arguments: [
    (["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "secret"]], "Bash"),
    (["hook_event_name": "PermissionRequest", "tool_name": "Edit"], "Edit"),
    (["hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "secret"], "permission_prompt"),
    (["hook_event_name": "StopFailure", "error": "rate_limit"], "rate_limit"),
    (["hook_event_name": "Elicitation", "mcp_server_name": "github"], "github"),
    (["hook_event_name": "UserPromptSubmit", "prompt": "secret"], ""),
] as [([String: any Sendable], String)])
func encodeDecodeRoundTrip(fields: [String: any Sendable], detail: String) throws {
    let (_, line) = try HookLine.from(payload: payload(fields), now: now)
    #expect(line.detail == detail)
    #expect(line.backgroundTasks == nil && line.cronSchedules.isEmpty)
    #expect(!line.encoded.contains("secret"))
    #expect(HookLine(encoded: line.encoded.dropLast()) == line)
}

@Test func detailDropsTabsAndNewlines() throws {
    let (_, line) = try HookLine.from(payload: payload(["hook_event_name": "PreToolUse", "tool_name": "a\tb\nc"]), now: now)
    #expect(line.detail == "abc")
}

@Test(arguments: ["../x", "a/b", "", String(repeating: "a", count: 65), "a b"])
func rejectsPathLikeSessionId(bad: String) throws {
    let data = try JSONSerialization.data(withJSONObject: ["session_id": bad, "hook_event_name": "Stop"])
    #expect(throws: HookPayloadError.badSessionId) { try HookLine.from(payload: data, now: now) }
}

@Test func invalidPayloadThrows() {
    #expect(throws: HookPayloadError.invalidJSON) { try HookLine.from(payload: Data("nope".utf8), now: now) }
}

@Test func stateUsesHighestTimestampNotLastLine() throws {
    let contents = "300\tPreToolUse\tBash\t\t\n100\tStop\t\t1\t\n200\tStop\t\t0\t5 0 * * *\n"
    let state = try #require(HookState.parse(contents))
    #expect(state.last.at == Date(timeIntervalSince1970: 0.3))
    #expect(state.last.event == "PreToolUse")
}

@Test func malformedLinesIgnored() throws {
    let state = try #require(HookState.parse("garbage\n\n100\tStop\t\t\t\nx\ty\n"))
    #expect(state.last.event == "Stop")
    #expect(HookState.parse("garbage\n") == nil)
}

@Test func loadHookStatesKeysByFileName() throws {
    let dir = try tempDir()
    try "100\tStop\t\t\t\n".write(to: dir.appending(path: sid), atomically: true, encoding: .utf8)
    try "junk".write(to: dir.appending(path: "other"), atomically: true, encoding: .utf8)
    #expect(Array(loadHookStates(dir: dir).keys) == [sid])
}

@Test func parallelHelperRunsGiveIntactLines() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let helper = root.appending(path: ".build/debug/rounds-hook")
    try #require(FileManager.default.isExecutableFile(atPath: helper.path), "run swift build first")
    let dir = try tempDir()
    let input = try payload(["hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_response": ["stdout": String(repeating: "x", count: 2000)]])
    let failures = Locked(0)
    DispatchQueue.concurrentPerform(iterations: 50) { _ in
        let p = Process()
        p.executableURL = helper
        p.environment = ["ROUNDS_STATE_DIR": dir.path]
        let pipe = Pipe()
        p.standardInput = pipe
        do { try p.run() } catch { failures.withLock { $0 += 1 }; return }
        pipe.fileHandleForWriting.write(input)
        try? pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        if p.terminationStatus != 0 { failures.withLock { $0 += 1 } }
    }
    #expect(failures.withLock { $0 } == 0)
    let lines = try String(contentsOf: dir.appending(path: sid), encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 50)
    #expect(lines.allSatisfy { HookLine(encoded: $0)?.detail == "Bash" })
}

@Test func idleCompactionAfterAStopIsNotANewTurn() {
    func line(_ s: Double, _ event: String, _ detail: String = "") -> String {
        HookLine(at: Date(timeIntervalSince1970: s), event: event, detail: detail, backgroundTasks: nil, cronSchedules: []).encoded
    }
    // Claude compacts an idle session between turns; a server error there is not the user's turn failing.
    let idle = [line(1, "Stop"), line(2, "PreCompact", "auto"), line(3, "StopFailure", "server_error")].joined()
    #expect(HookState.parse(idle)?.last.event == "Stop")
    #expect(HookState.parse([line(1, "Stop"), line(2, "PreCompact", "auto")].joined())?.last.event == "Stop")
    // A compaction inside a turn is work in progress, and its failure fails the turn.
    #expect(HookState.parse([line(1, "PostToolUse"), line(2, "PreCompact")].joined())?.last.event == "PreCompact")
    #expect(HookState.parse([line(1, "UserPromptSubmit"), line(2, "PreCompact"), line(3, "StopFailure")].joined())?.last.event == "StopFailure")
}
