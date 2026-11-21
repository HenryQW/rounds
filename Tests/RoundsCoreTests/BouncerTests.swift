import Foundation
import Testing
@testable import RoundsCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func waitingCountsOpenQuestionsAndUndecidedApprovals() throws {
    var thread = BouncerThread()
    #expect(thread.waitingCount == 0)
    thread.apply(.item(.question(BouncerQuestion(id: "q1", title: "Which?", options: ["A", "B", "C"]))))
    #expect(thread.waitingCount == 1)
    thread.apply(.item(.approval(ApprovalCard(id: "a1", taskID: "t1", title: "Push", actions: ["git push"], checkedAt: now))))
    #expect(thread.waitingCount == 2)
    thread.answer("q1", .option(0))
    #expect(thread.waitingCount == 1)
    thread.apply(.item(.question(BouncerQuestion(id: "q2", title: "Sure?", options: ["Yes", "No"], confirms: true))))
    thread.apply(.closed(questionID: "q2"))
    #expect(thread.waitingCount == 1)
    guard case .question(let closed) = thread.items[2] else { Issue.record("no question"); return }
    #expect(closed.closedByPi && closed.answer == nil)
    try thread.decide("a1", .approved)
    #expect(thread.waitingCount == 0)
}

@Test func rejectionNeedsAReason() {
    var thread = BouncerThread(items: [.approval(ApprovalCard(id: "a1", taskID: "t1", title: "Push", actions: ["git push"], checkedAt: now))])
    for reason in ["", "  \n "] {
        #expect(throws: BouncerError.reasonRequired) { try thread.decide("a1", .rejected(reason: reason)) }
    }
    #expect(thread.waitingCount == 1)
    guard case .approval(let card) = thread.items[0] else { Issue.record("no card"); return }
    #expect(card.decision == nil)
}

@Test func taskArchiveKeepsUnfinishedWorkVisibleAndCanRestoreHistory() {
    let states: [BouncerTaskState] = [.needsInput, .working, .failed, .finished, .stopped]
    var thread = BouncerThread(tasks: states.map {
        BouncerTask(id: $0.rawValue, title: $0.rawValue, state: $0, updatedAt: now)
    })
    for task in thread.tasks { thread.setArchived(task.id, true) }
    #expect(thread.tasks.filter(\.archived).map(\.state) == [.finished, .stopped])
    thread.setArchived("finished", false)
    #expect(thread.tasks.filter(\.archived).map(\.state) == [.stopped])
}

@Test func taskGroupsUseDisplayOrderAndKeepArchivedTasksSeparate() {
    let tasks = [
        BouncerTask(id: "a", title: "Zulu", repository: "web", organization: "Acme", state: .working, updatedAt: now),
        BouncerTask(id: "b", title: "Alpha", repository: "api", organization: "Acme", state: .needsInput, updatedAt: now),
        BouncerTask(id: "c", title: "Beta", repository: "web", state: .working, updatedAt: now.addingTimeInterval(1)),
        BouncerTask(id: "d", title: "Old", state: .finished, updatedAt: now, archived: true),
    ]
    let states = bouncerTaskGroups(tasks, archived: false, grouping: .state, sort: .activity)
    #expect(states.map(\.name) == ["needsInput", "working"])
    #expect(states.flatMap(\.tasks).map(\.id) == ["b", "c", "a"])
    let repositories = bouncerTaskGroups(tasks, archived: false, grouping: .repository, sort: .title)
    #expect(repositories.map(\.name) == ["api", "web"])
    #expect(repositories.flatMap(\.tasks).map(\.id) == ["b", "c", "a"])
    #expect(bouncerTaskGroups(tasks, archived: false, grouping: .organization, sort: .title).map(\.name) == ["Acme", "No organization"])
    #expect(bouncerTaskGroups(tasks, archived: true, grouping: .none, sort: .activity).flatMap(\.tasks).map(\.id) == ["d"])
    // Equal activity falls back to title, then id, independent of input order.
    let ties = ["z", "a"].map { BouncerTask(id: $0, title: "Same", state: .working, updatedAt: now) }
    #expect(bouncerTaskGroups(ties, archived: false, grouping: .none, sort: .activity).flatMap(\.tasks).map(\.id) == ["a", "z"])
}

@Test func selectedTaskShowsItsHistoryAndWholeThreadOmitsArchivedTasks() {
    let thread = BouncerThread(items: [
        .reply(id: "root", text: "Whole thread", toolSteps: 0),
        .report(id: "active", taskID: "a", role: "Bartender", text: "Active", toolSteps: []),
        .report(id: "old", taskID: "b", role: "Bartender", text: "Archived", toolSteps: []),
        .question(BouncerQuestion(id: "q", taskID: "a", title: "Which?")),
        .approval(ApprovalCard(id: "approval", taskID: "a", title: "Push?", actions: ["Push"], checkedAt: now)),
    ], tasks: [
        BouncerTask(id: "a", title: "Active", state: .needsInput, updatedAt: now),
        BouncerTask(id: "b", title: "Old", state: .finished, updatedAt: now, archived: true),
    ])
    #expect(thread.visibleItems(taskID: nil).map(\.id) == ["root", "active", "q", "approval"])
    #expect(thread.visibleItems(taskID: "a").map(\.id) == ["active", "q", "approval"])
    #expect(thread.visibleItems(taskID: "b").map(\.id) == ["old"])
    #expect(thread.visibleItems(taskID: "missing").isEmpty)
}

