import Foundation
import Testing
@testable import RoundsCore
@testable import Rounds

private actor UnconfirmedAnswerAdapter: BouncerAdapter {
    nonisolated let events: AsyncStream<BouncerEvent>
    private let continuation: AsyncStream<BouncerEvent>.Continuation
    private let committed: Bool
    private var saved: BouncerAnswer?
    private var starts = 0
    private(set) var answerCount = 0

    init(committed: Bool) {
        self.committed = committed
        (events, continuation) = AsyncStream.makeStream()
    }

    func start() async throws {
        starts += 1
        continuation.yield(.started(model: nil, selection: nil))
        continuation.yield(.item(.question(BouncerQuestion(id: "q", title: starts == 1 ? "Question" : "Replayed question"))))
        if let saved { continuation.yield(.answered("q", saved)) }
    }
    func send(_ text: String) async throws {}
    func stop() async throws {}
    func answer(_ questionID: String, _ answer: BouncerAnswer) async throws {
        answerCount += 1
        if committed { saved = answer }
        throw BouncerSendUnconfirmed(detail: "Reply lost.", answer: true)
    }
    func exit() { continuation.yield(.exited("Host stopped.")) }
    func decide(_ approvalID: String, _ decision: ApprovalDecision) async throws {}
    func checkAgain() async {}
    func setModel(_ id: String?) async throws {}
    func shutdown() async { continuation.finish() }
}

@MainActor
private func waitFor(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return predicate()
}

@Test
@MainActor
func demoCanSendFromATaskWhileAnotherTaskHasAnOpenQuestion() async {
    let adapter = DemoBouncer()
    let model = BouncerModel(adapter: adapter)
    model.launch()
    #expect(await waitFor { model.running && model.thread.waitingCount == 2 })
    model.selection = "t3"
    let text = "Show the build result."
    model.draft = text
    model.send()
    #expect(await waitFor {
        model.thread.items.contains { item in
            if case .user(_, let message) = item { return message == text }
            return false
        }
    })
    #expect(model.selection == nil)
    #expect(model.thread.waitingCount == 2)
    await adapter.shutdown()
}

@Test(arguments: [TaskInterfaceError.detailsNotAuthorized, ApprovalError.snapshotUnavailable,
                  TaskDetailStoreError.tooLarge] as [any Error])
@MainActor
func failedLocalApprovalSaveKeepsAttentionAndHidesCards(error: any Error) async {
    let taskID = UUID()
    let now = Date()
    let folder = FolderIdentity(path: "/fixture", device: 1, inode: 1)
    let revision = String(repeating: "a", count: 40)
    let sourceRef = "refs/heads/main"
    let urls = ["https://example.invalid/team/fixture.git"]
    let remote = ApprovalSnapshot.Remote(name: "origin", fetch: urls, push: urls)
    let snapshot = ApprovalSnapshot(folder: folder, sourceRef: sourceRef, revision: revision,
                                    annotatedSourceObject: nil, remote: remote.name, remotes: [remote],
                                    overrides: [], sshLoginDigest: nil)
    let action = ApprovalAction(intent: .push(sourceRef: sourceRef, revision: revision, remote: remote.name,
                                              urls: urls, destinationRef: "refs/heads/result"))
    let request = ApprovalRequest(id: UUID(), taskID: taskID, repositoryID: UUID(), organizationID: nil,
                                  resultRevisionID: UUID(), resultDigest: String(repeating: "b", count: 64),
                                  snapshot: snapshot, actions: [action], createdAt: now, checkedAt: now)
    let card = ApprovalCard(local: ApprovalRecord(request: request))
    var thread = BouncerThread()
    thread.replaceLocalApprovals(for: taskID, with: [card])
    let adapter = UnconfirmedAnswerAdapter(committed: false)
    let model = BouncerModel(adapter: adapter, thread: thread)
    #expect(model.pillWaiting == 1)

    model.completeLocalApprovalAnswer(.failure(error), card: card, taskID: taskID)

    #expect(model.pillWaiting == 1)
    #expect(model.thread.items.isEmpty)
    #expect(model.localApprovalError != nil)
    #expect(model.localApprovalRetryAvailable)
    await adapter.shutdown()
}

@Test(arguments: [BouncerAnswer.text("Original answer"), .dismissed], [false, true])
@MainActor
func unconfirmedAnswerBlocksUntilReplay(answer: BouncerAnswer, committed: Bool) async throws {
    let adapter = UnconfirmedAnswerAdapter(committed: committed)
    let model = BouncerModel(adapter: adapter)
    model.launch()
    #expect(await waitFor { model.canInteract && model.thread.waitingCount == 1 })
    model.answer("q", answer)
    #expect(await waitFor { model.unconfirmedAnswer != nil && model.running && !model.commandPending })
    #expect(model.banner?.contains("Start Again") == true)
    #expect(!model.canInteract)
    model.answer("q", answer)
    #expect(await waitFor { !model.commandPending })
    #expect(await adapter.answerCount == 1)
    await adapter.exit()
    #expect(await waitFor { !model.running })
    model.launch()
    #expect(await waitFor {
        let replayed = model.thread.items.contains { item in
            if case .question(let question) = item { return question.title == "Replayed question" }
            return false
        }
        return model.running && model.unconfirmedAnswer == nil && replayed
            && model.thread.waitingCount == (committed ? 0 : 1)
    })
    let question = try #require(model.thread.items.compactMap { item in
        if case .question(let question) = item { return question }
        return nil
    }.first)
    #expect(question.answer == (committed ? answer : nil))
    #expect(model.canInteract)
    await adapter.shutdown()
}
