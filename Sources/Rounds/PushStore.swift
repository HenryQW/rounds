import CoreGraphics
import Foundation
import Observation
import RoundsCore
import Security

/// Push notifications to the phone (spec 2.9): when a session wants the user and the Mac has had no input for a time,
/// one message through each channel that has values. The values live only in the Keychain. Checks run on each regroup,
/// so also on the app's 30 s timer.
@MainActor @Observable
final class PushStore {
    static let shared = PushStore()

    enum Status: Equatable { case notSet, ready, failed(String) }

    /// The states that send. A change learns the current events again, so it sends none of them.
    var states: Set<SessionState> {
        didSet {
            appDefaults.set(states.map(\.rawValue).sorted(), forKey: "pushStates")
            queue = PushQueue()
        }
    }
    /// Minutes with no key or pointer input before an event goes out; 0 sends at once.
    var awayMinutes: Int { didSet { appDefaults.set(awayMinutes, forKey: "pushAwayMinutes") } }
    /// The channels that have values: not secret, so no Keychain read happens while it is empty.
    private(set) var channels: Set<PushChannel> { didSet { appDefaults.set(channels.map(\.rawValue).sorted(), forKey: "pushChannels") } }
    /// The last send failure of each channel; the next success clears it.
    private var failures: [PushChannel: String] = [:]

    /// nil until the Keychain is read.
    @ObservationIgnored private var values: [PushChannel: [String: String]]?
    @ObservationIgnored private var loading = false
    /// Tests asked for while the Keychain read runs.
    @ObservationIgnored private var tests: Set<PushChannel> = []
    @ObservationIgnored private var queue = PushQueue()

    private init() {
        let defaultStates: [SessionState] = [.needsInput, .failed, .ready]
        states = Set(appDefaults.stringArray(forKey: "pushStates")?.compactMap(SessionState.init) ?? defaultStates)
        awayMinutes = appDefaults.object(forKey: "pushAwayMinutes") as? Int ?? 2
        channels = Set((appDefaults.stringArray(forKey: "pushChannels") ?? []).compactMap(PushChannel.init))
    }

    func status(of channel: PushChannel) -> Status {
        guard channels.contains(channel) else { return .notSet }
        return failures[channel].map(Status.failed) ?? .ready
    }

    /// The sessions of the list groups, after each regroup: sends the events that are due.
    func check(_ rows: [SessionRow]) {
        guard !Demo.isOn, !channels.isEmpty else { return }
        // The first check after the read only learns, so events from before it do not send.
        guard let values else { return load() }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        for row in queue.check(rows, states: states, idle: idle, awayMinutes: awayMinutes) {
            let message = PushMessage(row)
            for channel in channels { send(channel, message, values[channel] ?? [:]) }
        }
    }

    func save(_ channel: PushChannel, values new: [String: String]) {
        guard !Demo.isOn else { return }
        keychainIO.async {
            PushValues.save(channel, new)
            // After a read that started before the save, which brings the old values.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.values?[channel] = new } }
        }
        values?[channel] = new
        channels.insert(channel)
        failures[channel] = nil
        if values == nil { load() }
    }

    func remove(_ channel: PushChannel) {
        guard !Demo.isOn else { return }
        keychainIO.async {
            PushValues.delete(channel)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.values?[channel] = nil } }
        }
        values?[channel] = nil
        channels.remove(channel)
        failures[channel] = nil
        // A channel set up later learns the current events first.
        if channels.isEmpty { queue = PushQueue() }
    }

    func sendTest(_ channel: PushChannel) {
        guard !Demo.isOn, channels.contains(channel) else { return }
        guard let values else {
            tests.insert(channel)
            return load()
        }
        send(channel, PushMessage(title: "Rounds test", body: "Notifications work.", urgent: false), values[channel] ?? [:])
    }

    /// Once, at first need, off the main thread, so a Keychain prompt never blocks the app.
    private func load() {
        guard !loading else { return }
        loading = true
        let names = channels
        keychainIO.async {
            let read = Dictionary(uniqueKeysWithValues: names.compactMap { c in PushValues.read(c).map { (c, $0) } })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.values = read
                    self.tests.forEach(self.sendTest)
                    self.tests = []
                }
            }
        }
    }

    /// One request, 15 s, no retry. The log names the channel and the result, never the values or the URL, which
    /// holds the Telegram token.
    private func send(_ channel: PushChannel, _ message: PushMessage, _ values: [String: String]) {
        var request: URLRequest
        do { request = try channel.request(for: message, values: values) } catch {
            let text = switch error {
            case .missing(let label): "\(label) is missing"
            case .invalid(let label): "\(label) is not valid"
            }
            return sent(channel, failure: text)
        }
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            let failure = if let data, let status { channel.failure(status: status, body: data) } else { "Network error" as String? }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.sent(channel, failure: failure) } }
        }.resume()
    }

    private func sent(_ channel: PushChannel, failure: String?) {
        log.info("push: \(channel.rawValue, privacy: .public), \(failure ?? "sent", privacy: .public)")
        failures[channel] = failure
    }
}

/// The values of each channel in the login Keychain: service `com.henryqw.rounds.push`, account = the channel, data =
/// JSON of its values. Never in a file or a log.
private enum PushValues {
    static func item(_ channel: PushChannel) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.henryqw.rounds.push", kSecAttrAccount as String: channel.rawValue]
    }

    static func read(_ channel: PushChannel) -> [String: String]? {
        var data: AnyObject?
        let status = SecItemCopyMatching(item(channel).merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &data)
        if status != errSecSuccess && status != errSecItemNotFound { log.error("push: Keychain read failed (\(status))") }
        return (data as? Data).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }

    static func save(_ channel: PushChannel, _ values: [String: String]) {
        SecItemDelete(item(channel) as CFDictionary)
        let status = SecItemAdd(item(channel).merging([kSecValueData as String: try! JSONEncoder().encode(values)]) { $1 } as CFDictionary, nil)
        if status != errSecSuccess { log.error("push: Keychain save failed (\(status))") }
    }

    static func delete(_ channel: PushChannel) { SecItemDelete(item(channel) as CFDictionary) }
}
