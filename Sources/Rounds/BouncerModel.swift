import Foundation
import Observation
import RoundsCore

/// Bouncer mode (spec 5.9): the owner of the Bouncer adapter and its thread. Mode off keeps today's app: no adapter, no
/// Bouncer Window, and the pill and its hover as before.
@MainActor @Observable
final class BouncerModel {
    static let shared = BouncerModel()

    private init() {}

    init(adapter: any BouncerAdapter, thread: BouncerThread = BouncerThread()) {
        self.adapter = adapter
        self.thread = thread
        pillWaiting = thread.waitingCount
        listen(to: adapter)
    }

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
    /// The Model menu: Default (nil) and the configured Magpie models, each "provider/id".
    private(set) var models: [String] = []
    private(set) var model: String?
    private(set) var modelSelection: String?
    /// The selected sidebar row. Nil selects the Bouncer row.
    var selection: String?
    var grouping = BouncerTaskGrouping.state
    var sort = BouncerTaskSort.activity
    var archived = false
    var focusOnPrompt = false

    var taskGroups: [(name: String, tasks: [BouncerTask])] {
        bouncerTaskGroups(thread.tasks, archived: archived, grouping: grouping, sort: sort)
    }
    var selectedTask: BouncerTask? { thread.tasks.first { $0.id == selection } }
    var visibleItems: [BouncerItem] { thread.visibleItems(taskID: selection) }
    var draft = ""
    private(set) var unconfirmedSend: (text: String, message: String)?
    private(set) var unconfirmedAnswer: String?
    var banner: String? {
        let lines = [unconfirmedSend?.message, unconfirmedAnswer, thread.banner].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
    /// Each change asks the window to put the focus on the first thing that waits (`BouncerView.focusFirst`).
    var focusToken = 0
    /// The adapter does not run until no setup step is missing; this watches the steps until then.
    private(set) var running = false
    private var sendPending = false
    private var otherCommandPending = false
    var commandPending: Bool { sendPending || otherCommandPending }
    var canInteract: Bool { running && !commandPending && !thread.replying && unconfirmedAnswer == nil }
    var canSend: Bool {
        canInteract && unconfirmedSend == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (adapter is DemoBouncer || !thread.items.contains { if case .question(let question) = $0 { question.isOpen } else { false } })
    }
    @ObservationIgnored private var adapter: (any BouncerAdapter)?
    @ObservationIgnored private var localApprovalAccess: [UUID: @Sendable () -> TaskStorageAuthorization] = [:]
    private var checkingApprovals: Set<UUID> = []
    private var localApprovalErrors: [UUID: String] = [:]
    private var localApprovalErrorTask: UUID? {
        if let selection, let taskID = UUID(uuidString: selection) {
            return localApprovalErrors[taskID] == nil ? nil : taskID
        }
        return localApprovalErrors.keys.sorted { $0.uuidString < $1.uuidString }.first
    }
    var localApprovalError: String? { localApprovalErrorTask.flatMap { localApprovalErrors[$0] } }
    var localApprovalRetryAvailable: Bool {
        localApprovalErrorTask.map { thread.localApprovalRetries.contains($0) } ?? false
    }
    var retryingLocalApproval: Bool {
        localApprovalErrorTask.map { checkingApprovals.contains($0) } ?? false
    }
    func retryLocalApproval() {
        guard let taskID = localApprovalErrorTask, thread.localApprovalRetries.contains(taskID) else { return }
        reloadLocalApprovals(for: taskID)
    }
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var host: NodeHarnessHost?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var hostMonitor: Task<Void, Never>?
    @ObservationIgnored private var hostFailureActive = false
    private let hostNoticeKeys = ["bouncerHostShutdownError", "bouncerHostHealthError"]
    /// Quit also waits for an earlier mode-off shutdown.
    @ObservationIgnored private var shutdowns: [UUID: Task<Void, Never>] = [:]
    /// The former Bouncer is still excluded from the host note.
    private let sessionFile = appDefaults.string(forKey: "bouncerSessionFile")

    /// What the user must set up before the Bouncer can start; the Set Up row shows them.
    var setupSteps: [BouncerSetupStep] {
        if Demo.isOn { return Demo.bouncerSetup ? [.setUpBar] : [] }
        // At launch the checks of the recorded bars run off the main thread; the Bouncer waits for them.
        return bouncerSetupSteps(readyBars: BarSettingsState.shared.readyBars)
    }

    /// Sessions that need input or failed, without the Bouncer's own: the host note.
    var otherWaits: [SessionRow] { RoundsCore.otherWaits(AppModel.shared.allGroups.sessions, bouncerSessionFile: sessionFile) }

    /// Called once the app has finished launching, and when the mode turns on.
    func start() {
        guard on, adapter == nil else { return }
        reloadLocalApprovals()
        guard setupSteps.isEmpty else { return watchSetup() }
        let made: any BouncerAdapter
        if Demo.isOn {
            made = DemoBouncer()
        } else {
            let node = Bundle.main.bundleURL.appending(path: "Contents/Helpers/harness-host/node")
            guard FileManager.default.isExecutableFile(atPath: node.path),
                  let script = Bundle.main.url(forResource: "host", withExtension: "mjs", subdirectory: "harness-host") else {
                thread.apply(.failed("The Harness host is missing. Build the app with its host resources."))
                return
            }
            let host = NodeHarnessHost(executable: node, script: script,
                                   dataFolder: URL.applicationSupportDirectory.appending(path: "Rounds/harness"))
            self.host = host
            made = HarnessBouncer(host: host)
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

    /// Mode off closes the host and the window.
    func stop() { shutDown() }

    /// Quit waits for the host to stop and preserves the mode for the next launch.
    func quit() async {
        shutDown()
        for task in shutdowns.values { await task.value }
    }

    private func shutDown() {
        BouncerWindowController.shared.close()
        (thread, models, model, modelSelection) = (BouncerThread(), [], nil, nil)
        localApprovalErrors.removeAll()
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
        otherCommandPending = false
        let id = UUID()
        shutdowns[id] = Task {
            async let adapterStop: Void = adapter.shutdown()
            await startup?.value
            await monitor?.value
            do { try await host?.stop() } catch let error as HarnessMonitorFailure {
                let text = "The Harness host stopped: \(error.localizedDescription)"
                log.error("\(text, privacy: .public)")
                appDefaults.set(text, forKey: "bouncerHostHealthError")
                windowShown()
            } catch {
                recordHostShutdownError(error.localizedDescription)
                windowShown()
            }
            await adapterStop
            shutdowns[id] = nil
        }
    }

    /// Start Again in the exit banner.
    func launch() {
        guard !running, startup == nil else { return }
        guard adapter != nil else { start(); return }
        let host = self.host, earlierStops = Array(shutdowns.values), monitor = hostMonitor
        hostMonitor = nil
        monitor?.cancel()
        thread.clearHostNotices()
        windowShown()
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
                    unconfirmedAnswer = nil
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
                                await adapter.shutdown()
                                guard self.adapter === adapter else { return }
                                let replacement = HarnessBouncer(host: host)
                                self.adapter = replacement
                                otherCommandPending = false
                                listen(to: replacement)
                            }
                        }
                    }
                }
            } catch {
                if let host {
                    do { try await Task.detached { try await host.stop() }.value } catch {
                        recordHostShutdownError(error.localizedDescription)
                    }
                }
                if !Task.isCancelled {
                    fail("The Bouncer did not start: \(error.localizedDescription)", from: adapter, duringStartup: true)
                    startup = nil
                    windowShown()
                }
            }
        }
    }

    /// Restore a rejected message to an empty composer. Keep an unconfirmed message separate.
    func send() {
        guard let adapter, canSend else { return }
        let text = draft
        draft = ""
        sendPending = true
        selection = nil
        archived = false
        Task {
            defer { sendPending = false }
            do { try await adapter.send(text) } catch let error as BouncerSendUnconfirmed {
                unconfirmedSend = (text, "\(error.localizedDescription)\nCheck the conversation before you send the message again.")
            } catch {
                let recovery = bouncerRejectedDraft(text, current: draft)
                draft = recovery.draft
                if let copy = recovery.copy {
                    unconfirmedSend = (copy, "The message was rejected. Copy it before you dismiss this notice.")
                }
                fail(error.localizedDescription, from: adapter)
            }
        }
    }

    func dismissUnconfirmedSend() { unconfirmedSend = nil }

    func stopReply() {
        guard let adapter, thread.replying, !commandPending else { return }
        perform(on: adapter) { try await adapter.stop() }
    }

    func answer(_ questionID: String, _ answer: BouncerAnswer) {
        guard let adapter, canInteract else { return }
        otherCommandPending = true
        Task {
            defer { if self.adapter === adapter { otherCommandPending = false } }
            do {
                try await adapter.answer(questionID, answer)
                if self.adapter === adapter, Demo.isOn,
                   let taskID = thread.items.first(where: { $0.id == questionID })?.taskID {
                    updateDemoTask(taskID, state: .working)
                }
            } catch let error as BouncerSendUnconfirmed {
                unconfirmedAnswer = "\(error.localizedDescription)\nStart Again and check the conversation."
            } catch { fail(error.localizedDescription, from: adapter) }
        }
    }

    /// Registers a task from the local host. The caller supplies a fresh storage grant for every operation.
    func showLocalApprovals(for taskID: UUID, using access: @escaping @Sendable () -> TaskStorageAuthorization) {
        guard !Demo.isOn, !checkingApprovals.contains(taskID) else { return }
        localApprovalAccess[taskID] = access
        reloadLocalApprovals(for: taskID)
    }

    func reloadLocalApprovals() {
        for taskID in localApprovalAccess.keys { reloadLocalApprovals(for: taskID) }
    }

    private func reloadLocalApprovals(for taskID: UUID) {
        guard let access = localApprovalAccess[taskID], checkingApprovals.insert(taskID).inserted else { return }
        thread.beginLocalApprovalReload(for: taskID)
        let interface = TaskInterface(bar: BarSettingsState.shared.store)
        Task {
            defer { checkingApprovals.remove(taskID) }
            let loaded = await Task.detached { Result { try interface.reloadApprovals(for: taskID, using: access()) } }.value
            guard on else { return }
            switch loaded {
            case .success(let record):
                let approvals = record.details?.approvals ?? []
                let cards = approvals.map { approval in
                    let showResult = approval.id == approvals.last?.id && record.details?.resultRevisionID == approval.request.resultRevisionID
                    return ApprovalCard(local: approval, result: showResult ? record.details?.result : nil)
                }
                thread.replaceLocalApprovals(for: taskID, with: cards)
                localApprovalErrors[taskID] = nil
                if cards.contains(where: \.isOpen) { focusToken += 1 }
            case .failure(TaskGraphError.changedOnDisk):
                thread.localApprovalReloadNeedsRetry(for: taskID)
                localApprovalErrors[taskID] = "The task changed. Try again."
            case .failure(let error):
                localApprovalRecheckFailed(for: taskID, error: error)
            }
        }
    }

    private func localApprovalRecheckFailed(for taskID: UUID, error: Error) {
        thread.localApprovalReloadNeedsRetry(for: taskID, discardCards: true)
        localApprovalErrors[taskID] = localApprovalMessage(error)
    }

    func savingApproval(for card: ApprovalCard) -> Bool {
        guard card.source == .local, let taskID = UUID(uuidString: card.taskID) else { return false }
        return checkingApprovals.contains(taskID)
    }

    func decide(_ response: BouncerApprovalResponse) {
        let id = response.cardID, decision = response.decision
        guard let item = thread.items.first(where: { $0.id == id }), case .approval(let card) = item,
              card.taskID == response.taskID, card.isOpen else { return }
        if card.source == .demo {
            guard Demo.isOn else { return }
            do {
                try thread.decide(id, decision)
                updateDemoTask(card.taskID, state: decision == .approved ? .finished : .stopped)
            } catch { thread.apply(.failed(error.localizedDescription)) }
            return
        }
        guard let taskID = UUID(uuidString: card.taskID), let requestID = UUID(uuidString: id),
              let access = localApprovalAccess[taskID], checkingApprovals.insert(taskID).inserted else { return }
        let interface = TaskInterface(bar: BarSettingsState.shared.store)
        Task {
            defer { checkingApprovals.remove(taskID) }
            let saved = await Task.detached {
                Result {
                    try interface.answerApproval(requestID, for: taskID, decision: decision, using: access(),
                                                 authorizeAnswer: response.authorizes)
                }
            }.value
            guard on, thread.items.contains(where: { $0.id == id }) else { return }
            completeLocalApprovalAnswer(saved, card: card, taskID: taskID)
        }
    }

    func completeLocalApprovalAnswer(_ saved: Result<ApprovalRecord, Error>, card: ApprovalCard, taskID: UUID) {
        switch saved {
        case .success(let record):
            localApprovalErrors[taskID] = nil
            thread.apply(.item(.approval(ApprovalCard(local: record, result: card.result))))
        case .failure(ApprovalError.credentialAddressInText):
            localApprovalErrors[taskID] = ApprovalError.credentialAddressInText.localizedDescription
        case .failure(TaskGraphError.changedOnDisk):
            thread.localApprovalReloadNeedsRetry(for: taskID)
            localApprovalErrors[taskID] = "The task changed. Try again."
            Task { reloadLocalApprovals(for: taskID) }
        case .failure(let error):
            localApprovalRecheckFailed(for: taskID, error: error)
        }
    }

    private func localApprovalMessage(_ error: Error) -> String {
        if let error = error as? ApprovalError { return error.localizedDescription }
        if let error = error as? BouncerError, error == .reasonRequired { return "Enter a reason to reject this request." }
        if let error = error as? TaskDetailStoreError, error == .tooLarge { return "The local task record exceeds its size limit." }
        return "Rounds could not verify or save the local approval. Check task storage."
    }

    private func updateDemoTask(_ id: String, state: BouncerTaskState) {
        var tasks = thread.tasks
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].state = state
        tasks[i].updatedAt = Date()
        thread.apply(.tasks(tasks))
    }

    func setArchived(_ task: BouncerTask, _ archived: Bool) {
        guard Demo.isOn else { return }
        thread.setArchived(task.id, archived)
        if thread.tasks.first(where: { $0.id == task.id })?.archived != self.archived, selection == task.id {
            selection = nil
        }
    }

    func setModel(_ id: String?) {
        guard let adapter, canInteract, id != modelSelection else { return }
        perform(on: adapter) { try await adapter.setModel(id) }
    }

    private func perform(on adapter: any BouncerAdapter, _ command: @escaping @Sendable () async throws -> Void) {
        otherCommandPending = true
        Task {
            defer { if self.adapter === adapter { otherCommandPending = false } }
            do { try await command() } catch { fail(error.localizedDescription, from: adapter) }
        }
    }

    /// ⌘N: until dispatch exists, a new task is a message in the Bouncer thread (slice 01, Decided).
    func newTask() {
        selection = nil
        archived = false
        draft = ""
        focusOnPrompt = true
        focusToken += 1
    }

    func windowShown() {
        let notices = hostNoticeKeys.compactMap { appDefaults.string(forKey: $0) }
        guard !notices.isEmpty else { return }
        thread.showHostNotices(notices, windowIsVisible: isWindowVisible)
    }

    func hostNoticesShown(_ notices: [String]) {
        guard isWindowVisible else { return }
        for key in hostNoticeKeys {
            if let pending = appDefaults.string(forKey: key), notices.contains(pending) {
                appDefaults.removeObject(forKey: key)
            }
        }
    }

    private var isWindowVisible: Bool {
        guard let window = BouncerWindowController.shared.window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    private func recordHostShutdownError(_ message: String) {
        let text = "The Harness host did not stop: \(message)"
        log.error("\(text, privacy: .public)")
        appDefaults.set(text, forKey: "bouncerHostShutdownError")
    }

    private func apply(_ event: BouncerEvent) {
        switch event {
        case .item(.approval) where !(adapter is DemoBouncer): return
        case .started(let current, let selection):
            (model, modelSelection) = (current, selection)
            models = []
        case .availableModel(let id): models.append(id)
        case .selectedModel(let id, let selection): (model, modelSelection) = (id, selection)
        case .exited: running = false
        default: break
        }
        thread.apply(event)
        switch event {
        case .started, .exited: windowShown()
        default: break
        }
    }

    /// An error of an adapter that `stop()` replaced does not reach the current thread.
    private func fail(_ text: String, from adapter: any BouncerAdapter, duringStartup: Bool = false) {
        if self.adapter === adapter, !hostFailureActive || duringStartup { thread.apply(.failed(text)) }
    }

    /// Starts the adapter once the last setup step is done.
    private func watchSetup() {
        withObservationTracking { _ = setupSteps } onChange: { [weak self] in
            Task { @MainActor in self?.start() }
        }
    }
}
