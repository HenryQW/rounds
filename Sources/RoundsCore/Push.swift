import Foundation

/// What a channel sends for one push event.
public struct PushMessage: Equatable, Sendable {
    public var title: String
    public var body: String
    /// A wait (Needs input, Failed): Bark shows it through Focus.
    public var urgent: Bool

    public init(title: String, body: String, urgent: Bool) { (self.title, self.body, self.urgent) = (title, body, urgent) }

    /// "Needs input: <title>", with "Permission: Bash in atlas", or "In atlas" when there is no detail.
    public init(_ row: SessionRow) {
        let detail = row.status.detail
        // An empty cwd (a herdr agent without one) has no folder.
        let folder = row.cwd.isEmpty ? "" : URL(fileURLWithPath: row.cwd).lastPathComponent
        title = "\(row.status.state.title): \(row.title)"
        body = folder.isEmpty ? detail : detail.isEmpty ? "In \(folder)" : "\(detail) in \(folder)"
        urgent = row.status.state.waits
    }
}

/// One value a channel needs, such as a token. A field with a default value is optional.
public struct PushField: Equatable, Sendable {
    public let key: String
    public let label: String
    public let placeholder: String
    public let isSecret: Bool
    public let defaultValue: String?
}

/// The label of the field that is missing or not valid.
public enum PushError: Error, Equatable { case missing(String), invalid(String) }

/// A service that gets push messages (GLOSSARY "Channel"). This enum is the only place a channel is defined: to add
/// one, add a case with its fields, its request and its failure parts.
public enum PushChannel: String, CaseIterable, Codable, Sendable {
    case telegram, bark

    public var fields: [PushField] {
        switch self {
        case .telegram: [PushField(key: "token", label: "Bot token", placeholder: "123456:ABC-DEF", isSecret: true, defaultValue: nil),
                         PushField(key: "chat", label: "Chat ID", placeholder: "123456789", isSecret: false, defaultValue: nil)]
        case .bark: [PushField(key: "key", label: "Device key", placeholder: "From the Bark app", isSecret: true, defaultValue: nil),
                     PushField(key: "server", label: "Server", placeholder: "https://api.day.app", isSecret: false, defaultValue: "https://api.day.app")]
        }
    }

    /// A POST with a JSON body. Throws for a missing value, or a value that would make a bad URL.
    public func request(for message: PushMessage, values: [String: String]) throws(PushError) -> URLRequest {
        var v: [String: String] = [:]
        for f in fields {
            let value = values[f.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let value = value.isEmpty ? f.defaultValue : value else { throw PushError.missing(f.label) }
            v[f.key] = value
        }
        let url: URL?, body: [String: Any]
        switch self {
        case .telegram:
            // The token is part of the URL path.
            let token = v["token"]!
            guard token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ":_-".contains($0)) }) else { throw PushError.invalid("Bot token") }
            url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage")
            body = ["chat_id": v["chat"]!, "text": message.title + "\n" + message.body, "disable_web_page_preview": true]
        case .bark:
            var server = v["server"]!
            while server.hasSuffix("/") { server.removeLast() }
            url = URL(string: server + "/push").flatMap { ["https", "http"].contains($0.scheme) && $0.host() != nil ? $0 : nil }
            guard url != nil else { throw PushError.invalid("Server") }
            body = ["device_key": v["key"]!, "title": message.title, "body": message.body, "group": "Rounds",
                    "level": message.urgent ? "timeSensitive" : "active"]
        }
        var request = URLRequest(url: url!)
        request.httpMethod = "POST"
        request.httpBody = try! JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// nil when the service took the message; else its own message, or "HTTP <status>".
    public func failure(status: Int, body: Data) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let ok: Bool, message: String?
        switch self {
        case .telegram: (ok, message) = (json?["ok"] as? Bool == true, json?["description"] as? String)
        case .bark: (ok, message) = (json?["code"] as? Int == 200, json?["message"] as? String)
        }
        return (200..<300).contains(status) && ok ? nil : message ?? "HTTP \(status)"
    }
}

/// Which push events to send now. A push event is a Your Turn row in a chosen state, by row id, state and since. It
/// waits while the user works and goes out once the Mac has had no input for `awayMinutes`; it is dropped when it
/// leaves Your Turn, changes or is seen before that. Each event goes out at most once.
public struct PushQueue: Sendable {
    private struct Event: Hashable, Sendable {
        let id: String
        let state: SessionState
        let since: Date
    }

    /// Every event checked so far, for the app's life; nil before the first check, which only learns.
    private var known: Set<Event>?
    private var waiting: Set<Event> = []

    public init() {}

    public mutating func check(_ rows: [SessionRow], states: Set<SessionState>, idle: TimeInterval, awayMinutes: Int) -> [SessionRow] {
        let events = rows.filter { $0.status.group == .yourTurn && states.contains($0.status.state) }
            .map { (row: $0, event: Event(id: $0.id, state: $0.status.state, since: $0.status.since)) }
        let current = Set(events.map(\.event))
        defer { known = (known ?? []).union(current) }
        guard let known else { return [] }
        waiting = waiting.union(current.subtracting(known)).intersection(current).subtracting(events.filter(\.row.isSeen).map(\.event))
        guard idle >= TimeInterval(awayMinutes * 60) else { return [] }
        let due = events.filter { waiting.contains($0.event) }
        waiting.subtract(due.map(\.event))
        return due.map(\.row)
    }
}
