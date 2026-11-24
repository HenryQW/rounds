import Foundation

/// The window's connection to the conversation in the app-owned Node Host.
public actor HarnessBouncer: BouncerAdapter {
    public nonisolated let events: AsyncStream<BouncerEvent>
    private let output: AsyncStream<BouncerEvent>.Continuation
    private let host: NodeHarnessHost

    public init(host: NodeHarnessHost) {
        self.host = host
        (events, output) = AsyncStream.makeStream(of: BouncerEvent.self)
    }

    public func start() async throws { try await host.openBouncer(events: output) }
    public func send(_ text: String) async throws { try await host.bouncer(.send(text)) }
    public func stop() async throws { try await host.bouncer(.stop) }
    public func answer(_ questionID: String, _ answer: BouncerAnswer) async throws {
        try await host.bouncer(.answer(questionID, answer))
    }
    public func decide(_ approvalID: String, _ decision: ApprovalDecision) async throws { throw BouncerError.notAvailable }
    public func checkAgain() async {}
    public func setModel(_ id: String?) async throws { try await host.bouncer(.model(id)) }
    public func shutdown() async { output.finish() }
}

enum HarnessBouncerCommand: Sendable {
    case open, send(String), stop, answer(String, BouncerAnswer), model(String?)

    var fields: (command: String, parameters: [String: Any]) {
        switch self {
        case .open: ("bouncerOpen", [:])
        case .send(let text): ("bouncerSend", ["text": text])
        case .stop: ("bouncerStop", [:])
        case .answer(let id, let answer): ("bouncerAnswer", ["questionID": id, "answer": encode(answer)])
        case .model(let id): ("bouncerModel", ["model": id as Any? ?? NSNull()])
        }
    }

    private func encode(_ answer: BouncerAnswer) -> [String: Any] {
        switch answer {
        case .option(let index): ["kind": "option", "index": index]
        case .text(let text): ["kind": "text", "text": text]
        case .dismissed: ["kind": "dismissed"]
        }
    }
}

struct HarnessBouncerEvent: Decodable {
    let version: Int
    let event: String
    let itemID, text, model, selection, title, questionID: String?
    let options: [String]?
    let recommended: Int?
    let replying: Bool?
    let answer: Answer?

    struct Answer: Decodable {
        let kind: String
        let index: Int?
        let text: String?
    }

    func decode() throws -> BouncerEvent {
        if version == 1 {
            switch event {
            case "started": return .started(model: model, selection: selection)
            case "model": if let model { return .availableModel(model) }
            case "selectedModel": if let model { return .selectedModel(model: model, selection: selection) }
            case "user": if let itemID { return .item(.user(id: itemID, text: "")) }
            case "reply": if let itemID { return .item(.reply(id: itemID, text: "", toolSteps: 0)) }
            case "delta": if let itemID, let text { return .textDelta(id: itemID, text: text) }
            case "toolStep": if let itemID { return .toolStep(id: itemID) }
            case "remove": if let itemID { return .remove(id: itemID) }
            case "stopped": if let itemID { return .item(.stopped(id: itemID)) }
            case "question":
                if let itemID, let title, let options {
                    return .item(.question(BouncerQuestion(id: itemID, title: title, options: options,
                                                           recommended: recommended, takesText: options.isEmpty)))
                }
            case "answered":
                if let questionID, let answer {
                    switch answer.kind {
                    case "option": if let index = answer.index { return .answered(questionID, .option(index)) }
                    case "text": if let text = answer.text { return .answered(questionID, .text(text)) }
                    case "dismissed": return .answered(questionID, .dismissed)
                    default: break
                    }
                }
            case "replying": if let replying { return .replying(replying) }
            case "banner": return .banner(text)
            case "failed": if let text { return .failed(text) }
            default: break
            }
        }
        throw HarnessHostError("Invalid Harness conversation event.")
    }
}
