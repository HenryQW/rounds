import Foundation
import Testing
@testable import RoundsCore

private let now = Date(timeIntervalSince1970: 1_792_990_000)
private func ago(_ s: Double) -> Date { now.addingTimeInterval(-s) }
private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
/// Every free text field in the inputs carries it; no report may.
private let marker = "SECRET-MARKER"

private func session(_ overrides: [String: Any] = [:]) -> DesktopSession {
    var d: [String: Any] = [
        "sessionId": "local_1", "cliSessionId": "c1", "cwd": "/Users/\(marker)/proj", "title": "\(marker) title", "isArchived": false,
        "lastActivityAt": ms(ago(60)), "lastAssistantUuid": "u1", "branch": "fix/\(marker)",
        "prs": [["prNumber": 7, "url": "https://github.com/\(marker)/pull/7", "state": "OPEN"]],
        "turnWrapUp": ["description": "\(marker) prompt"],
        "postTurnSummary": ["status_category": "blocked", "needs_action": "\(marker) step", "summarizes_uuid": "u1", "status_detail": marker],
        "error": "\(marker) error",
    ]
    d.merge(overrides) { $1 }
    return try! DesktopSession(json: JSONSerialization.data(withJSONObject: d))
}

private let stop = HookLine(at: ago(30), event: "Stop", detail: "", backgroundTasks: 0, cronSchedules: [])
/// A Stop with a background task (rule 6) and a cron (rule 8 after the task window).
private let busyStop = HookLine(at: ago(30), event: "Stop", detail: "", backgroundTasks: 1, cronSchedules: ["*/5 * * * *"],
                                tasks: [BackgroundTask(type: "shell", description: "\(marker) task")])

private func claudeInput(_ s: DesktopSession = session(), hook: HookLine? = stop, tail: LastMessage? = .endTurn, running: Bool = true) -> StateInput {
    .claude(ClassifierInput(session: s, hook: hook.map(HookState.init(last:)), tail: tail, claudeRunning: running, claudeLaunchedAt: ago(3600), now: now))
}

private let codexInput = StateInput.codex(
    CodexThread(id: "t1", title: "\(marker) title", cwd: "/Users/\(marker)/proj", branch: marker, updatedAt: ago(60),
                rolloutPath: "/Users/\(marker)/rollout.jsonl", parentId: nil),
    hook: HookState(last: HookLine(at: ago(20), event: "PermissionRequest", detail: "Bash", backgroundTasks: nil, cronSchedules: [])),
    turn: CodexTurn(kind: .started, at: ago(40)), live: true)

private let piInput = StateInput.pi(
    PiSession(id: "p1", path: "/Users/\(marker)/s.jsonl", cwd: "/Users/\(marker)/proj", parentPath: nil, title: "\(marker) title",
              updatedAt: ago(60), turn: PiTurn(kind: .working, detail: marker, at: ago(50))),
    state: PiState(at: ago(10), state: "blocked", detail: "\(marker) dialog", pid: 42, sessionPath: "/Users/\(marker)/s.jsonl"),
    live: true, aged: false)

private let herdrInput = StateInput.herdr(status: "done", since: ago(15))

/// A report of the input, through JSON and back.
private func roundTrip(_ input: StateInput, correct: SessionState? = .finished) throws -> (json: String, report: WrongStateReport) {
    let (status, explanation) = input.explain()
    let report = WrongStateReport(input: input, shown: status.state, explanation: explanation, correct: correct, savedAt: now)
    let data = try WrongStateReport.encoder().encode(report)
    return (String(decoding: data, as: UTF8.self), try WrongStateReport.decoder().decode(WrongStateReport.self, from: data))
}

@Test(arguments: [claudeInput(), claudeInput(hook: busyStop), claudeInput(tail: .interrupted), claudeInput(hook: nil, tail: .waiting("Question")),
                  claudeInput(session(["sshConfig": ["host": marker]])), claudeInput(running: false),
                  claudeInput(hook: HookLine(at: ago(5), event: "PreToolUse", detail: "Bash", backgroundTasks: nil, cronSchedules: [])),
                  codexInput, piInput, herdrInput])
