import Foundation

// `pi --mode rpc` records (Pi 1.5.2 docs: rpc.md, rpc-commands.md, rpc-extension-ui.md, json.md).

/// Splits stdout into records. Pi frames records with LF only; U+2028 and U+2029 are valid inside JSON strings.
public struct PiRPCFramer {
    private var buffer = Data()

    public init() {}

    /// The whole records in `data` and the bytes before it, without the LF and one CR before it. Empty lines are dropped.
    public mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let lf = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<lf]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[(lf + 1)...])
        }
        return lines
    }
}

public enum PiRPCRecord: Equatable, Sendable {
    case response(id: String?, command: String, success: Bool, error: String?)
    /// A successful `get_state` response. `model`: "provider/id" of the selected model.
    case state(id: String?, sessionFile: String?, model: String?)
    /// A successful `get_messages` response, as thread items with the ids of the live stream.
    case messages(id: String?, [BouncerItem])
    case event(BouncerEvent), uiRequest(BouncerQuestion, timeoutMs: Int?), ignored(type: String), malformed(String)
    /// `agent_settled` with `aborted: true`: the reply ends because of a stop.
    case aborted
}

public func decodePiRPC(_ line: Data) -> PiRPCRecord {
    guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = record["type"] as? String else {
        return .malformed(String(decoding: line.prefix(200), as: UTF8.self))
    }
    switch type {
    case "response":
        let id = record["id"] as? String, command = record["command"] as? String ?? "", success = record["success"] as? Bool ?? false
        let data = record["data"] as? [String: Any]
        if success, command == "get_state", let data {
            let model = (data["model"] as? [String: Any]).flatMap { m -> String? in
                guard let provider = m["provider"] as? String, let id = m["id"] as? String else { return nil }
                return provider + "/" + id
            }
            return .state(id: id, sessionFile: data["sessionFile"] as? String, model: model)
        }
        if success, command == "get_available_models", let models = data?["models"] as? [[String: Any]] {
            return .event(.models(models.compactMap { m in
                guard let provider = m["provider"] as? String, let id = m["id"] as? String else { return nil }
                return provider + "/" + id
            }))
        }
        if success, command == "get_messages", let messages = data?["messages"] as? [[String: Any]] {
            return .messages(id: id, messages.flatMap(piItems))
        }
        return .response(id: id, command: command, success: success, error: record["error"] as? String)
    case "message_start":
        // A reply starts empty and grows by deltas and tool steps.
        guard var message = record["message"] as? [String: Any] else { return .ignored(type: type) }
        if message["role"] as? String == "assistant" { message["content"] = [[String: Any]]() }
        guard let item = piItems(message).first else { return .ignored(type: type) }
        return .event(.item(item))
    case "message_update":
        guard let update = record["assistantMessageEvent"] as? [String: Any], update["type"] as? String == "text_delta",
              let delta = update["delta"] as? String else { return .ignored(type: type) }
        return .event(.textDelta(delta))
    case "message_end":
        // The error note, as `get_messages` gives it after a restart.
        guard let message = record["message"] as? [String: Any], message["stopReason"] as? String == "error",
              let note = piItems(message).last, case .note = note else { return .ignored(type: type) }
        return .event(.item(note))
    case "tool_execution_start": return .event(.toolStep(record["toolName"] as? String ?? ""))
    case "agent_start": return .event(.replying(true))
    case "agent_settled": return record["aborted"] as? Bool == true ? .aborted : .event(.replying(false))
    case "extension_ui_request": return decodeUIRequest(record)
    default: return .ignored(type: type)
    }
}

/// The prefix of a Pi dialog's item id, so a dialog id never matches the id of another item, such as an approval card.
private let piDialogPrefix = "pi-ui-"

