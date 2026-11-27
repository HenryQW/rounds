import Foundation
import Testing
@testable import Rounds

@Test @MainActor
func piSourceRefreshesChangedFilesAndClearsPaneLinksWhenItsHomeDisappears() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.resolvingSymlinksInPath().appending(path: "rounds-test-\(UUID())")
    let home = root.appending(path: "agent")
    let states = root.appending(path: "states")
    let folder = home.appending(path: "sessions/project")
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let source = PiSource(home: home, stateDirectory: states, isRunning: { $0 == 401 }, paneID: { _ in "pane" })
    source.prepareStateDirectory()

    let session = folder.appending(path: "first.jsonl")
    try Data(#"{"type":"session","id":"first","cwd":"/project"}"#.utf8).write(to: session)
    try Data("1000\tworking\t\t401\t\(session.path)\n".utf8).write(to: states.appending(path: "first"))
    let initial = try #require(source.refresh(changed: [session.path], agedAfter: 3_600))
    let first = try #require(initial.rows.first)
    #expect(first.status.state == .working)
    #expect(source.paneSessions == ["pane": session.path])

    let second = folder.appending(path: "second.jsonl")
    let unseen = folder.appending(path: "unseen.jsonl")
    try Data(#"{"type":"session","id":"second","cwd":"/project"}"#.utf8).write(to: second)
    try Data(#"{"type":"session","id":"unseen","cwd":"/project"}"#.utf8).write(to: unseen)
    try Data("2000\tworking\t\t401\t\(second.path)\n".utf8).write(to: states.appending(path: "second"))
    let updated = try #require(source.refresh(changed: [second.path], agedAfter: 3_600))
    #expect(Set(updated.rows.map(\.id)) == [first.id, "pi:" + second.path])
    #expect(source.paneSessions == ["pane": second.path])

    try files.removeItem(at: home)
    #expect(source.refresh(changed: nil, agedAfter: 3_600) == nil)
    #expect(source.paneSessions.isEmpty)
    #expect(source.sessions.isEmpty)
}
