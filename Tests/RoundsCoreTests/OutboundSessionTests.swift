import Foundation
import Network
import Testing
@testable import RoundsCore

private final class RedirectFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rounds.redirect-fixture")
    let port: UInt16

    init(response: String, onRequest: @escaping @Sendable (String) -> Void = { _ in }) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue.global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data { onRequest(String(decoding: data, as: UTF8.self)) }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port else {
            listener.cancel()
            throw FixtureError.startFailed
        }
        port = bound.rawValue
    }

    deinit { listener.cancel() }
    enum FixtureError: Error { case startFailed }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    func append(_ request: String) { lock.withLock { requests.append(request) } }
    func snapshot() -> [String] { lock.withLock { requests } }
}

@Suite struct OutboundSessionTests {
    @Test func doesNotShareCookiesBetweenRequests() async throws {
        let captured = RequestRecorder()
        let server = try RedirectFixture(response: "HTTP/1.1 200 OK\r\nSet-Cookie: session=private; Path=/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") {
            captured.append($0)
        }
        let url = URL(string: "http://127.0.0.1:\(server.port)/push")!
        _ = try await OutboundSession.noRedirects.data(from: url)
        _ = try await OutboundSession.noRedirects.data(from: url)
        let requests = captured.snapshot()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { !$0.lowercased().contains("\r\ncookie:") })
    }

    @Test func doesNotFollowRedirectWithPrivateBody() async throws {
        let receiver = try RedirectFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        let redirect = try RedirectFixture(response: "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(receiver.port)/other\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(redirect.port)/push")!)
        request.httpMethod = "POST"
        request.httpBody = Data("private-session-and-key".utf8)
        request.timeoutInterval = 5
        let (_, response) = try await OutboundSession.noRedirects.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 307)
        withExtendedLifetime(receiver) {}
    }
}
