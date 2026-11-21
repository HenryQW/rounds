import Foundation
import Observation
import RoundsCore

/// Bouncer mode (spec 5.9): the owner of the Bouncer adapter and its thread. Mode off keeps today's app: no adapter, no
/// Bouncer Window, and the pill and its hover as before.
@MainActor @Observable
final class BouncerModel {
    static let shared = BouncerModel()

    /// Settings > General > Bouncer mode, off by default. On starts the adapter; off stops it and closes the window.
    var on = appDefaults.bool(forKey: "bouncerMode") {
        didSet {
            guard on != oldValue else { return }
            appDefaults.set(on, forKey: "bouncerMode")
            on ? start() : stop()
        }
    }
    private(set) var thread = BouncerThread() {
        didSet { if pillWaiting != thread.waitingCount { pillWaiting = thread.waitingCount } }
    }
    /// The pill's count: open questions and undecided approvals. Set only when it changes, so the pill reads only this.
    private(set) var pillWaiting = 0
    /// The Model menu: Default (nil) and the models that Pi lists, each "provider/id".
    private(set) var models: [String] = []
    private(set) var model: String?
    /// The selected sidebar row; nil is the Bouncer row (01c adds task rows).
    var selection: String?
    var draft = ""
    /// Each change asks the window to put the focus on the first thing that waits (`BouncerView.focusFirst`).
    var focusToken = 0
    /// The adapter does not run until no setup step is missing; this watches the steps until then.
    private(set) var running = false
    @ObservationIgnored private var adapter: (any BouncerAdapter)?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var host: NodeHarnessHost?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var hostMonitor: Task<Void, Never>?
    @ObservationIgnored private var hostFailureActive = false
    /// Shutdowns that have not ended, from each Off and quit, so quit waits for a Pi that an earlier Off stops.
    @ObservationIgnored private var shutdowns: [UUID: Task<Void, Never>] = [:]
    /// The session file that Pi reported at start; `sessionFile` once it exists.
    @ObservationIgnored private var reportedFile: String?

    /// The Bouncer session file that Pi last reported, to reopen it at the next start and to leave it out of the host note.
    private(set) var sessionFile = appDefaults.string(forKey: "bouncerSessionFile") {
        didSet { appDefaults.set(sessionFile, forKey: "bouncerSessionFile") }
    }

