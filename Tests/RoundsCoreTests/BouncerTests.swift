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

@Test func onlyEndedTasksCanArchive() {
    let archivable = [BouncerTaskState.working, .needsInput, .failed, .finished, .stopped]
        .filter { BouncerTask(id: "t", title: "T", state: $0, updatedAt: now).canArchive }
    #expect(archivable == [.finished, .stopped])
}

@Test func setupStepsNameWhatIsMissing() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "bouncer-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let remotes = [WorkspaceRemote(name: "origin", url: "git@example.com:o/w.git")]
    var settings = WorkspaceSettings()
    #expect(bouncerSetupSteps(workspace: settings, isWorkspace: false, remotes: [], piPath: "/bin/pi") == [.chooseWorkspace])
    try settings.setWorkspace(folder.path)
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

@Test func childExitShowsItsErrorText() async throws {
    let script = #"read line; echo '{"type":"response","id":"rounds-1","command":"get_state","success":true,"data":{"sessionFile":"/s/a.jsonl"}}'; echo 'pi: no model' >&2; exit 1"#
    let adapter = PiRPCBouncer(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                               folder: FileManager.default.temporaryDirectory)
    try await adapter.start()
    let seen = await events(adapter)
    #expect(seen == [.started(sessionFile: "/s/a.jsonl", isNew: true), .exited("pi: no model")])
    await adapter.shutdown()
}

@Test func missingExecutableThrowsWithoutEvents() async {
    let adapter = PiRPCBouncer(executable: URL(fileURLWithPath: "/nonexistent/pi"), arguments: [], folder: FileManager.default.temporaryDirectory)
    await #expect(throws: (any Error).self) { try await adapter.start() }
    await adapter.shutdown()
    var count = 0
    for await _ in adapter.events { count += 1 }
    #expect(count == 0)
}
