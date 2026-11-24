import Darwin
import Foundation
import Testing
@testable import RoundsCore

@Suite struct BarTests {
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
        #expect(try inspectBarFolder(plain.path) == .noRepository)

        let repo = try folder(base.appending(path: "repo"))
        let child = try folder(repo.appending(path: "records"))
        try git("-C", repo.path, "init", "--quiet")
        #expect(try inspectBarFolder(child.path) == .repository(root: resolved(repo), remotes: []))
        try git("-C", repo.path, "remote", "add", "origin", "https://example.invalid/team/bar.git")
        #expect(try inspectBarFolder(child.path) == .repository(
            root: resolved(repo), remotes: [BarRemote(name: "origin", url: "https://example.invalid/team/bar.git")]))
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
        #expect(try resolveBarSourceCommit(in: repo.path, sourceRef: ref) == first)

        try git("-C", repo.path, "update-ref", ref, second)
        #expect(try resolveBarSourceCommit(in: repo.path, sourceRef: ref) == second)

        // A revision expression could still find this tag after the exact reference is deleted.
        try git("-C", repo.path, "update-ref", "refs/tags/\(ref)", first)
        try git("-C", repo.path, "update-ref", "-d", ref)
        #expect(throws: BarError.gitFailed("Git could not read the local source reference.")) {
            try resolveBarSourceCommit(in: repo.path, sourceRef: ref)
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
        #expect(try resolveBarSourceCommit(in: repo.path, sourceRef: decomposed) == revision)
        #expect(throws: BarError.gitFailed("Git could not read the local source reference.")) {
            try resolveBarSourceCommit(in: repo.path, sourceRef: composed)
        }
    }

    @Test func sourceCommitRejectsRevisionExpressions() throws {
        let repo = try tempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git("-C", repo.path, "init", "--quiet", "--initial-branch=main")
        let commit = try commit(in: repo)
        for ref in ["main", "HEAD", commit, "--all", "refs/heads/main^0", "refs/heads/main~0",
                    "refs/heads/main@{0}", "refs//heads/main", "refs/heads/main\0extra"] {
            #expect(throws: BarError.gitFailed("Use a valid full Git reference name under refs/.")) {
                try resolveBarSourceCommit(in: repo.path, sourceRef: ref)
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
        #expect(throws: BarError.gitFailed("The source reference does not resolve to a locally available commit.")) {
            try resolveBarSourceCommit(in: repo.path, sourceRef: ref)
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
        #expect(try resolveBarSourceCommit(in: linked.path, sourceRef: "refs/tags/result") == commit)
    }

    @Test func sourceCommitDoesNotUseTheParentRepository() throws {
        let repo = try tempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git("-C", repo.path, "init", "--quiet", "--initial-branch=main")
        _ = try commit(in: repo)
        let child = try folder(repo.appending(path: "child"))
        #expect(throws: BarError.notRepository) {
            try resolveBarSourceCommit(in: child.path, sourceRef: "refs/heads/main")
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
        #expect(throws: BarError.self) {
            try resolveBarSourceCommit(in: repo.path, sourceRef: "refs/heads/main")
        }
        let objects = try git("-C", repo.path, "--no-lazy-fetch", "rev-list", "--objects", "--missing=print", "--all")
        #expect(objects.split(separator: "\n").contains("?\(commit)"))
    }

    @Test func createNeverOverwritesAndAddsNoRemote() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let taken = try folder(base.appending(path: "taken"))
        let existing = taken.appending(path: barFileName)
        try Data("keep".utf8).write(to: existing)
        #expect(throws: BarError.fileExists) { try createBarRepository(in: taken.path, name: "Team") }
        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
        #expect(!FileManager.default.fileExists(atPath: taken.appending(path: ".git").path))

        let fresh = try folder(base.appending(path: "fresh"))
        #expect(throws: BarError.invalidName) { try createBarRepository(in: fresh.path, name: "  ") }
        try createBarRepository(in: fresh.path, name: "Team bar")
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: fresh.appending(path: barFileName))) as? [String: Any]
        #expect(file?["formatVersion"] as? Int == 1)
        #expect(file?["name"] as? String == "Team bar")
        #expect(try inspectBarFolder(fresh.path) == .repository(root: resolved(fresh), remotes: []))
        #expect(throws: BarError.alreadyRepository) { try createBarRepository(in: fresh.path, name: "Again") }
    }

    private let owner = RemoteOwner("github.com/HenryQW")!

    @Test func remoteOfAnotherOwnerBlocksTheBar() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try folder(base.appending(path: "repo"))
        try git("-C", repo.path, "init", "--quiet")
        let organization = UUID()
        var settings = BarSettings()
        try settings.setBar(repo.path, for: organization, projectFolders: [])
        #expect(settings.barProblem(for: organization, inspection: try inspectBarFolder(repo.path)) == .noOwner)
        settings.setOwner(owner, for: organization)
        // A bar with no remote is ready.
        #expect(settings.barProblem(for: organization, inspection: try inspectBarFolder(repo.path)) == nil)
        try git("-C", repo.path, "remote", "add", "origin", "https://github.com/HenryQW/bar.git")
        #expect(settings.barProblem(for: organization, inspection: try inspectBarFolder(repo.path)) == nil)

        let fork = BarRemote(name: "fork", url: "https://github.com/Evermark/bar.git")
        try git("-C", repo.path, "remote", "add", fork.name, fork.url)
        #expect(settings.barProblem(for: organization, inspection: try inspectBarFolder(repo.path)) == .remoteNotOwned(fork))
        try git("-C", repo.path, "remote", "remove", "fork")

        // A push target set as a URL in configuration is not listed by `git remote -v`, but is checked too.
        try git("-C", repo.path, "config", "remote.pushDefault", "https://github.com/Evermark/bar.git")
        #expect(settings.barProblem(for: organization, inspection: try inspectBarFolder(repo.path)) ==
            .remoteNotOwned(BarRemote(name: "remote.pushdefault", url: "https://github.com/Evermark/bar.git")))
        #expect(settings.barProblem(for: nil, inspection: try inspectBarFolder(repo.path)) == .noOrganization)
    }

    @Test func barMustStayItsOwnRepositoryRoot() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let outer = try folder(base.appending(path: "outer"))
        try git("-C", outer.path, "init", "--quiet")
        let inner = try folder(outer.appending(path: "bar"))
        try git("-C", inner.path, "init", "--quiet")
        let organization = UUID()
        var settings = BarSettings()
        settings.setOwner(owner, for: organization)
        try settings.setBar(inner.path, for: organization, projectFolders: [])
        #expect(settings.barProblem(for: organization, inspection: try inspectBarFolder(inner.path)) == nil)
        // Without its own repository, the folder resolves to the outer repository and must not pass.
        try FileManager.default.removeItem(at: inner.appending(path: ".git"))
        #expect(settings.barProblem(for: organization, inspection: try inspectBarFolder(inner.path)) == .notRepository)
        // A replaced folder at the same path is a new folder.
        try FileManager.default.removeItem(at: inner)
        _ = try folder(inner)
        #expect(settings.barProblem(for: organization, inspection: .noRepository) == .folderChanged)
    }

    @Test func barStaysOutsideProjectsAndServesOneOrganization() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let project = try folder(base.appending(path: "project"))
        let inside = try folder(project.appending(path: "bar"))
        let bar = try folder(base.appending(path: "bar"))
        let first = UUID(), second = UUID()
        var settings = BarSettings()
        for folder in [project, inside, base] {
            #expect(throws: BarError.barInProject(project.path)) {
                try settings.setBar(folder.path, for: first, projectFolders: [project.path])
            }
        }
        try settings.setBar(bar.path, for: first, projectFolders: [project.path])
        #expect(throws: BarError.barShared(first)) { try settings.setBar(bar.path, for: second, projectFolders: []) }
        #expect(settings.organizations[second] == nil)
        settings.removeBar(for: first)
        try settings.setBar(bar.path, for: second, projectFolders: [])
        #expect(settings.organizations[first] == nil)
    }

    @Test func displayHidesCredentialsInRemoteURLs() {
        let remote = BarRemote(name: "origin", url: "https://user:secret-token@example.invalid/team/bar.git")
        #expect(!remote.displayURL.contains("secret-token"))
        #expect(!remote.displayURL.contains("user"))
        #expect(remote.displayURL.contains("example.invalid/team/bar.git"))
        #expect(!BarProblem.remoteNotOwned(remote).message.contains("secret-token"))
    }

    @Test func storageNeedsOwnerReadyBarAndPrivateTaskFolders() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try folder(base.appending(path: "repo"))
        try createBarRepository(in: repo.path, name: "Team")
        let organization = UUID(), other = UUID()
        let store = BarSettingsStore(url: base.appending(path: "bar-settings.json"))
        #expect(store.storageProblem(for: nil) == .noOrganization)
        #expect(store.storageProblem(for: organization) == .noOwner)
        try store.update { try $0.setBar(repo.path, for: organization, projectFolders: []) }
        #expect(store.storageProblem(for: organization) == .noOwner)
        try store.update { $0.setOwner(owner, for: organization) }
        #expect(store.storageProblem(for: organization) == .taskFolderNotPrivate)
        _ = try folder(repo.appending(path: "tasks"))
        _ = try folder(repo.appending(path: barGraphFolder))
        let details = try folder(repo.appending(path: barDetailFolder))
        #expect(store.storageProblem(for: organization) == nil)
        #expect(store.storageProblem(for: other) == .noOwner)
        #expect(store.storageProblem(for: nil) == .noOrganization)
        let storage = try store.taskStorage(for: organization)
        #expect(storage.detailDirectory.path == (try resolved(details)))
        #expect(storage.graphDirectory.path == (try resolved(repo.appending(path: barGraphFolder))))

        chmod(details.path, 0o750)
        #expect(store.storageProblem(for: organization) == .taskFolderNotPrivate)
        chmod(details.path, 0o700)

        // A remote of another owner, added after setup, blocks storage until it is removed.
        try git("-C", repo.path, "remote", "add", "origin", "https://example.invalid/team/bar.git")
        #expect(store.storageProblem(for: organization) ==
            .remoteNotOwned(BarRemote(name: "origin", url: "https://example.invalid/team/bar.git")))
        try git("-C", repo.path, "remote", "remove", "origin")
        #expect(store.storageProblem(for: organization) == nil)

        var info = stat()
        #expect(stat(store.url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }

    @Test func corruptOrUnknownSettingsFailClosed() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appending(path: "bar-settings.json")
        let store = BarSettingsStore(url: url)
        let id = UUID().uuidString
        for content in ["{not json", #"{"version":1,"bar":null,"detailFolders":{}}"#, #"{"version":3,"organizations":{}}"#,
                        #"{"version":2,"organizations":{"someone":{"owner":{"host":"github.com","account":"a"}}}}"#,
                        #"{"version":2,"organizations":{"\#(id)":{"owner":{"host":"https://github.com","account":"a"}}}}"#,
                        #"{"version":2,"organizations":{"\#(id)":{}}}"#] {
            try Data(content.utf8).write(to: url)
            #expect(throws: BarError.malformedData) { try store.load() }
            #expect(throws: BarError.malformedData) { try store.update { $0.removeBar(for: UUID()) } }
            #expect(try Data(contentsOf: url) == Data(content.utf8))
            #expect(store.storageProblem(for: UUID(uuidString: id)) == .unreadableSettings)
        }
    }
}
