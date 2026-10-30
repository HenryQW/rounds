import AppKit
import RoundsCore
import Observation
import SwiftUI

/// Which screen edge the session window slides out from (spec 5.7). The pill is the app's only entry point, so it is
/// always at one edge.
enum DrawerEdge: String, CaseIterable {
    case left, right

    var label: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        }
    }
}

@MainActor @Observable
final class DrawerSettings {
    static let shared = DrawerSettings()
    /// The allowed wait before the window slides back, in seconds.
    static let delayRange: ClosedRange<Double> = 0...5

    var edge = DrawerEdge(rawValue: appDefaults.string(forKey: "drawerEdge") ?? "") ?? .right {
        didSet { appDefaults.set(edge.rawValue, forKey: "drawerEdge") }
    }
    /// Seconds without focus before the window slides back.
    var delay = appDefaults.object(forKey: "drawerDelay") as? Double ?? 0.25 {
        didSet { appDefaults.set(delay, forKey: "drawerDelay") }
    }
    /// Displays the user unchecked (`DisplayInfo.id`); every other display, also one connected later, shows a pill.
    var displaysOff = Set(appDefaults.stringArray(forKey: "pillDisplaysOff") ?? []) {
        didSet { appDefaults.set(Array(displaysOff), forKey: "pillDisplaysOff") }
    }
    /// Where the pill's centre sits along the edge, as a part of the visible height from the bottom; ⌘-drag sets it.
    var pillPosition = appDefaults.object(forKey: "pillPosition") as? Double ?? 0.5 {
        didSet { appDefaults.set(pillPosition, forKey: "pillPosition") }
    }
    /// Clicks on a row that open its session in its app: 1 or 2.
    var openClicks = appDefaults.object(forKey: "openClicks") as? Int ?? 2 {
        didSet { appDefaults.set(openClicks, forKey: "openClicks") }
    }
    /// The connected displays, for Settings; the drawer refreshes them when the screens change.
    var displays: [DisplayInfo] = []
}

extension NSScreen {
    /// The display's UUID (stable across restarts and reconnects), its name, and whether it is the built-in one.
    var displayInfo: DisplayInfo {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        let uuid = CGDisplayCreateUUIDFromDisplayID(number).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        return DisplayInfo(id: uuid ?? "\(number)", name: localizedName, builtIn: CGDisplayIsBuiltin(number) != 0)
    }
}

/// The session window as a drawer at a screen edge: a small glass pill stays at the middle of that edge of each chosen
/// display; a click or a hover slides the window out on that display, the full height of its visible frame; when the
/// pointer leaves the window or another app takes focus, the window slides back after the set time and the pills show
/// again.
@MainActor
final class EdgeDrawer {
    static let shared = EdgeDrawer()
    private let settings = DrawerSettings.shared
    /// One pill per display that shows it, by `DisplayInfo.id`.
    private var pills: [String: NSPanel] = [:]
    /// The display the window is on, or slides out on next (the pill the user used).
    private var screen: NSScreen?
    /// The slide back that waits for the set time; a return to the app cancels it.
    private var pendingClose: Task<Void, Never>?
    /// Counts slides, so a slide that a newer one interrupted does not finish (hide the pill or the window).
    private var slides = 0
    /// True while the window slides in: a new height then aims the slide again (`fit`), with no second animation.
    private var sliding = false
    /// Checks the pointer while the drawer is open; `pointerEntered` arms it, `pointerLeftAt` times the slide back.
    private var pointerTimer: Timer?
    private var pointerEntered = false, pointerLeftAt: Date?
    /// A menu from the window (right-click) is outside its frame but still part of it.
    private var menuOpen = false
    /// The pill grows while a session needs input.
    /// The attention panel is larger than the pill: `EdgePill.peek` for the peek, `EdgePill.ripple` for the ring.
    private static let pillSize = NSSize(width: EdgePill.width, height: EdgePill.height),
                       attentionSize = NSSize(width: EdgePill.width + EdgePill.peek + EdgePill.ripple, height: EdgePill.height + 2 * EdgePill.ripple)
    /// Opening: a SwiftUI spring with a slight bounce, run on the window through AppKit's bridge; it overshoots by a
    /// few points and settles. Closing: an ease-in that leaves the screen at full speed (a spring's slow tail would leave a strip
    /// of window at the edge until it settled).
    private static let opening = Animation.spring(duration: 0.45, bounce: 0.25), closing = Animation.easeIn(duration: 0.22)

