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
func barCheckEndsWhenSettingsChangeDuringTheCheck() async throws {
    let base = try tempFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let bar = base.appending(path: "bar")
    try FileManager.default.createDirectory(at: bar, withIntermediateDirectories: true)
    let id = UUID()
    _ = try BarSettingsStore(url: base.appending(path: "bar-settings.json")).update { settings in
        settings.setOwner(RemoteOwner("github.com/first"), for: id)
        try settings.setBar(bar.path, for: id, projectFolders: [])
    }
    let state = BarSettingsState(directory: base)
    #expect(state.checks[id] == .checking)
    // The change lands before the background check returns.
    _ = try state.store.update { $0.setOwner(RemoteOwner("github.com/second"), for: id) }
    state.reload()
    #expect(await waitUntil { state.checks[id] != .checking })
    #expect(state.checks[id] == .done(.notRepository))
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
