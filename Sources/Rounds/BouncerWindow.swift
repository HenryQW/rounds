import AppKit
import Observation
import RoundsCore
import SwiftUI

/// The Bouncer Window's view state (no @State: see RoundsApp).
@MainActor @Observable
final class BouncerWindowState {
    /// The host note's popover shows.
    var hostNote = false
    /// The control under the pointer, which shows the grey hover fill.
    var hovered: String?
    /// The sidebar by hand; nil: shown at 700 pt and wider, hidden below.
    var sidebar: Bool?
    var details: Bool?
    var sidebarHovered = false
    var rejectionReasons: [String: String] = [:]
    var expandedReports: Set<String> = []
    var detailSections: Set<String> = ["Changes", "Checks", "Agents", "Environment"]
    var factUnconfirmed = true
    var width: CGFloat = 900
    var narrow: Bool { width < 700 }
    var sidebarShown: Bool { sidebar ?? !narrow }
}

/// The Bouncer Window (spec 5.9): a normal titled, resizable window, because it holds a long conversation. ⌘W closes it;
/// the Bouncer keeps running.
@MainActor
final class BouncerWindowController: NSObject, NSWindowDelegate {
    static let shared = BouncerWindowController()
    let state = BouncerWindowState()
    private(set) var window: NSWindow?
    private var keyMonitor: Any?

    func show() {
        let model = BouncerModel.shared
        // A setup step can have completed since the last check.
        model.start()
        model.reloadLocalApprovals()
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.windowShown()
        model.focusOnPrompt = false
        model.focusToken += 1
        keyMonitor = keyMonitor ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Bouncer"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 400)
        window.delegate = self
        window.contentView = NSHostingView(rootView: BouncerView(model: BouncerModel.shared, state: state))
        // Demo mode neither reads nor saves the frame.
        if Demo.isOn || !window.setFrameUsingName("RoundsBouncerWindow") { window.center() }
        // `self.window` is not set yet, so `windowDidResize` cannot read the restored width.
        state.width = window.frame.width
        if !Demo.isOn { window.setFrameAutosaveName("RoundsBouncerWindow") }
        observeSubtitle(window)
        return window
    }

    /// The subtitle says what waits, as the pill does.
    private func observeSubtitle(_ window: NSWindow) {
        let waiting = withObservationTracking { BouncerModel.shared.pillWaiting } onChange: { [weak self, weak window] in
            Task { @MainActor in if let window { self?.observeSubtitle(window) } }
        }
        window.subtitle = waiting > 0 ? "\(waiting) waiting" : "Nothing waits"
    }

    /// ⌘N new task; ⌃Tab and ⌃⇧Tab the next and previous sidebar row, with wrap; Return sends from the prompt box (⇧Return
    /// adds a line); Esc closes the popover, then stops the reply, then closes the sidebar overlay; ⌘W closes the window.
    private func handle(_ event: NSEvent) -> Bool {
        let model = BouncerModel.shared
        // Keypad Enter (76) also has `.numericPad` and `.function`; they are not modifiers the user holds.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        let editor = window?.firstResponder as? NSTextView
        // While an input method composes text, its keys belong to it.
        if editor?.hasMarkedText() == true { return false }
        switch (event.keyCode, flags) {
        case (45, .command): // N
            model.newTask()
        case (13, .command): // W
            window?.performClose(nil)
        case (48, let f) where f.contains(.control): // Tab
            let rows: [String?] = [nil] + model.taskGroups.flatMap(\.tasks).map { Optional($0.id) }
            let i = rows.firstIndex(of: model.selection) ?? 0
            model.selection = rows[(i + (f.contains(.shift) ? rows.count - 1 : 1)) % rows.count]
        case (36, []), (76, []): // Return; the prompt box only (a field editor is a one-line text field)
            guard let editor, !editor.isFieldEditor else { return false }
            model.send()
        case (53, []): // Esc
            if state.hostNote { state.hostNote = false }
            else if model.thread.replying { model.stopReply() }
            else if state.narrow, state.sidebar == true { state.sidebar = nil }
            else if state.narrow, state.details == true { state.details = nil }
            else { return false }
        default:
            return false
        }
        return true
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        BouncerModel.shared.windowShown()
    }

    func windowDidResize(_ notification: Notification) {
        if let width = window?.frame.width, width != state.width { state.width = width }
    }
}