/// A dialog becomes a question card, never an approval card, whatever its title says.
private func decodeUIRequest(_ record: [String: Any]) -> PiRPCRecord {
    let method = record["method"] as? String ?? ""
    guard let raw = record["id"] as? String else { return .malformed("extension_ui_request without id") }
    let id = piDialogPrefix + raw
    let title = record["title"] as? String ?? ""
    let timeout = (record["timeout"] as? NSNumber)?.intValue
    switch method {
    case "select":
        return .uiRequest(BouncerQuestion(id: id, title: title, options: record["options"] as? [String] ?? []), timeoutMs: timeout)
    case "confirm":
        let message = record["message"] as? String ?? ""
        let text = message.isEmpty ? title : title + "\n" + message
        return .uiRequest(BouncerQuestion(id: id, title: text, options: ["Yes", "No"], confirms: true), timeoutMs: timeout)
    case "input", "editor":
        return .uiRequest(BouncerQuestion(id: id, title: title, takesText: true), timeoutMs: timeout)
    case "notify": return .event(.item(.note(id: id, text: record["message"] as? String ?? "")))
    default: return .ignored(type: "extension_ui_request " + method)
    }
}

/// The thread items of one Pi message. Ids come from the role and the message timestamp, so a message from the live
/// stream and the same message from `get_messages` have one id. A message without a timestamp gets a new id.
private func piItems(_ message: [String: Any]) -> [BouncerItem] {
    let stamp = (message["timestamp"] as? NSNumber).map { "\($0.int64Value)" } ?? UUID().uuidString
    let blocks = message["content"] as? [[String: Any]] ?? []
    let text = (message["content"] as? String)
        ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    switch message["role"] as? String {
    case "user": return [.user(id: "pi-user-\(stamp)", text: text)]
    case "assistant":
        let reply = BouncerItem.reply(id: "pi-assistant-\(stamp)", text: text,
                                      toolSteps: blocks.filter { $0["type"] as? String == "toolCall" }.count)
        guard message["stopReason"] as? String == "error" else { return [reply] }
        return [reply, .note(id: "pi-error-\(stamp)", text: message["errorMessage"] as? String ?? "Pi reported an error.")]
    default: return []
    }
}

public enum PiRPCCommand: Sendable {
    case prompt(id: String, message: String), abort(id: String), getState(id: String), getMessages(id: String)
    case setModel(id: String, provider: String, model: String), availableModels(id: String)
    /// The answer to a dialog: the question gives the request id (its id without `pi-ui-`), the option texts and the
    /// dialog kind.
    case uiResponse(BouncerQuestion, BouncerAnswer)
}

/// One JSON object and LF.
public func encodePiRPC(_ command: PiRPCCommand) -> Data {
    let object: [String: Any] = switch command {
    case .prompt(let id, let message): ["id": id, "type": "prompt", "message": message]
    case .abort(let id): ["id": id, "type": "abort"]
    case .getState(let id): ["id": id, "type": "get_state"]
    case .getMessages(let id): ["id": id, "type": "get_messages"]
    case .setModel(let id, let provider, let model): ["id": id, "type": "set_model", "provider": provider, "modelId": model]
    case .availableModels(let id): ["id": id, "type": "get_available_models"]
    case .uiResponse(let question, let answer):
        ["type": "extension_ui_response", "id": question.id.hasPrefix(piDialogPrefix) ? String(question.id.dropFirst(piDialogPrefix.count)) : question.id]
            .merging(uiValue(question, answer)) { a, _ in a }
    }
    // Only strings and booleans: serialization cannot fail.
    var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    data.append(0x0A)
    return data
}

/// An answer that does not fit the dialog cancels it.
private func uiValue(_ question: BouncerQuestion, _ answer: BouncerAnswer) -> [String: Any] {
    switch (answer, question.confirms) {
    case (.confirmed(let yes), true): ["confirmed": yes]
    case (.option(let i), true) where i == 0 || i == 1: ["confirmed": i == 0]
    case (.option(let i), false) where question.options.indices.contains(i): ["value": question.options[i]]
    case (.text(let text), false) where question.takesText: ["value": text]
    default: ["cancelled": true]
    }
}

/// The arguments after `pi`: RPC mode, no tools, extensions, MCP, skills or prompt templates, and the Bouncer's
/// session folder. A recorded session file that exists reopens it; otherwise Pi starts a new session.
public func bouncerArguments(sessionFile: String?, fileExists: Bool, sessionDir: String) -> (arguments: [String], isNew: Bool) {
    let base = ["--mode", "rpc", "--no-tools", "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates",
                "--session-dir", sessionDir]
    guard let sessionFile, fileExists else { return (base, true) }
    return (base + ["--session", sessionFile], false)
}
