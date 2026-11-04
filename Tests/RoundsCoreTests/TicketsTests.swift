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

@Test func ignoresShortRefsAndOtherHosts() {
    #expect(ticketRefs(inPrompt: "#123 and # 12, color #fff, step #2, prefix #3") == [])
    #expect(ticketRefs(inPrompt: "https://example.com/acme/issue/BBQ-1 and https://gitlab.com/o/r/issues/3") == [])
}

@Test func bareIDsAreNoVersionsAndHaveNoLeadingZero() {
    #expect(ticketRefs(inPrompt: "ios-1.57 v2-1.0 BBQ-0123") == [])
    #expect(ticketRefs(inPrompt: "Do BBQ-123.") == [.linearID("BBQ-123")])
}

@Test func findsGitHubPullRequestLinks() {
    #expect(ticketRefs(inPrompt: "https://github.com/o/r/pull/5, HTTPS://GitHub.com/O/R/pull/6/files https://github.com/o/r/pull/7/")
        == [.githubPR(owner: "o", repo: "r", number: 5), .githubPR(owner: "O", repo: "R", number: 6), .githubPR(owner: "o", repo: "r", number: 7)])
}

@Test func findsOwnerRepoNumberRefsAfterURLs() {
    #expect(ticketRefs(inPrompt: "see my-org/r.js#12 and https://github.com/a/b/issues/1#x, a/b#1")
        == [.githubNumber(12, repository: GitHubRepository(owner: "my-org", name: "r.js")), .github(owner: "a", repo: "b", number: 1),
            .githubNumber(1, repository: GitHubRepository(owner: "a", name: "b"))])
    #expect(ticketRefs(inPrompt: "src/o/r#1 x.o/r#2 o/r#3a o/r#0 o_x/r#4") == [])
}

@Test func findsHashNumbersOnlyAfterAKeyword() {
    #expect(ticketRefs(inPrompt: "fixes #12, Fixes: #13; issue #7 and CLOSES  #8") == [12, 13, 7, 8].map { .githubNumber($0, repository: nil) })
    #expect(ticketRefs(inPrompt: "prefix #3 fixes #4x issue#5 fix #0") == [])
}

@Test func keepsAtMost20Refs() {
    let ids = (1...25).map { "A-\($0)" }
    #expect(ticketRefs(inPrompt: ids.joined(separator: " ")) == ids.prefix(20).map { .linearID($0) })
}

@Test func rowRefsKeepIdentifiersOfKnownTeamsThenTheFirstFive() {
    let refs: [TicketRef] = [.linearID("UTF-8"), .linearID("BBQ-1"), .github(owner: "o", repo: "r", number: 1), .linearURL(workspace: "a", id: "X-1"),
                             .linearID("BBQ-2"), .linearID("OPS-3"), .linearID("BBQ-4"), .linearID("BBQ-5")]
    #expect(rowRefs(refs, teamKeys: ["BBQ", "OPS"], repository: nil) == Array(refs[1...5]))
    #expect(rowRefs(refs, teamKeys: [], repository: nil) == [.github(owner: "o", repo: "r", number: 1), .linearURL(workspace: "a", id: "X-1")])
}

@Test func rowRefsGiveHashNumbersTheOriginRepositoryThenTheFirstFive() {
    let refs: [TicketRef] = [.githubNumber(1, repository: nil), .linearID("BBQ-1"), .githubNumber(2, repository: nil), .github(owner: "o", repo: "r", number: 1),
                             .githubNumber(6, repository: GitHubRepository(owner: "u", name: "v")), .githubNumber(4, repository: nil), .githubNumber(5, repository: nil)]
    #expect(rowRefs(refs, teamKeys: ["BBQ"], repository: GitHubRepository(owner: "o", name: "r"))
        == [.github(owner: "o", repo: "r", number: 1), .linearID("BBQ-1"), .github(owner: "o", repo: "r", number: 2),
            .github(owner: "u", repo: "v", number: 6), .github(owner: "o", repo: "r", number: 4)])
    #expect(rowRefs(refs, teamKeys: ["BBQ"], repository: nil)
        == [.linearID("BBQ-1"), .github(owner: "o", repo: "r", number: 1), .github(owner: "u", repo: "v", number: 6)])
}

@Test func githubRepositoryIsTheOriginURLOfAGitConfig() {
    func repo(_ url: String) -> GitHubRepository? {
        githubRepository(gitConfig: "[core]\n\turl = git@github.com:x/y\n[remote \"upstream\"]\n\turl = git@github.com:u/v\n[remote \"origin\"]\n\turl = \(url)\n\tfetch = +refs/heads/*\n")
    }
    let o = GitHubRepository(owner: "o", name: "r")
    #expect(["git@github.com:o/r.git", "git@github.com:o/r", "ssh://git@github.com/o/r.git", "https://github.com/o/r.git", "https://github.com/o/r/", "https://x-access-token@github.com/o/r.git"].map(repo) == [o, o, o, o, o, o])
    #expect(repo("https://github.com/o/r.github") == GitHubRepository(owner: "o", name: "r.github"))
    #expect(repo("git@gitlab.com:o/r.git") == nil && repo("https://example.com/o/r") == nil)
    #expect(githubRepository(gitConfig: "[remote \"upstream\"]\n\turl = git@github.com:u/v\n") == nil)
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

@Test func readsTheOriginRepositoryFromTheCommonGitFolder() throws {
    let dir = try folder([
        "wt/.git": "gitdir: ../main/.git/worktrees/wt\n",
        "main/.git/worktrees/wt/HEAD": "ref: refs/heads/feat\n",
        "main/.git/worktrees/wt/commondir": "../..\n",
        "main/.git/config": "[remote \"origin\"]\n\turl = git@github.com:o/r.git\n",
    ])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(gitBranch(folder: dir.appendingPathComponent("wt")).repository == GitHubRepository(owner: "o", name: "r"))
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
