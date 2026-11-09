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
    /// The sidebar button or status menu under the pointer, which then shows the grey hover fill.
    var hoveredButton: String?
    /// The Linear key as the user types it; cleared once saved (the key itself lives only in the Keychain).
    var linearKey = ""
    /// The sheet that asks for the Linear key shows.
    var linearSheet = false
    /// The channel the push sheet sets up; nil when the sheet is closed.
    var pushSheet: PushChannel?
    /// The push values as the user types them; cleared at any close (the values live only in the Keychain).
    var pushValues: [String: String] = [:]
    /// The Connect sheet checks the values with the service before it saves them.
    var pushChecking = false
    var pushError: String?
    @ObservationIgnored weak var window: NSWindow?
}

/// The Settings pages in the sidebar (spec 5.4), each with a title and one line on what it is for.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, pill, filters, agents, tickets, notifications, history, keys
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .pill: "Pill"
        case .filters: "Filters"
        case .agents: "Agents"
        case .tickets: "Tickets"
        case .notifications: "Notifications"
        case .history: "History"
        case .keys: "Keys"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .pill: "sidebar.right"
        case .filters: "line.3.horizontal.decrease.circle"
        case .agents: "sparkles"
        case .tickets: "ticket"
        case .notifications: "bell"
        case .history: "chart.bar"
        case .keys: "keyboard"
        }
    }

    var summary: String {
        switch self {
        case .general: "How Rounds starts, opens sessions and opens its window."
        case .pill: "The pill at the screen edge and the window it opens."
        case .filters: "What Last Call counts, and when a session is Aged."
        case .agents: "Where the live state of each session comes from."
        case .tickets: "Shows the Linear and GitHub issues of each session."
        case .notifications: "Sounds on this Mac, and remote messages when you are away."
        case .history: "When agents waited for you, in the last 90 days."
        case .keys: "Keyboard shortcuts in the session window."
        }
    }
}

struct SettingsView: View {
    let model: AppModel
    @Bindable var state: SettingsState
    @Bindable private var drawer = DrawerSettings.shared
    @Bindable private var updater = Updater.shared
    @Bindable private var push = PushStore.shared

