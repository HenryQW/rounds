import Foundation
import Testing
@testable import RoundsCore

private func write(_ dir: URL, _ name: String, _ text: String) throws { try text.write(to: dir.appending(path: name), atomically: true, encoding: .utf8) }
private func names(_ dir: URL) -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []) }

@Test func deletesUnknownKeepsLive() throws {
    let dir = try tempDir()
    try write(dir, "live", "1\tStop\t\t\t\n")
    try write(dir, "gone", "1\tStop\t\t\t\n")
    pruneStateFiles(dir: dir, liveIds: ["live"])
    #expect(names(dir) == ["live"])
}

@Test func unknownLiveSetDeletesNothing() throws {
    let dir = try tempDir()
    try write(dir, "a", "1\tStop\t\t\t\n")
    pruneStateFiles(dir: dir, liveIds: nil)
    #expect(names(dir) == ["a"])
}

@Test func shrinksLargeFileToLastLines() throws {
    let dir = try tempDir()
    var text = "100\tStop\t\t2\t*/5 * * * *\n"
    for i in 0..<3000 { text += "\(200 + i)\tPreToolUse\tBash\t\t\n" }
    try write(dir, "s", text)
    pruneStateFiles(dir: dir, liveIds: nil, maxBytes: 1024)
    let kept = try String(contentsOf: dir.appending(path: "s"), encoding: .utf8)
    // The newest 64 lines, as they were: a permission request that waits stays with its rule.
    #expect(kept == (2936..<3000).map { "\(200 + $0)\tPreToolUse\tBash\t\t\n" }.joined())
    #expect(HookState.parse(kept)?.last.at == Date(timeIntervalSince1970: 3.199))
}
