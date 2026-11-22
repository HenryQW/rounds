import Foundation

/// The one way the Bouncer Window talks to the Bouncer: the Node Host or demo data.
public protocol BouncerAdapter: AnyObject, Sendable {
    var events: AsyncStream<BouncerEvent> { get }
    func start() async throws
    func send(_ text: String) async throws
    /// Stops the current reply.
    func stop() async throws
    func answer(_ questionID: String, _ answer: BouncerAnswer) async throws
    func decide(_ approvalID: String, _ decision: ApprovalDecision) async throws
    func checkAgain() async
    /// "provider/id", or nil for the configured default.
    func setModel(_ id: String?) async throws
    func shutdown() async
}
