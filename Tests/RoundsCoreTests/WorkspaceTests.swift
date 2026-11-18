import Darwin
import Foundation
import Testing
@testable import RoundsCore

@Suite struct WorkspaceTests {
    private func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
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
