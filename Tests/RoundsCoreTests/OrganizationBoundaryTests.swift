import Foundation
import Testing
@testable import RoundsCore

@Suite struct OrganizationBoundaryTests {
    private let remote = "git@github.com:team/project.git"

    private func directoryRule(_ id: String, _ path: String) -> OrganizationBoundaryRule {
        OrganizationBoundaryRule(organizationID: id, match: .directory(path))
    }

    private func remoteRule(_ id: String, _ remote: String) -> OrganizationBoundaryRule {
        OrganizationBoundaryRule(organizationID: id, match: .gitRemote(remote))
    }

    @Test func directoriesMatchComponentsAndExplicitWorktrees() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appending(path: "repo")
        let child = repo.appending(path: "src/module")
        let sibling = base.appending(path: "repo-other")
        let worktree = base.appending(path: "worktrees/feature")
        for dir in [child, sibling, worktree.appending(path: "src")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let repoRule = directoryRule("team", repo.path)
        let rules = [repoRule, directoryRule("team", worktree.path)]
        #expect(resolveOrganizationBoundary(rules: rules, sessionDirectory: repo.path, gitRemote: .absent) == .classified(organizationID: "team"))
        #expect(resolveOrganizationBoundary(rules: rules, sessionDirectory: child.path, gitRemote: .absent) == .classified(organizationID: "team"))
        #expect(resolveOrganizationBoundary(rules: rules, sessionDirectory: sibling.path, gitRemote: .absent) == .localOnly(.unmatched))
        #expect(resolveOrganizationBoundary(rules: [repoRule], sessionDirectory: worktree.path, gitRemote: .absent) == .localOnly(.unmatched))
        #expect(resolveOrganizationBoundary(rules: rules, sessionDirectory: worktree.appending(path: "src").path, gitRemote: .absent) == .classified(organizationID: "team"))
        #expect(resolveOrganizationBoundary(rules: [directoryRule("all", "/")], sessionDirectory: child.path, gitRemote: .absent) == .classified(organizationID: "all"))
    }

