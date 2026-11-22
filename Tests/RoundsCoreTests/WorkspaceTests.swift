import Darwin
import Foundation
import Testing
@testable import RoundsCore

@Suite struct WorkspaceTests {
    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private func commit(in repository: URL, message: String = "Fixture") throws -> String {
        try git("-C", repository.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--allow-empty", "--no-gpg-sign", "-m", message)
        return try git("-C", repository.path, "rev-parse", "HEAD")
    }

    private func folder(_ url: URL, mode: mode_t = 0o700) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        chmod(url.path, mode)
        return url
    }

    private func resolved(_ url: URL) throws -> String { try #require(FolderIdentity.current(url.path)).path }

    @Test func inspectionFindsRepositoryRootAndRemotes() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let plain = try folder(base.appending(path: "plain"))
        #expect(try inspectWorkspaceFolder(plain.path) == .noRepository)

        let repo = try folder(base.appending(path: "repo"))
        let child = try folder(repo.appending(path: "records"))
        try git("-C", repo.path, "init", "--quiet")
        #expect(try inspectWorkspaceFolder(child.path) == .repository(root: resolved(repo), remotes: []))
        try git("-C", repo.path, "remote", "add", "origin", "https://example.invalid/team/workspace.git")
        #expect(try inspectWorkspaceFolder(child.path) == .repository(
            root: resolved(repo), remotes: [WorkspaceRemote(name: "origin", url: "https://example.invalid/team/workspace.git")]))
    }

    @Test func sourceCommitFollowsOnlyTheNamedRef() throws {
        let repo = try tempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git("-C", repo.path, "init", "--quiet", "--initial-branch=main")
        let first = try commit(in: repo)
        let ref = "refs/heads/result"
        try git("-C", repo.path, "update-ref", ref, first)
        let second = try commit(in: repo, message: "Next")
        try #require(first != second)
        #expect(try resolveWorkspaceSourceCommit(in: repo.path, sourceRef: ref) == first)

        try git("-C", repo.path, "update-ref", ref, second)
        #expect(try resolveWorkspaceSourceCommit(in: repo.path, sourceRef: ref) == second)

        // A revision expression could still find this tag after the exact reference is deleted.
        try git("-C", repo.path, "update-ref", "refs/tags/\(ref)", first)
        try git("-C", repo.path, "update-ref", "-d", ref)
        #expect(throws: WorkspaceError.gitFailed("Git could not read the local source reference.")) {
            try resolveWorkspaceSourceCommit(in: repo.path, sourceRef: ref)
        }
    }

    @Test func sourceCommitRejectsAReferenceSpellingChangedByTheSubprocess() throws {
        let repo = try tempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git("-C", repo.path, "init", "--quiet", "--initial-branch=main")
        let revision = try commit(in: repo)
        let composed = "refs/heads/caf\u{e9}"
        let decomposed = "refs/heads/cafe\u{301}"
        try git("-C", repo.path, "config", "core.precomposeUnicode", "false")
        try git("-C", repo.path, "update-ref", decomposed, revision)
        try git("-C", repo.path, "pack-refs", "--all")
        #expect(try resolveWorkspaceSourceCommit(in: repo.path, sourceRef: decomposed) == revision)
        #expect(throws: WorkspaceError.gitFailed("Git could not read the local source reference.")) {
            try resolveWorkspaceSourceCommit(in: repo.path, sourceRef: composed)
        }
    }

    @Test func sourceCommitRejectsRevisionExpressions() throws {
        let repo = try tempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git("-C", repo.path, "init", "--quiet", "--initial-branch=main")
        let commit = try commit(in: repo)
        for ref in ["main", "HEAD", commit, "--all", "refs/heads/main^0", "refs/heads/main~0",
                    "refs/heads/main@{0}", "refs//heads/main", "refs/heads/main\0extra"] {
            #expect(throws: WorkspaceError.gitFailed("Use a valid full Git reference name under refs/.")) {
                try resolveWorkspaceSourceCommit(in: repo.path, sourceRef: ref)
            }
        }
    }

    @Test func sourceCommitRejectsAnObjectEvenWhenReplacedByACommit() throws {
        let repo = try tempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git("-C", repo.path, "init", "--quiet")
        let commit = try commit(in: repo)
        let file = repo.appending(path: "blob")
        try Data("fixture".utf8).write(to: file)
        let blob = try git("-C", repo.path, "hash-object", "-w", "blob")
        let ref = "refs/tags/blob"
        try git("-C", repo.path, "update-ref", ref, blob)
        try git("-C", repo.path, "replace", "-f", blob, commit)
        #expect(throws: WorkspaceError.gitFailed("The source reference does not resolve to a locally available commit.")) {
            try resolveWorkspaceSourceCommit(in: repo.path, sourceRef: ref)
        }
    }

    @Test func sourceCommitPeelsAnAnnotatedTagInALinkedWorktree() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try folder(base.appending(path: "repo"))
        let linked = base.appending(path: "linked")
        try git("-C", repo.path, "init", "--quiet", "--object-format=sha256")
        let commit = try commit(in: repo)
        try git("-C", repo.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "-c", "tag.gpgSign=false", "tag", "-a", "result", "-m", "Fixture tag")
        try git("-C", repo.path, "worktree", "add", "--quiet", "--detach", linked.path)
        #expect(try resolveWorkspaceSourceCommit(in: linked.path, sourceRef: "refs/tags/result") == commit)
    }

    @Test func sourceCommitDoesNotUseTheParentRepository() throws {
        let repo = try tempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git("-C", repo.path, "init", "--quiet", "--initial-branch=main")
        _ = try commit(in: repo)
        let child = try folder(repo.appending(path: "child"))
        #expect(throws: WorkspaceError.notRepository) {
            try resolveWorkspaceSourceCommit(in: child.path, sourceRef: "refs/heads/main")
        }
    }

    @Test func sourceCommitDoesNotFetchAMissingObject() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let remote = try folder(base.appending(path: "remote"))
        let repo = base.appending(path: "repo")
        try git("-C", remote.path, "init", "--quiet", "--initial-branch=main")
        let commit = try commit(in: remote)
        try git("-C", base.path, "clone", "--quiet", "--local", remote.path, repo.path)
        try git("-C", repo.path, "config", "remote.origin.promisor", "true")
        let object = repo.appending(path: ".git/objects/\(commit.prefix(2))/\(commit.dropFirst(2))")
        try FileManager.default.removeItem(at: object)
        #expect(throws: WorkspaceError.self) {
            try resolveWorkspaceSourceCommit(in: repo.path, sourceRef: "refs/heads/main")
        }
        let objects = try git("-C", repo.path, "--no-lazy-fetch", "rev-list", "--objects", "--missing=print", "--all")
        #expect(objects.split(separator: "\n").contains("?\(commit)"))
    }

    @Test func createNeverOverwritesAndAddsNoRemote() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let taken = try folder(base.appending(path: "taken"))
        let existing = taken.appending(path: workspaceFileName)
        try Data("keep".utf8).write(to: existing)
        #expect(throws: WorkspaceError.fileExists) { try createWorkspaceRepository(in: taken.path, name: "Team") }
        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
        #expect(!FileManager.default.fileExists(atPath: taken.appending(path: ".git").path))

        let fresh = try folder(base.appending(path: "fresh"))
        #expect(throws: WorkspaceError.invalidName) { try createWorkspaceRepository(in: fresh.path, name: "  ") }
        try createWorkspaceRepository(in: fresh.path, name: "Team workspace")
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: fresh.appending(path: workspaceFileName))) as? [String: Any]
        #expect(file?["formatVersion"] as? Int == 1)
        #expect(file?["name"] as? String == "Team workspace")
        #expect(try inspectWorkspaceFolder(fresh.path) == .repository(root: resolved(fresh), remotes: []))
        #expect(throws: WorkspaceError.alreadyRepository) { try createWorkspaceRepository(in: fresh.path, name: "Again") }
    }

    @Test func changedRemoteSetNeedsNewAcknowledgement() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try folder(base.appending(path: "repo"))
        try git("-C", repo.path, "init", "--quiet")
        try git("-C", repo.path, "remote", "add", "origin", "https://example.invalid/team/workspace.git")
        var settings = WorkspaceSettings()
        try settings.setWorkspace(repo.path)
        #expect(settings.workspaceProblem(try inspectWorkspaceFolder(repo.path)) == .remotesNotAcknowledged)
        guard case .repository(_, let remotes) = try inspectWorkspaceFolder(repo.path) else { Issue.record("no repository"); return }
        try settings.acknowledgeRemotes(remotes)
        #expect(settings.workspaceProblem(try inspectWorkspaceFolder(repo.path)) == nil)

        try git("-C", repo.path, "remote", "add", "backup", "git@example.invalid:team/workspace.git")
        #expect(settings.workspaceProblem(try inspectWorkspaceFolder(repo.path)) == .remotesNotAcknowledged)
        try git("-C", repo.path, "remote", "remove", "backup")
        try git("-C", repo.path, "remote", "set-url", "origin", "https://example.invalid/other/workspace.git")
        #expect(settings.workspaceProblem(try inspectWorkspaceFolder(repo.path)) == .remotesNotAcknowledged)

        // A push target set as a URL in configuration is not listed by `git remote -v`, but still needs acknowledgement.
        try git("-C", repo.path, "remote", "set-url", "origin", "https://example.invalid/team/workspace.git")
        #expect(settings.workspaceProblem(try inspectWorkspaceFolder(repo.path)) == nil)
        try git("-C", repo.path, "config", "remote.pushDefault", "https://example.invalid/elsewhere.git")
        #expect(settings.workspaceProblem(try inspectWorkspaceFolder(repo.path)) == .remotesNotAcknowledged)
    }

    @Test func workspaceMustStayItsOwnRepositoryRoot() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let outer = try folder(base.appending(path: "outer"))
        try git("-C", outer.path, "init", "--quiet")
        let inner = try folder(outer.appending(path: "workspace"))
        try git("-C", inner.path, "init", "--quiet")
        var settings = WorkspaceSettings()
        try settings.setWorkspace(inner.path)
        #expect(settings.workspaceProblem(try inspectWorkspaceFolder(inner.path)) == nil)
        // Without its own repository, the folder resolves to the outer repository and must not pass.
        try FileManager.default.removeItem(at: inner.appending(path: ".git"))
        #expect(settings.workspaceProblem(try inspectWorkspaceFolder(inner.path)) == .notRepository)
    }

    @Test func displayHidesCredentialsInRemoteURLs() {
        let remote = WorkspaceRemote(name: "origin", url: "https://user:secret-token@example.invalid/team/workspace.git")
        #expect(!remote.displayURL.contains("secret-token"))
        #expect(!remote.displayURL.contains("user"))
        #expect(remote.displayURL.contains("example.invalid/team/workspace.git"))
    }

    @Test func detailFolderMustBePrivateRealAndOutsideRepository() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try folder(base.appending(path: "repo"))
        try git("-C", repo.path, "init", "--quiet")
        let inside = try folder(repo.appending(path: "details"))
        let shared = try folder(base.appending(path: "shared"), mode: 0o750)
        let open = try folder(base.appending(path: "open"), mode: 0o705)
        let good = try folder(base.appending(path: "private"))
        let link = base.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: good)

        #expect(checkDetailFolder(inside.path, repositoryRoot: repo.path) == .insideRepository)
        #expect(checkDetailFolder(repo.path, repositoryRoot: repo.path) == .insideRepository)
        #expect(checkDetailFolder(shared.path, repositoryRoot: repo.path) == .notPrivate)
        #expect(checkDetailFolder(open.path, repositoryRoot: repo.path) == .notPrivate)
        #expect(checkDetailFolder(link.path, repositoryRoot: repo.path) == .symlink)
        #expect(checkDetailFolder(base.appending(path: "missing").path, repositoryRoot: repo.path) == .missing)
        #expect(checkDetailFolder(good.path, repositoryRoot: repo.path) == nil)

        var settings = WorkspaceSettings()
        try settings.setWorkspace(repo.path)
        #expect(throws: WorkspaceError.detailFolderInvalid(.insideRepository)) {
            try settings.approveDetailFolder(inside.path, for: .unclassified, repositoryRoot: repo.path)
        }
        #expect(settings.detailFolders.isEmpty)
    }

    @Test func approvalOnlyForCompleteSetupAndSameFolder() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try folder(base.appending(path: "repo"))
        try createWorkspaceRepository(in: repo.path, name: "Team")
        let details = try folder(base.appending(path: "details"))
        let organization = UUID(), other = UUID()
        let store = WorkspaceSettingsStore(url: base.appending(path: "workspace-settings.json"))
        #expect(!store.mayStoreTaskDetails(for: organization))
        try store.update { settings in
            try settings.setWorkspace(repo.path)
            try settings.approveDetailFolder(details.path, for: .organization(organization), repositoryRoot: repo.path)
        }
        #expect(store.mayStoreTaskDetails(for: organization))
        #expect(!store.mayStoreTaskDetails(for: other))
        #expect(!store.mayStoreTaskDetails(for: nil))

        // A remote added after setup needs an acknowledgement before task details are stored.
        try git("-C", repo.path, "remote", "add", "origin", "https://example.invalid/team/workspace.git")
        #expect(!store.mayStoreTaskDetails(for: organization))
        try git("-C", repo.path, "remote", "remove", "origin")
        #expect(store.mayStoreTaskDetails(for: organization))

        // A replaced folder at the same path is a new folder.
        try FileManager.default.removeItem(at: details)
        _ = try folder(details)
        #expect(!store.mayStoreTaskDetails(for: organization))
        #expect(try store.load().detailFolderProblem(for: .organization(organization), repositoryRoot: repo.path) == .replaced)

        // A different workspace folder removes every approval.
        let next = try folder(base.appending(path: "next"))
        try store.update { try $0.setWorkspace(next.path) }
        #expect(try store.load().detailFolders.isEmpty)
    }

    @Test func corruptOrUnknownSettingsFailClosed() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appending(path: "workspace-settings.json")
        let store = WorkspaceSettingsStore(url: url)
        for content in ["{not json", #"{"version":2,"detailFolders":{}}"#,
                        #"{"version":1,"detailFolders":{"someone":{"path":"/tmp","device":1,"inode":2}}}"#] {
            try Data(content.utf8).write(to: url)
            #expect(throws: WorkspaceError.malformedData) { try store.load() }
            #expect(throws: WorkspaceError.malformedData) { try store.update { $0.withdrawAcknowledgement() } }
            #expect(try Data(contentsOf: url) == Data(content.utf8))
            #expect(!store.mayStoreTaskDetails(for: nil))
        }
    }
}
