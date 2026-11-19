import Foundation
import RoundsCore

/// The Bouncer for `--demo`: the thread of the picked mockup, with one undecided approval and one open question with three
/// options, so the pill shows 2. A message gets a short scripted reply; nothing leaves the app.
actor DemoBouncer: BouncerAdapter {
    nonisolated let events: AsyncStream<BouncerEvent>
    private let output: AsyncStream<BouncerEvent>.Continuation
    private var reply: Task<Void, Never>?
    private var count = 0

    init() {
        (events, output) = AsyncStream.makeStream(of: BouncerEvent.self)
    }

    func start() async throws {
        output.yield(.started(sessionFile: nil, isNew: false))
        output.yield(.models(["example/small-model", "example/large-model"]))
        for item in Self.thread { output.yield(.item(item)) }
    }

    func send(_ text: String) async throws {
        count += 1
        let n = count
        output.yield(.item(.user(id: "demo-user-\(n)", text: text)))
        output.yield(.item(.reply(id: "demo-reply-\(n)", text: "", toolSteps: 0)))
        output.yield(.replying(true))
        reply = Task {
            for word in "Noted. This is a demo, so no agent starts. In a real run I plan the work and ask you before any push.".split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(120))
                if Task.isCancelled { return }
                output.yield(.textDelta(word + " "))
            }
            output.yield(.replying(false))
        }
    }

    func stop() async {
        guard let reply, !reply.isCancelled else { return }
        reply.cancel()
        self.reply = nil
        count += 1
        output.yield(.replying(false))
        output.yield(.item(.stopped(id: "demo-stopped-\(count)")))
    }

    func answer(_ questionID: String, _ answer: BouncerAnswer) async throws {}
    func decide(_ approvalID: String, _ decision: ApprovalDecision) async throws {}
    func checkAgain() async {}
    func setModel(_ id: String?) async throws {}

    func shutdown() async {
        reply?.cancel()
        output.finish()
    }

    /// Neutral names only (`example`), as in the rest of the demo.
    private static let thread: [BouncerItem] = [
        .user(id: "demo-1", text: "Add rate limit headers to the acme/api responses, and show the remaining count on the acme/web status page."),
        .reply(id: "demo-2", text: "I split this into two repository tasks: one Bartender for acme/api and one for acme/web. I will ask you before any push or pull request.", toolSteps: 0),
        .user(id: "demo-3", text: "Also change the login page copy in acme/web to the new product name."),
        .question(BouncerQuestion(id: "demo-question", taskID: "t2",
                                  title: "Update the login page copy (acme/web): the new name is longer and the heading wraps on small screens. Which do you want? I recommend 1.",
                                  options: ["Shorten the heading to the new name only", "Keep the full heading and allow two lines",
                                            "Keep the old name on the login page for now"],
                                  recommended: 0)),
        .report(id: "demo-4", taskID: "t1", role: "Bartender",
                text: "Responses now carry RateLimit-Limit, RateLimit-Remaining and RateLimit-Reset. Unit tests and lint pass.",
                toolSteps: ["Read src/middleware/rateLimit.ts", "Edited src/middleware/rateLimit.ts (+38 -4)",
                            "Wrote src/middleware/rateLimit.test.ts (+61)", "Ran npm test (212 passed)", "Ran npm run lint (passed)"]),
        .approval(ApprovalCard(id: "demo-approval", taskID: "t1", title: "Approve 4 actions for “Add rate limit headers”?",
                               actions: ["Push branch rounds/rate-limit-headers to https://github.com/acme/api.git at revision 4f1c2a9e.",
                                         "Open a draft pull request in acme/api from rounds/rate-limit-headers into main.",
                                         "Push branch rounds/rate-limit-headers to https://github.com/acme/web.git at revision b83e0171.",
                                         "Open a draft pull request in acme/web from rounds/rate-limit-headers into main."],
                               checkedAt: Date())),
    ]
}
