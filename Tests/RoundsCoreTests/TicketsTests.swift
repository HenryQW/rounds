import Foundation
import Testing
@testable import RoundsCore

@Test func findsALinearURLAndDropsSlugAndTrailingPunctuation() {
    #expect(ticketRefs(inPrompt: "[x](https://linear.app/acme/issue/BBQ-12/fix-login).") == [.linearURL(workspace: "acme", id: "BBQ-12")])
}

@Test func findsBareLinearIDsAndGitHubIssueURLsInOrder() {
    let refs = ticketRefs(inPrompt: "see bbq-7 and https://github.com/o/r/issues/9#issuecomment-1)")
    #expect(refs == [.linearID("BBQ-7"), .github(owner: "o", repo: "r", number: 9)])
}

@Test func ignoresPullRequestsShortRefsAndOtherHosts() {
    #expect(ticketRefs(inPrompt: "https://github.com/o/r/pull/5 and #123") == [])
    #expect(ticketRefs(inPrompt: "https://example.com/acme/issue/BBQ-1 and https://gitlab.com/o/r/issues/3") == [])
}

@Test func keepsAtMost20Refs() {
    let ids = (1...25).map { "A-\($0)" }
    #expect(ticketRefs(inPrompt: ids.joined(separator: " ")) == ids.prefix(20).map { .linearID($0) })
}

@Test func rowRefsKeepIdentifiersOfKnownTeamsThenTheFirstFive() {
    let refs: [TicketRef] = [.linearID("UTF-8"), .linearID("BBQ-1"), .github(owner: "o", repo: "r", number: 1), .linearURL(workspace: "a", id: "X-1"),
                             .linearID("BBQ-2"), .linearID("OPS-3"), .linearID("BBQ-4"), .linearID("BBQ-5")]
    #expect(rowRefs(refs, teamKeys: ["BBQ", "OPS"]) == Array(refs[1...5]))
    #expect(rowRefs(refs, teamKeys: []) == [.github(owner: "o", repo: "r", number: 1), .linearURL(workspace: "a", id: "X-1")])
}

@Test func schemeAndHostIgnoreCaseAndTheWorkspaceIsLowerCase() {
    #expect(ticketRefs(inPrompt: "HTTPS://Linear.APP/Acme/issue/bbq-12 Https://GitHub.com/o/r/issues/9/")
        == [.linearURL(workspace: "acme", id: "BBQ-12"), .github(owner: "o", repo: "r", number: 9)])
    #expect(ticketRefs(inPrompt: "https://github.com/o/r/issues/9//") == [])
}

@Test func readsOnlyTheFirst64KB() {
    let pad = String(repeating: "x", count: 65_535) + " "
    #expect(ticketRefs(inPrompt: pad + "BBQ-1") == [])
    #expect(ticketRefs(inPrompt: "BBQ-1 " + pad) == [.linearID("BBQ-1")])
}

@Test func dropsARefThatTheCutEnds() {
    // The cut makes BBQ-123 into BBQ-12, and in the second text it falls inside "é" and moves back to the end of BBQ-12.
    #expect(ticketRefs(inPrompt: String(repeating: "x", count: 65_529) + " BBQ-123") == [])
    #expect(ticketRefs(inPrompt: String(repeating: "x", count: 65_528) + " BBQ-12é") == [])
    #expect(ticketRefs(inPrompt: "BBQ-1 " + String(repeating: "x", count: 65_529) + "é") == [.linearID("BBQ-1")])
}

@Test func dropsDuplicates() {
    #expect(ticketRefs(inPrompt: "BBQ-1 bbq-1") == [.linearID("BBQ-1")])
}

@Test func lookupBranchSkipsDefaultBranches() {
    #expect(lookupBranch("main", defaultBranch: nil) == nil)
    #expect(lookupBranch("release", defaultBranch: "release") == nil)
    #expect(lookupBranch("", defaultBranch: nil) == nil)
    #expect(lookupBranch("henry/bbq-1-x", defaultBranch: "main") == "henry/bbq-1-x")
}

private func folder(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func readsTheBranchAndDefaultBranchOfARepo() throws {
    let dir = try folder([".git/HEAD": "ref: refs/heads/henry/bbq-1\n", ".git/refs/remotes/origin/HEAD": "ref: refs/remotes/origin/main\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = gitBranch(folder: dir)
    #expect(r.branch == "henry/bbq-1" && r.defaultBranch == "main")
}

@Test func readsAWorktreeThroughGitdirAndCommondir() throws {
    let dir = try folder([
        "wt/.git": "gitdir: ../main/.git/worktrees/wt\n",
        "main/.git/worktrees/wt/HEAD": "ref: refs/heads/feat\n",
        "main/.git/worktrees/wt/commondir": "../..\n",
        "main/.git/refs/remotes/origin/HEAD": "ref: refs/remotes/origin/trunk\n",
    ])
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = gitBranch(folder: dir.appendingPathComponent("wt"))
    #expect(r.branch == "feat" && r.defaultBranch == "trunk")
}

@Test func readsAWorktreeThroughAnAbsoluteGitdir() throws {
    let dir = try folder(["wt/file": "", "g/HEAD": "ref: refs/heads/feat\n", "g/commondir": "../main\n", "main/refs/remotes/origin/HEAD": "ref: refs/remotes/origin/trunk\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try "gitdir: \(dir.path)/g\n".write(to: dir.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)
    let r = gitBranch(folder: dir.appendingPathComponent("wt"))
    #expect(r.branch == "feat" && r.defaultBranch == "trunk")
}

/// Without `commondir` the git folder is also the common folder.
@Test func readsAWorktreeWithoutCommondir() throws {
    let dir = try folder(["wt/.git": "gitdir: ../g\n", "g/HEAD": "ref: refs/heads/feat\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = gitBranch(folder: dir.appendingPathComponent("wt"))
    #expect(r.branch == "feat" && r.defaultBranch == nil)
}

@Test func aDetachedHeadHasNoBranch() throws {
    let dir = try folder([".git/HEAD": "0123456789abcdef0123456789abcdef01234567\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = gitBranch(folder: dir)
    #expect(r.branch == nil && r.defaultBranch == nil)
}

@Test func aFolderWithoutGitHasNoBranch() throws {
    let dir = try folder([:])
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = gitBranch(folder: dir)
    #expect(r.branch == nil && r.defaultBranch == nil)
}

@Test func gitFolderWalksUpToTheFirstFolderWithGit() throws {
    let dir = try folder([".git/HEAD": "ref: refs/heads/a\n", "a/b/file": "", "wt/.git": "gitdir: x\n", "wt/c/file": ""])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(gitFolder(above: dir.appendingPathComponent("a/b").path)?.path == dir.path)
    #expect(gitFolder(above: dir.appendingPathComponent("wt/c").path)?.path == dir.appendingPathComponent("wt").path)
    #expect(gitFolder(above: FileManager.default.temporaryDirectory.path) == nil)
}

@Test func retryDelayDoublesFrom30SecondsTo10Minutes() {
    #expect([1, 2, 3, 5, 6, 20].map(retryDelay(failures:)) == [30, 60, 120, 480, 600, 600])
}
