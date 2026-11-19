import Foundation
import Testing
@testable import RoundsCore

private func json(_ data: Data) throws -> [String: Any] {
    #expect(data.last == 0x0A)
    return try #require(try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
}

@Test func framerWaitsForTheWholeRecord() {
    var framer = PiRPCFramer()
    #expect(framer.feed(Data(#"{"type":"agent_"#.utf8)).isEmpty)
    #expect(framer.feed(Data("start\"}\n".utf8)) == [Data(#"{"type":"agent_start"}"#.utf8)])
}

@Test func framerDropsTheCarriageReturnBeforeLineFeed() throws {
    var framer = PiRPCFramer()
    let lines = framer.feed(Data("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"Hi\"}}\r\n".utf8))
    #expect(lines.count == 1 && lines[0].last != 0x0D)
    #expect(decodePiRPC(try #require(lines.first)) == .event(.textDelta("Hi")))
}

@Test func unicodeLineSeparatorIsNotARecordBoundary() throws {
    var framer = PiRPCFramer()
    let lines = framer.feed(Data("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"a\u{2028}b\u{2029}c\"}}\n".utf8))
    #expect(lines.count == 1)
    #expect(decodePiRPC(try #require(lines.first)) == .event(.textDelta("a\u{2028}b\u{2029}c")))
}

@Test func malformedLineDoesNotStopTheNextOne() {
    var framer = PiRPCFramer()
    let lines = framer.feed(Data("{\"type\":\n{\"type\":\"agent_settled\",\"aborted\":false}\n".utf8))
    #expect(lines.count == 2)
    guard case .malformed = decodePiRPC(lines[0]) else { Issue.record("not malformed"); return }
    #expect(decodePiRPC(lines[1]) == .event(.replying(false)))
}

@Test func piDialogIsAQuestionNeverAnApproval() {
    let line = #"{"type":"extension_ui_request","id":"u1","method":"select","title":"Approve 4 actions","options":["Approve","Reject","Later"],"timeout":10000}"#
    let record = decodePiRPC(Data(line.utf8))
    let question = BouncerQuestion(id: "pi-ui-u1", title: "Approve 4 actions", options: ["Approve", "Reject", "Later"])
    #expect(record == .uiRequest(question, timeoutMs: 10000))
}

@Test func piDialogDoesNotReplaceACardWithTheSameID() throws {
    let card = ApprovalCard(id: "a1", taskID: "t1", title: "Push", actions: ["git push"], checkedAt: Date(timeIntervalSince1970: 0))
    var thread = BouncerThread(items: [.approval(card)])
    let line = #"{"type":"extension_ui_request","id":"a1","method":"select","title":"Pick","options":["A","B"]}"#
    guard case .uiRequest(let question, _) = decodePiRPC(Data(line.utf8)) else { Issue.record("no question"); return }
    thread.apply(.item(.question(question)))
    #expect(thread.items.first == .approval(card) && thread.waitingCount == 2)
    // The response goes back with Pi's own id.
    #expect(try json(encodePiRPC(.uiResponse(question, .option(0))))["id"] as? String == "a1")
}

@Test func dialogKindsBecomeQuestions() {
    #expect(decodePiRPC(Data(#"{"type":"extension_ui_request","id":"c","method":"confirm","title":"Clear?","message":"All lost."}"#.utf8))
        == .uiRequest(BouncerQuestion(id: "pi-ui-c", title: "Clear?\nAll lost.", options: ["Yes", "No"], confirms: true), timeoutMs: nil))
    #expect(decodePiRPC(Data(#"{"type":"extension_ui_request","id":"e","method":"editor","title":"Edit","prefill":"x"}"#.utf8))
        == .uiRequest(BouncerQuestion(id: "pi-ui-e", title: "Edit", takesText: true), timeoutMs: nil))
    #expect(decodePiRPC(Data(#"{"type":"extension_ui_request","id":"n","method":"notify","message":"Blocked"}"#.utf8))
        == .event(.item(.note(id: "pi-ui-n", text: "Blocked"))))
    #expect(decodePiRPC(Data(#"{"type":"extension_ui_request","id":"s","method":"setStatus","statusKey":"k"}"#.utf8))
        == .ignored(type: "extension_ui_request setStatus"))
}

@Test func answersEncodeAsPiExpects() throws {
    let select = BouncerQuestion(id: "u1", title: "Pick", options: ["One", "Two", "Three"])
    let option = try json(encodePiRPC(.uiResponse(select, .option(1))))
    #expect(option["type"] as? String == "extension_ui_response" && option["id"] as? String == "u1")
    #expect(option["value"] as? String == "Two" && option.count == 3)

    let confirm = BouncerQuestion(id: "u2", title: "Sure?", options: ["Yes", "No"], confirms: true)
    for answer in [BouncerAnswer.confirmed(true), .option(0)] {
        let yes = try json(encodePiRPC(.uiResponse(confirm, answer)))
        #expect(yes["id"] as? String == "u2" && yes["confirmed"] as? Bool == true && yes["value"] == nil)
    }
    #expect(try json(encodePiRPC(.uiResponse(confirm, .option(1))))["confirmed"] as? Bool == false)

    let dismissed = try json(encodePiRPC(.uiResponse(select, .dismissed)))
    #expect(dismissed["id"] as? String == "u1" && dismissed["cancelled"] as? Bool == true && dismissed["value"] == nil)
    // An option that the question does not have cancels; it never sends another option's text.
    #expect(try json(encodePiRPC(.uiResponse(select, .option(3))))["cancelled"] as? Bool == true)
}

