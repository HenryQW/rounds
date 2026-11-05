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

extension PushError {
    public var text: String {
        switch self {
        case .missing(let label): "\(label) is missing"
        case .invalid(let label): "\(label) is not valid"
        }
    }
}

/// A request that checks saved values, and the sentence for a value the service rejects.
public struct PushCheck: Sendable {
    public let request: URLRequest
    public let rejected: String
}

/// A service that gets push messages (GLOSSARY "Channel"). This enum is the only place a channel is defined: to add
/// one, add a case with its words, its logo (`Resources/<rawValue>.svg`) and colour, its fields, its request and its
/// failure parts.
public enum PushChannel: String, CaseIterable, Codable, Sendable, Identifiable {
    case telegram, bark

    public var id: Self { self }

    public var title: String {
        switch self {
        case .telegram: "Telegram"
        case .bark: "Bark"
        }
    }

    /// The Settings row's line on what the channel does.
    public var line: String {
        switch self {
        case .telegram: "Messages from your Telegram bot."
        case .bark: "Push messages to your iPhone."
        }
    }

    /// The Connect sheet's line on where the values come from.
    public var hint: String {
        switch self {
        case .telegram: "Make a bot with @BotFather and send it a message. Your chat ID is your user ID, from @userinfobot."
        case .bark: "Copy the device key from the Bark app. Change the server only if you run your own."
        }
    }

    /// The logo's brand colour, 0xRRGGBB.
    public var color: Int {
        switch self {
        case .telegram: 0x26A5E4
        case .bark: 0xFF543D
        }
    }

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
        let (v, base) = try resolved(values)
        let url: URL, body: [String: Any]
        switch self {
        case .telegram:
            url = base.appending(path: "sendMessage")
            body = ["chat_id": v["chat"]!, "text": message.title + "\n" + message.body, "disable_web_page_preview": true]
        case .bark:
            url = base.appending(path: "push")
            body = ["device_key": v["key"]!, "title": message.title, "body": message.body, "group": "Rounds",
                    "level": message.urgent ? "timeSensitive" : "active"]
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try! JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// The requests that check the values before they are saved, in order; none sends a message. Telegram: the token
    /// (`getMe`), then the chat (`getChat`). Bark: the device key (`/register/<key>`, bark-server's key check).
    public func checks(values: [String: String]) throws(PushError) -> [PushCheck] {
        let (v, base) = try resolved(values)
        switch self {
        case .telegram:
            return [PushCheck(request: URLRequest(url: base.appending(path: "getMe")), rejected: "Bot token: Telegram does not know this token."),
                    PushCheck(request: URLRequest(url: base.appending(path: "getChat").appending(queryItems: [URLQueryItem(name: "chat_id", value: v["chat"])])),
                              rejected: "Chat ID: the bot cannot find this chat. Send your bot a message first.")]
        case .bark:
            return [PushCheck(request: URLRequest(url: base.appending(path: "register").appending(path: v["key"]!)),
                              rejected: "Device key: the server does not know this key. Copy it again from the Bark app.")]
        }
    }

    /// nil when the check passed. A rejected value (HTTP 4xx) gets the check's sentence; no answer (`status` nil) or
    /// another failure says what happened.
    public func checkFailure(_ check: PushCheck, status: Int?, body: Data?) -> String? {
        guard let status else { return self == .telegram ? "Could not reach Telegram." : "Could not reach the Bark server." }
        guard let failure = failure(status: status, body: body ?? Data()) else { return nil }
        return (400..<500).contains(status) ? check.rejected : "\(title): \(failure)"
    }

    /// The trimmed values with defaults, and the URL that the requests start from. Throws for a missing value, or a
    /// value that would make a bad URL.
    private func resolved(_ values: [String: String]) throws(PushError) -> (values: [String: String], base: URL) {
        var v: [String: String] = [:]
        for f in fields {
            let value = values[f.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let value = value.isEmpty ? f.defaultValue : value else { throw PushError.missing(f.label) }
            v[f.key] = value
        }
        switch self {
        case .telegram:
            // The token is part of the URL path.
            let token = v["token"]!
            guard token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ":_-".contains($0)) }),
                  let base = URL(string: "https://api.telegram.org/bot\(token)") else { throw PushError.invalid("Bot token") }
            return (v, base)
        case .bark:
            var server = v["server"]!
            while server.hasSuffix("/") { server.removeLast() }
            guard let base = URL(string: server), ["https", "http"].contains(base.scheme), base.host() != nil else { throw PushError.invalid("Server") }
            return (v, base)
        }
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

        init(_ row: SessionRow) { (id, state, since) = (row.id, row.status.state, row.status.since) }
    }

    /// Every event checked so far, for the app's life; nil before the first check, which only learns.
    private var known: Set<Event>?
    private var waiting: Set<Event> = []

    public init() {}

    public mutating func check(_ rows: [SessionRow], states: Set<SessionState>, idle: TimeInterval, awayMinutes: Int) -> [SessionRow] {
        let events = rows.filter { $0.status.group == .yourTurn && states.contains($0.status.state) }
            .map { (row: $0, event: Event($0)) }
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
