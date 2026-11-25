import Darwin
import Foundation
import Synchronization
import Testing
@testable import RoundsCore

@Suite struct OrganizationPolicyTests {
    private let remote = "git@github.com:team/project.git"

    @Test func independentOrganizationsPersistAndRequireExactGrants() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let firstFolder = base.appending(path: "first")
        let secondFolder = base.appending(path: "second")
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let store = OrganizationPolicyStore(url: base.appending(path: "policy.json"))
        var first = UUID(), second = UUID()
        try store.update { policy in
            first = try policy.addOrganization(name: "First")
            second = try policy.addOrganization(name: "Second")
            try policy.addRule(organizationID: first, match: .directory(firstFolder.path))
            try policy.addRule(organizationID: second, match: .directory(secondFolder.path))
            try policy.grant(organizationID: first, service: "linear", destinationIdentity: "workspace:first")
            try policy.grant(organizationID: second, service: "bark", destinationIdentity: "device:second")
        }
        let policy = try store.load()
        #expect(policy.organizations.map(\.id) == [first, second])
        #expect(policy.classify(sessionDirectory: firstFolder.path, gitRemote: .absent) == .classified(organizationID: first.uuidString))
        #expect(policy.allowsTransmission(sessionDirectory: firstFolder.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:first"))
        #expect(!policy.allowsTransmission(sessionDirectory: secondFolder.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:first"))
        #expect(policy.allowsTransmission(sessionDirectory: secondFolder.path, gitRemote: .absent, service: "bark", destinationIdentity: "device:second"))
        #expect(!policy.allowsTransmission(sessionDirectory: firstFolder.path, gitRemote: .absent, service: "bark", destinationIdentity: "device:second"))
        #expect(!policy.allowsTransmission(sessionDirectory: base.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:first"))