/// Where the focus goes when the window opens: the first undecided approval, else option 1 of the first open question
/// (its text field when it takes text), else the prompt box.
enum BouncerFocus: Hashable {
    case approval(String), option(String, Int), text(String), prompt, group, sort, taskMenu(String)
}

struct BouncerView: View {
    let model: BouncerModel
    @Bindable var state: BouncerWindowState
    @FocusState private var focus: BouncerFocus?

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                bannerView(banner)
                    .onChange(of: model.thread.hostNotices, initial: true) { _, notices in model.hostNoticesShown(notices) }
            }
            if let error = model.localApprovalError {
                bannerView(error, localApproval: true)
            }
            if Demo.isOn, !model.thread.tasks.isEmpty, state.factUnconfirmed { BouncerFactBanner(state: state) }
            HStack(spacing: 0) {
                if state.sidebarShown && !state.narrow {
                    sidebar
                    Divider()
                }
                conversation
                if detailsShown && !state.narrow { Divider(); detailsPanel }
            }
            .overlay(alignment: .leading) {
                if state.sidebarShown && state.narrow {
                    sidebar.background(.regularMaterial).overlay(alignment: .trailing) { Divider() }
                }
            }
            .overlay(alignment: .trailing) {
                if detailsShown && state.narrow {
                    detailsPanel.background(.regularMaterial).overlay(alignment: .leading) { Divider() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: focusFirst)
        .onChange(of: model.focusToken) { focusFirst() }
    }

    private var detailsShown: Bool { model.selectedTask != nil && (state.details ?? !state.narrow) }

    @ViewBuilder private var detailsPanel: some View {
        if Demo.isOn, let task = model.selectedTask {
            BouncerDetails(task: task, details: DemoBouncer.details(task.id, factUnconfirmed: state.factUnconfirmed), state: state)
        }
    }

    private func focusFirst() {
        // Approval priority applies to the whole thread, even when an earlier question waits.
        var target = BouncerFocus.prompt
        if !model.focusOnPrompt {
            if let item = model.thread.items.first(where: { if case .approval(let card) = $0 { card.isOpen } else { false } }),
               case .approval(let card) = item {
                if model.selection != nil { model.selection = card.taskID }
                target = .approval(card.id)
            } else if let item = model.thread.items.first(where: { if case .question(let q) = $0 { q.isOpen } else { false } }),
                      case .question(let q) = item {
                if model.selection != nil { model.selection = q.taskID }
                target = q.takesText ? .text(q.id) : .option(q.id, 0)
            }
        }
        // After this layout pass, so the selected task and its focus target exist.
        DispatchQueue.main.async { focus = target }
    }

    // MARK: Header and banner

    private var header: some View {
        HStack(spacing: 8) {
            iconButton("sidebar", "sidebar.left", state.sidebarShown ? "Hide the sidebar" : "Show the sidebar") {
                state.sidebar = !state.sidebarShown
                if state.narrow { state.details = nil }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedTask?.title ?? "Bouncer").font(.headline).lineLimit(1)
                if let task = model.selectedTask {
                    stateWord(task.state.title, task.state.color)
                    Text([task.repository, task.organization].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("The whole thread, with reports from every task").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            hostNote
            if model.selectedTask != nil {
                iconButton("details", "sidebar.right", detailsShown ? "Hide task details" : "Show task details") {
                    state.details = !detailsShown
                    if state.narrow { state.sidebar = nil }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func bannerView(_ text: String, localApproval: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if localApproval {
                if model.localApprovalRetryAvailable {
                    Button("Try Again") { model.retryLocalApproval() }
                        .disabled(model.retryingLocalApproval)
                        .bouncerHover("retry-local-approval", state: state)
                }
            } else {
                VStack(alignment: .trailing) {
                    if !model.running { Button("Start Again") { model.launch() } }
                    if let send = model.unconfirmedSend {
                        Button("Copy Message") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(send.text, forType: .string)
                        }
                        Button("Dismiss") { model.dismissUnconfirmedSend() }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    /// Sessions outside the Bouncer that need the user, from Rounds; 0 hides the button.
    @ViewBuilder private var hostNote: some View {
        let waits = model.otherWaits
        if !waits.isEmpty {
            Button { state.hostNote.toggle() } label: {
                HStack(spacing: 6) {
                    Circle().fill(.orange).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(waits.count == 1 ? "1 other session needs you" : "\(waits.count) other sessions need you")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(state.hovered == "host" ? 0.08 : 0), in: .capsule)
                .overlay(Capsule().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .onHover { hover("host", $0) }
            .popover(isPresented: $state.hostNote, arrowEdge: .bottom) { hostNotePopover(waits) }
        }
    }

    private func hostNotePopover(_ waits: [SessionRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(waits, id: \.id) { row in
                HStack(spacing: 8) {
                    Circle().fill(row.status.state == .failed ? Color.red : .orange).frame(width: 7, height: 7)
                    Text(row.title).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(row.status.state.title).font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Divider()
            HStack(spacing: 12) {
                Text("Shown by Rounds; the Bouncer does not see these.").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Open Session List") {
                    state.hostNote = false
                    PanelController.shared.show(.yourTurn)
                    PanelController.shared.show()
                }
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let step = model.setupSteps.first { setUpRow(step) }
            Button(action: model.newTask) {
                HStack(spacing: 8) {
                    Image(systemName: "plus").frame(width: 16)
                    Text("New Task")
                    Spacer()
                    Text("⌘N").font(.callout).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .sidebarRow(hovered: state.hovered == "new")
            }
            .buttonStyle(.plain)
            .onHover { hover("new", $0) }
            bouncerRow
            taskControls
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.taskGroups, id: \.name) { group in
                        if !group.name.isEmpty {
                            Text(model.grouping == .state ? (BouncerTaskState(rawValue: group.name)?.title ?? group.name) : group.name)
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.top, 12).padding(.horizontal, 8)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.tasks) { taskRow($0) }
                    }
                }
            }
            Button(model.archived ? "Back to Tasks" : "Archive") {
                model.archived.toggle()
                model.selection = nil
            }
            .buttonStyle(.plain)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bouncerHover("archive", state: state)
        }
        .padding(8)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .onHover { state.sidebarHovered = $0 }
    }

    private var taskControls: some View {
        HStack {
            Text(model.archived ? "Archive" : "Tasks").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Group By", selection: Binding(get: { model.grouping }, set: { model.grouping = $0 })) {
                    ForEach(BouncerTaskGrouping.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: { Image(systemName: "rectangle.3.group") }
            .focused($focus, equals: .group)
            .opacity(state.sidebarHovered || focus == .group ? 1 : 0)
            .bouncerHover("group", state: state)
            .help("Group tasks").accessibilityLabel("Group tasks")
            Menu {
                Picker("Sort By", selection: Binding(get: { model.sort }, set: { model.sort = $0 })) {
                    ForEach(BouncerTaskSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
            .focused($focus, equals: .sort)
            .opacity(state.sidebarHovered || focus == .sort ? 1 : 0)
            .bouncerHover("sort", state: state)
            .help("Sort tasks").accessibilityLabel("Sort tasks")
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 8).padding(.top, 12)
    }

    private func taskRow(_ task: BouncerTask) -> some View {
        let selected = task.id == model.selection
        return HStack(spacing: 0) {
            Button { selectTask(task.id) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(task.state.color).frame(width: 7, height: 7).padding(.top, 5).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).lineLimit(2)
                        if let repository = task.repository {
                            Text(repository).font(.caption).lineLimit(1)
                        }
                        if model.grouping != .state { Text(task.state.title).font(.caption) }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(selected ? Color.white : .primary)
                .padding(.vertical, 6).padding(.leading, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(task.title), \(task.state.title), \(task.repository ?? "No repository")")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Menu {
                Button(task.archived ? "Unarchive" : "Archive") { model.setArchived(task, !task.archived) }
                    .disabled(!task.archived && !task.canArchive)
                if !task.archived && !task.canArchive { Text("Only finished or stopped tasks can be archived.") }
            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(selected ? Color.white : .primary)
            .focused($focus, equals: .taskMenu(task.id))
            .opacity(state.hovered == task.id || state.hovered == "menu-\(task.id)" || focus == .taskMenu(task.id) ? 1 : 0)
            .bouncerHover("menu-\(task.id)", state: state)
            .accessibilityLabel("Actions for \(task.title)")
        }
        .padding(.trailing, 4)
        .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(state.hovered == task.id ? 0.08 : 0)),
                    in: .rect(cornerRadius: 6))
        .onHover { hover(task.id, $0) }
    }

    private func selectTask(_ id: String?) {
        model.selection = id
        if state.narrow { state.sidebar = nil }
    }

    /// The Bouncer's own thread, pinned at the top; selected while no task is.
    private var bouncerRow: some View {
        let selected = model.selection == nil, waiting = model.pillWaiting
        return Button { selectTask(nil) } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bouncer")
                    Text("Whole thread · " + (waiting > 0 ? "\(waiting) waiting" : "nothing waits"))
                        .font(.callout)
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .sidebarRow(hovered: state.hovered == "bouncer", selected: selected)
        }
        .buttonStyle(.plain)
        .onHover { hover("bouncer", $0) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A missing setup step: a click opens Settings on the page that sets it.
    private func setUpRow(_ step: BouncerSetupStep) -> some View {
        let (text, page): (String, SettingsPage) = switch step {
        case .chooseWorkspace: ("Choose a workspace folder", .workspace)
        case .confirmRemotes: ("Confirm the workspace remotes", .workspace)
        }
        return Button {
            SettingsState.shared.page = page
            NSApp.activate(ignoringOtherApps: true)
            // The app menu's Settings… item (⌘,), which SwiftUI's Settings scene adds.
            if let menu = NSApp.mainMenu?.items.first?.submenu, let item = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                menu.performActionForItem(at: item)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver").frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up")
                    Text(text).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .sidebarRow(hovered: state.hovered == "setup")
        }
        .buttonStyle(.plain)
        .onHover { hover("setup", $0) }
        .help("The Bouncer starts when the setup is complete. Opens Settings.")
        .padding(.bottom, 6)
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.visibleItems) { item in
                            VStack(alignment: .leading, spacing: 16) { itemView(item) }.id(item.id)
                        }
                        if model.thread.replying { TypingDots() }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onAppear { scrollFocus(proxy) }
                .onChange(of: focus) { scrollFocus(proxy) }
                .onChange(of: state.width) { scrollFocus(proxy) }
            }
            .overlay {
                if model.visibleItems.isEmpty && !model.thread.replying {
                    Text(model.setupSteps.isEmpty ? "Ask the Bouncer to start a task, or ask what waits." : "Set up the Bouncer first.")
                        .foregroundStyle(.secondary)
                }
            }
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private func itemView(_ item: BouncerItem) -> some View {
        switch item {
        case .user(_, let text):
            VStack(alignment: .trailing, spacing: 4) {
                Text("You").font(.callout).foregroundStyle(.secondary)
                Text(text).textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 12))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .reply(_, let text, let steps):
            VStack(alignment: .leading, spacing: 4) {
                who("Bouncer")
                Text(markdown(text)).textSelection(.enabled)
                if steps > 0 { Text(steps == 1 ? "1 tool step" : "\(steps) tool steps").font(.callout).foregroundStyle(.secondary) }
            }
        case .report(let id, let taskID, let role, let text, let steps):
            BouncerReportCard(id: id, task: model.thread.tasks.first { $0.id == taskID }, role: role,
                              text: text, steps: steps, state: state) { selectTask(taskID) }
            if Demo.isOn, ["t4", "t5"].contains(taskID), let task = model.thread.tasks.first(where: { $0.id == taskID }) {
                BouncerResultCard(title: task.title, details: DemoBouncer.details(taskID))
            }
        case .question(let q): questionView(q)
        case .approval(let card):
            if let result = card.result {
                BouncerLocalResultCard(result: result)
            } else if card.source == .demo, let task = model.thread.tasks.first(where: { $0.id == card.taskID }) {
                BouncerResultCard(title: task.title, details: DemoBouncer.details(card.taskID))
            }
            BouncerApprovalCard(card: card, focus: $focus, state: state, saving: model.savingApproval(for: card),
                                decide: model.decide)
                .id("approval-\(card.id)")
        case .note(_, let text):
            Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        case .stopped:
            Text("You stopped the reply.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func scrollFocus(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            switch focus {
            case .approval(let id): proxy.scrollTo("approval-\(id)", anchor: .top)
            case .option(let id, _), .text(let id): proxy.scrollTo(id, anchor: .top)
            default: break
            }
        }
    }

    private func who(_ name: String) -> some View {
        Text(name).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
    }

    /// Inline Markdown only (bold, code, links); a reply that does not parse shows as plain text.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// A question from the Bouncer with options or a text answer.
    private func questionView(_ q: BouncerQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                who("Bouncer")
                if q.isOpen { stateWord("Needs input", .orange) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(q.title).textSelection(.enabled)
                if q.isOpen {
                    if q.takesText {
                        TextField("Your answer", text: Binding(get: { answers[q.id] ?? "" }, set: { answers[q.id] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .text(q.id))
                            .onSubmit { model.answer(q.id, .text(answers[q.id] ?? "")) }
                            .disabled(!model.canInteract)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(q.options.enumerated()), id: \.offset) { i, option in
                                optionButton(q, i, option)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Answer the Bouncer")
                    }
                    HStack {
                        Spacer()
                        Button("Dismiss") { model.answer(q.id, .dismissed) }.disabled(!model.canInteract)
                    }
                } else {
                    Text(answered(q)).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.03), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        }
    }

    private var answers: [String: String] {
        get { BouncerAnswers.shared.text }
        nonmutating set { BouncerAnswers.shared.text = newValue }
    }

    private func optionButton(_ q: BouncerQuestion, _ i: Int, _ option: String) -> some View {
        let id = "\(q.id)-\(i)"
        return Button {
            model.answer(q.id, .option(i))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary)
                Text(option).frame(maxWidth: .infinity, alignment: .leading)
                if q.recommended == i { Text("Recommended").font(.callout).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(state.hovered == id ? 0.08 : 0), in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focus, equals: .option(q.id, i))
        .onHover { hover(id, $0) }
        .disabled(!model.canInteract)
        .accessibilityLabel("\(i + 1): \(option)" + (q.recommended == i ? ", recommended" : ""))
    }

    private func answered(_ q: BouncerQuestion) -> String {
        switch q.answer {
        case .option(let i): return q.options.indices.contains(i) ? "You chose \(i + 1): \(q.options[i])." : "You answered."
        case .text(let text): return "You answered: \(text)"
        case .dismissed: return "You dismissed this question."
        case nil: return ""
        }
    }

    private func stateWord(_ word: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(word).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(spacing: 6) {
                TextEditor(text: Binding(get: { model.draft }, set: { model.draft = $0 }))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 36, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($focus, equals: .prompt)
                    .accessibilityLabel("Message to the Bouncer")
                    .overlay(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text("Message the Bouncer").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 8) {
                    modelMenu
                    Spacer()
                    sendButton
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
            Text("Return sends · Shift-Return adds a line").font(.callout).foregroundStyle(.secondary).padding(.leading, 4)
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    private var modelMenu: some View {
        Menu {
            Picker("Model", selection: Binding(get: { model.modelSelection }, set: { model.setModel($0) })) {
                Text("Default Model").tag(String?.none)
                ForEach(model.models, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(model.model ?? "Default Model")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(state.hovered == "model" ? 0.08 : 0), in: .rect(cornerRadius: 6))
        .onHover { hover("model", $0) }
        .disabled(!model.canInteract)
        .accessibilityLabel("Model")
        .help("The model for the next messages. Default follows the Magpie model in Pi settings.")
    }

    /// Send a message or stop the current reply.
    private var sendButton: some View {
        let replying = model.thread.replying
        let canSend = model.canSend
        return Button { replying ? model.stopReply() : model.send() } label: {
            Image(systemName: replying ? "stop.fill" : "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(replying || canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.5)), in: .circle)
                .overlay { if state.hovered == "send" { Circle().fill(Color.primary.opacity(0.08)) } }
        }
        .buttonStyle(.plain)
        .disabled(model.commandPending || (!replying && !canSend))
        .onHover { hover("send", $0) }
        .accessibilityLabel(replying ? "Stop the reply" : "Send")
    }

    // MARK: Helpers

    private func iconButton(_ id: String, _ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 24)
                .background(Color.primary.opacity(state.hovered == id ? 0.08 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover(id, $0) }
        .help(label)
        .accessibilityLabel(label)
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { state.hovered = id } else if state.hovered == id { state.hovered = nil }
    }
}

/// The text typed into open text questions, by question id, until it is sent.
@MainActor @Observable
final class BouncerAnswers {
    static let shared = BouncerAnswers()
    var text: [String: String] = [:]
}

/// Three dots while the Bouncer replies; still with Reduce Motion.
private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Text("Bouncer is replying").font(.callout).foregroundStyle(.secondary)
            if reduceMotion {
                dots(0)
            } else {
                TimelineView(.animation(minimumInterval: 0.2)) { context in
                    dots(Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func dots(_ lit: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle().fill(.secondary).frame(width: 5, height: 5).opacity(reduceMotion || i == lit ? 1 : 0.35)
            }
        }
        .accessibilityHidden(true)
    }
}

private extension View {
    /// A sidebar row: the accent fill when selected, the grey hover fill under the pointer.
    func sidebarRow(hovered: Bool, selected: Bool = false) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(hovered ? 0.08 : 0)),
                        in: .rect(cornerRadius: 6))
            .contentShape(.rect)
    }
}