    /// Called once the app has finished launching (windows cannot be made in `App.init`).
    func start() {
        let actions: [(Notification.Name, @MainActor @Sendable (EdgeDrawer) -> Void)] = [
            (NSApplication.didResignActiveNotification, { $0.closeLater() }),
            (NSApplication.didBecomeActiveNotification, { $0.pendingClose?.cancel() }),
            (NSMenu.didBeginTrackingNotification, { $0.menuOpen = true }),
            (NSMenu.didEndTrackingNotification, { $0.menuOpen = false }),
            (NSApplication.didChangeScreenParametersNotification, { $0.apply() }),
        ]
        for (name, action) in actions {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
        }
        observe()
    }

    /// Puts a pill at the chosen place along the edge of each chosen display, at its size for the current state, and shows the
    /// pills while the window is hidden. A size change while a pill shows grows or shrinks it with a spring. An open
    /// window follows the edge, and moves to a display with a pill when its display has none.
    func apply() {
        let screens = NSScreen.screens
        let infos = screens.map(\.displayInfo)
        if settings.displays != infos { settings.displays = infos }
        let chosen = Set(pillDisplays(infos, off: settings.displaysOff).map(\.id))
        for (id, pill) in pills where !chosen.contains(id) {
            pill.orderOut(nil)
            pills[id] = nil
        }
        let size = AppModel.shared.ringing ? Self.attentionSize : Self.pillSize
        let windowShown = PanelController.shared.panel?.isVisible == true
        for (screen, info) in zip(screens, infos) where chosen.contains(info.id) {
            let pill = pills[info.id] ?? makePill(display: info.id)
            pills[info.id] = pill
            let visible = screen.visibleFrame
            let frame = NSRect(x: settings.edge == .right ? visible.maxX - size.width : visible.minX,
                               y: Self.pillY(settings.pillPosition, height: size.height, in: visible), width: size.width, height: size.height)
            if pill.frame != frame {
                if pill.isVisible, pill.frame.size != frame.size {
                    NSAnimationContext.animate(.spring(duration: 0.6, bounce: 0.25)) { pill.animator().setFrame(frame, display: true) }
                } else {
                    pill.setFrame(frame, display: false)
                }
            }
            if windowShown {
                pill.orderOut(nil)
            } else {
                pill.alphaValue = 1
                pill.orderFrontRegardless()
            }
        }
        if let screen, windowShown {
            let id = screen.displayInfo.id
            self.screen = pills[id] == nil ? shortcutScreen() : NSScreen.screens.first { $0.displayInfo.id == id }
            fit()
        }
    }