    /// The `pi` executable. An app started from Finder has no shell PATH, so Rounds looks in the usual install places.
    var piPath: String? {
        if Demo.isOn { return Demo.bouncerSetup ? nil : "/usr/local/bin/pi" }
        let home = URL.homeDirectory.path
        return [home + "/.pi/agent/bin/pi", "/opt/homebrew/bin/pi", "/usr/local/bin/pi", home + "/.local/bin/pi"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What the user must set up before the Bouncer can start; the Set Up row shows them.
    var setupSteps: [BouncerSetupStep] {
        let workspace = WorkspaceSettingsState.shared
        if Demo.isOn { return Demo.bouncerSetup ? [.installPi] : [] }
        // At launch the check of the recorded folder runs off the main thread; Pi waits for its remotes.
        var remotes: [WorkspaceRemote]?
        if case .repository(_, let found) = workspace.inspection { remotes = found }
        return bouncerSetupSteps(workspace: workspace.settings, isWorkspace: workspace.isWorkspace, remotes: remotes, piPath: piPath)
    }

    /// Sessions that need input or failed, without the Bouncer's own: the host note.
    var otherWaits: [SessionRow] { RoundsCore.otherWaits(AppModel.shared.allGroups.sessions, bouncerSessionFile: sessionFile) }

    /// Called once the app has finished launching, and when the mode turns on.
    func start() {
        guard on, adapter == nil else { return }
        guard setupSteps.isEmpty, let made = makeAdapter() else { return watchSetup() }
        if !Demo.isOn {
            let helpers = Bundle.main.bundleURL.appending(path: "Contents/Helpers/harness-host")
            guard FileManager.default.isExecutableFile(atPath: helpers.appending(path: "node").path),
                  FileManager.default.fileExists(atPath: helpers.appending(path: "host.mjs").path) else {
                thread.apply(.failed("The Harness host is missing. Build the app with its host resources."))
                return
            }
            host = NodeHarnessHost(executable: helpers.appending(path: "node"), script: helpers.appending(path: "host.mjs"),
                                   dataFolder: URL.applicationSupportDirectory.appending(path: "Rounds/harness"))
        }
        adapter = made
        hostFailureActive = false
        listen(to: made)
        launch()
    }

    private func listen(to adapter: any BouncerAdapter) {
        listener = Task { [weak self] in
            // `stop()` cancels this task on the main actor, so no event of an old adapter reaches the next thread.
            for await event in adapter.events where !Task.isCancelled { self?.apply(event) }
        }
    }

    /// Mode off: the adapter closes Pi (stdin, then signals), and the window closes.
    func stop() { shutDown() }

    /// Quit: Pi stops as at mode off, and the mode stays on for the next launch. Returns once every Pi has exited.
    func quit() async {
        shutDown()
        for task in shutdowns.values { await task.value }
    }

    private func shutDown() {
        BouncerWindowController.shared.close()
        guard let adapter else { return }
        let host = self.host, startup = self.startup, monitor = self.hostMonitor
        startup?.cancel()
        monitor?.cancel()
        hostMonitor = nil
        self.startup = nil
        self.host = nil
        self.adapter = nil
        running = false
        listener?.cancel()
        listener = nil
        reportedFile = nil
        (thread, models, model) = (BouncerThread(), [], nil)
        let id = UUID()
        shutdowns[id] = Task {
            async let adapterStop: Void = adapter.shutdown()
            await startup?.value
            await monitor?.value
            do { try await host?.stop() } catch let error as HarnessMonitorFailure {
                let text = "The Harness host stopped: \(error.localizedDescription)"
                log.error("\(text, privacy: .public)")
                appDefaults.set(text, forKey: "bouncerHostHealthError")
            } catch {
                let text = "The Harness host did not stop: \(error.localizedDescription)"
                log.error("\(text, privacy: .public)")
                appDefaults.set(text, forKey: "bouncerHostShutdownError")
                thread.apply(.failed(text))
            }
            await adapterStop
            shutdowns[id] = nil
        }
    }

    /// Start Again in the exit banner.
    func launch() {
        guard adapter != nil, startup == nil else { return }
        let host = self.host, earlierStops = Array(shutdowns.values), monitor = hostMonitor
        hostMonitor = nil
        monitor?.cancel()
        startup = Task {
            defer { if !Task.isCancelled { startup = nil } }
            await monitor?.value
            guard !Task.isCancelled, let adapter = self.adapter else { return }
            do {
                for task in earlierStops { await task.value }
                try Task.checkCancellation()
                if let host { _ = try await host.start() }
                try Task.checkCancellation()
                try await adapter.start()
                if self.adapter === adapter {
                    running = true
                    hostFailureActive = false
                    if let host {
                        hostMonitor = Task {
                            do { try await host.monitor() } catch {
                                guard !(error is CancellationError), self.adapter === adapter else { return }
                                running = false
                                hostFailureActive = true
                                listener?.cancel()
                                listener = nil
                                let text = "The Harness host stopped: \(error.localizedDescription)"
                                appDefaults.set(text, forKey: "bouncerHostHealthError")
                                thread.apply(.exited(text))
                                windowShown()
                                await host.acknowledgeMonitorFailure()
                                await adapter.shutdownAfterHostFailure()
                                guard self.adapter === adapter else { return }
                                if let replacement = makeAdapter() {
                                    self.adapter = replacement
                                    listen(to: replacement)
                                } else {
                                    self.adapter = nil
                                }
                            }
                        }
                    }
                }
            } catch {
                fail("The Bouncer did not start: \(error.localizedDescription)", from: adapter, duringStartup: true)
                if !Task.isCancelled {
                    startup = nil
                    windowShown()
                }
            }
        }
    }

    /// Sends the draft. No send while Pi is stopped or a reply runs: Pi rejects a prompt then. A failed send puts the
    /// text back in an empty prompt box.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let adapter, running, !text.isEmpty, !thread.replying else { return }
        draft = ""
        Task {
            do { try await adapter.send(text) } catch {
                if self.adapter === adapter, draft.isEmpty { draft = text }
                fail(message(error), from: adapter)
            }
        }
    }

    func stopReply() {
        guard let adapter, thread.replying else { return }
        Task { await adapter.stop() }
    }

    func answer(_ questionID: String, _ answer: BouncerAnswer) {
        guard let adapter else { return }
        thread.answer(questionID, answer)
        Task {
            do { try await adapter.answer(questionID, answer) } catch { fail(message(error), from: adapter) }
        }
    }

    func setModel(_ id: String?) {
        guard let adapter, id != model else { return }
        let previous = model
        model = id
        Task {
            do { try await adapter.setModel(id) } catch {
                guard self.adapter === adapter else { return }
                model = previous
                if !hostFailureActive { thread.apply(.failed(message(error))) }
            }
        }
    }

    /// ⌘N: until dispatch exists, a new task is a message in the Bouncer thread (slice 01, Decided).
    func newTask() {
        selection = nil
        draft = ""
        focusToken += 1
    }

    /// Clears a saved host notice only when its banner is visible in the Bouncer window.
    func windowShown() {
        guard let window = BouncerWindowController.shared.window, window.isVisible, !window.isMiniaturized,
              let notice = appDefaults.string(forKey: "bouncerHostHealthError") else { return }
        if thread.banner?.contains(notice) != true {
            // A pending Pi request may have replaced the host banner during shutdown.
            // During startup, wait for `.started` to restore the notice after Pi clears the banner.
            guard startup == nil else { return }
            thread.apply(.failed([thread.banner, notice].compactMap { $0 }.joined(separator: "\n")))
        }
        appDefaults.removeObject(forKey: "bouncerHostHealthError")
    }

    private func apply(_ event: BouncerEvent) {
        switch event {
        case .started(let file, let isNew, let current):
            if let old = missingBouncerSession(recorded: sessionFile, reported: file, isNew: isNew) {
                thread.apply(.item(.note(id: "missing-\(old)", text: "New conversation. The earlier Bouncer session file is missing.")))
            }
            reportedFile = file
            // A reopened session keeps its own model, so the menu shows Pi's model, not Default.
            model = current
            recordSessionFile()
        case .replying(false): recordSessionFile()
        case .models(let list): models = list
        case .exited: running = false
        default: break
        }
        thread.apply(event)
        if case .started = event {
            var notices: [String] = []
            if let error = appDefaults.string(forKey: "bouncerHostShutdownError") {
                appDefaults.removeObject(forKey: "bouncerHostShutdownError")
                notices.append(error)
            }
            if let error = appDefaults.string(forKey: "bouncerHostHealthError") { notices.append(error) }
            if !notices.isEmpty { thread.apply(.failed(notices.joined(separator: "\n"))) }
            windowShown()
        } else if case .exited = event, let notice = appDefaults.string(forKey: "bouncerHostHealthError") {
            thread.apply(.failed([thread.banner, notice].compactMap { $0 }.joined(separator: "\n")))
            windowShown()
        }
    }

    private func recordSessionFile() {
        sessionFile = bouncerSessionToRecord(reported: reportedFile, recorded: sessionFile,
                                             exists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// An error of an adapter that `stop()` replaced does not reach the current thread.
    private func fail(_ text: String, from adapter: any BouncerAdapter, duringStartup: Bool = false) {
        if self.adapter === adapter, !hostFailureActive || duringStartup { thread.apply(.failed(text)) }
    }

    private func makeAdapter() -> (any BouncerAdapter)? {
        if Demo.isOn { return DemoBouncer() }
        guard let pi = piPath, let folder = WorkspaceSettingsState.shared.settings.workspace?.path else { return nil }
        let sessions = URL.applicationSupportDirectory.appending(path: "Rounds/bouncer-sessions")
        do {
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        } catch {
            thread.apply(.failed("Rounds cannot make the Bouncer session folder: \(error.localizedDescription)"))
            return nil
        }
        return PiRPCBouncer(executable: URL(fileURLWithPath: pi), folder: URL(fileURLWithPath: folder), sessionFile: sessionFile,
                            sessionDir: sessions.path)
    }

    /// Starts the adapter once the last setup step is done.
    private func watchSetup() {
        withObservationTracking { _ = setupSteps } onChange: { [weak self] in
            Task { @MainActor in self?.start() }
        }
    }

    private func message(_ error: Error) -> String {
        switch error as? BouncerError {
        case .notRunning: "Pi is not running."
        case .noAnswer: "Pi did not answer in 10 s."
        case .rejected(let text): text.isEmpty ? "Pi refused the command." : text
        default: error.localizedDescription
        }
    }
}