    @Test func linkedWorktreesFollowTheirRepositoryOnlyWithGitsBackLink() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let repo = base.appending(path: "repo")
        let worktree = base.appending(path: "worktrees/feature")
        let forged = base.appending(path: "worktrees/forged")
        let link = repo.appending(path: ".git/worktrees/feature")
        for dir in [link, worktree.appending(path: "src"), forged] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // The layout `git worktree add` writes: a .git file in the worktree and a link back in the repository.
        try "gitdir: \(link.path)\n".write(to: worktree.appending(path: ".git"), atomically: true, encoding: .utf8)
        try "\(worktree.appending(path: ".git").path)\n".write(to: link.appending(path: "gitdir"), atomically: true, encoding: .utf8)
        try "gitdir: \(link.path)\n".write(to: forged.appending(path: ".git"), atomically: true, encoding: .utf8)
        let repoRule = directoryRule("team", repo.path)
        #expect(resolveOrganizationBoundary(rules: [repoRule], sessionDirectory: worktree.path, gitRemote: .absent) == .classified(organizationID: "team"))
        #expect(resolveOrganizationBoundary(rules: [repoRule], sessionDirectory: worktree.appending(path: "src").path, gitRemote: .absent) == .classified(organizationID: "team"))
        #expect(resolveOrganizationBoundary(rules: [repoRule], sessionDirectory: forged.path, gitRemote: .absent) == .localOnly(.unmatched))
        #expect(resolveOrganizationBoundary(rules: [repoRule, directoryRule("other", worktree.path)], sessionDirectory: worktree.path, gitRemote: .absent) == .localOnly(.conflicting))
    }

    @Test func symlinksResolveBeforeMatchingAndDotDot() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let allowed = base.appending(path: "allowed")
        let outside = base.appending(path: "outside")
        for dir in [allowed.appending(path: "inside"), outside.appending(path: "deep"), outside.appending(path: "inside")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fm = FileManager.default
        try fm.createSymbolicLink(at: base.appending(path: "alias"), withDestinationURL: allowed)
        try fm.createSymbolicLink(at: allowed.appending(path: "escape"), withDestinationURL: outside.appending(path: "deep"))
        let rule = directoryRule("team", allowed.path)
        #expect(resolveOrganizationBoundary(rules: [rule], sessionDirectory: base.appending(path: "alias/inside").path, gitRemote: .absent) == .classified(organizationID: "team"))
        #expect(resolveOrganizationBoundary(rules: [directoryRule("team", base.appending(path: "alias").path)], sessionDirectory: allowed.path, gitRemote: .absent) == .classified(organizationID: "team"))
        let escape = allowed.path + "/escape/../inside"
        #expect(resolveOrganizationBoundary(rules: [rule], sessionDirectory: escape, gitRemote: .absent) == .localOnly(.unmatched))
    }

    @Test func distinctMatchesConflictEvenWhenOneIsMoreSpecific() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let child = base.appending(path: "child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let parentRule = directoryRule("first", base.path)
        let childRule = directoryRule("second", child.path)
        let otherRemoteRule = remoteRule("second", remote)
        #expect(resolveOrganizationBoundary(rules: [parentRule, childRule], sessionDirectory: child.path, gitRemote: .absent) == .localOnly(.conflicting))
        #expect(resolveOrganizationBoundary(rules: [childRule, parentRule], sessionDirectory: child.path, gitRemote: .absent) == .localOnly(.conflicting))
        #expect(resolveOrganizationBoundary(rules: [parentRule, otherRemoteRule], sessionDirectory: child.path, gitRemote: .observed([remote])) == .localOnly(.conflicting))
        #expect(resolveOrganizationBoundary(rules: [parentRule, directoryRule("first", child.path), remoteRule("first", remote)], sessionDirectory: child.path, gitRemote: .observed([remote])) == .classified(organizationID: "first"))
    }

    @Test func identifiersWithDifferentBytesDoNotCollapseIntoOneOrganization() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let rules = [directoryRule("café", base.path), directoryRule("cafe\u{301}", base.path)]
        #expect(resolveOrganizationBoundary(rules: rules, sessionDirectory: base.path, gitRemote: .absent) == .localOnly(.conflicting))
    }

    @Test func invalidRulesBlockOtherMatches() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let matching = directoryRule("team", base.path)
        let file = base.appending(path: "file")
        try Data().write(to: file)
        let invalid = [directoryRule("", base.path), directoryRule("  ", base.path), directoryRule("other", "relative"),
                       directoryRule("other", base.appending(path: "missing").path), directoryRule("other", file.path),
                       directoryRule("other", file.path + "/.."), directoryRule("other", base.path + "\0/ignored"),
                       remoteRule("other", "not a remote"),
                       remoteRule("other", "https://example.com/a%ZZ")]
        for rule in invalid {
            #expect(resolveOrganizationBoundary(rules: [matching, rule], sessionDirectory: base.path, gitRemote: .absent) == .localOnly(.invalidRule))
        }
    }

    @Test func unknownInputsCannotHideAConflict() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = directoryRule("first", base.path)
        let remote = remoteRule("second", self.remote)
        #expect(resolveOrganizationBoundary(rules: [directory, remote], sessionDirectory: base.path, gitRemote: .unknown) == .localOnly(.unknownInput))
        #expect(resolveOrganizationBoundary(rules: [directory, remote], sessionDirectory: nil, gitRemote: .observed([self.remote])) == .localOnly(.unknownInput))
        #expect(resolveOrganizationBoundary(rules: [directory, remote], sessionDirectory: base.path, gitRemote: .absent) == .classified(organizationID: "first"))
        #expect(resolveOrganizationBoundary(rules: [directory], sessionDirectory: base.path, gitRemote: .observed(["bad remote"])) == .localOnly(.unknownInput))
        #expect(resolveOrganizationBoundary(rules: [directory], sessionDirectory: base.path, gitRemote: .observed([])) == .localOnly(.unknownInput))
        let file = base.appending(path: "file")
        try Data().write(to: file)
        for path in ["relative", base.appending(path: "missing").path, file.path, file.path + "/..", base.path + "\0/ignored"] {
            #expect(resolveOrganizationBoundary(rules: [directory], sessionDirectory: path, gitRemote: .absent) == .localOnly(.unknownInput))
        }
        #expect(resolveOrganizationBoundary(rules: [directory], sessionDirectory: base.path, gitRemote: .unknown) == .classified(organizationID: "first"))
        #expect(resolveOrganizationBoundary(rules: [remote], sessionDirectory: nil, gitRemote: .observed([self.remote])) == .classified(organizationID: "second"))
    }

    @Test func danglingLinksAreNotResolvedAsAuthorizedPaths() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appending(path: "dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base.appending(path: "missing"))
        #expect(resolveOrganizationBoundary(rules: [directoryRule("team", base.path)], sessionDirectory: link.path, gitRemote: .absent) == .localOnly(.unknownInput))
        #expect(resolveOrganizationBoundary(rules: [directoryRule("team", link.path)], sessionDirectory: base.path, gitRemote: .absent) == .localOnly(.invalidRule))
    }

    @Test func exactRemoteMatchesDoNotNormalizeDifferentURLs() {
        let original = "https://git.example.com/Team/repo.git"
        let rule = remoteRule("team", original)
        let different = ["http://git.example.com/Team/repo.git", "https://GIT.example.com/Team/repo.git",
                         "https://git.example.com/team/repo.git", "https://git.example.com/Team/repo",
                         "https://git.example.com/Team/repo.git/", "https://git.example.com:443/Team/repo.git",
                         "https://user@git.example.com/Team/repo.git", "https://git.example.com/Team/repo.git?x=1",
                         "ssh://git@git.example.com/Team/repo.git", "git@git.example.com:Team/repo.git",
                         "https://git.example.com/Team%2Frepo.git"]
        #expect(resolveOrganizationBoundary(rules: [rule], sessionDirectory: nil, gitRemote: .observed([original])) == .classified(organizationID: "team"))
        for value in different {
            #expect(resolveOrganizationBoundary(rules: [rule], sessionDirectory: nil, gitRemote: .observed([value])) == .localOnly(.unmatched))
        }
        let scp = remoteRule("team", remote)
        #expect(resolveOrganizationBoundary(rules: [scp], sessionDirectory: nil, gitRemote: .observed([remote])) == .classified(organizationID: "team"))
        #expect(resolveOrganizationBoundary(rules: [scp], sessionDirectory: nil, gitRemote: .absent) == .localOnly(.unmatched))
        #expect(resolveOrganizationBoundary(rules: [scp, remoteRule("other", remote)], sessionDirectory: nil, gitRemote: .observed([remote])) == .localOnly(.conflicting))
        let otherRemote = "git@example.com:other.git"
        let distinctRules = [scp, remoteRule("other", otherRemote)]
        #expect(resolveOrganizationBoundary(rules: distinctRules, sessionDirectory: nil, gitRemote: .observed([remote, otherRemote])) == .localOnly(.conflicting))
        #expect(resolveOrganizationBoundary(rules: distinctRules, sessionDirectory: nil, gitRemote: .observed([remote, "bad remote"])) == .localOnly(.unknownInput))

        let composed = "git@example.com:café.git"
        let decomposed = "git@example.com:cafe\u{301}.git"
        #expect(resolveOrganizationBoundary(rules: [remoteRule("team", composed)], sessionDirectory: nil, gitRemote: .observed([decomposed])) == .localOnly(.unmatched))
    }
}
