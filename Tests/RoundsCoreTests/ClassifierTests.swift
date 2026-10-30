import Foundation
import Testing
@testable import RoundsCore

private let now = Date(timeIntervalSince1970: 1_792_990_000)
private func ago(_ s: Double) -> Date { now.addingTimeInterval(-s) }
private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

private func session(_ overrides: [String: Any] = [:]) -> DesktopSession {
    var d: [String: Any] = ["sessionId": "local_1", "cliSessionId": "c1", "cwd": "/Users/test/proj", "title": "S",
                            "isArchived": false, "lastActivityAt": ms(ago(60)), "lastAssistantUuid": "u1"]
    d.merge(overrides) { $1 }
    return try! DesktopSession(json: JSONSerialization.data(withJSONObject: d))
}
private func line(_ event: String, _ detail: String = "", at: Date = ago(10), bg: Int? = nil, crons: [String] = []) -> HookLine {
    HookLine(at: at, event: event, detail: detail, backgroundTasks: bg, cronSchedules: crons)
}
private func hook(_ l: HookLine) -> HookState { HookState(last: l) }
private func classify(_ s: DesktopSession, _ h: HookState? = nil, tail t: LastMessage? = nil, running: Bool = true) -> SessionStatus {
    RoundsCore.classify(ClassifierInput(session: s, hook: h, tail: t, claudeRunning: running, now: now))
}
private func expect(_ st: SessionStatus, _ state: SessionState, _ detail: String = "", group: StatusGroup? = nil,
                    sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(st.state == state, sourceLocation: sourceLocation)
    #expect(st.detail == detail, sourceLocation: sourceLocation)
    #expect(st.group == (group ?? state.group), sourceLocation: sourceLocation)
}
private let stop = hook(line("Stop", bg: 0))
nonisolated(unsafe) private let blockedSummary: [String: Any] = ["status_category": "blocked", "needs_action": "x", "summarizes_uuid": "u1"]

@Test func rule0Archived() { expect(classify(session(["isArchived": true]), stop), .finished, group: .hidden) }

@Test func rule1StaleWhenClaudeNotRunning() {
    expect(classify(session(), hook(line("PreToolUse", "Bash")), running: false), .offline)
    expect(classify(session(), hook(line("PermissionRequest", "Bash")), running: false), .offline)
    expect(classify(session(), stop, running: false), .finished)
}

@Test func rule1StaleAfterSessionEnd() {
    expect(classify(session(), hook(line("SessionEnd", at: ago(5)))), .finished)
}

@Test func rule2RemoteHasNoLiveState() {
    expect(classify(session(["sshConfig": ["host": "h"]]), hook(line("PreToolUse", "Bash"))), .offline, "remote")
    expect(classify(session(["sshConfig": ["host": "h"], "turnWrapUp": ["description": "d", "needsUser": "Q?"]])), .needsInput, "Question")
}

@Test(arguments: [
    (line("PermissionRequest", "Bash"), "Permission: Bash"),
    (line("Notification", "permission_prompt"), "Permission"),
    (line("Notification", "elicitation_dialog"), "MCP input"),
    (line("Elicitation", "github"), "MCP input"),
    (line("PreToolUse", "AskUserQuestion"), "Question"),
    (line("PreToolUse", "ExitPlanMode"), "Plan approval"),
])
func rule3Blocked(l: HookLine, label: String) {
    let st = classify(session(), hook(l))
    expect(st, .needsInput, label)
    #expect(st.since == l.at)
}

@Test func rule4InterruptedAwaitingPerson() {
    expect(classify(session(["interruptedAwaitingPerson": true]), stop), .needsInput, "Interrupted")
}

@Test(arguments: [
    (line("PreToolUse", "Bash"), "Bash"), (line("UserPromptSubmit"), "Thinking"), (line("PostToolUse", "Bash"), "Thinking"),
    (line("PostToolUseFailure", "Bash"), "Thinking"), (line("ElicitationResult", "github"), "Thinking"), (line("PreCompact", "auto"), "Compacting"),
])
func rule5Running(l: HookLine, label: String) {
    expect(classify(session(), hook(l)), .working, label)
}

@Test func rule6BackgroundTasks() {
    expect(classify(session(), hook(line("Stop", bg: 2))), .background, "2 tasks")
    // An old line knows the count only: one line stands for all tasks.
    #expect(classify(session(), hook(line("Stop", bg: 2))).tasks == [BackgroundTask(type: "", description: "2 background tasks")])
    let tasks = [BackgroundTask(type: "shell", description: "npm test")]
    let withList = HookLine(at: ago(10), event: "Stop", detail: "", backgroundTasks: 1, cronSchedules: [], tasks: tasks)
    #expect(classify(session(), hook(withList)).tasks == tasks)
    #expect(classify(session(), hook(withList), running: false).tasks.isEmpty)
    // A task that outlives two hours without a hook event (or died) no longer holds the row in Running.
    expect(classify(session(), hook(line("Stop", at: ago(3 * 3600), bg: 2))), .finished)
}

