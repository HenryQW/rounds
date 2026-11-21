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
        output.yield(.started(sessionFile: nil, isNew: false, model: nil))
        output.yield(.models(["example/small-model", "example/large-model"]))
        output.yield(.tasks(Self.tasks))
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

    static let tasks: [BouncerTask] = [
        BouncerTask(id: "t1", title: "Add rate limit headers", repository: "acme/api + acme/web", organization: "Acme",
                    state: .needsInput, updatedAt: Date(timeIntervalSince1970: 1_800_000_000)),
        BouncerTask(id: "t2", title: "Update login copy", repository: "acme/web", organization: "Acme",
                    state: .needsInput, updatedAt: Date(timeIntervalSince1970: 1_799_999_940)),
        BouncerTask(id: "t3", title: "Upgrade logger", repository: "acme/api", organization: "Acme",
                    state: .working, updatedAt: Date(timeIntervalSince1970: 1_799_999_880)),
        BouncerTask(id: "t4", title: "Tidy shell aliases", repository: "me/dotfiles", organization: "Personal",
                    state: .finished, updatedAt: Date(timeIntervalSince1970: 1_799_999_820)),
        BouncerTask(id: "t5", title: "Bump test runner", repository: "acme/web", organization: "Acme",
                    state: .finished, updatedAt: Date(timeIntervalSince1970: 1_799_999_760), archived: true),
        BouncerTask(id: "t6", title: "Refresh icons", repository: "acme/web", organization: "Acme",
                    state: .stopped, updatedAt: Date(timeIntervalSince1970: 1_799_999_700)),
    ]

    static func details(_ id: String, factUnconfirmed: Bool = true) -> BouncerTaskDetails {
        if id == "t1" {
            return BouncerTaskDetails(
                summary: "Both repositories now use the rate limit headers. The status page shows the remaining count.",
                risks: ["Older X-RateLimit header names are no longer supported.",
                        "The remaining count stays a placeholder until the API change is deployed."],
                changes: [
                    .init(repository: "acme/api", path: "src/middleware/rateLimit.ts", added: 38, removed: 4),
                    .init(repository: "acme/api", path: "src/middleware/rateLimit.test.ts", added: 61, removed: 0),
                    .init(repository: "acme/web", path: "src/RemainingCount.tsx", added: 22, removed: 0),
                    .init(repository: "acme/web", path: "src/api.ts", added: 6, removed: 1),
                ],
                checks: [
                    .init(repository: "acme/api", name: "212 unit tests", result: "Passed", passed: true),
                    .init(repository: "acme/api", name: "Lint", result: "Passed", passed: true),
                    .init(repository: "acme/web", name: "88 unit tests", result: "Passed", passed: true),
                    .init(repository: "acme/web", name: "Browser unavailable", result: "Not run", passed: false),
                ],
                agents: [
                    .init(role: "Bartender", name: "acme/api", state: "Finished", child: false),
                    .init(role: "Barback", name: "Add headers", state: "Finished", child: true),
                    .init(role: "Barback", name: "Test headers", state: "Finished", child: true),
                    .init(role: "Bartender", name: "acme/web", state: "Finished", child: false),
                    .init(role: "Barback", name: "Show remaining count", state: "Finished", child: true),
                ],
                environments: [
                    .init(repository: "acme/api", name: "container-use/brave-otter", branch: "rounds/rate-limit-headers", revision: "4f1c2a9e"),
                    .init(repository: "acme/web", name: "container-use/calm-heron", branch: "rounds/rate-limit-headers", revision: "b83e0171"),
                ])
        }
        let finished = id == "t4" || id == "t5"
        return BouncerTaskDetails(
            summary: finished ? "The requested changes are complete. The result stays local." : nil,
            risks: [], changes: [], checks: [],
            agents: [.init(role: "Bartender", name: tasks.first { $0.id == id }?.repository ?? "Task",
                           state: finished ? "Finished" : id == "t6" ? "Stopped" : "Working", child: false)] +
                    (id == "t3" ? [.init(role: "Barback", name: "Update call sites", state: factUnconfirmed ? "Not confirmed" : "Stopped", child: true)] : []),
            environments: [])
    }

    /// Neutral names only, as in the rest of the demo.
    private static let thread: [BouncerItem] = [
        .user(id: "demo-1", text: "Add rate limit headers to the acme/api responses, and show the remaining count on the acme/web status page."),
        .reply(id: "demo-2", text: "I split this into two repository tasks: one Bartender for acme/api and one for acme/web. I will ask you before any push or pull request.", toolSteps: 0),
        .user(id: "demo-3", text: "Also change the login page copy in acme/web to the new product name."),
        .question(BouncerQuestion(id: "demo-question", taskID: "t2",
                                  title: "Update the login page copy (acme/web): the new name is longer and the heading wraps on small screens. Which do you want? I recommend 1.",
                                  options: ["Shorten the heading to the new name only", "Keep the full heading and allow two lines",
                                            "Keep the old name on the login page for now"],
                                  recommended: 0)),
        .report(id: "demo-4", taskID: "t1", role: "Bartender · acme/api",
                text: "Responses now carry RateLimit-Limit, RateLimit-Remaining and RateLimit-Reset. Unit tests and lint pass.",
                toolSteps: ["Read src/middleware/rateLimit.ts", "Edited src/middleware/rateLimit.ts (+38 -4)",
                            "Wrote src/middleware/rateLimit.test.ts (+61)", "Ran npm test (212 passed)", "Ran npm run lint (passed)"]),
        .report(id: "demo-web", taskID: "t1", role: "Bartender · acme/web",
                text: "The status page reads RateLimit-Remaining and shows the remaining count. Browser checks were not run.",
                toolSteps: ["Read src/api.ts", "Edited src/RemainingCount.tsx (+22)", "Ran npm test (88 passed)"]),
        .report(id: "demo-logger", taskID: "t3", role: "Bartender · acme/api",
                text: "The logger upgrade is in progress. The state of the Barback “Update call sites” is not confirmed.",
                toolSteps: ["Read package.json", "Updated the logger dependency"]),
        .report(id: "demo-aliases", taskID: "t4", role: "Bartender · me/dotfiles",
                text: "The unused aliases are removed. Shell syntax checks passed.", toolSteps: ["Ran zsh -n aliases.zsh (passed)"]),
        .report(id: "demo-archived", taskID: "t5", role: "Bartender · acme/web",
                text: "The test runner update is complete and archived.", toolSteps: ["Ran npm test (88 passed)"]),
        .report(id: "demo-stopped-task", taskID: "t6", role: "Bartender · acme/web",
                text: "You stopped this task before it changed any icons.", toolSteps: []),
        .approval(ApprovalCard(id: "demo-approval", taskID: "t1", title: "Approve 4 actions for “Add rate limit headers”?",
                               actions: ["Push branch rounds/rate-limit-headers to https://github.com/acme/api.git at revision 4f1c2a9e.",
                                         "Open a draft pull request in acme/api from rounds/rate-limit-headers into main.",
                                         "Push branch rounds/rate-limit-headers to https://github.com/acme/web.git at revision b83e0171.",
                                         "Open a draft pull request in acme/web from rounds/rate-limit-headers into main."],
                               checkedAt: Date())),
    ]
}
