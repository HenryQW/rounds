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
        return bouncerSetupSteps(workspace: workspace.settings, isWorkspace: workspace.isWorkspace, remotes: workspace.remotes, piPath: piPath)
    }

    /// Sessions that need input or failed, without the Bouncer's own: the host note.
    var otherWaits: [SessionRow] { RoundsCore.otherWaits(AppModel.shared.allGroups.sessions, bouncerSessionFile: sessionFile) }

    /// Called once the app has finished launching, and when the mode turns on.
    func start() {
        guard on, adapter == nil else { return }
        guard setupSteps.isEmpty, let made = makeAdapter() else { return watchSetup() }
        adapter = made
        listener = Task { [weak self] in
            for await event in made.events { self?.apply(event) }
        }
        launch()
    }

    /// Mode off: the adapter closes Pi (stdin, then signals), and the window closes.
    func stop() {
        BouncerWindowController.shared.close()
        guard let adapter else { return }
        self.adapter = nil
        running = false
        listener = nil
        // Shutdown ends the event stream, so the listener ends too.
        Task { await adapter.shutdown() }
        (thread, models, model) = (BouncerThread(), [], nil)
    }

    /// Start Again in the exit banner.
    func launch() {
        guard let adapter else { return }
        Task {
            do {
                try await adapter.start()
                running = true
            } catch {
                thread.apply(.failed("Pi did not start: \(error.localizedDescription)"))
            }
        }
    }

    /// Sends the draft. No send while a reply runs: Pi rejects a prompt then.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let adapter, !text.isEmpty, !thread.replying else { return }
        draft = ""
        Task {
            do { try await adapter.send(text) } catch { thread.apply(.failed(message(error))) }
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
            do { try await adapter.answer(questionID, answer) } catch { thread.apply(.failed(message(error))) }
        }
    }

    func setModel(_ id: String?) {
        guard let adapter, id != model else { return }
        let previous = model
        model = id
        Task {
            do { try await adapter.setModel(id) } catch {
                model = previous
                thread.apply(.failed(message(error)))
            }
        }
    }

    /// ⌘N: until dispatch exists, a new task is a message in the Bouncer thread (slice 01, Decided).
    func newTask() {
        selection = nil
        draft = ""
        focusToken += 1
    }

    private func apply(_ event: BouncerEvent) {
        switch event {
        case .started(let file, let isNew):
            // Only a file that exists is recorded, so a recorded file that is gone was removed: say so once.
            if isNew, let old = sessionFile, old != file {
                thread.apply(.item(.note(id: "missing-\(old)", text: "New conversation. The earlier Bouncer session file is missing.")))
            }
            reportedFile = file
            recordSessionFile()
        case .replying(false): recordSessionFile()
        case .models(let list): models = list
        case .exited: running = false
        default: break
        }
        thread.apply(event)
    }

    /// Pi writes a new session file after the first reply, not at start: recording it before would call an unused
    /// session missing at the next start.
    private func recordSessionFile() {
        if let file = reportedFile, file != sessionFile, FileManager.default.fileExists(atPath: file) { sessionFile = file }
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
