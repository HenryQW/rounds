import Foundation
import Testing
@testable import RoundsCore

@Test func reusesDecodedValueUntilFileChanges() throws {
    let file = try tempDir().appending(path: "a.json")
    try Data("one".utf8).write(to: file)
    let cache = FileCache<String>()
    var decodes = 0
    let decode: (Data) -> String = { decodes += 1; return String(decoding: $0, as: UTF8.self) }
    #expect(cache.value(at: file, decode: decode) == "one")
    #expect(cache.value(at: file, decode: decode) == "one")
    #expect(decodes == 1)
    try Data("two!".utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
    #expect(cache.value(at: file, decode: decode) == "two!")
    #expect(decodes == 2)
}

@Test func missingFileGivesNil() throws {
    let cache = FileCache<String>()
    #expect(cache.value(at: try tempDir().appending(path: "none")) { _ in "x" } == nil)
}

@Test func loadDesktopSessionsReusesCache() throws {
    let root = try tempDir()
    let dir = root.appending(path: "acct/org")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try fixture("session_full.json").write(to: dir.appending(path: "local_good.json"))
    let cache = FileCache<Result<DesktopSession, DesktopSessionError>>()
    #expect(loadDesktopSessions(root: root, cache: cache).sessions.count == 1)
    #expect(cache.count == 1)
    try FileManager.default.removeItem(at: dir.appending(path: "local_good.json"))
    #expect(loadDesktopSessions(root: root, cache: cache).sessions.isEmpty)
    #expect(cache.count == 0)
}