    private func observe() {
        withObservationTracking {
            _ = settings.edge
            _ = settings.displaysOff
            _ = settings.pillPosition
            _ = AppModel.shared.ringing
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply()
                self?.observe()
            }
        }
        apply()
    }

    private func makePill(display: String) -> NSPanel {
        let pill = NSPanel(contentRect: NSRect(origin: .zero, size: Self.pillSize), styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: true)
        pill.level = .statusBar
        pill.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        pill.isOpaque = false
        pill.backgroundColor = .clear
        pill.hasShadow = false
        pill.contentView = NSHostingView(rootView: EdgePill(model: AppModel.shared,
                                                            open: { [weak self] in self?.open(display: display) },
                                                            drag: { [weak self] ended in self?.drag(display: display, ended: ended) }))
        return pill
    }

    /// The pill's bottom for a centre at `position` (a part of the visible height), kept inside the visible frame.
    private static func pillY(_ position: Double, height: CGFloat, in visible: NSRect) -> CGFloat {
        min(max(visible.minY + visible.height * position - height / 2, visible.minY), visible.maxY - height)
    }

    /// ⌘-drag: the pill follows the pointer along the edge; at the end, every pill takes the new place.
    private func drag(display: String, ended: Bool) {
        guard let pill = pills[display], let visible = NSScreen.screens.first(where: { $0.displayInfo.id == display })?.visibleFrame
        else { return }
        let position = min(max((NSEvent.mouseLocation.y - visible.minY) / visible.height, 0), 1)
        if ended {
            settings.pillPosition = position
        } else {
            pill.setFrameOrigin(NSPoint(x: pill.frame.minX, y: Self.pillY(position, height: pill.frame.height, in: visible)))
        }
    }

    private func open(display: String) {
        pendingClose?.cancel()
        screen = NSScreen.screens.first { $0.displayInfo.id == display }
        // A hover, or a click on a panel that takes no focus, does not activate the app, and the cooperative
        // `activate()` leaves the other app in front: without focus the drawer would never slide back.
        NSApp.activate(ignoringOtherApps: true)
        PanelController.shared.show()
    }

    /// Where the window slides out when no pill chose it (the shortcut): the display under the pointer if it has a
    /// pill, else the first display with a pill.
    private func shortcutScreen() -> NSScreen? {
        let withPill = NSScreen.screens.filter { pills[$0.displayInfo.id] != nil }
        return withPill.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? withPill.first ?? NSScreen.screens.first
    }

    /// Puts the window at the edge, as tall as its rows, sliding in from off the screen when hidden.
    func slideIn(_ window: NSWindow) {
        pendingClose?.cancel()
        guard let screen = screen ?? shortcutScreen() else { return }
        self.screen = screen
        // SwiftUI lays out every row now, also in a hidden window, so the slide starts at the right height.
        window.contentView?.layoutSubtreeIfNeeded()
        let target = fittedFrame(window, on: screen)
        // An open window of the same size stays (`fit` keeps it at the target), and a slide on its way there goes on: a
        // fit, a second hover on the fading pill or a click just after the hover started the slide again.
        if window.isVisible, target.size == window.frame.size { return window.makeKeyAndOrderFront(nil) }
        frameLog.debug("slideIn h=\(window.frame.height) -> \(target.height) visible=\(window.isVisible) content=\(PanelController.shared.state.contentHeight)")
        let start = hidden(target, on: screen)
        if !window.isVisible {
            window.setFrame(start.frame, display: false)
            window.alphaValue = start.fade ? 0 : 1
        } else {
            // The size changes at once and the spring below moves the window only (no animation ever changes the
            // height): an animated height resizes the window on every frame, and each resize draws the toolbar again.
            window.setFrame(NSRect(origin: NSPoint(x: window.frame.minX, y: target.minY), size: target.size), display: true)
        }
        window.makeKeyAndOrderFront(nil)
        watchPointer(window)
        slides += 1
        sliding = true
        let slide = slides
        // The pills fade while the window comes out of the edge, so the edge is never empty.
        NSAnimationContext.animate(Self.opening) {
            window.animator().setFrameOrigin(target.origin)
            window.animator().alphaValue = 1
            for pill in pills.values { pill.animator().alphaValue = 0 }
        } completion: { [weak self] in
            guard let self, slide == slides else { return }
            sliding = false
            for pill in pills.values {
                pill.orderOut(nil)
                pill.alphaValue = 1
            }
        }
    }

    /// Fits the open window to its content in one step (no animation, see `slideIn`): the list calls it when its height changes,
    /// and `apply` when the edge or the displays change.
    /// One fit for the layout passes of one change: the bars above and below the list (the filter bar, the Another
    /// round? banner) take their height a pass after the list, and a fit for each pass resized the window twice.
    func fitSoon() {
        guard !fitPending else { return }
        fitPending = true
        DispatchQueue.main.async { [weak self] in
            self?.fitPending = false
            self?.fit()
        }
    }
    private var fitPending = false

    func fit() {
        guard let window = PanelController.shared.panel, window.isVisible, let screen else { return }
        let target = fittedFrame(window, on: screen)
        guard target != window.frame else { return }
        frameLog.debug("fit h=\(window.frame.height) -> \(target.height) sliding=\(self.sliding)")
        if sliding { return slideIn(window) }
        window.setFrame(target, display: true)
    }

    /// The window's frame at the edge: the list's rows plus the search, filters and bottom bar around them (the
    /// content height from SwiftUI layout), from `minHeight` up to the visible frame, centred on the pill and kept
    /// inside the visible frame (spec 5.7).
    private func fittedFrame(_ window: NSWindow, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame, width = min(window.frame.width, visible.width)
        // Whole points, as AppKit sets them, so a fitted frame compares equal to the window's.
        let height = min(max(PanelController.shared.state.contentHeight, Self.minHeight), visible.height).rounded()
        let atMax = height >= visible.height
        if PanelController.shared.state.windowAtMaxHeight != atMax { PanelController.shared.state.windowAtMaxHeight = atMax }
        let centre = visible.minY + visible.height * settings.pillPosition
        let y = min(max(centre - height / 2, visible.minY), visible.maxY - height)
        return NSRect(x: settings.edge == .right ? visible.maxX - width : visible.minX, y: y, width: width, height: height)
    }

    /// The window's only minimum height, also for a resize by hand (`makePanel`): a higher content minimum would push a
    /// fitted window back up, and the fit and AppKit would resize it in turns.
    static let minHeight: CGFloat = 300

    /// Slides the window back into the edge while the pills fade in; then hides the window.
    func slideOut(_ window: NSWindow) {
        pendingClose?.cancel()
        pointerTimer?.invalidate()
        guard let screen = screen ?? shortcutScreen() else { return }
        self.screen = nil
        slides += 1
        sliding = false
        let slide = slides
        apply()
        for pill in pills.values where !pill.isVisible {
            pill.alphaValue = 0
            pill.orderFrontRegardless()
        }
        let end = hidden(window.frame, on: screen)
        NSAnimationContext.animate(Self.closing) {
            window.animator().setFrame(end.frame, display: true)
            if end.fade { window.animator().alphaValue = 0 }
            for pill in pills.values { pill.animator().alphaValue = 1 }
        } completion: { [weak self] in
            guard let self, slide == slides else { return }
            window.orderOut(nil)
            window.alphaValue = 1
        }
    }

    /// The window's frame just past the edge. A window cannot be cut at a display's border, so when another display
    /// lies past the edge, the window moves only a short way and fades instead of showing on that display.
    private func hidden(_ frame: NSRect, on screen: NSScreen) -> (frame: NSRect, fade: Bool) {
        let past = frame.offsetBy(dx: settings.edge == .right ? screen.frame.maxX - frame.minX : screen.frame.minX - frame.maxX, dy: 0)
        guard NSScreen.screens.contains(where: { $0 != screen && $0.frame.intersects(past) }) else { return (past, false) }
        return (frame.offsetBy(dx: settings.edge == .right ? 60 : -60, dy: 0), true)
    }

    /// Once the pointer has been in the window, leaving it for the set time slides the window back. Until it enters
    /// (the shortcut opened the window with the pointer elsewhere) only focus loss does. A demo window stays open.
    private func watchPointer(_ window: NSWindow) {
        pointerTimer?.invalidate()
        guard !Demo.isOn else { return }
        (pointerEntered, pointerLeftAt) = (false, nil)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer(window) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func checkPointer(_ window: NSWindow) {
        guard window.isVisible else {
            pointerTimer?.invalidate()
            return
        }
        // A menu, a sheet (the Quit confirmation) or Settings keeps the window open while it shows.
        if menuOpen || window.attachedSheet != nil || SettingsState.shared.isOpen || NSMouseInRect(NSEvent.mouseLocation, window.frame, false) {
            (pointerEntered, pointerLeftAt) = (true, nil)
        } else if pointerEntered {
            let left = pointerLeftAt ?? Date()
            pointerLeftAt = left
            if Date().timeIntervalSince(left) >= settings.delay { PanelController.shared.close() }
        }
    }

    /// After the set time without focus the window slides back, unless the app takes focus again first.
    private func closeLater() {
        guard !Demo.isOn, let window = PanelController.shared.panel, window.isVisible else { return }
        pendingClose?.cancel()
        pendingClose = Task { @MainActor in
            try? await Task.sleep(for: .seconds(settings.delay))
            guard !Task.isCancelled, !NSApp.isActive else { return }
            PanelController.shared.close()
        }
    }
}