func reportReplaysToTheSameStateAndRule(input: StateInput) throws {
    let (status, explanation) = input.explain()
    let (_, report) = try roundTrip(input)
    let replay = try #require(report.stateInput).explain()
    #expect(replay.status.state == status.state)
    #expect(replay.status.since == status.since)
    #expect(replay.explanation.rule == explanation.rule)
    #expect(report.shown == status.state)
    #expect(report.correct == .finished)
    #expect(report.explanation == explanation)
}

@Test(arguments: [claudeInput(), claudeInput(hook: busyStop), claudeInput(session(["sshConfig": ["host": marker], "turnWrapUp": ["description": marker, "needsUser": "\(marker) ask"]])),
                  codexInput, piInput, herdrInput])
func reportHoldsNoTitlePromptOrPath(input: StateInput) throws {
    let (json, _) = try roundTrip(input, correct: nil)
    #expect(!json.contains(marker))
    #expect(!json.contains("/Users"))
}

@Test func reportFileIsPrivateAndNamedByTime() throws {
    let dir = try tempDir()
    let (status, explanation) = claudeInput().explain()
    let report = WrongStateReport(input: claudeInput(), shown: status.state, explanation: explanation, correct: nil, savedAt: now)
    let first = try save(report, in: dir), second = try save(report, in: dir)
    let stamp = now.formatted(Date.VerbatimFormatStyle(format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)", timeZone: .current, calendar: Calendar(identifier: .gregorian)))
    #expect(first.lastPathComponent == "wrong-state-\(stamp).json")
    #expect(second.lastPathComponent == "wrong-state-\(stamp)-2.json")
    let mode = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let saved = try WrongStateReport.decoder().decode(WrongStateReport.self, from: Data(contentsOf: first))
    #expect(saved.correct == nil)
    #expect(try #require(saved.stateInput).explain().explanation.rule == explanation.rule)
}

@Test func reportsFolderIsPrivate() throws {
    let dir = try tempDir().appending(path: "reports")
    let (status, explanation) = herdrInput.explain()
    _ = try save(WrongStateReport(input: herdrInput, shown: status.state, explanation: explanation, correct: nil, savedAt: now), in: dir)
    let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
    #expect(mode == 0o700)
}

// One explanation per source: the rule the classifier took and the signals it read.

@Test func claudeExplanationNamesTheSpecRule() {
    let (status, e) = claudeInput().explain()
    #expect(status.state == .needsInput)
    #expect(e.source == "Claude")
    #expect(e.rule == StateRule(9, "Question, from the summary"))
    #expect(e.rule.label == "9: Question, from the summary")
    #expect(e.sentence == "Rule 9 decided this state.")
    #expect(e.signals.contains(StateSignal("Summary", "blocked, fresh")))
    #expect(e.signals.contains(StateSignal("Last hook event", "Stop", at: ago(30))))
    #expect(e.signals.contains(StateSignal("Transcript tail", "end_turn")))
    #expect(e.signals.contains(StateSignal("Claude desktop", "running")))
}

@Test func claudeOfflineNamesItsCause() {
    let working = HookLine(at: ago(5), event: "PreToolUse", detail: "Bash", backgroundTasks: nil, cronSchedules: [])
    #expect(claudeInput(hook: working).explain().explanation.rule == StateRule(5, "Running"))
    #expect(claudeInput(hook: working, running: false).explain().explanation.rule == StateRule(1, "Claude desktop is not running"))
    #expect(claudeInput(hook: busyStop).explain().explanation.rule == StateRule(6, "Background tasks"))
}

@Test func codexExplanation() {
    let (status, e) = codexInput.explain()
    #expect(status.state == .needsInput)
    #expect(e.rule == StateRule(nil, "Waits for the user, from the hook"))
    #expect(e.sentence == "A Codex rule decided this state.")
    #expect(e.signals == [StateSignal("Last hook event", "PermissionRequest (Bash)", at: ago(20)),
                          StateSignal("Rollout turn", "started", at: ago(40)), StateSignal("Codex", "running")])
}

@Test func piExplanation() {
    let (status, e) = piInput.explain()
    #expect(status.state == .needsInput)
    #expect(e.rule == StateRule(nil, "Extension state"))
    #expect(e.signals.first == StateSignal("pi state line", "blocked", at: ago(10)))
}

@Test func herdrExplanation() {
    let (status, e) = herdrInput.explain()
    #expect(status.state == .ready)
    #expect(e.rule == StateRule(nil, "herdr status"))
    #expect(e.signals == [StateSignal("herdr status", "done", at: ago(15))])
}
