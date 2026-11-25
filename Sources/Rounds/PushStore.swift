import AppKit
import CoreGraphics
import Foundation
import Observation
import RoundsCore
import Security

/// Push notifications (spec 2.9): a sound on this Mac at once, and, when the Mac has had no input for a time, one
/// message through each channel that has values. The values live only in the Keychain. Checks run on each regroup, so
/// also on the app's 30 s timer.
@MainActor @Observable
final class PushStore {
    static let shared = PushStore()

    enum Status: Equatable { case notSet, ready, failed(String) }

    /// The states that send. A change learns the current events again, so it sends none of them.
    var states: Set<SessionState> {
        didSet {
            appDefaults.set(states.map(\.rawValue).sorted(), forKey: "pushStates")
            queue = PushQueue()
            soundQueue = PushQueue()
        }
    }
    /// Sounds on this Mac. A change learns the current events again, so it plays none of them.
    var sounds: Bool {
        didSet {
            appDefaults.set(sounds, forKey: "pushSounds")
            soundQueue = PushQueue()
        }
    }
    /// The sound of each state; an empty name is None.
    var soundNames: [SessionState: String] {
        didSet {
            appDefaults.set(Dictionary(uniqueKeysWithValues: soundNames.map { ($0.key.rawValue, $0.value) }), forKey: "pushSoundNames")
            soundQueue = PushQueue()
        }
    }
    /// The system sounds, by name.
    static let soundList: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
        .map { ($0 as NSString).deletingPathExtension }.sorted()
    /// Most urgent first: one check plays one sound.
    private static let soundOrder: [SessionState] = [.needsInput, .failed, .ready]
    /// Minutes with no key or pointer input before an event goes out; 0 sends at once.
    var awayMinutes: Int { didSet { appDefaults.set(awayMinutes, forKey: "pushAwayMinutes") } }
    /// The channels that have values: not secret, so no Keychain read happens while it is empty.
    private(set) var channels: Set<PushChannel> { didSet { appDefaults.set(channels.map(\.rawValue).sorted(), forKey: "pushChannels") } }
    /// The last send failure of each channel; the next success clears it.
    private var failures: [PushChannel: String] = [:]

    /// nil until the Keychain is read.
    @ObservationIgnored private var values: [PushChannel: [String: String]]?
    private(set) var organizationDestinations: [OrganizationDestination] = []
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var valueRevisions: [PushChannel: Int] = [:]
    /// Tests asked for while the Keychain read runs.
    @ObservationIgnored private var tests: Set<PushChannel> = []
    @ObservationIgnored private var queue = PushQueue()
    /// Sounds play at once: the same queue with no away time.
    @ObservationIgnored private var soundQueue = PushQueue()
    /// Reads one channel's values on `keychainIO`; tests replace it, so no test reads the Keychain.
    @ObservationIgnored var readValues: @Sendable (PushChannel) -> [String: String]? = PushValues.read

    /// A channel with no readable values shows this, not Ready.
    static let unreadable = "Could not read the values from Keychain. Choose Change… to enter them again."

    init() {
        let defaultStates: [SessionState] = [.needsInput, .failed, .ready]
        states = Set(appDefaults.stringArray(forKey: "pushStates")?.compactMap(SessionState.init) ?? defaultStates)
        awayMinutes = appDefaults.object(forKey: "pushAwayMinutes") as? Int ?? 2
        channels = Set((appDefaults.stringArray(forKey: "pushChannels") ?? []).compactMap(PushChannel.init))
        sounds = appDefaults.bool(forKey: "pushSounds")
        let stored = appDefaults.dictionary(forKey: "pushSoundNames") as? [String: String] ?? [:]
        soundNames = Dictionary(uniqueKeysWithValues: zip(Self.soundOrder, ["Submarine", "Basso", "Glass"]).map { ($0, stored[$0.rawValue] ?? $1) })
    }