@Test func setupStepsNameWhatIsMissing() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "bouncer-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let remotes = [WorkspaceRemote(name: "origin", url: "git@example.com:o/w.git")]
    var settings = WorkspaceSettings()
    #expect(bouncerSetupSteps(workspace: settings, isWorkspace: false, remotes: [], piPath: "/bin/pi") == [.chooseWorkspace])
    try settings.setWorkspace(folder.path)
    // The folder check has not ended (or failed): no remote list, so Pi must not start.
    #expect(bouncerSetupSteps(workspace: settings, isWorkspace: true, remotes: nil, piPath: "/bin/pi") == [.chooseWorkspace])
    #expect(bouncerSetupSteps(workspace: settings, isWorkspace: true, remotes: remotes, piPath: "/bin/pi") == [.confirmRemotes])
    try settings.acknowledgeRemotes(remotes)
    #expect(bouncerSetupSteps(workspace: settings, isWorkspace: true, remotes: remotes, piPath: nil) == [.installPi])
    #expect(bouncerSetupSteps(workspace: settings, isWorkspace: true, remotes: remotes, piPath: "/bin/pi").isEmpty)
}

@Test func otherWaitsLeaveOutTheBouncerSession() {
    func row(_ path: String, _ state: SessionState) -> SessionRow {
        SessionRow(pi: PiSession(id: path, path: path, cwd: "/w", parentPath: nil, title: path, updatedAt: now, turn: nil),
                   status: SessionStatus(state, since: now))
    }
    let own = "/b/bouncer.jsonl", other = row("/s/other.jsonl", .needsInput)
    let waits = otherWaits([row(own, .needsInput), other, row("/s/busy.jsonl", .working)], bouncerSessionFile: own)
    #expect(waits.map(\.id) == [other.id])
}

/// Every event until `.exited`, or nil after 10 s.
private func events(_ adapter: PiRPCBouncer) async -> [BouncerEvent]? {
    await withTaskGroup(of: [BouncerEvent]?.self) { group in
        group.addTask {
            var seen: [BouncerEvent] = []
            for await event in adapter.events {
                seen.append(event)
                if case .exited = event { return seen }
            }
            return seen
        }
        group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// A `pi` stand-in: a shell script that `PiRPCBouncer` starts with the Bouncer arguments.
private func fakePi(_ script: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "fake-pi-\(UUID().uuidString)")
    try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func bouncer(_ pi: URL, exitWait: Duration = .seconds(5), requestWait: Duration = .seconds(10)) -> PiRPCBouncer {
    PiRPCBouncer(executable: pi, folder: FileManager.default.temporaryDirectory, sessionFile: nil, sessionDir: "/s",
                 exitWait: exitWait, requestWait: requestWait)
}

/// The events of a stream as they come, and whether the stream finished.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [BouncerEvent] = [], done = false

    init(_ stream: AsyncStream<BouncerEvent>) {
        Task {
            for await event in stream { lock.withLock { list.append(event) } }
            lock.withLock { done = true }
        }
    }

    var events: [BouncerEvent] { lock.withLock { list } }
    var finished: Bool { lock.withLock { done } }
}

/// The error of a call that runs on, so a call that never returns fails the test and does not hang it.
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var thrown: (any Error)?

    init(_ call: @escaping @Sendable () async throws -> Void) {
        Task { do { try await call() } catch { lock.withLock { thrown = error } } }
    }

    var error: BouncerError? { lock.withLock { thrown as? BouncerError } }
}

