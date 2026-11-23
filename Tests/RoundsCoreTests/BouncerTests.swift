import Foundation
import Testing
@testable import RoundsCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func hostShutdownNoticeWaitsForAVisibleWindowThroughPiRestartAndExit() {
    var thread = BouncerThread()
    let pending = ["The Harness host did not stop."]
    thread.apply(.started(model: nil, selection: nil))
    thread.showHostNotices(pending, windowIsVisible: false)
    #expect(thread.hostNotices.isEmpty)
    thread.apply(.exited("Pi exited."))
    thread.showHostNotices(pending, windowIsVisible: false)
    #expect(thread.banner == "Pi exited.")
    thread.showHostNotices(pending, windowIsVisible: true)
    thread.apply(.started(model: nil, selection: nil))
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
        BouncerTask(id: "c", title: "Zyzzyva", repository: "web", state: .working, updatedAt: now.addingTimeInterval(1)),
        BouncerTask(id: "d", title: "Old", state: .finished, updatedAt: now, archived: true),
    ]
    let states = bouncerTaskGroups(tasks, archived: false, grouping: .state, sort: .activity)
    #expect(states.map(\.name) == ["needsInput", "working"])
    #expect(states.flatMap(\.tasks).map(\.id) == ["b", "c", "a"])
    let repositories = bouncerTaskGroups(tasks, archived: false, grouping: .repository, sort: .title)
    #expect(repositories.map(\.name) == ["api", "web"])
    #expect(repositories.flatMap(\.tasks).map(\.id) == ["b", "a", "c"])
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
    let remotes = [BarRemote(name: "origin", url: "git@example.com:o/w.git")]
    var settings = BarSettings()
    #expect(bouncerSetupSteps(bar: settings, isBar: false, remotes: []) == [.chooseBar])
    try settings.setBar(folder.path)
    // The folder check has not ended (or failed): no remote list, so the Bouncer must wait.
    #expect(bouncerSetupSteps(bar: settings, isBar: true, remotes: nil) == [.chooseBar])
    #expect(bouncerSetupSteps(bar: settings, isBar: true, remotes: remotes) == [.confirmRemotes])
    try settings.acknowledgeRemotes(remotes)
    #expect(bouncerSetupSteps(bar: settings, isBar: true, remotes: remotes).isEmpty)
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
