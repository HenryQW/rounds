import Foundation
import Testing
@testable import RoundsCore

private func row(_ id: String, _ group: StatusGroup, cwd: String, activity: Double, since: Double = 0, parent: String? = nil) -> SessionRow {
    var d: [String: Any] = ["sessionId": id, "cliSessionId": id, "cwd": cwd, "title": id, "isArchived": false,
                            "lastActivityAt": Int64(activity * 1000)]
    if let parent { d["spawnedFrom"] = ["sessionId": parent, "title": "", "userFork": false] }
    let s = try! DesktopSession(json: JSONSerialization.data(withJSONObject: d))
    return SessionRow(session: s, status: SessionStatus(.finished, since: Date(timeIntervalSince1970: since), group: group))
}

@Test func projectRootResolvesWorktreesAndSubfolders() throws {
    let base = try tempDir()
    let repo = base.appending(path: "repo")
    try FileManager.default.createDirectory(at: repo.appending(path: ".git/worktrees/wt1"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo.appending(path: "pkg/sub"), withIntermediateDirectories: true)
    let worktree = base.appending(path: "elsewhere/wt1")
    try FileManager.default.createDirectory(at: worktree.appending(path: "src"), withIntermediateDirectories: true)
    try Data("gitdir: \(repo.path)/.git/worktrees/wt1\n".utf8).write(to: worktree.appending(path: ".git"))
    let plain = base.appending(path: "plain")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

    #expect(projectRoot(for: repo.appending(path: "pkg/sub").path) == repo.path)
    #expect(projectRoot(for: worktree.appending(path: "src").path) == repo.path)
    #expect(projectRoot(for: plain.path) == plain.path)
}

@Test func projectSectionsPutUrgentProjectsFirst() {
    let rows = [
        row("a-idle", .quiet, cwd: "/p/a", activity: 50),
        row("b-run", .running, cwd: "/p/b", activity: 10),
        row("a-input", .yourTurn, cwd: "/p/a", activity: 5, since: 1),
        row("c-idle", .quiet, cwd: "/p/c", activity: 90),
    ]
    let sections = projectSections(group(rows, query: ""), filter: .all) { $0 }
    #expect(sections.map(\.id) == ["/p/a", "/p/b", "/p/c"])
    #expect(sections[0].rows.map(\.id) == ["a-input", "a-idle"])
    #expect(sections[0].name == "a")
    #expect(projectSections(group(rows, query: ""), filter: .yourTurn) { $0 }.map(\.id) == ["/p/a"])
    #expect(projectSections(group(rows, query: ""), filter: .running) { $0 }.flatMap(\.rows).map(\.id) == ["b-run"])
}

@Test func quietAndOlderFilters() {
    let rows = [
        row("idle", .quiet, cwd: "/p/a", activity: 50),
        row("old", .older, cwd: "/p/a", activity: 1),
        row("run", .running, cwd: "/p/b", activity: 10),
    ]
    #expect(projectSections(group(rows, query: ""), filter: .quiet) { $0 }.flatMap(\.rows).map(\.id) == ["idle"])
    // Older rows join the groups only for the Older filter (or a search).
    #expect(projectSections(group(rows, query: ""), filter: .older) { $0 }.isEmpty)
    #expect(projectSections(group(rows, query: "", includeOlder: true), filter: .older) { $0 }.flatMap(\.rows).map(\.id) == ["old"])
    #expect(!projectSections(group(rows, query: ""), filter: .all) { $0 }.flatMap(\.rows).map(\.id).contains("old"))
}

@Test func sourceNamesAndSourceFilter() throws {
    let claude = row("c", .quiet, cwd: "/p/a", activity: 5)
    let agents = try parseHerdrAgents(Data(#"{"id":"1","result":{"agents":[{"agent":"pi","pane_id":"a","agent_status":"working"},{"agent":"droid","pane_id":"b","agent_status":"working"}]}}"#.utf8))
    let status = SessionStatus(.working, since: .distantPast)
    let pi = SessionRow(agent: agents[0], status: status), droid = SessionRow(agent: agents[1], status: status)
    let codex = SessionRow(thread: CodexThread(id: "t", title: "x", cwd: "/p/a", branch: nil, updatedAt: .distantPast, rolloutPath: ""), status: status)
    #expect([claude, codex, pi, droid].map(\.sourceName) == ["claude", "codex", "pi", "droid"])
    let g = group([claude, codex, pi, droid], query: "")
    let shown = projectSections(g, filter: .all, hiddenSources: ["pi", "claude"]) { $0 }.flatMap(\.rows).map(\.sourceName)
    #expect(shown.sorted() == ["codex", "droid"])
}

@Test func filterShowsOnlyMatchingChildrenUnderTheirParent() {
    let rows = [
        row("parent", .running, cwd: "/p/a", activity: 50),
        row("asks", .yourTurn, cwd: "/p/a", activity: 40, parent: "parent"),
        row("works", .running, cwd: "/p/a", activity: 30, parent: "parent"),
        row("done", .quiet, cwd: "/p/a", activity: 20, parent: "parent"),
    ]
    let g = group(rows, query: "")
    // The parent does not need input: it only names the parent of the child that does.
    let input = projectSections(g, filter: .yourTurn) { $0 }.flatMap(\.rows)
    #expect(input.map(\.id) == ["parent"] && input[0].isContext && input[0].children.map(\.id) == ["asks"])
    // The parent runs: a full row, with only its running child.
    let running = projectSections(g, filter: .running) { $0 }.flatMap(\.rows)
    #expect(running.map(\.id) == ["parent"] && !running[0].isContext && running[0].children.map(\.id) == ["works"])
    #expect(projectSections(g, filter: .all) { $0 }.flatMap(\.rows).first?.children.count == 3)
}

/// Under a status filter the Starred section has only the starred sessions in that group, so it does not fill Last
/// Call with finished work.
@Test func starredFollowsTheFilter() {
    let rows = [row("done", .quiet, cwd: "/p/a", activity: 2), row("wait", .yourTurn, cwd: "/p/a", activity: 1)]
    var marks = SessionMarks()
    marks.toggleStar("done")
    marks.toggleStar("wait")
    let g = group(rows, query: "", marks: marks)
    #expect(projectSections(g, filter: .yourTurn) { $0 }.map(\.id) == [ProjectSection.starredId])
    #expect(projectSections(g, filter: .yourTurn) { $0 }[0].rows.map(\.id) == ["wait"])
    #expect(projectSections(g, filter: .running) { $0 }.isEmpty)
    #expect(projectSections(g, filter: .all) { $0 }[0].rows.count == 2)
}