    func status(of channel: PushChannel) -> Status {
        guard channels.contains(channel) else { return .notSet }
        return failures[channel].map(Status.failed) ?? .ready
    }

    /// The sessions of the list groups, after each regroup: sends the events that are due.
    func check(_ rows: [SessionRow]) {
        guard !Demo.isOn else { return }
        if sounds { playSound(rows) }
        guard !channels.isEmpty, OrganizationSettingsState.shared.hasLease else { return }
        // The first check after the read only learns, so events from before it do not send.
        guard let values, !loading else { if !loading { load() }; return }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        for row in queue.check(rows, states: states, idle: idle, awayMinutes: awayMinutes) {
            let message = PushMessage(row)
            for channel in channels {
                let current = values[channel] ?? [:]
                guard let destination = destination(channel, values: current) else {
                    failures[channel] = Self.unreadable
                    continue
                }
                _ = try? OrganizationSettingsState.shared.withPolicy { policy in
                    guard policy.allowsTransmission(sessionDirectory: row.cwd, gitRemote: .unknown,
                                                    service: destination.service, destinationIdentity: destination.identity) else { return }
                    send(channel, message, current)
                }
            }
        }
    }

    /// Plays the sound of the most urgent new event.
    private func playSound(_ rows: [SessionRow]) {
        let named = soundNames.filter { !$0.value.isEmpty }
        let new = soundQueue.check(rows, states: Set(named.keys), idle: 0, awayMinutes: 0)
        guard let state = Self.soundOrder.first(where: { s in new.contains { $0.status.state == s } }), let name = named[state] else { return }
        play(name)
    }

    func play(_ name: String) { NSSound(named: name)?.play() }

    /// Checks the values with the service before they are saved, one request at a time (15 s each); nil when all
    /// pass, else the line for the Connect sheet. The log names the channel and the result, never the values.
    func verify(_ channel: PushChannel, values: [String: String]) async -> String? {
        guard !Demo.isOn else { return nil }
        guard OrganizationSettingsState.shared.hasLease else { return "Another Rounds instance manages organization permissions." }
        let checks: [PushCheck]
        do { checks = try channel.checks(values: values) } catch { return error.text }
        for check in checks {
            var request = check.request
            request.timeoutInterval = 15
            let answer = try? await OutboundSession.noRedirects.data(for: request)
            if let failure = channel.checkFailure(check, status: (answer?.1 as? HTTPURLResponse)?.statusCode, body: answer?.0) {
                log.info("push: \(channel.rawValue, privacy: .public) check failed")
                return failure
            }
        }
        return nil
    }

    @discardableResult
    func save(_ channel: PushChannel, values new: [String: String]) -> Bool {
        guard !Demo.isOn, OrganizationSettingsState.shared.hasLease else { return false }
        if destination(channel, values: values?[channel] ?? [:]) != destination(channel, values: new),
           !OrganizationSettingsState.shared.resetPermissions(service: "push-\(channel.rawValue)") { return false }
        if values == nil { load() }
        valueRevisions[channel, default: 0] += 1
        if values == nil { values = [:] }
        values?[channel] = new
        keychainIO.async { PushValues.save(channel, new) }
        channels.insert(channel)
        refreshOrganizationDestinations()
        failures[channel] = nil
        return true
    }

    func remove(_ channel: PushChannel) {
        guard !Demo.isOn else { return }
        guard OrganizationSettingsState.shared.resetPermissions(service: "push-\(channel.rawValue)") else {
            failures[channel] = "Could not update organization permissions. Open Organizations to resolve the error."
            return
        }
        valueRevisions[channel, default: 0] += 1
        keychainIO.async { PushValues.delete(channel) }
        values?[channel] = nil
        channels.remove(channel)
        refreshOrganizationDestinations()
        failures[channel] = nil
        // A channel set up later learns the current events first.
        if channels.isEmpty { queue = PushQueue() }
    }

