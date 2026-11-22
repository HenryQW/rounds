import Foundation
import Testing
@testable import RoundsCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func hostShutdownNoticeWaitsForAVisibleWindowThroughPiRestartAndExit() {
    var thread = BouncerThread()
    let pending = ["The Harness host did not stop."]
    thread.apply(.started(sessionFile: nil, isNew: true, model: nil))
    thread.showHostNotices(pending, windowIsVisible: false)
    #expect(thread.hostNotices.isEmpty)
    thread.apply(.exited("Pi exited."))
    thread.showHostNotices(pending, windowIsVisible: false)
    #expect(thread.banner == "Pi exited.")
    thread.showHostNotices(pending, windowIsVisible: true)
    thread.apply(.started(sessionFile: nil, isNew: true, model: nil))
    thread.apply(.exited("Pi exited."))
    #expect(thread.hostNotices == pending)
    #expect(thread.banner == "Pi exited.\nThe Harness host did not stop.")
}

@Test func waitingCountsOpenQuestionsAndUndecidedApprovals() throws {
    var thread = BouncerThread()
    #expect(thread.waitingCount == 0)
    thread.apply(.item(.question(BouncerQuestion(id: "q1", title: "Which?", options: ["A", "B", "C"]))))
    #expect(thread.waitingCount == 1)
    thread.apply(.item(.approval(ApprovalCard(id: "a1", taskID: "t1", title: "Push", actions: ["git push"], checkedAt: now))))
    #expect(thread.waitingCount == 2)
    thread.answer("q1", .option(0))
    #expect(thread.waitingCount == 1)
    thread.apply(.item(.question(BouncerQuestion(id: "q2", title: "More detail?", takesText: true))))
    thread.apply(.exited("The host stopped."))
    #expect(thread.waitingCount == 2)
    thread.apply(.answered("q2", .dismissed))
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

@Test func setupStepsNameWhatIsMissing() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "bouncer-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let remotes = [WorkspaceRemote(name: "origin", url: "git@example.com:o/w.git")]
    var settings = WorkspaceSettings()
    #expect(bouncerSetupSteps(workspace: settings, isWorkspace: false, remotes: []) == [.chooseWorkspace])
    try settings.setWorkspace(folder.path)
    // The folder check has not ended (or failed): no remote list, so the Bouncer must wait.
    #expect(bouncerSetupSteps(workspace: settings, isWorkspace: true, remotes: nil) == [.chooseWorkspace])
    #expect(bouncerSetupSteps(workspace: settings, isWorkspace: true, remotes: remotes) == [.confirmRemotes])
    try settings.acknowledgeRemotes(remotes)
    #expect(bouncerSetupSteps(workspace: settings, isWorkspace: true, remotes: remotes).isEmpty)
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
