import Foundation
import Testing
@testable import RoundsCore

private func row(_ state: SessionState = .needsInput, id: String = "s1", detail: String = "", since: Double = 0,
                 cwd: String = "/Users/test/atlas", seen: Bool = false) -> SessionRow {
    let d: [String: Any] = ["sessionId": id, "cliSessionId": id, "cwd": cwd, "title": "Fix login", "isArchived": false, "lastActivityAt": 0]
    let s = try! DesktopSession(json: JSONSerialization.data(withJSONObject: d))
    var r = SessionRow(session: s, status: SessionStatus(state, detail, since: Date(timeIntervalSince1970: since)))
    r.isSeen = seen
    return r
}

private func json(_ request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@Test func messageFromRow() {
    #expect(PushMessage(row(detail: "Permission: Bash")) == PushMessage(title: "Needs input: Fix login", body: "Permission: Bash in atlas", urgent: true))
    #expect(PushMessage(row(.ready)) == PushMessage(title: "Ready: Fix login", body: "In atlas", urgent: false))
    #expect(PushMessage(row(.failed, cwd: "")).body == "")
    #expect(PushMessage(row(.failed)).urgent)
}

private let message = PushMessage(title: "Needs input: Fix login", body: "In atlas", urgent: true)

@Test func telegramRequest() throws {
    let r = try PushChannel.telegram.request(for: message, values: ["token": "123:abc", "chat": "42"])
    #expect(r.url?.absoluteString == "https://api.telegram.org/bot123:abc/sendMessage")
    #expect(r.httpMethod == "POST")
    #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try json(r)
    #expect(body["chat_id"] as? String == "42")
    #expect(body["text"] as? String == "Needs input: Fix login\nIn atlas")
    #expect(body["disable_web_page_preview"] as? Bool == true)
    #expect(body["parse_mode"] == nil)
}

@Test func barkRequest() throws {
    let r = try PushChannel.bark.request(for: message, values: ["key": "dev", "server": "https://bark.example.com/"])
    #expect(r.url?.absoluteString == "https://bark.example.com/push")
    let body = try json(r)
    #expect(body["device_key"] as? String == "dev")
    #expect(body["title"] as? String == "Needs input: Fix login")
    #expect(body["body"] as? String == "In atlas")
    #expect(body["group"] as? String == "Rounds")
    #expect(body["level"] as? String == "timeSensitive")
    // The server has a default; a quiet message is active.
    let quiet = try PushChannel.bark.request(for: PushMessage(title: "t", body: "b", urgent: false), values: ["key": "dev"])
    #expect(quiet.url?.absoluteString == "https://api.day.app/push")
    #expect(try json(quiet)["level"] as? String == "active")
}

@Test func missingOrBadValuesThrow() {
    #expect(throws: PushError.missing("Chat ID")) { try PushChannel.telegram.request(for: message, values: ["token": "123:abc", "chat": " "]) }
    #expect(throws: PushError.missing("Device key")) { try PushChannel.bark.request(for: message, values: [:]) }
    // A token is part of the URL path: a slash would change the path.
    #expect(throws: PushError.invalid("Bot token")) { try PushChannel.telegram.request(for: message, values: ["token": "1/../x", "chat": "42"]) }
    #expect(throws: PushError.invalid("Server")) { try PushChannel.bark.request(for: message, values: ["key": "dev", "server": "api.day.app"]) }
}

@Test func failureText() {
    #expect(PushChannel.telegram.failure(status: 200, body: Data(#"{"ok":true,"result":{}}"#.utf8)) == nil)
    #expect(PushChannel.telegram.failure(status: 400, body: Data(#"{"ok":false,"description":"Bad Request: chat not found"}"#.utf8)) == "Bad Request: chat not found")
    #expect(PushChannel.bark.failure(status: 200, body: Data(#"{"code":200,"message":"success"}"#.utf8)) == nil)
    #expect(PushChannel.bark.failure(status: 400, body: Data(#"{"code":400,"message":"failed to get device token"}"#.utf8)) == "failed to get device token")
    #expect(PushChannel.bark.failure(status: 502, body: Data("<html>".utf8)) == "HTTP 502")
}

private let all: Set<SessionState> = [.needsInput, .failed, .ready]

@Test func firstCheckOnlyLearns() {
    var q = PushQueue()
    #expect(q.check([row()], states: all, idle: 999, awayMinutes: 0).isEmpty)
    #expect(q.check([row()], states: all, idle: 999, awayMinutes: 0).isEmpty)
}

@Test func newEventWaitsUntilAwayThenSendsOnce() {
    var q = PushQueue()
    _ = q.check([], states: all, idle: 0, awayMinutes: 2)
    #expect(q.check([row()], states: all, idle: 10, awayMinutes: 2).isEmpty)
    #expect(q.check([row()], states: all, idle: 119, awayMinutes: 2).isEmpty)
    #expect(q.check([row()], states: all, idle: 120, awayMinutes: 2).map(\.id) == ["s1"])
    #expect(q.check([row()], states: all, idle: 500, awayMinutes: 2).isEmpty)
}

@Test func seenOrChangedEventIsDropped() {
    var q = PushQueue()
    _ = q.check([], states: all, idle: 0, awayMinutes: 2)
    _ = q.check([row(id: "a"), row(id: "b")], states: all, idle: 0, awayMinutes: 2)
    // "a" is seen; "b" goes on working, then waits again with a new since.
    _ = q.check([row(id: "a", seen: true), row(.working, id: "b")], states: all, idle: 0, awayMinutes: 2)
    #expect(q.check([row(id: "a"), row(id: "b", since: 5)], states: all, idle: 999, awayMinutes: 2).map(\.id) == ["b"])
}

@Test func zeroMinutesSendsAtOnce() {
    var q = PushQueue()
    _ = q.check([], states: all, idle: 0, awayMinutes: 0)
    #expect(q.check([row()], states: all, idle: 0, awayMinutes: 0).map(\.id) == ["s1"])
}

@Test func stateNotChosenNeverSends() {
    var q = PushQueue()
    _ = q.check([], states: [.needsInput], idle: 0, awayMinutes: 0)
    #expect(q.check([row(.ready)], states: [.needsInput], idle: 999, awayMinutes: 0).isEmpty)
}

@Test func staleBannersAreSeenChangedOrGone() {
    let sent = [row(id: "a"), row(id: "b"), row(id: "c"), row(id: "d"), row(id: "e")]
    // "a" is still current; "b" is seen; "c" waits again with a new since; "d" works; "e" is gone.
    let now = [row(id: "a"), row(id: "b", seen: true), row(id: "c", since: 5), row(.working, id: "d")]
    #expect(PushQueue.stale(sent, in: now).map(\.id) == ["b", "c", "d", "e"])
}
