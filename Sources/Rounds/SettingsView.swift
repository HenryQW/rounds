import RoundsCore
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class SettingsState {
    static let shared = SettingsState()
    /// The hooks file the install sheet previews; nil when the sheet is closed.
    var installTarget: HookTarget?
    var error: String?
    let recorder = RecorderState()
    /// While Settings shows, the session window stays open, so changes show in it as they are made.
    var isOpen = false
    /// The page the sidebar shows; optional, as `List` selection is.
    var page: SettingsPage? = .general
    /// The pointer is on Report a Bug, which then shows the grey hover fill.
    var bugHovered = false
    @ObservationIgnored weak var window: NSWindow?
}

/// The Settings pages in the sidebar (spec 5.4), each with a title and one line on what it is for.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, pill, filters, sources, keys
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .pill: "Pill"
        case .filters: "Filters"
        case .sources: "Sources"
        case .keys: "Keys"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .pill: "sidebar.right"
        case .filters: "line.3.horizontal.decrease.circle"
        case .sources: "powerplug"
        case .keys: "keyboard"
        }
    }

    var summary: String {
        switch self {
        case .general: "How Rounds starts, opens sessions and opens its window."
        case .pill: "The pill at the screen edge and the window it opens."
        case .filters: "What Last Call counts, and when a session is Aged."
        case .sources: "Where the live state of each session comes from."
        case .keys: "Keyboard shortcuts in the session window."
        }
    }
}

struct SettingsView: View {
    let model: AppModel
    @Bindable var state: SettingsState
    @Bindable private var drawer = DrawerSettings.shared

