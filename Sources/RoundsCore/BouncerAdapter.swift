import Foundation

/// The one way the Bouncer Window talks to the Bouncer: the Node Host or demo data.
public protocol BouncerAdapter: AnyObject, Sendable {
    var events: AsyncStream<BouncerEvent> { get }
    func start() async throws
    /// Throws `BouncerSendUnconfirmed` if the host may already have accepted the text.
    func send(_ text: String) async throws
    /// Stops the current reply.
    func stop() async throws
    /// Throws `BouncerSendUnconfirmed` if the answer or dismissal may have been accepted.
    func answer(_ questionID: String, _ answer: BouncerAnswer) async throws
    func decide(_ approvalID: String, _ decision: ApprovalDecision) async throws
    func checkAgain() async
    /// "provider/id", or nil for the configured default.
    func setModel(_ id: String?) async throws
    func shutdown() async
}

public struct BouncerSendUnconfirmed: LocalizedError, Sendable {
    let detail: String
    let answer: Bool

    public init(detail: String, answer: Bool = false) { self.detail = detail; self.answer = answer }

    public var errorDescription: String? {
        let action = answer ? "answer was saved" : "message was sent"
        return "Rounds could not confirm that the \(action).\n\(detail)"
    }
}

/// Keep both texts when the composer changed while a rejected send was pending.
public func bouncerRejectedDraft(_ original: String, current: String) -> (draft: String, copy: String?) {
    current.isEmpty ? (original, nil) : (current, original)
}