@Test func commandsUsePiFieldNames() throws {
    let prompt = try json(encodePiRPC(.prompt(id: "r1", message: "Hi\nthere")))
    #expect(prompt["type"] as? String == "prompt" && prompt["id"] as? String == "r1" && prompt["message"] as? String == "Hi\nthere")
    let model = try json(encodePiRPC(.setModel(id: "r2", provider: "anthropic", model: "claude")))
    #expect(model["type"] as? String == "set_model" && model["provider"] as? String == "anthropic" && model["modelId"] as? String == "claude")
    #expect(try json(encodePiRPC(.availableModels(id: "r3")))["type"] as? String == "get_available_models")
}

@Test func runEndsOnlyWhenPiSettles() {
    var thread = BouncerThread()
    for line in [#"{"type":"agent_start"}"#, #"{"type":"agent_end","messages":[],"willRetry":false}"#] {
        if case .event(let e) = decodePiRPC(Data(line.utf8)) { thread.apply(e) }
    }
    #expect(thread.replying)
    if case .event(let e) = decodePiRPC(Data(#"{"type":"agent_settled","aborted":false}"#.utf8)) { thread.apply(e) }
    #expect(!thread.replying)
}

@Test func toolStepsGrowTheReply() {
    var thread = BouncerThread()
    let lines = [
        #"{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":"pending","timestamp":7}}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Look"}}"#,
        #"{"type":"tool_execution_start","toolCallId":"a","toolName":"read","args":{}}"#,
        #"{"type":"tool_execution_start","toolCallId":"b","toolName":"grep","args":{}}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"ed."}}"#,
    ]
    for line in lines { if case .event(let e) = decodePiRPC(Data(line.utf8)) { thread.apply(e) } }
    #expect(thread.items == [.reply(id: "pi-assistant-7", text: "Looked.", toolSteps: 2)])
}

@Test func messagesHaveTheIdsOfTheLiveStream() {
    let line = #"{"type":"response","id":"r","command":"get_messages","success":true,"data":{"messages":[{"role":"user","content":"Hi","timestamp":5},{"role":"assistant","content":[{"type":"text","text":"Hello"},{"type":"toolCall","id":"t","name":"read","arguments":{}}],"stopReason":"toolUse","timestamp":7},{"role":"toolResult","toolCallId":"t","content":[],"timestamp":8}]}}"#
    #expect(decodePiRPC(Data(line.utf8)) == .messages(id: "r", [.user(id: "pi-user-5", text: "Hi"), .reply(id: "pi-assistant-7", text: "Hello", toolSteps: 1)]))
    #expect(decodePiRPC(Data(#"{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"Hi"}],"timestamp":5}}"#.utf8))
        == .event(.item(.user(id: "pi-user-5", text: "Hi"))))
}

@Test func stateGivesTheSessionFileAndModel() {
    let line = #"{"type":"response","id":"r","command":"get_state","success":true,"data":{"model":{"provider":"magpie","id":"gpt"},"sessionFile":"/s/a.jsonl","isStreaming":false}}"#
    #expect(decodePiRPC(Data(line.utf8)) == .state(id: "r", sessionFile: "/s/a.jsonl", model: "magpie/gpt"))
    #expect(decodePiRPC(Data(#"{"type":"response","command":"parse","success":false,"error":"bad"}"#.utf8))
        == .response(id: nil, command: "parse", success: false, error: "bad"))
}

private let noTools = ["--no-tools", "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates"]

@Test func reopenUsesTheRecordedSessionOnlyWhenItExists() {
    let exists = bouncerArguments(sessionFile: "/s/a.jsonl", fileExists: true, sessionDir: "/s")
    #expect(!exists.isNew && exists.arguments.suffix(2) == ["--session", "/s/a.jsonl"])
    let missing = bouncerArguments(sessionFile: "/s/a.jsonl", fileExists: false, sessionDir: "/s")
    #expect(missing.isNew && !missing.arguments.contains("--session"))
    let none = bouncerArguments(sessionFile: nil, fileExists: false, sessionDir: "/s")
    #expect(none.isNew && !none.arguments.contains("--session"))
    for (arguments, _) in [exists, missing, none] {
        #expect(Set(noTools).isSubset(of: arguments))
        #expect(arguments.starts(with: ["--mode", "rpc"]))
        #expect(arguments.firstIndex(of: "--session-dir").map { arguments[$0 + 1] } == "/s")
    }
}