    /// Five pages in a sidebar (spec 5.4), each a short grouped form under its title.
    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $state.page) { Label($0.title, systemImage: $0.symbol) }
                .safeAreaInset(edge: .top, spacing: 8) { appHeader }
                .safeAreaInset(edge: .bottom) { VStack(spacing: 0) { reportBug; signature } }
                .navigationSplitViewColumnWidth(230)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            switch state.page ?? .general {
            case .general: page(.general) { general }
            case .pill: page(.pill) { pill }
            case .filters: page(.filters) { filters }
            case .sources: page(.sources) { sources }
            case .keys: page(.keys) { keys }
            }
        }
        // The page title names the page; the window title stays for Mission Control.
        .navigationTitle("Rounds Settings")
        .toolbar(removing: .title)
        // The form scrolls; the window resizes from this minimum (the Settings scene uses .contentMinSize).
        .frame(minWidth: 560, minHeight: 360)
        .background(ResizableWindow())
        .sheet(item: $state.installTarget) { installSheet($0) }
        .onAppear {
            NSApp.activate()
            model.refreshHookStatus()
            state.isOpen = true
            // Each time it opens, at the centre of the screen; it keeps the size the user gave it.
            DispatchQueue.main.async { state.window?.center() }
        }
        .onDisappear {
            state.recorder.stop()
            state.isOpen = false
        }
    }

    /// The sidebar's head (spec 5.4): the app icon, name and version.
    private var appHeader: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text("Rounds").font(.headline)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    /// The sidebar's foot: the author's picture and line; "Henry" is a link to henry.wang in the site's cobalt
    /// (Evidence Blue in dark mode, for contrast on a dark sidebar).
    private var signature: some View {
        HStack(spacing: 8) {
            Bundle.main.image(forResource: "henry").map { Image(nsImage: $0).resizable().frame(width: 24, height: 24).clipShape(.circle) }
            Text("Made with [Henry](https://henry.wang) by AI 🤖.").font(.caption).lineLimit(1).fixedSize()
                .tint(Color(nsColor: Self.cobalt))
            Spacer(minLength: 0)
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
        .padding(8)
    }

    /// Opens a new GitHub issue with the versions filled in (spec 5.4).
    private var reportBug: some View {
        Button { NSWorkspace.shared.open(Self.bugReportURL()) } label: {
            Label("Report a Bug", systemImage: "ladybug")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.primary.opacity(state.bugHovered ? 0.08 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { state.bugHovered = $0 }
        .help("Open a new GitHub issue with the versions filled in")
        .padding(.horizontal, 8)
    }

    /// github.com/HenryQW/rounds/issues/new with the Rounds, macOS, Claude, Codex and herdr versions in the body.
    private static func bugReportURL() -> URL {
        let info = Bundle.main.infoDictionary ?? [:]
        func app(_ url: URL?) -> String {
            url.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "not found"
        }
        let herdr = URL.homeDirectory.appending(path: ".local/bin/herdr")
        let body = """
            **Versions**
            - Rounds \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))
            - macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            - Claude \(app(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")))
            - Codex \(app(URL(string: "codex://").flatMap(NSWorkspace.shared.urlForApplication(toOpen:))))
            - herdr \(Self.output(of: herdr, "--version") ?? "not found")

            **What happened**


            **Steps to reproduce**

            """
        var components = URLComponents(string: "https://github.com/HenryQW/rounds/issues/new")!
        components.queryItems = [URLQueryItem(name: "labels", value: "bug"), URLQueryItem(name: "body", value: body)]
        return components.url!
    }

    /// The first line a command prints, or nil when it is not there or fails.
    private static func output(of executable: URL, _ arguments: String...) -> String? {
        let process = Process(), pipe = Pipe()
        (process.executableURL, process.arguments, process.standardOutput) = (executable, arguments, pipe)
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return process.terminationStatus == 0 ? text.split(separator: "\n").first.map(String.init) : nil
    }

    /// henry.wang's Decisive Cobalt, oklch(0.488 0.217 264.4); in dark mode its Evidence Blue, oklch(0.77 0.116 264.4).
    private static let cobalt = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x8F / 255, green: 0xB3 / 255, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0x1D / 255, green: 0x4E / 255, blue: 0xD8 / 255, alpha: 1)
    }

    private func page(_ page: SettingsPage, @ViewBuilder _ content: () -> some View) -> some View {
        Form {
            // A large title with tight tracking and one line under it, as the page header.
            Section {} header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title).font(.system(size: 20, weight: .semibold)).tracking(-0.4).foregroundStyle(.primary)
                    Text(page.summary).font(.callout).foregroundStyle(.secondary)
                }
            }
            content()
        }
            .formStyle(.grouped)
            // Labels and values are not text to copy; a grouped Form makes LabeledContent values selectable, and the
            // selection would stay highlighted after a click elsewhere.
            .textSelection(.disabled)
    }

    private var general: some View {
        Section {
            Toggle(isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in
                    do {
                        try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        state.error = nil
                    } catch {
                        state.error = "Open at login: \(error.localizedDescription)"
                    }
                })) {
                described("Open at login", "Start Rounds when you log in to your Mac.")
            }
            Picker(selection: $drawer.openClicks) {
                Text("Single Click").tag(1)
                Text("Double-Click").tag(2)
            } label: {
                described("Open a session with", "How a click on a row opens its session.")
            }
            .help("Opens the session in Claude, Codex or herdr. With Double-Click, a single click only selects the row.")
            LabeledContent {
                ShortcutRecorder(shortcut: HotkeyManager.shared.current, state: state.recorder) { HotkeyManager.shared.register($0) }
            } label: {
                described("Session window shortcut", "Opens or closes the session window.")
            }
            .help("Works in any app. With no shortcut, open the window from the pill.")
        } footer: {
            footer(state.error ?? state.recorder.message)
        }
    }

    private var pill: some View {
        Section {
            Picker(selection: $drawer.edge) {
                ForEach(DrawerEdge.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                described("Screen edge", "The edge where the pill shows.")
            }
            LabeledContent {
                // Any value typed in the field, or 0.05 s steps with the arrows; kept inside the range.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField("", value: Binding(get: { drawer.delay },
                                                 set: { drawer.delay = min(max($0, DrawerSettings.delayRange.lowerBound), DrawerSettings.delayRange.upperBound) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 48)
                    Text("s")
                    Stepper("", value: $drawer.delay, in: DrawerSettings.delayRange, step: 0.05).labelsHidden()
                }
            } label: {
                described("Close the window after", "Time after the pointer leaves the window.")
            }
            .help("How long the session window stays open after the pointer leaves it or you go to another app.")
            Toggle(isOn: Binding(get: { model.seenStopsAlert }, set: { model.seenStopsAlert = $0 })) {
                described("Stop the alert for opened sessions", "An opened wait stops the pill ringing.")
            }
            .help("When you open a session, its row dot becomes a ring. An opened result leaves Last Call; an opened wait stays there, but the pill no longer rings for it. When this is off, the pill rings until you answer, and results stay until their state changes.")
            LabeledContent {
                let ids = Set(drawer.displays.map(\.id))
                if !drawer.displaysOff.isDisjoint(with: ids) {
                    Button("Select All") { drawer.displaysOff.subtract(ids) }
                }
            } label: {
                described("Show the pill on", "The displays that show the pill.")
            }
            .help("When no selected display is connected, the built-in display shows the pill.")
            ForEach(drawer.displays) { display in
                Toggle(display.name, isOn: Binding(get: { !drawer.displaysOff.contains(display.id) },
                                                   set: { on in
                                                       if on { drawer.displaysOff.remove(display.id) } else { drawer.displaysOff.insert(display.id) }
                                                   }))
                .toggleStyle(.checkbox)
            }
        } footer: {
            footer(nil, help: "Right-click the pill for Settings and Quit.")
        }
    }

    /// What Last Call counts and when a session is Older (spec 3.2): `AppModel.lastCall`.
    private var filters: some View {
        Section {
            LabeledContent {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(LastCallRule.counted, id: \.self) { s in
                        Toggle(s.title, isOn: Binding(get: { model.lastCall.states.contains(s) }, set: { on in
                            if on { model.lastCall.states.insert(s) } else { model.lastCall.states.remove(s) }
                        }))
                        .toggleStyle(.checkbox)
                    }
                }
            } label: {
                described("Count in Last Call", "Waits stay; opened results leave.")
            }
            .help("Needs input and Failed stay in Last Call until the agent goes on. Ready, Finished and Stopped stay until you open them, in Rounds or in Claude. Right-click Last Call for Mark All as Seen.")
            Toggle(isOn: Binding(get: { model.lastCall.subAgents }, set: { model.lastCall.subAgents = $0 })) {
                described("Count sub-agents in Last Call", "Codex and herdr sub-agents.")
            }
            .help("When this is off, the agent that started a sub-agent handles its result and asks you itself.")
            LabeledContent {
                let days = model.lastCall.agedHours % 24 == 0
                let count = Binding(get: { days ? model.lastCall.agedHours / 24 : model.lastCall.agedHours },
                                    set: { model.lastCall.agedHours = min(max($0, 1), 99) * (days ? 24 : 1) })
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField("", value: count, format: .number).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 40)
                    Stepper("", value: count, in: 1...99).labelsHidden()
                    Picker("", selection: Binding(get: { days }, set: { model.lastCall.agedHours = count.wrappedValue * ($0 ? 24 : 1) })) {
                        Text("Hours").tag(false)
                        Text("Days").tag(true)
                    }
                    .labelsHidden().fixedSize()
                }
            } label: {
                described("Move to Aged after", "No activity for this long.")
            }
            .help("Aged sessions show under the Aged tile and in search. A session that runs, needs input or failed never ages.")
        } footer: {
            footer(nil, help: "Right-click Last Call for Mark All as Seen.")
        }
    }

    private var keys: some View {
        Section {
            ForEach(Self.cheatsheet, id: \.action) { item in
                LabeledContent { keycaps(item.keys) } label: { Text(item.action).labelColumn() }
            }
        } footer: {
            footer(nil, help: "The keys work while the session window is in front.")
        }
    }

    private var sources: some View {
        Section {
            LabeledContent { hookControls(.claude) } label: { source("claude", "Claude Code", "Sessions in the Code tab.") }
                .help("Sessions from the Claude desktop app's Code tab, with live state from async hooks in ~/.claude/settings.json. Remove Hooks turns this source off. Return opens a session through a claude:// link; if Claude only comes to the front, turn on its entry points setting.")
            LabeledContent {
                if model.codexInstalled {
                    hookControls(.codex)
                } else {
                    statusPill("Not found", .gray)
                }
            } label: { source("codex", "Codex", "Threads, state from hooks.") }
                .help("Hooks in ~/.codex/hooks.json; Codex asks you to review new hooks. Remove Hooks turns this source off; without hooks, Rounds reads the thread files, with no waiting state. Return opens the thread in the Codex app.")
            LabeledContent { statusPill(herdrStatus, herdrConnected ? .green : .gray) } label: { source("herdr", "herdr", "Agents from herdr's socket.") }
                .help("The agents herdr runs, from its socket. While herdr is not running, this source is off. For pi states, run herdr integration install pi. Return focuses the agent in herdr.")
        } footer: {
            footer(model.hookError ?? model.codexError ?? model.codexHookError)
        }
    }

    /// Keys of the session window (PanelController.handle and the row menu); keep in step with spec 5.2. Each key in
    /// brackets shows as its own keycap; a space between keycaps parts two shortcuts.
    private static let cheatsheet: [(action: String, keys: String)] = [
        ("Open the session", "[Return]"),
        ("Select the next or previous row", "[↑] [↓]"),
        ("Mark as Done", "[⌘][D]"),
        ("Star or Unstar", "[⌘][S]"),
        ("Hide or Unhide", "[⌘][⌫]"),
        ("Undo or Redo", "[⌘][Z] [⇧][⌘][Z]"),
        ("Show a tile, All to Aged", "[⌘][1] to [⌘][5]"),
        ("Clear the search, then close", "[Esc]"),
        ("More actions", "Right-click a row"),
        ("Move the pill along the edge", "[⌘] and drag"),
    ]

    /// "[⌘][1] to [⌘][5]": each bracketed key in a small keycap with a hairline, the words between as text, and a
    /// wider gap for a space between keycaps.
    private func keycaps(_ spec: String) -> some View {
        var pieces: [(text: String, key: Bool)] = []
        for (i, chunk) in spec.split(separator: "[", omittingEmptySubsequences: false).enumerated() {
            let parts = chunk.split(separator: "]", maxSplits: 1, omittingEmptySubsequences: false)
            if i > 0 { pieces.append((String(parts[0]), true)) }
            let text = (i > 0 ? parts.dropFirst().first : parts.first).map(String.init) ?? ""
            if !text.isEmpty { pieces.append((text.trimmingCharacters(in: .whitespaces), false)) }
        }
        return HStack(spacing: 4) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                if piece.key {
                    Text(piece.text).font(.system(size: 11))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .frame(minWidth: 20)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5))
                } else if piece.text.isEmpty {
                    Color.clear.frame(width: 4, height: 1)
                } else {
                    Text(piece.text).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A state in a small hairline capsule: a dot in its colour (green set up, orange needs action, grey otherwise) and its words.
    private func statusPill(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
    }

    private var herdrConnected: Bool {
        if case .connected = model.herdrConnection { true } else { false }
    }

    private var herdrStatus: String {
        switch model.herdrConnection {
        case .connected(let n): n == 1 ? "Connected · 1 agent" : "Connected · \(n) agents"
        case .notRunning: "Not running"
        case .notInstalled: "Not found"
        }
    }

    /// Section footer: an error in red when there is one, else the help text.
    /// A setting's name and, under it in the secondary colour, what it does (spec 5.4). The same maximum width on
    /// every row keeps the labels one column and the controls another.
    private func described(_ title: String, _ explanation: String) -> some View {
        nameAndExplanation(title, explanation).labelColumn()
    }

    private func nameAndExplanation(_ title: String, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(explanation).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// A source row's label: its icon, its name and where its state comes from.
    private func source(_ name: String, _ title: String, _ explanation: String) -> some View {
        Label { nameAndExplanation(title, explanation) } icon: { Badge.origin(name, size: 16) }.labelColumn()
    }

    @ViewBuilder
    private func footer(_ error: String?, help: String? = nil) -> some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        } else if let help {
            Text(help).foregroundStyle(.secondary)
        }
    }

    /// The hooks' status, and the one action it needs: Remove Hooks, Install Hooks… (the sheet previews the entries) or
    /// Repair Hooks.
    private func hookControls(_ target: HookTarget) -> some View {
        let status = model.hookStatus(target)
        // The status last, so every row's capsule ends on the same edge, with or without a button.
        return HStack(spacing: 8) {
            switch status {
            case .installed: Button("Remove Hooks") { run { try model.removeHooks(target) } }
            case .missing: Button("Install Hooks…") { state.installTarget = target }
            case .wrongPath: Button("Repair Hooks") { run { try model.installHooks(target) } }
            }
            hookStatusLabel(status)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func hookStatusLabel(_ status: HookInstallStatus) -> some View {
        switch status {
        case .installed: statusPill("Installed", .green)
        case .missing: statusPill("Not installed", .orange)
        case .wrongPath: statusPill("Needs repair", .orange)
        }
    }

    /// Shows every entry before anything is written (spec 2.4, 2.6).
    private func installSheet(_ target: HookTarget) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch target {
            case .claude:
                Text("Install Claude Code hooks").font(.headline)
                Text("Rounds adds these entries to ~/.claude/settings.json. Each runs \(model.helperPath) with \"async\": true, so no session waits for it.")
                    .font(.caption)
            case .codex:
                Text("Install Codex hooks").font(.headline)
                Text("Rounds adds these entries to ~/.codex/hooks.json. Each runs \(model.helperPath) with a 10-second timeout; it ends in a few milliseconds.")
                    .font(.caption)
            }
            ForEach(target.entries, id: \.event) { entry in
                Text("\(entry.event)\(entry.matcher.map { "  matcher: \($0)" } ?? "")").font(.system(.caption, design: .monospaced))
            }
            switch target {
            case .claude:
                Text("settings.json is written again with new formatting; a backup is kept at settings.json.rounds-backup.")
                    .font(.caption).foregroundStyle(.secondary)
            case .codex:
                Text("It also sets hooks = true under [features] in ~/.codex/config.toml. Each changed file keeps a backup next to it (.rounds-backup). Codex then asks you to review the new hooks before they run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { state.installTarget = nil }
                Button("Install") {
                    run { try model.installHooks(target) }
                    state.installTarget = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            state.error = nil
        } catch {
            state.error = "\(error)"
        }
        model.refreshHookStatus()
    }
}

extension View {
    /// The label column of every Settings tab: one maximum width, so labels and controls read as two columns.
    func labelColumn() -> some View { frame(maxWidth: 240, alignment: .leading) }
}

/// SwiftUI's Settings window has no resizable style, whatever the scene's resizability; add it, as in a normal window.
/// It first opens at 640 x 560 (room for the sidebar), then keeps the size the user gives it; it opens at the centre of
/// the screen. The frame name is new with the sidebar, so a frame saved for the narrow tab window does not come back.
private struct ResizableWindow: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            guard let window else { return }
            window.styleMask.insert(.resizable)
            // Demo mode neither reads nor saves the frame.
            if Demo.isOn || !window.setFrameUsingName("RoundsSettingsSidebar") {
                window.setContentSize(NSSize(width: 640, height: 560))
                window.center()
            }
            if !Demo.isOn { window.setFrameAutosaveName("RoundsSettingsSidebar") }
            SettingsState.shared.window = window
        }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {}
}