        try store.update { policy in try policy.renameOrganization(id: first, name: "Renamed") }
        let renamed = try store.load()
        #expect(renamed.organizations.first?.id == first)
        #expect(renamed.organizations.first?.name == "Renamed")
        #expect(renamed.allowsTransmission(sessionDirectory: firstFolder.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:first"))
    }

    @Test func destinationsMustBeConcreteAndRevocationPersists() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = OrganizationPolicyStore(url: base.appending(path: "policy.json"))
        var id = UUID()
        try store.update { policy in
            id = try policy.addOrganization(name: "Team")
            try policy.addRule(organizationID: id, match: .directory(base.path))
            try policy.grant(organizationID: id, service: "linear", destinationIdentity: "workspace:one")
            #expect(throws: OrganizationPolicyError.invalidDestination) {
                try policy.grant(organizationID: id, service: "linear", destinationIdentity: "")
            }
            #expect(throws: OrganizationPolicyError.invalidDestination) {
                try policy.grant(organizationID: id, service: "linear", destinationIdentity: "https://example.com/key")
            }
        }
        var policy = try store.load()
        for destination: String? in [nil, "", "workspace:two", "Workspace:one"] {
            #expect(!policy.allowsTransmission(sessionDirectory: base.path, gitRemote: .absent, service: "linear", destinationIdentity: destination))
        }
        #expect(!policy.allowsTransmission(sessionDirectory: base.path, gitRemote: .absent, service: "bark", destinationIdentity: "workspace:one"))
        try store.update { policy in try policy.revoke(organizationID: id, service: "linear", destinationIdentity: "workspace:one") }
        policy = try store.load()
        #expect(!policy.allowsTransmission(sessionDirectory: base.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:one"))
        try store.update { policy in try policy.removeOrganization(id: id) }
        policy = try store.load()
        #expect(policy.organizations.isEmpty && policy.rules.isEmpty && policy.grants.isEmpty)
    }

    @Test func onlyOneInstanceMayUseCachedDestinations() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = OrganizationPolicyStore(url: base.appending(path: "policy.json"))
        let second = OrganizationPolicyStore(url: base.appending(path: "policy.json"))
        var lease: OrganizationPolicyLease? = try first.acquireLease()
        #expect(lease != nil)
        #expect(throws: OrganizationPolicyError.anotherInstance) { try second.acquireLease() }
        lease = nil
        let next = try second.acquireLease()
        withExtendedLifetime(next) {}
    }

    @Test func changingDestinationRemovesEarlierConsent() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = OrganizationPolicyStore(url: base.appending(path: "policy.json"))
        var id = UUID()
        try store.update { policy in
            id = try policy.addOrganization(name: "Team")
            try policy.addRule(organizationID: id, match: .directory(base.path))
            try policy.grant(organizationID: id, service: "github", destinationIdentity: "account:first")
            try policy.grant(organizationID: id, service: "linear", destinationIdentity: "workspace:one")
        }
        try store.update { $0.retainGrants(service: "github", destinationIdentity: "account:second") }
        var policy = try store.load()
        #expect(!policy.allowsTransmission(sessionDirectory: base.path, gitRemote: .absent, service: "github", destinationIdentity: "account:first"))
        #expect(!policy.allowsTransmission(sessionDirectory: base.path, gitRemote: .absent, service: "github", destinationIdentity: "account:second"))
        #expect(policy.allowsTransmission(sessionDirectory: base.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:one"))
        try store.update { try $0.grant(organizationID: id, service: "github", destinationIdentity: "account:second") }
        try store.update { $0.revokeAll(service: "github") }
        policy = try store.load()
        #expect(!policy.allowsTransmission(sessionDirectory: base.path, gitRemote: .absent, service: "github", destinationIdentity: "account:first"))
        #expect(!policy.allowsTransmission(sessionDirectory: base.path, gitRemote: .absent, service: "github", destinationIdentity: "account:second"))
    }

    @Test func conflictsUnknownInputsAndInvalidRulesDenyTransmission() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appending(path: "project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var policy = OrganizationPolicy()
        let first = try policy.addOrganization(name: "First")
        let second = try policy.addOrganization(name: "Second")
        try policy.addRule(organizationID: first, match: .directory(folder.path))
        try policy.addRule(organizationID: second, match: .gitRemote(remote))
        try policy.grant(organizationID: first, service: "linear", destinationIdentity: "workspace:one")
        #expect(policy.classify(sessionDirectory: folder.path, gitRemote: .observed([remote])) == .localOnly(.conflicting))
        #expect(!policy.allowsTransmission(sessionDirectory: folder.path, gitRemote: .observed([remote]), service: "linear", destinationIdentity: "workspace:one"))
        #expect(!policy.allowsTransmission(sessionDirectory: folder.path, gitRemote: .unknown, service: "linear", destinationIdentity: "workspace:one"))
        #expect(!policy.allowsTransmission(sessionDirectory: nil, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:one"))
        #expect(policy.allowsTransmission(sessionDirectory: folder.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:one"))
        #expect(throws: OrganizationPolicyError.invalidRule) {
            try policy.addRule(organizationID: first, match: .gitRemote("https://user:invalid-credential@example.com/repo"))
        }
        #expect(throws: OrganizationPolicyError.invalidRule) {
            try policy.addRule(organizationID: first, match: .gitRemote("git@example.com:team/repo?token=example"))
        }
        try FileManager.default.removeItem(at: folder)
        #expect(policy.classify(sessionDirectory: base.path, gitRemote: .absent) == .localOnly(.invalidRule))
        #expect(!policy.allowsTransmission(sessionDirectory: base.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:one"))
        try policy.removeRule(organizationID: first, match: .directory(folder.path))
    }

    @Test func exactRemoteRulesPersistAndUnknownRemotesDeny() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = OrganizationPolicyStore(url: base.appending(path: "policy.json"))
        try store.update { policy in
            let id = try policy.addOrganization(name: "Team")
            try policy.addRule(organizationID: id, match: .gitRemote(remote))
            try policy.grant(organizationID: id, service: "linear", destinationIdentity: "workspace:one")
        }
        let policy = try store.load()
        #expect(policy.allowsTransmission(sessionDirectory: nil, gitRemote: .observed([remote]), service: "linear", destinationIdentity: "workspace:one"))
        #expect(!policy.allowsTransmission(sessionDirectory: nil, gitRemote: .observed(["git@github.com:Team/project.git"]), service: "linear", destinationIdentity: "workspace:one"))
        #expect(!policy.allowsTransmission(sessionDirectory: nil, gitRemote: .unknown, service: "linear", destinationIdentity: "workspace:one"))
    }

    @Test func malformedStoredDataNeverGetsOverwritten() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appending(path: "policy.json")
        let store = OrganizationPolicyStore(url: url)
        let id = UUID().uuidString
        let other = UUID().uuidString
        let prefix = "[1,"
        let badDocuments = [
            "", "{\"version\":1,\"version\":1}", "[2,[],[],[]]", prefix + "[],[],[],0]",
            prefix + "[[\"\(id)\",\"Team\"],[\"\(id)\",\"Other\"]],[],[]]",
            prefix + "[[\"\(id)\",\"Team\"],[\"\(other)\",\"team\"]],[],[]]",
            prefix + "[[\"\(id)\",\"Team\"]],[[\"\(other)\",\"directory\",\"/tmp\",\"/private/tmp\",\"1\",\"1\"]],[]]",
            prefix + "[[\"\(id)\",\"Team\"]],[[\"\(id)\",\"directory\",\"relative\",\"/private/tmp\",\"1\",\"1\"]],[]]",
            prefix + "[[\"\(id)\",\"Team\"]],[[\"\(id)\",\"gitRemote\",\"https://user:invalid-credential@example.com/repo\",\"\",\"\",\"\"]],[]]",
            prefix + "[[\"\(id)\",\"Team\"]],[],[[\"\(id)\",\"linear\",\"\"]]]",
            prefix + "[[\"\(id)\",\"Team\"]],[],[[\"\(id)\",\"linear\",\"workspace:one\"],[\"\(id)\",\"linear\",\"workspace:one\"]]]",
        ]
        for document in badDocuments {
            let original = Data(document.utf8)
            try original.write(to: url)
            #expect(throws: OrganizationPolicyError.malformedData) { try store.load() }
            var called = false
            #expect(throws: OrganizationPolicyError.malformedData) {
                try store.update { _ in called = true }
            }
            #expect(!called)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func damagedSnapshotAndNonRegularFilesFailClosed() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appending(path: "policy.json")
        let store = OrganizationPolicyStore(url: url)
        try store.update { policy in _ = try policy.addOrganization(name: "Team") }
        try store.update { policy in _ = try policy.addOrganization(name: "Other") }
        let snapshot = try Data(contentsOf: url)
        let corrupted = Data(snapshot.prefix(snapshot.count / 2))
        try corrupted.write(to: url)
        #expect(throws: OrganizationPolicyError.malformedData) { try store.load() }
        #expect(throws: OrganizationPolicyError.malformedData) { try store.update { _ in } }
        #expect(try Data(contentsOf: url) == corrupted)

        let fifo = base.appending(path: "fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let pipeStore = OrganizationPolicyStore(url: fifo)
        #expect(throws: OrganizationPolicyError.invalidFile) { try pipeStore.load() }
        #expect(throws: OrganizationPolicyError.invalidFile) { try pipeStore.update { _ in } }
    }

    @Test func retargetedDirectoryAndHardLinkedPolicyFailClosed() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appending(path: "first")
        let second = base.appending(path: "second")
        let alias = base.appending(path: "project")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let url = base.appending(path: "policy.json")
        let store = OrganizationPolicyStore(url: url)
        try store.update { policy in
            let id = try policy.addOrganization(name: "Team")
            try policy.addRule(organizationID: id, match: .directory(alias.path))
            try policy.grant(organizationID: id, service: "linear", destinationIdentity: "workspace:one")
        }
        #expect(try store.load().allowsTransmission(sessionDirectory: first.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:one"))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        #expect(!(try store.load()).allowsTransmission(sessionDirectory: second.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:one"))
        let linked = base.appending(path: "linked.json")
        try FileManager.default.linkItem(at: url, to: linked)
        #expect(throws: OrganizationPolicyError.invalidFile) { try store.load() }
        #expect(throws: OrganizationPolicyError.invalidFile) { try OrganizationPolicyStore(url: linked).load() }
    }

    @Test func keepingParentLocalAlsoKeepsAssignedChildrenLocal() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let parent = base.appending(path: "parent"), child = parent.appending(path: "child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        var policy = OrganizationPolicy()
        let personal = try policy.addOrganization(name: "Personal")
        let work = try policy.addOrganization(name: "Work")
        try policy.addRule(organizationID: personal, match: .directory(parent.path))
        try policy.addRule(organizationID: work, match: .directory(child.path))
        try policy.grant(organizationID: personal, service: "linear", destinationIdentity: "workspace:personal")
        try policy.grant(organizationID: work, service: "linear", destinationIdentity: "workspace:work")
        try policy.assignDirectory(parent.path, to: nil)
        #expect(policy.rules.isEmpty)
        #expect(!policy.allowsTransmission(sessionDirectory: child.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:work"))
    }

    @Test func removingRetargetedSymlinkRuleUsesOriginalPath() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appending(path: "first"), second = base.appending(path: "second"), alias = base.appending(path: "alias")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        var policy = OrganizationPolicy()
        let id = try policy.addOrganization(name: "Team")
        try policy.addRule(organizationID: id, match: .directory(alias.path))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        try policy.assignDirectory(alias.path, to: nil)
        #expect(policy.rules.isEmpty)
    }

    @Test func replacedProjectDoesNotInheritGrant() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let project = base.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var policy = OrganizationPolicy()
        let id = try policy.addOrganization(name: "Team")
        try policy.addRule(organizationID: id, match: .directory(project.path))
        try policy.grant(organizationID: id, service: "linear", destinationIdentity: "workspace:one")
        #expect(policy.allowsTransmission(sessionDirectory: project.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:one"))
        try FileManager.default.moveItem(at: project, to: base.appending(path: "original"))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        #expect(!policy.allowsTransmission(sessionDirectory: project.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:one"))
    }

    @Test func interruptedWriteBlocksSendsUntilUserResetsPermissions() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = OrganizationPolicyStore(url: base.appending(path: "policy.json"))
        var id = UUID()
        try store.update {
            id = try $0.addOrganization(name: "Team")
            try $0.addRule(organizationID: id, match: .directory(base.path))
            try $0.grant(organizationID: id, service: "linear", destinationIdentity: "workspace:one")
        }
        try Data([1]).write(to: store.url.appendingPathExtension("lock"))
        #expect(throws: OrganizationPolicyError.interruptedWrite) { try store.load() }
        #expect(throws: OrganizationPolicyError.interruptedWrite) { try store.update { _ in } }
        try store.recoverInterruptedWrite()
        let recovered = try store.load()
        #expect(recovered.organizations.count == 1)
        #expect(recovered.rules.count == 1)
        #expect(!recovered.allowsTransmission(sessionDirectory: base.path, gitRemote: .absent, service: "linear", destinationIdentity: "workspace:one"))
    }

    @Test func revocationWaitsUntilAuthorizedOperationStarts() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = OrganizationPolicyStore(url: base.appending(path: "policy.json"))
        var created = UUID()
        try store.update {
            created = try $0.addOrganization(name: "Team")
            try $0.grant(organizationID: created, service: "linear", destinationIdentity: "workspace:one")
        }
        let id = created
        let holding = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), revoked = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? store.withPolicy { _ in holding.signal(); release.wait() }
        }
        #expect(holding.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async {
            try? store.update { try $0.revoke(organizationID: id, service: "linear", destinationIdentity: "workspace:one") }
            revoked.signal()
        }
        #expect(revoked.wait(timeout: .now() + 0.1) == .timedOut)
        release.signal()
        #expect(revoked.wait(timeout: .now() + 5) == .success)
        #expect(try store.load().grants.isEmpty)
    }

    @Test func concurrentStoresSerializeMutations() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = OrganizationPolicyStore(url: base.appending(path: "policy.json"))
        let errors = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do {
                try store.update { policy in _ = try policy.addOrganization(name: "Team \(index)") }
            } catch {
                errors.withLock { $0.append(String(describing: error)) }
            }
        }
        #expect(errors.withLock { $0.isEmpty })
        #expect(try store.load().organizations.count == 12)
    }

    @Test func failedMutationsAndExternalChangesDoNotOverwriteData() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appending(path: "policy.json")
        let store = OrganizationPolicyStore(url: url)
        try store.update { policy in _ = try policy.addOrganization(name: "Team") }
        let original = try Data(contentsOf: url)
        #expect(throws: OrganizationPolicyError.duplicateOrganization) {
            try store.update { policy in _ = try policy.addOrganization(name: "team") }
        }
        #expect(try Data(contentsOf: url) == original)
        let corrupt = Data("corrupt".utf8)
        #expect(throws: OrganizationPolicyError.changedOnDisk) {
            try store.update { policy in
                _ = try policy.addOrganization(name: "Other")
                try corrupt.write(to: url)
            }
        }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func firstSaveLeavesOneLinkAndRefusesAFileMadeMeanwhile() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appending(path: "policy.json")
        let store = OrganizationPolicyStore(url: url)
        try store.update { policy in _ = try policy.addOrganization(name: "Team") }
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.referenceCount] as? Int == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".tmp") }.isEmpty)
        let other = base.appending(path: "other.json")
        let made = Data("made".utf8)
        #expect(throws: OrganizationPolicyError.changedOnDisk) {
            try OrganizationPolicyStore(url: other).update { policy in
                _ = try policy.addOrganization(name: "Team")
                try made.write(to: other)
            }
        }
        #expect(try Data(contentsOf: other) == made)
    }
}
