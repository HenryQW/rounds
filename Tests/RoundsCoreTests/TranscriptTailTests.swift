import Foundation
import Testing
@testable import RoundsCore

private func entry(_ type: String, _ message: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["type": type, "message": message])
    return String(decoding: data, as: UTF8.self)
}
private func user(_ text: String) -> String { entry("user", ["role": "user", "content": text]) }
private func assistantText(_ text: String, stop: String = "end_turn") -> String {
    entry("assistant", ["role": "assistant", "stop_reason": stop, "content": [["type": "text", "text": text]]])
}
private func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> String {
    entry("assistant", ["role": "assistant", "stop_reason": "tool_use", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]])
}
private func toolResult(_ id: String) -> String {
    entry("user", ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]])
}
private let noise = #"{"type":"attachment","attachment":{}}"# + "\n" + #"{"type":"cost-state"}"#
private func tail(_ lines: [String]) -> LastMessage { LastMessage.parse(Data((lines.joined(separator: "\n") + "\n").utf8)) }

@Test func endTurnIsDetected() {
    let t = tail([user("hi"), assistantText("All done."), noise])
    #expect(t == .endTurn)
}

@Test func interruptMarkerIsDetected() {
    #expect(tail([toolUse("t1", "Bash", ["command": "sleep 30"]), toolResult("t1"), user("[Request interrupted by user for tool use]")]) == .interrupted)
    let listForm = entry("user", ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]])
    #expect(tail([assistantText("x"), listForm]) == .interrupted)
}

@Test func otherLastMessageIsInProgress() {
    #expect(tail([user("do it")]) == .inProgress)
    #expect(tail([assistantText("thinking", stop: "tool_use")]) == .inProgress)
}

@Test func noMessagesIsUnknown() {
    #expect(tail([noise]) == .unknown)
}

@Test func oversizedLastLineIsUnknown() throws {
    let file = try tempDir().appending(path: "t.jsonl")
    let big = assistantText(String(repeating: "x", count: 100_000))
    try Data((user("hi") + "\n" + big + "\n").utf8).write(to: file)
    let t = LastMessage.parse(readTail(file))
    #expect(t == .unknown)
}

@Test func smallFileReadsWhole() throws {
    let file = try tempDir().appending(path: "t.jsonl")
    try Data((assistantText("only") + "\n").utf8).write(to: file)
    #expect(LastMessage.parse(readTail(file)) == .endTurn)
}

@Test func findsTranscriptBySimpleEncoding() throws {
    let root = try tempDir()
    let dir = root.appending(path: "-Users-test-proj--claude-wt")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data().write(to: dir.appending(path: "abc.jsonl"))
    #expect(transcriptURL(cwd: "/Users/test/proj/.claude/wt", cliSessionId: "abc", projectsRoot: root)?.deletingLastPathComponent().lastPathComponent == dir.lastPathComponent)
}

@Test func findsTranscriptWhenFolderNameDiffers() throws {
    let root = try tempDir()
    let dir = root.appending(path: "something-else")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data().write(to: dir.appending(path: "abc.jsonl"))
    #expect(transcriptURL(cwd: "/Users/test/my proj_x", cliSessionId: "abc", projectsRoot: root)?.lastPathComponent == "abc.jsonl")
    #expect(transcriptURL(cwd: "/Users/test/none", cliSessionId: "zzz", projectsRoot: root) == nil)
}


@Test func wrapUpQuestionIsDetected() {
    let wrap = "mcp__ccd_turn__wrap_up"
    #expect(tail([user("go"), toolUse("w1", wrap, ["recap": "r", "ask": "Commit now?"]), toolResult("w1"), assistantText("Done.")]) == .question)
    // No question, or a newer prompt after it: the turn just ended.
    #expect(tail([user("go"), toolUse("w1", wrap, ["recap": "r"]), toolResult("w1"), assistantText("Done.")]) == .endTurn)
    #expect(tail([toolUse("w1", wrap, ["recap": "r", "ask": "Commit now?"]), toolResult("w1"), assistantText("Done."),
                  user("yes"), assistantText("Committed.")]) == .endTurn)
}