    func sendTest(_ channel: PushChannel) {
        guard !Demo.isOn, channels.contains(channel), OrganizationSettingsState.shared.hasLease else { return }
        guard let values else {
            tests.insert(channel)
            return load()
        }
        send(channel, PushMessage(title: "Rounds test", body: "Notifications work.", urgent: false), values[channel] ?? [:])
    }

    func prepareOrganizationDestinations() {
        if values == nil && !channels.isEmpty { load() }
    }

    /// Once, at first need, off the main thread, so a Keychain prompt never blocks the app.
    private func load() {
        guard !loading else { return }
        loading = true
        let names = channels
        let revisions = valueRevisions
        let readValues = readValues
        keychainIO.async {
            let read = Dictionary(uniqueKeysWithValues: names.compactMap { c in readValues(c).map { (c, $0) } })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var merged = self.values ?? [:]
                    for channel in names where self.valueRevisions[channel, default: 0] == revisions[channel, default: 0] {
                        merged[channel] = read[channel]
                        if read[channel] == nil { self.failures[channel] = Self.unreadable }
                    }
                    self.values = merged
                    self.loading = false
                    self.refreshOrganizationDestinations()
                    self.tests.forEach(self.sendTest)
                    self.tests = []
                }
            }
        }
    }

    /// Destination identity changes when the channel's configured endpoint or credentials change.
    private func destination(_ channel: PushChannel, values: [String: String]) -> OrganizationDestination? {
        guard (try? channel.request(for: PushMessage(title: "", body: "", urgent: false), values: values)) != nil else { return nil }
        let normalized = Dictionary(uniqueKeysWithValues: channel.fields.map { field in
            let value = values[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (field.key, value.isEmpty ? field.defaultValue ?? "" : value)
        })
        let detail: String
        switch channel {
        case .telegram: detail = "Chat \(normalized["chat"] ?? "")"
        case .bark:
            var endpoint = URLComponents(string: normalized["server"] ?? "")
            endpoint?.user = nil
            endpoint?.password = nil
            endpoint?.path = ""
            endpoint?.query = nil
            endpoint?.fragment = nil
            detail = endpoint?.string ?? "Bark server"
        }
        return makeOrganizationDestination(service: "push-\(channel.rawValue)", fields: normalized, title: channel.title, detail: detail)
    }

    private func refreshOrganizationDestinations() {
        organizationDestinations = channels.sorted { $0.rawValue < $1.rawValue }.compactMap { channel in
            values?[channel].flatMap { destination(channel, values: $0) }
        }
    }

    /// One request, 15 s, no retry. The log names the channel and the result, never the values or the URL, which
    /// holds the Telegram token.
    private func send(_ channel: PushChannel, _ message: PushMessage, _ values: [String: String]) {
        var request: URLRequest
        do { request = try channel.request(for: message, values: values) } catch { return sent(channel, failure: error.text) }
        request.timeoutInterval = 15
        OutboundSession.noRedirects.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            let failure = if let data, let status { channel.failure(status: status, body: data) } else { "Network error" as String? }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.sent(channel, failure: failure) } }
        }.resume()
    }

    private func sent(_ channel: PushChannel, failure: String?) {
        log.info("push: \(channel.rawValue, privacy: .public), \(failure == nil ? "sent" : "failed", privacy: .public)")
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

    /// Update, then add: a failed write keeps the old value.
    static func save(_ channel: PushChannel, _ values: [String: String]) {
        let changes = [kSecValueData as String: try! JSONEncoder().encode(values)]
        var status = SecItemUpdate(item(channel) as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(item(channel).merging(changes) { $1 } as CFDictionary, nil) }
        if status != errSecSuccess { log.error("push: Keychain save failed (\(status))") }
    }

    static func delete(_ channel: PushChannel) { SecItemDelete(item(channel) as CFDictionary) }
}
