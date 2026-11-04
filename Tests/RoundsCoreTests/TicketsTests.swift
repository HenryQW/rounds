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

@Test func keepsAtMostFiveRefs() {
    #expect(ticketRefs(inPrompt: "A-1 B-2 C-3 D-4 E-5 F-6") == ["A-1", "B-2", "C-3", "D-4", "E-5"].map { .linearID($0) })
}

@Test func readsOnlyTheFirst64KB() {
    let pad = String(repeating: "x", count: 65_535) + " "
    #expect(ticketRefs(inPrompt: pad + "BBQ-1") == [])
    #expect(ticketRefs(inPrompt: "BBQ-1 " + pad) == [.linearID("BBQ-1")])
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
    let r = gitBranch(folder: dir.appendingPathComponent("wt"))
    #expect(r.branch == "feat" && r.defaultBranch == "trunk")
}

@Test func aDetachedHeadHasNoBranch() throws {
    let dir = try folder([".git/HEAD": "0123456789abcdef0123456789abcdef01234567\n"])
    let r = gitBranch(folder: dir)
    #expect(r.branch == nil && r.defaultBranch == nil)
}

@Test func aFolderWithoutGitHasNoBranch() throws {
    let r = gitBranch(folder: try folder([:]))
    #expect(r.branch == nil && r.defaultBranch == nil)
}