    /// Eight pages in a sidebar (spec 5.4), each a short grouped form under its title.
    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $state.page) { Label($0.title, systemImage: $0.symbol) }
                .safeAreaInset(edge: .top, spacing: 8) { appHeader }
                .safeAreaInset(edge: .bottom) { VStack(spacing: 0) { checkForUpdates; reportBug; signature } }
                .navigationSplitViewColumnWidth(230)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            switch state.page ?? .general {
            case .general: page(.general) { general }
            case .pill: page(.pill) { pill }
            case .filters: page(.filters) { filters }
            case .agents: page(.agents) { sources }
            case .tickets: page(.tickets) { tickets }
            case .notifications: page(.notifications) { notifications }
            case .history:
                // The data loads when the page opens and goes when it closes.
                page(.history) { HistorySections(model: model, state: HistoryState.shared) }
                    .onAppear { HistoryState.shared.open() }
                    .onDisappear { HistoryState.shared.close() }
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
        // Cancel or any other close clears a key typed but not saved.
        .sheet(isPresented: $state.linearSheet, onDismiss: { state.linearKey = "" }) { linearSheet }
        .sheet(item: $state.pushSheet, onDismiss: { (state.pushValues, state.pushChecking, state.pushError) = ([:], false, nil) }) { pushSheet($0) }
        .onAppear {
            NSApp.activate()
            model.refreshHookStatus()
            // gh may be installed or signed in since the last check.
            if case .signedIn = TicketStore.shared.githubStatus {} else { TicketStore.shared.checkGitHub() }
            state.isOpen = true
            // Each time it opens, at the centre of the screen; it keeps the size the user gave it.
            DispatchQueue.main.async { state.window?.center() }
        }
        .onDisappear {
            state.recorder.stop()
            state.isOpen = false
            // A key typed but not saved does not stay in memory.
            state.linearKey = ""
            state.pushValues = [:]
            HistoryState.shared.close()
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
        sidebarButton("Report a Bug", "ladybug", help: "Open a new GitHub issue with the versions filled in") {
            NSWorkspace.shared.open(Self.bugReportURL())
        }
    }

    /// Sparkle's check for a new version (spec 5.8).
    private var checkForUpdates: some View {
        sidebarButton("Check for Updates…", "arrow.down.circle", help: "Look for a new version of Rounds now", action: Updater.shared.check)
    }

    /// A plain sidebar button with the grey hover fill, like the rows. The symbol has the signature picture's width
    /// and spacing, so the symbols, the picture and the titles line up whatever each symbol's own width.
    private func sidebarButton(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 24)
                Text(title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(state.hoveredButton == title ? 0.08 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { state.hoveredButton = title } else if state.hoveredButton == title { state.hoveredButton = nil } }
        .help(help)
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

    @ViewBuilder private var general: some View {
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
        Section {
            Toggle(isOn: $updater.automaticChecks) {
                described("Check for updates automatically", "Look for a new version once a day.")
            }
            Toggle(isOn: $updater.automaticInstall) {
                described("Install updates automatically", "Download a new version and install it when Rounds quits.")
            }
            .disabled(!updater.automaticChecks)
            Picker(selection: $updater.channel) {
                Text("Stable").tag(Updater.Channel.stable)
                Text("Beta").tag(Updater.Channel.beta)
            } label: {
                described("Update channel", "Beta: a build of each change on the main branch. It can have bugs.")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Updates")
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
            hookRow(.claude, "Claude Code", "Sessions in the Code tab.", found: true)
                .help("Sessions from the Claude desktop app's Code tab, with live state from async hooks in ~/.claude/settings.json. Remove Hooks turns this agent off. Return opens a session through a claude:// link; if Claude only comes to the front, turn on its entry points setting.")
            hookRow(.codex, "Codex", "Threads, state from hooks.", found: model.codexInstalled)
                .help("Hooks in ~/.codex/hooks.json; Codex asks you to review new hooks. Remove Hooks turns this agent off; without hooks, Rounds reads the thread files, with no waiting state. Return opens the thread in the Codex app.")
            hookRow(.pi, "pi", "Sessions, state from an extension.", found: model.piInstalled)
                .help("An extension in ~/.pi/agent/extensions/rounds.ts writes each session's state; pi loads it at its next start. Remove Extension turns this agent off. A session that also runs in herdr shows once, as the herdr agent. Return brings its terminal to the front, or resumes it in a new window.")
            integrationRow("herdr", "Agents from herdr's socket.", logo: Badge.origin("herdr", size: 18)) {
                switch model.herdrConnection {
                case .connected(let n): statusLabel(n == 1 ? "1 agent" : "\(n) agents", .green)
                case .notRunning: statusLabel("Not running", .gray)
                case .notInstalled: statusLabel("Not found", .gray)
                }
            }
                .help("The agents herdr runs, from its socket. While herdr is not running, this agent is off. For pi states, run herdr integration install pi. Return focuses the agent in herdr.")
        } footer: {
            footer(model.hookError ?? model.codexError ?? model.codexHookError)
        }
    }

    /// Where the ticket marks get titles and states (spec 2.8): the Linear key, kept in the Keychain, and the gh sign-in.
    private var tickets: some View {
        let store = TicketStore.shared
        let linear: (line: String, problem: Bool) = switch store.linearStatus {
        case .connected(let workspace) where store.hasLinearKey: ("Issues in \(workspace).", false)
        case .invalidKey where store.hasLinearKey: ("Linear did not accept the key.", true)
        default: ("Titles and states of issues.", false)
        }
        let github: (line: String, problem: Bool) = switch store.githubStatus {
        case .signedIn(let user): ("Your gh account is \(user).", false)
        case .notSignedIn: ("Run gh auth login in a shell.", true)
        case .notFound: ("Install it with brew install gh.", false)
        case .offline, nil: ("Uses the gh command line tool.", false)
        }
        return Section {
            integrationRow("Linear", linear.line, problem: linear.problem, logo: serviceLogo("linear", Self.linearColor)) {
                if store.hasLinearKey {
                    let (word, color): (String, Color) = switch store.linearStatus {
                    case .connected: ("Connected", .green)
                    case .invalidKey: ("Key not valid", .orange)
                    case .offline: ("Offline", .gray)
                    // A saved key waits for its first answer.
                    case .noKey: ("Checking", .gray)
                    }
                    statusMenu("Linear", word, color) {
                        Button("Change Key…") { state.linearSheet = true }
                        Button("Remove Key") { store.removeLinearKey() }
                    }
                } else {
                    Button("Connect…") { state.linearSheet = true }
                }
            }
            .help("Make a personal API key in Linear: Settings, Account, Security and access. Read permission is enough. Rounds sends Linear only branch names, PR links and issue IDs. The key stays in your Keychain.")
            integrationRow("GitHub", github.line, problem: github.problem, logo: serviceLogo("github", Self.githubColor)) {
                let status: (word: String, color: Color)? = switch store.githubStatus {
                case .signedIn: ("Signed in", .green)
                case .notSignedIn: ("Not signed in", .orange)
                case .notFound: ("gh not found", .gray)
                case .offline: ("Offline", .gray)
                // The launch check has not answered yet.
                case nil: nil
                }
                if let status {
                    statusMenu("GitHub", status.word, status.color) { Button("Check Again") { store.checkGitHub() } }
                } else {
                    statusLabel("Checking", .gray)
                }
            }
            .help("Rounds runs gh from Homebrew or ~/.local/bin; sign in with gh auth login. It sends GitHub only repository names and PR and issue numbers.")
        }
    }

    private static let soundStates: [(SessionState, Color)] = [(.needsInput, .orange), (.failed, .red), (.ready, .green)]

    /// Sounds on this Mac and the remote channels (spec 2.9), then what sends and when.
    @ViewBuilder private var notifications: some View {
        Section {
            Toggle(isOn: $push.sounds) { described("Play sounds", "When a session comes into Your Turn.") }
            ForEach(Self.soundStates, id: \.0) { s, color in
                let name = push.soundNames[s] ?? ""
                LabeledContent {
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(get: { name }, set: { push.soundNames[s] = $0 })) {
                            Text("None").tag("")
                            ForEach(PushStore.soundList, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Button { push.play(name) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless)
                            .padding(4)
                            .background(Color.primary.opacity(state.hoveredButton == "play-\(s.rawValue)" ? 0.08 : 0), in: .rect(cornerRadius: 6))
                            .onHover { if $0 { state.hoveredButton = "play-\(s.rawValue)" } else if state.hoveredButton == "play-\(s.rawValue)" { state.hoveredButton = nil } }
                            .help("Play")
                            .disabled(name.isEmpty)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(s.title)
                    }
                }
                .disabled(!push.sounds)
            }
        } header: {
            // The first header after the page title gets the title's small grey style and no gap; this matches "Remote".
            Text("Sounds").font(.headline).foregroundStyle(.primary).padding(.top, 12)
        }
        Section {
            ForEach(PushChannel.allCases) { channel in
                let status = push.status(of: channel)
                let failure: String? = if case .failed(let text) = status { text } else { nil }
                integrationRow(channel.title, failure ?? channel.line, problem: failure != nil, logo: serviceLogo(channel.rawValue, Self.color(channel.color))) {
                    if status == .notSet {
                        Button("Connect…") { state.pushSheet = channel }
                    } else {
                        statusMenu(channel.title, failure == nil ? "Connected" : "Send failed", failure == nil ? .green : .orange) {
                            Button("Send Test") { push.sendTest(channel) }
                            Button("Change…") { state.pushSheet = channel }
                            Button("Remove") { push.remove(channel) }
                        }
                    }
                }
                .help("Rounds sends the state, the session title, the detail and the folder name to Telegram, or to the Bark server and from there to Apple. Never prompt text. The values stay in your Keychain.")
            }
        } header: {
            Text("Remote")
        }
        Section {
            described("Send for", "The states that send a remote message.")
            ForEach(Self.soundStates, id: \.0) { s, color in
                Toggle(isOn: Binding(get: { push.states.contains(s) }, set: { if $0 { push.states.insert(s) } else { push.states.remove(s) } })) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(s.title)
                    }
                }
                .toggleStyle(.checkbox)
            }
            LabeledContent {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField("", value: Binding(get: { push.awayMinutes }, set: { push.awayMinutes = min(max($0, 0), 60) }), format: .number)
                        .multilineTextAlignment(.trailing).monospacedDigit().frame(width: 40)
                    Text("min")
                    Stepper("", value: $push.awayMinutes, in: 0...60).labelsHidden()
                }
            } label: {
                described("Send remote messages after", "Time with no key or pointer input.")
            }
        }
    }

    /// An agent row with hooks or an extension: Install… opens the preview sheet; the status menu repairs or removes
    /// them. An agent not on the Mac shows "Not found".
    private func hookRow(_ target: HookTarget, _ title: String, _ explanation: String, found: Bool) -> some View {
        let status = model.hookStatus(target)
        let remove = target == .pi ? "Remove Extension" : "Remove Hooks"
        var line = explanation, problem = false
        if found, case .wrongPath = status {
            (line, problem) = (target == .pi ? "The extension is out of date." : "Hooks point to an old path.", true)
        }
        // The target's name is its logo's name.
        return integrationRow(title, line, problem: problem, logo: Badge.origin("\(target)", size: 18)) {
            switch found ? status : nil {
            case .installed:
                statusMenu(title, "Installed", .green) { Button(remove) { run { try model.removeHooks(target) } } }
            case .wrongPath:
                statusMenu(title, target == .pi ? "Needs update" : "Needs repair", .orange) {
                    Button(target == .pi ? "Update Extension" : "Repair Hooks") { run { try model.installHooks(target) } }
                    Button(remove) { run { try model.removeHooks(target) } }
                }
            case .missing: Button("Install…") { state.installTarget = target }
            case nil: statusLabel("Not found", .gray)
            }
        }
    }

    /// A row of the Agents and Tickets pages (spec 5.4), as Linear shows its connections: the logo in a hairline tile;
    /// the name and one line on what it does, or in orange what is wrong; and at the end the row's control. The row
    /// takes the full width, with no label column.
    private func integrationRow(_ title: String, _ line: String, problem: Bool = false, logo: some View,
                                @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 10) {
            logoTile(logo)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                // A long workspace or account name ends in "…".
                Text(line).font(.callout).foregroundStyle(problem ? Color.orange : .secondary).lineLimit(1)
            }
            // The words take the room before the gap, so they stay on one line next to the control.
            .layoutPriority(1)
            Spacer(minLength: 8)
            control().fixedSize()
        }
    }

    /// A state's dot (green set up, orange needs action, grey otherwise) and its word. The trailing room is the menus'
    /// hover padding and indicator gap, so the word ends on the same edge as a menu's arrow.
    private func statusLabel(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .padding(.trailing, 10)
    }

    /// A state's dot and a borderless menu, with the word as its label, of what the row can do. The dot is outside the
    /// menu, as a borderless menu drops shapes from its label. The menu shows the grey hover fill, like the rows.
    private func statusMenu(_ id: String, _ text: String, _ color: Color, @ViewBuilder _ items: () -> some View) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 7, height: 7)
            Menu(content: items) { Text(text) }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Color.primary.opacity(state.hoveredButton == id ? 0.08 : 0), in: .rect(cornerRadius: 6))
                .onHover { if $0 { state.hoveredButton = id } else if state.hoveredButton == id { state.hoveredButton = nil } }
        }
    }

    /// A logo in a 28 pt tile with a hairline.
    private func logoTile(_ logo: some View) -> some View {
        logo.frame(width: 18, height: 18)
            .frame(width: 28, height: 28)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator, lineWidth: 0.5))
    }

    /// Asks for the Linear key (spec 5.4); Return saves.
    private var linearSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                logoTile(serviceLogo("linear", Self.linearColor))
                Text("Connect Linear").font(.headline)
            }
            Text("Make a personal API key in Linear: Settings, Account, Security and access. Read permission is enough. The key stays in your Keychain.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("Linear API key", text: $state.linearKey, prompt: Text("Paste the API key")).labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { state.linearSheet = false }
                Button("Save Key", action: saveLinearKey)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.linearKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Asks for the values of a channel (spec 5.4), from its fields; Return saves. Fields start empty.
    private func pushSheet(_ channel: PushChannel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                logoTile(serviceLogo(channel.rawValue, Self.color(channel.color)))
                Text("Connect \(channel.title)").font(.headline)
            }
            Text(channel.hint).font(.callout).foregroundStyle(.secondary)
            Form {
                ForEach(channel.fields, id: \.key) { field in
                    let value = Binding(get: { state.pushValues[field.key, default: ""] }, set: {
                        state.pushValues[field.key] = $0
                        state.pushError = nil
                    })
                    if field.isSecret {
                        SecureField(field.label, text: value, prompt: Text(field.placeholder))
                    } else {
                        TextField(field.label, text: value, prompt: Text(field.placeholder))
                    }
                }
            }
            .formStyle(.columns)
            .disabled(state.pushChecking)
            if let error = state.pushError {
                Text(error).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    state.pushChecking = false
                    state.pushSheet = nil
                }
                Button {
                    let values = state.pushValues
                    state.pushChecking = true
                    Task {
                        let failure = await push.verify(channel, values: values)
                        // Cancel, or a closed sheet, drops the result.
                        guard state.pushChecking, state.pushSheet == channel else { return }
                        state.pushChecking = false
                        if let failure {
                            state.pushError = failure
                        } else {
                            push.save(channel, values: values)
                            state.pushSheet = nil
                        }
                    }
                } label: {
                    if state.pushChecking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                // A field with a default value may stay empty.
                .disabled(state.pushChecking || channel.fields.contains { $0.defaultValue == nil && (state.pushValues[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// A service's one-colour logo (simple-icons, CC0), drawn in its brand colour.
    private func serviceLogo(_ name: String, _ color: Color) -> some View {
        IconCache.image("\(name).svg") { Bundle.main.url(forResource: name, withExtension: "svg") }
            .map { Image(nsImage: $0).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).foregroundStyle(color) }
    }

    private static let linearColor = color(0x5E6AD2)

    private static func color(_ rgb: Int) -> Color {
        Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
    /// GitHub's black (#181717); white in dark mode, where the black does not show on the tile.
    private static let githubColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : NSColor(srgbRed: 0x18 / 255, green: 0x17 / 255, blue: 0x17 / 255, alpha: 1)
    })

    private func saveLinearKey() {
        TicketStore.shared.setLinearKey(state.linearKey)
        state.linearKey = ""
        state.linearSheet = false
    }

    /// Keys of the session window (PanelController.handle and the row menu); keep in step with spec 5.2. Each key in
    /// brackets shows as its own keycap; a space between keycaps parts two shortcuts.
    private static let cheatsheet: [(action: String, keys: String)] = [
        ("Open the session", "[Return]"),
        ("Select the next or previous row", "[↑] [↓]"),
        ("Mark as Done", "[⌘][D]"),
        ("Star or Unstar", "[⌘][S]"),
        ("Why This State", "[⌘][I]"),
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

    /// Section footer: an error in red when there is one, else the help text.
    @ViewBuilder
    private func footer(_ error: String?, help: String? = nil) -> some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        } else if let help {
            Text(help).foregroundStyle(.secondary)
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
            case .pi:
                Text("Install the pi extension").font(.headline)
                Text("Rounds copies rounds.ts to ~/.pi/agent/extensions. On these pi events it writes the session's state, process and session file to ~/Library/Application Support/Rounds/pi; no prompt or model text.")
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
            case .pi:
                Text("No other file changes. pi loads the extension when a session starts; restart running sessions to see their state.")
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

/// A setting's name and, under it in the secondary colour, what it does (spec 5.4). The same maximum width on every row
/// keeps the labels one column and the controls another.
@MainActor func described(_ title: String, _ explanation: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(explanation).font(.callout).foregroundStyle(.secondary)
    }
    .labelColumn()
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