/// The pill: an edge tab, square on the screen side, of clear glass with a hairline edge. While sessions run it turns
/// opaque deep blue with the running count in white (about 5:1). While Last Call has sessions it shows their count in
/// near-black: green while only results wait (Ready, Finished, Stopped), still; orange while a session needs input, or
/// red while one failed. A wait the user has not opened makes it ring: it grows (the panel frame, spec 5.7) and peeks. The blue tab is a glass
/// two-thirds full, with fizz that rises behind the count; on the orange tab a cocktail shaker shakes over the count.
/// Both are flat colour with a hairline dark edge, so no wallpaper shows through and the tab reads on any wallpaper. Every 2 s it peeks: it eases `peek` points out from the edge
/// with a small bounce, rests, and slides back; never a colour change.
/// Right-click: Settings and Quit, since there is no menu bar item. ⌘-drag moves it along the edge; a hover with ⌘
/// down does not open the window, so the pill can be grabbed.
private struct EdgePill: View {
    static let peek: CGFloat = 12, ripple: CGFloat = 30
    static let width: CGFloat = 28, height: CGFloat = 100
    /// Square on the screen side and round on the inner side, so the pill reads as part of the edge.
    static var shape: UnevenRoundedRectangle {
        let r: CGFloat = 12
        return DrawerSettings.shared.edge == .right
            ? UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r)
            : UnevenRoundedRectangle(bottomTrailingRadius: r, topTrailingRadius: r)
    }
    let model: AppModel
    let open: () -> Void
    /// Called while the pill is dragged (false) and once at the end (true).
    let drag: (_ ended: Bool) -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let waiting = model.yourTurnCount, running = model.runningCount, ringing = model.ringing, failing = model.failedCount > 0
        Button(action: open) {
            ZStack {
                if model.waitCount > 0 {
                    // Red wins over orange: a failed turn stopped and does not go on by itself.
                    tab(failing ? Color(nsColor: .systemRed) : Color(nsColor: .systemOrange), count: waiting,
                        ink: failing ? Color(red: 0.2, green: 0.02, blue: 0.02) : Color(red: 0.17, green: 0.1, blue: 0), broken: failing)
                } else if waiting > 0 {
                    tab(Color(nsColor: .systemGreen), count: waiting, ink: Color(red: 0.02, green: 0.16, blue: 0.06), symbol: "wineglass.fill")
                } else if running > 0 {
                    tab(.roundsBlue, count: running, ink: .white, pour: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: ringing ? EdgePill.height : .infinity)
            .contentShape(EdgePill.shape)
            .modifier(Peek(on: ringing && !reduceMotion, color: Color(nsColor: failing ? .systemRed : .systemOrange)))
            .animation(.smooth(duration: 0.6), value: ringing)
        }
        .buttonStyle(.plain)
        .glassEffect(waiting > 0 || running > 0 ? .identity : .clear, in: EdgePill.shape)
        .overlay { if waiting == 0 && running == 0 { EdgePill.shape.strokeBorder(.primary.opacity(0.25), lineWidth: 1) } }
        // The pill keeps to the screen edge; the panel's spare room around it is where it peeks and the ring grows.
        // Only the pill takes the hover and the click.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: DrawerSettings.shared.edge == .right ? .trailing : .leading)
        .highPriorityGesture(DragGesture(minimumDistance: 2).modifiers(.command)
            .onChanged { _ in drag(false) }
            .onEnded { _ in drag(true) })
        .onHover { if $0, !NSEvent.modifierFlags.contains(.command) { open() } }
        .contextMenu {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Divider()
            Button("Quit Rounds") { NSApp.terminate(nil) }
        }
        .help("Open Rounds. ⌘-drag to move.")
        .accessibilityLabel("Open Rounds")
        .accessibilityValue(waiting > 0 ? "\(waiting) in Last Call" + (failing ? ", \(model.failedCount) failed" : "") : running > 0 ? "\(running) running" : "")
    }

    /// An opaque tab with the count: poured (`pour`), with a drink and fizz behind the count, or under a cocktail shaker
    /// that shakes as the pill peeks, or a glass that shakes and breaks (`broken`). Still with Reduce Motion, and while no unseen wait rings (the glass
    /// broken).
    private func tab(_ fill: Color, count: Int, ink: Color, pour: Bool = false, symbol: String? = nil, broken: Bool = false) -> some View {
        ZStack {
            EdgePill.shape.fill(fill)
                .overlay(alignment: .bottom) {
                    if pour {
                        // A darker drink, so the white count keeps about 7:1 (a lighter one gave 3.7:1).
                        Color.black.opacity(0.18).frame(height: EdgePill.height * 0.6)
                        if !reduceMotion {
                            Fizz(x: -4, size: 4, period: 1.9)
                            Fizz(x: 3, size: 3, period: 2.6)
                        }
                    }
                }
                .clipShape(EdgePill.shape)
                .overlay(EdgePill.shape.strokeBorder(.black.opacity(0.3), lineWidth: 0.5))
            VStack(spacing: 7) {
                if let symbol {
                    // A served glass, still: a result waits, nothing is blocked.
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                } else if !pour {
                    // The same 2 s cycle as the peek, which starts 0.1 s after the pill turns orange.
                    TimelineView(.periodic(from: .now.addingTimeInterval(-1.9), by: 2)) { context in
                        if broken {
                            // At rest the glass is broken (the start and the end); each peek makes it whole, shakes it like
                            // the shaker, then breaks it.
                            KeyframeAnimator(initialValue: Break(), trigger: reduceMotion || !model.ringing ? nil : context.date) { b in
                                BrokenGlass(broken: b.broken, color: ink, lineWidth: 1.5).frame(width: 11, height: 14)
                                    .rotationEffect(.degrees(b.angle), anchor: .bottom)
                            } keyframes: { _ in
                                KeyframeTrack(\.angle) {
                                    for angle in [-16.0, 16, -16, 16, -16, 16] { LinearKeyframe(angle, duration: 0.09) }
                                    SpringKeyframe(0, duration: 0.2)
                                }
                                KeyframeTrack(\.broken) {
                                    MoveKeyframe(0)
                                    LinearKeyframe(0, duration: 0.6)
                                    LinearKeyframe(1, duration: 0.4)
                                }
                            }
                        } else {
                            Shaker().frame(width: 10, height: 16)
                                .keyframeAnimator(initialValue: 0.0, trigger: reduceMotion || !model.ringing ? nil : context.date) { view, angle in
                                    view.rotationEffect(.degrees(angle))
                                } keyframes: { _ in
                                    KeyframeTrack {
                                        for angle in [-16.0, 16, -16, 16, -16, 16] { LinearKeyframe(angle, duration: 0.09) }
                                        SpringKeyframe(0, duration: 0.2)
                                    }
                                }
                        }
                    }
                }
                Text("\(count)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .tracking(-0.2)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 2)
            }
            .foregroundStyle(ink)
        }
    }

    /// The failed pill's glass in one peek: its shake angle and how far it is broken (`BrokenGlass.broken`).
    private struct Break { var angle = 0.0, broken = 1.0 }

    /// A cocktail shaker (no SF Symbol has one): a cap, a strainer top and a tin that narrows to the base.
    private struct Shaker: Shape {
        func path(in r: CGRect) -> Path {
            func x(_ f: CGFloat) -> CGFloat { r.minX + f * r.width }
            func y(_ f: CGFloat) -> CGFloat { r.minY + f * r.height }
            var p = Path()
            p.addRoundedRect(in: CGRect(x: x(0.36), y: y(0), width: 0.28 * r.width, height: 0.1 * r.height), cornerSize: CGSize(width: 1, height: 1))
            p.addLines([CGPoint(x: x(0.3), y: y(0.14)), CGPoint(x: x(0.7), y: y(0.14)), CGPoint(x: x(0.86), y: y(0.4)), CGPoint(x: x(0.14), y: y(0.4))])
            p.closeSubpath()
            p.addLines([CGPoint(x: x(0.08), y: y(0.45)), CGPoint(x: x(0.92), y: y(0.45)), CGPoint(x: x(0.8), y: y(1)), CGPoint(x: x(0.2), y: y(1))])
            p.closeSubpath()
            return p
        }
    }

    /// A bubble that rises 70 pt from the bottom of the blue tab and fades, every `period` s; `x` is from the middle.
    private struct Fizz: View {
        let x: CGFloat, size: CGFloat, period: Double

        var body: some View {
            Circle().fill(.white).frame(width: size, height: size)
                .keyframeAnimator(initialValue: 0.0, repeating: true) { view, t in
                    view.offset(x: x, y: -8 - 70 * t).opacity(t < 0.15 ? t / 0.15 : (1 - t) / 0.85)
                } keyframes: { _ in
                    KeyframeTrack { LinearKeyframe(1.0, duration: period) }
                }
        }
    }

    /// Every 2 s the attention pill peeks, and a ring in its colour (orange, or red for a failure) grows out of it and fades (`ring` goes 0 to 1); off, the
    /// pill fills its panel (and no animation runs). The timeline starts each cycle, so no frames are drawn while the
    /// pill rests between peeks.
    private struct Peek: ViewModifier {
        let on: Bool, color: Color

        private struct Phase { var width: CGFloat, ring = 0.0 }

        func body(content: Content) -> some View {
            if on {
                let edge: UnitPoint = DrawerSettings.shared.edge == .right ? .trailing : .leading
                // The first tick is 1.9 s back, so the first peek starts 0.1 s after the pill turns orange.
                TimelineView(.periodic(from: .now.addingTimeInterval(-1.9), by: 2)) { context in
                    content.keyframeAnimator(initialValue: Phase(width: EdgePill.width), trigger: context.date) { view, phase in
                        view.frame(width: phase.width)
                            .overlay {
                                // Grows from the screen edge, inwards and up and down, into the panel's spare room.
                                EdgePill.shape.strokeBorder(color, lineWidth: 3)
                                    .scaleEffect(1 + 0.7 * phase.ring, anchor: edge)
                                    .opacity(phase.ring == 0 ? 0 : 1 - phase.ring)
                                    .allowsHitTesting(false)
                            }
                    } keyframes: { _ in
                        KeyframeTrack(\.width) {
                            SpringKeyframe(EdgePill.width + EdgePill.peek, duration: 0.35, spring: .bouncy)
                            LinearKeyframe(EdgePill.width + EdgePill.peek, duration: 0.3)
                            SpringKeyframe(EdgePill.width, duration: 0.45, spring: .smooth)
                        }
                        KeyframeTrack(\.ring) {
                            MoveKeyframe(0)
                            CubicKeyframe(1, duration: 1.2)
                        }
                    }
                }
            } else {
                content
            }
        }
    }
}