/// True when `ok` holds within `seconds`.
private func waitUntil(seconds: Double = 5, _ ok: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !ok(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    return ok()
}

@Test func childExitShowsItsErrorText() async throws {
    let pi = try fakePi(#"read line; echo '{"type":"response","id":"rounds-1","command":"get_state","success":true,"data":{"sessionFile":"/s/a.jsonl"}}'; echo 'pi: no model' >&2; exit 1"#)
    defer { try? FileManager.default.removeItem(at: pi) }
    let adapter = bouncer(pi)
    try await adapter.start()
    let seen = await events(adapter)
    #expect(seen == [.started(sessionFile: "/s/a.jsonl", isNew: true, model: nil), .exited("pi: no model")])
    await adapter.shutdown()
}

@Test func missingExecutableThrowsWithoutEvents() async {
    let adapter = bouncer(URL(fileURLWithPath: "/nonexistent/pi"))
    await #expect(throws: (any Error).self) { try await adapter.start() }
    await adapter.shutdown()
    var count = 0
    for await _ in adapter.events { count += 1 }
    #expect(count == 0)
}

@Test func piAlwaysStartsWithoutTools() async throws {
    let record = FileManager.default.temporaryDirectory.appending(path: "fake-pi-args-\(UUID().uuidString)")
    let pi = try fakePi(#"printf '%s\n' "$@" > '\#(record.path)'"#)
    defer { try? FileManager.default.removeItem(at: pi); try? FileManager.default.removeItem(at: record) }
    let adapter = bouncer(pi)
    try await adapter.start()
    _ = await events(adapter)
    await adapter.shutdown()
    let arguments = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(Set(["--no-tools", "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates"]).isSubset(of: arguments))
    #expect(arguments.starts(with: ["--mode", "rpc"]))
}

@Test func shutdownStopsAPiThatIgnoresEndOfInputAndSIGTERM() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(path: "fake-pi-pid-\(UUID().uuidString)")
    let pi = try fakePi("trap '' TERM; echo $$ > '\(pidFile.path)'; while :; do sleep 0.05; done")
    defer { try? FileManager.default.removeItem(at: pi); try? FileManager.default.removeItem(at: pidFile) }
    let adapter = bouncer(pi, exitWait: .milliseconds(300))
    let recorder = Recorder(adapter.events)
    try await adapter.start()
    #expect(await waitUntil { FileManager.default.fileExists(atPath: pidFile.path) })
    let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { kill(pid, SIGKILL) }
    let begin = ContinuousClock.now
    await adapter.shutdown()
    #expect(ContinuousClock.now - begin < .seconds(3))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    #expect(await waitUntil(seconds: 1) { recorder.finished })
}

@Test func exitDuringARequestGivesNotRunning() async throws {
    let pi = try fakePi("read a; read b; read c; exit 0")
    defer { try? FileManager.default.removeItem(at: pi) }
    let adapter = bouncer(pi)
    try await adapter.start()
    await #expect(throws: BouncerError.notRunning) { try await adapter.send("Hi") }
    await adapter.shutdown()
}

@Test func requestWithoutAnAnswerTimesOut() async throws {
    let pi = try fakePi("cat > /dev/null")
    defer { try? FileManager.default.removeItem(at: pi) }
    let adapter = bouncer(pi, requestWait: .milliseconds(300))
    try await adapter.start()
    let send = Outcome { try await adapter.send("Hi") }
    #expect(await waitUntil(seconds: 3) { send.error != nil })
    #expect(send.error == .noAnswer)
    await adapter.shutdown()
}

@Test func questionPastItsTimeoutClosesAndTakesNoAnswer() async throws {
    let pi = try fakePi(#"echo '{"type":"extension_ui_request","id":"q","method":"select","title":"Pick","options":["A","B"],"timeout":100}'; cat > /dev/null"#)
    defer { try? FileManager.default.removeItem(at: pi) }
    let adapter = bouncer(pi)
    let recorder = Recorder(adapter.events)
    try await adapter.start()
    #expect(await waitUntil { recorder.events.contains(.closed(questionID: "pi-ui-q")) })
    await #expect(throws: BouncerError.unknownQuestion) { try await adapter.answer("pi-ui-q", .option(0)) }
    await adapter.shutdown()
}

@Test func sessionFileIsRecordedOnlyOnceItExists() {
    // Exists: the reported file replaces the recorded one.
    #expect(bouncerSessionToRecord(reported: "/s/b.jsonl", recorded: "/s/a.jsonl", exists: { _ in true }) == "/s/b.jsonl")
    // Unused: Pi has not written the file yet, so the recorded file stays.
    #expect(bouncerSessionToRecord(reported: "/s/b.jsonl", recorded: "/s/a.jsonl", exists: { _ in false }) == "/s/a.jsonl")
}

@Test func missingNoteNamesOnlyARecordedFileThatPiDidNotReopen() {
    // Missing: Pi started new, so the recorded file is gone.
    #expect(missingBouncerSession(recorded: "/s/a.jsonl", reported: "/s/b.jsonl", isNew: true) == "/s/a.jsonl")
    // Exists: Pi reopened the recorded file.
    #expect(missingBouncerSession(recorded: "/s/a.jsonl", reported: "/s/a.jsonl", isNew: false) == nil)
}

@Test func restartOfAnUnusedSessionGivesNoMissingNote() {
    // First start: Pi reports a file that it writes only after the first reply; nothing is recorded.
    let recorded = bouncerSessionToRecord(reported: "/s/a.jsonl", recorded: nil, exists: { _ in false })
    // Restart: the unused file does not exist, so Pi starts new; nothing was lost.
    #expect(missingBouncerSession(recorded: recorded, reported: "/s/b.jsonl", isNew: true) == nil)
}
