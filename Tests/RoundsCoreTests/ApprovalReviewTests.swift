import Foundation
import Testing
@testable import RoundsCore

@Suite struct ApprovalReviewTests {
    @discardableResult
    private func git(_ repository: URL, _ arguments: String...) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "approval-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(root, "init", "--quiet", "--initial-branch=main")
        try git(root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--allow-empty", "--no-gpg-sign", "-m", "Fixture")
        try git(root, "remote", "add", "origin", "https://example.invalid/team/repo.git")
        return root
    }

    @Test func freeTextRejectsCredentialsWithDelimiters() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try inspectApprovalSnapshot(repository: root, sourceRef: "refs/heads/main", remote: "origin")
        let taskID = UUID(), now = Date()
        for address in ["https://user:pa'ss@example.invalid/repo", "https://user:pa(ss)@example.invalid/repo",
                        "https://user:pa\"ss@example.invalid/repo", "ssh://user:pa'ss@example.invalid/repo",
                        "ftp://user:pa(ss)@example.invalid/repo"] {
            let text = "Review [link](\(address))."
            for draft in [ApprovalDraft(title: text, body: "Fixture"), ApprovalDraft(title: "Fixture", body: text)] {
                let action = ApprovalAction(intent: .draftPullRequest(
                    repository: "example.invalid/team/repo", baseRef: "refs/heads/other", headRef: "refs/heads/main",
                    revision: snapshot.revision, draft: draft))
                let request = ApprovalRequest(id: UUID(), taskID: taskID, repositoryID: UUID(), organizationID: nil,
                                              resultRevisionID: UUID(), resultDigest: String(repeating: "a", count: 64),
                                              snapshot: snapshot, actions: [action], createdAt: now, checkedAt: now, harnessBinding: nil)
                #expect(throws: ApprovalError.credentialAddressInText) { try request.validate(taskID: taskID) }
            }
            #expect(throws: ApprovalError.credentialAddressInText) {
                try ApprovalDecision.rejected(reason: text).normalized()
            }
        }
        #expect(try ApprovalDecision.rejected(reason: "Review ssh://git@example.invalid/repo.").normalized() ==
                .rejected(reason: "Review ssh://git@example.invalid/repo."))
    }

    @Test func snapshotRejectsCustomRemoteHelpers() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try inspectApprovalSnapshot(repository: root, sourceRef: "refs/heads/main", remote: "origin")
        try git(root, "config", "remote.origin.vcs", "fixture")
        #expect(throws: ApprovalError.snapshotUnavailable) {
            try inspectApprovalSnapshot(repository: root, sourceRef: before.sourceRef, remote: before.remote)
        }
        try git(root, "config", "--unset", "remote.origin.vcs")
        #expect(try inspectApprovalSnapshot(repository: root, sourceRef: before.sourceRef, remote: before.remote) == before)
        try git(root, "config", "remote.other.vcs", "")
        #expect(throws: ApprovalError.snapshotUnavailable) {
            try inspectApprovalSnapshot(repository: root, sourceRef: before.sourceRef, remote: before.remote)
        }
    }
}