@Test func rule7Failed() {
    expect(classify(session(), hook(line("StopFailure", "rate_limit"))), .failed, "rate_limit")
    expect(classify(session(["errorAt": ms(ago(3600))]), stop), .failed, "error")
    expect(classify(session(["errorAt": ms(ago(8 * 86400))]), stop), .finished)
    expect(classify(session(["postTurnSummary": ["status_category": "failed", "needs_action": "", "summarizes_uuid": "u1"]]), stop), .failed, "error")
}

@Test func rule8WakesSoon() {
    let utc = Calendar(identifier: .gregorian)
    let soon = utc.date(byAdding: .minute, value: 10, to: now)!
    let c = utc.dateComponents([.minute, .hour, .day, .month], from: soon)
    let expr = "\(c.minute!) \(c.hour!) \(c.day!) \(c.month!) *"
    expect(classify(session(), hook(line("Stop", bg: 0, crons: [expr]))), .background, "Wakes in 10 min")
    let later = utc.dateComponents([.minute, .hour, .day, .month], from: utc.date(byAdding: .minute, value: 30, to: now)!)
    expect(classify(session(), hook(line("Stop", bg: 0, crons: ["\(later.minute!) \(later.hour!) \(later.day!) \(later.month!) *"]))), .finished)
}

@Test func rule9Question() {
    expect(classify(session(["turnWrapUp": ["description": "d", "needsUser": "Q?"]]), stop), .needsInput, "Question")
    expect(classify(session(["postTurnSummary": blockedSummary]), stop), .needsInput, "Question")
    expect(classify(session(["postTurnSummary": ["status_category": "need_input", "needs_action": "", "summarizes_uuid": "u1"]]), stop), .needsInput, "Question")
    // A blocked summary that names a step for the user wants input, also after a wrap-up without a question.
    expect(classify(session(["postTurnSummary": blockedSummary, "turnWrapUp": ["description": "d"]]), stop), .needsInput, "Question")
    // The wrap-up asked a question that only the transcript holds.
    expect(classify(session(["turnWrapUp": ["description": "d"]]), stop, tail: .question), .needsInput, "Question")
}

@Test func staleSummaryIgnored() {
    var s = blockedSummary
    s["summarizes_uuid"] = "old"
    expect(classify(session(["postTurnSummary": s]), stop), .finished)
}

@Test func summaryMidTurnIgnored() {
    expect(classify(session(["postTurnSummary": blockedSummary]), hook(line("PreToolUse", "Bash"))), .working, "Bash")
}

@Test func wrapUpWithoutQuestionDowngradesBlockedSummary() {
    let noAction: [String: Any] = ["status_category": "blocked", "needs_action": "", "summarizes_uuid": "u1"]
    expect(classify(session(["postTurnSummary": noAction, "turnWrapUp": ["description": "d"]]), stop), .ready, "review")
    expect(classify(session(["postTurnSummary": ["status_category": "review_ready", "needs_action": "", "summarizes_uuid": "u1"]]), stop), .ready, "review")
}

@Test func rule10Labels() {
    expect(classify(session(), stop), .finished)
    expect(classify(session(["lastAssistantUuid": NSNull()])), .finished, "new")
}

@Test func reconcileAfterHook() {
    let edge: [String: Any] = ["lastTurnEdgeAt": ms(ago(2))]
    let running = hook(line("PreToolUse", "Bash", at: ago(30)))
    #expect(needsTail(session: session(edge), hook: running))
    #expect(!needsTail(session: session(["lastTurnEdgeAt": ms(ago(30.2))]), hook: running))
    expect(classify(session(edge), running, tail: .interrupted), .stopped)
    expect(classify(session(edge), running, tail: .endTurn), .finished)
    expect(classify(session(edge), running, tail: .inProgress), .working, "Thinking")
}

@Test func wakeupTurnAfterStopIsRunning() {
    expect(classify(session(["lastTurnEdgeAt": ms(ago(2))]), hook(line("Stop", at: ago(60), bg: 0)), tail: .inProgress), .working, "Thinking")
}

@Test func noHookUsesTranscript() {
    #expect(needsTail(session: session(), hook: nil))
    expect(classify(session(), nil, tail: .inProgress), .working, "Thinking")
    expect(classify(session(["lastActivityAt": ms(ago(3600))]), nil, tail: .inProgress), .finished)
    expect(classify(session(), nil, tail: .interrupted), .stopped)
}

@Test func hookFromBeforeClaudeLaunchIsStale() {
    let input = { (launched: Date?) in
        ClassifierInput(session: session(), hook: hook(line("PreToolUse", "Bash", at: ago(60))), tail: nil,
                        claudeRunning: true, claudeLaunchedAt: launched, now: now)
    }
    expect(RoundsCore.classify(input(ago(30))), .offline)
    expect(RoundsCore.classify(input(ago(120))), .working, "Bash")
    let blocked = ClassifierInput(session: session(), hook: hook(line("PermissionRequest", "Bash", at: ago(60))), tail: nil,
                                  claudeRunning: true, claudeLaunchedAt: ago(30), now: now)
    expect(RoundsCore.classify(blocked), .offline)
}

@Test func mcpToolLabelsShowTheToolName() {
    let tool = "mcp__00000000-0000-4000-8000-000000000000__send_message"
    expect(classify(session(), hook(line("PreToolUse", tool))), .working, "send_message")
    expect(classify(session(), hook(line("PermissionRequest", tool))), .needsInput, "Permission: send_message")
}
