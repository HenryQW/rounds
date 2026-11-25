import Foundation
import Testing
@testable import RoundsCore
@testable import Rounds

@MainActor
private func waitUntil(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return predicate()
}

private func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "rounds-app-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test
@MainActor
func pushChannelWithMissingValuesIsNotReady() async {
    appDefaults.set([PushChannel.telegram.rawValue], forKey: "pushChannels")
    defer { appDefaults.removeObject(forKey: "pushChannels") }
    let store = PushStore()
    store.readValues = { _ in nil }
    store.prepareOrganizationDestinations()
    #expect(await waitUntil { store.status(of: .telegram) != .ready })
    #expect(store.status(of: .telegram) == .failed(PushStore.unreadable))
}

@Test
func versionOfACommandThatHangsIsEmptyAfterTheTimeout() throws {
    let base = try tempFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let script = base.appending(path: "hang")
    try "#!/bin/sh\nexec sleep 10\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let start = ContinuousClock.now
    #expect(SettingsView.version(of: script.path, timeout: 0.2) == "")
    #expect(ContinuousClock.now - start < .seconds(3))
    #expect(SettingsView.version(of: base.appending(path: "missing").path) == "not found")
}

@Test
func linearBatchNeedsAGrant() throws {
    let base = try tempFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = base.appending(path: "project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let store = OrganizationPolicyStore(url: base.appending(path: "policy.json"))
    var organization = UUID()
    try store.update { policy in
        organization = try policy.addOrganization(name: "Team")
        try policy.addRule(organizationID: organization, match: .directory(project.path))
    }
    let destination = try #require(makeOrganizationDestination(service: "ticket-linear", fields: ["key": "test"],
                                                                title: "Linear", detail: "test"))
    let lookup = Lookup.branch("feature")
    #expect(linearBatch([lookup], folders: [lookup: [project.path]], policy: try store.load(), destination: destination).isEmpty)
    try store.update { try $0.grant(organizationID: organization, service: destination.service, destinationIdentity: destination.identity) }
    #expect(linearBatch([lookup], folders: [lookup: [project.path]], policy: try store.load(), destination: destination) == [lookup])
}
