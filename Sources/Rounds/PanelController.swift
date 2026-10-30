import AppKit
import RoundsCore
import Observation
import SwiftUI

@MainActor @Observable
final class PanelState {
    var selectedId: String?
    var focusToken = 0  // bumped on show, so the search field takes focus
    /// The row under the pointer, drawn with a light fill.
    var hoveredId: String?
    /// The filter tile or source toggle under the pointer, drawn with the same light fill as a row.
    var hoveredControl: String?
    /// The window is as tall as the screen allows, so the list may scroll; below that it fits its rows and shows no scroller.
    var windowAtMaxHeight = false
    /// The height the list's rows and the bars around them take, from SwiftUI layout; the window fits it (spec 5.7).
    @ObservationIgnored var contentHeight: CGFloat = 0
    /// The Quit confirmation shows on the window.
    var confirmQuit = false
    /// Ids of parent rows the user unfolded; parent rows start folded.
    var expanded: Set<String> = []
    /// Ids of folded sections, kept across launches.
    var collapsed = Set(appDefaults.stringArray(forKey: "collapsedSections") ?? []) {
        didSet { appDefaults.set(Array(collapsed), forKey: "collapsedSections") }
    }
    /// Sources the user hid with the source toggles (`SessionRow.sourceName`), kept across launches.
    var hiddenSources = Set(appDefaults.stringArray(forKey: "hiddenSources") ?? []) {
        didSet { appDefaults.set(Array(hiddenSources), forKey: "hiddenSources") }
    }
    /// The status filter, kept across launches.
    var filter = StatusFilter(rawValue: appDefaults.string(forKey: "statusFilter") ?? "") ?? .all {
        didSet {
            appDefaults.set(filter.rawValue, forKey: "statusFilter")
            AppModel.shared.includeOlder = filter == .older
        }
    }
}

/// The session window (spec 5.2): a normal window with system components. The hotkey shows it, or closes it when it is in front.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()
    let state = PanelState()

    override init() {
        super.init()
        model.includeOlder = state.filter == .older
    }
    private let model = AppModel.shared
    private(set) var panel: NSWindow?
    private var keyMonitor: Any?
    private static let frameName = "RoundsWindow"

    func toggle() {
        if panel?.isKeyWindow == true { close() } else { show() }
    }

    /// Makes the window at launch and lays it out, hidden, so SwiftUI knows the list and the bars around it before the
    /// first opening. Made at the first hover instead, the bars took their height during the slide, and the window grew
    /// in three steps (spec 5.7).
    func prepare() {
        let panel = makePanel()
        self.panel = panel
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // No row is selected at rest: a selection marks a row the user chose (↓, ↑ or a click), never one at random.
        state.selectedId = nil
        // While the pill calls (orange, red or green), a hidden window opens on Last Call, where every session it counts
        // is. Demo scenes keep the filter they set.
        if !panel.isVisible, model.yourTurnCount > 0, !Demo.isOn { state.filter = .yourTurn }
        NSApp.activate()
        EdgeDrawer.shared.slideIn(panel)
        state.focusToken += 1
        keyMonitor = keyMonitor ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func close() {
        if let panel { EdgeDrawer.shared.slideOut(panel) }
        model.query = ""
    }

    func open(_ row: SessionRow) {
        model.open(row)
        close()
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        frameLog.debug("resized h=\(panel.frame.height) w=\(panel.frame.width) y=\(panel.frame.minY) live=\(panel.inLiveResize)")
    }

    func windowWillClose(_ notification: Notification) {
        model.query = ""
        // The window is still visible here; the drawer pill shows once it is gone.
        Task { @MainActor in
            await Task.yield()
            EdgeDrawer.shared.apply()
        }
    }

    /// One section per project folder, for the toolbar filter; the id (the project root) keys the folded state.
    func sections() -> [ProjectSection] {
        projectSections(model.groups, filter: state.filter, hiddenSources: state.hiddenSources) { model.root(for: $0) }
    }

    /// A parent row shows its children when the user unfolded it, while a child session needs input, and during a search.
    func isExpanded(_ row: SessionRow) -> Bool {
        state.expanded.contains(row.id) || !model.query.isEmpty || row.children.contains { $0.status.group == .yourTurn }
    }

    /// Session rows the user can see, in list order: rows of folded sections and children of folded rows are left out.
    func visibleRows() -> [SessionRow] {
        sections().filter { !state.collapsed.contains($0.id) }.flatMap(\.rows)
            .flatMap { $0.isContext ? $0.children : isExpanded($0) ? $0.withChildren : [$0] }
    }

    func row(_ id: String?) -> SessionRow? { sections().lazy.flatMap(\.rows).flatMap(\.withChildren).first { $0.id == id } }

    func markDone(_ row: SessionRow) { changeMarks("Mark as Done", of: row) { model.markDone(row) } }

    /// A Claude star is Claude desktop's; Rounds never changes it, so only its own star toggles.
    func toggleStar(_ row: SessionRow) {
        guard row.session?.isStarred != true else { return }
        changeMarks(model.marks.starred.contains(row.id) ? "Unstar" : "Star", of: row) { model.toggleStar(row) }
    }

    func toggleHidden(_ row: SessionRow) {
        let hidden = model.isHidden(row)
        changeMarks(hidden ? "Unhide" : "Hide", of: row) { hidden ? model.unhide(row) : model.hide(row) }
    }

    /// Runs a mark change that ⌘Z can undo; undo puts back the marks from before and selects the row again.
    private func changeMarks(_ name: String, of row: SessionRow, _ action: () -> Void) {
        let before = model.marks
        keepingPosition(of: row, action)
        registerRestore(before, name: name, select: row.id)
    }

    private func registerRestore(_ saved: SessionMarks, name: String, select id: String) {
        guard let undo = panel?.undoManager else { return }
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                let current = target.model.marks
                target.model.restoreMarks(saved)
                target.state.selectedId = id
                target.registerRestore(current, name: name, select: id)
            }
        }
        undo.setActionName(name)
    }

    /// Switches the filter and clears the selection.
    func show(_ filter: StatusFilter) {
        state.filter = filter
        state.selectedId = nil
    }

    /// After the selected row leaves the list, select the row that takes its place.
    private func keepingPosition(of row: SessionRow, _ action: () -> Void) {
        let index = visibleRows().firstIndex { $0.id == row.id } ?? 0
        let wasSelected = state.selectedId == row.id
        action()
        let rows = visibleRows()
        if wasSelected, !rows.contains(where: { $0.id == state.selectedId }) {
            state.selectedId = rows.isEmpty ? nil : rows[min(index, rows.count - 1)].id
        }
    }

    /// ↑/↓ move the list selection and ↵ opens it, also while the search field has focus, so the user can type and
    /// pick without leaving the field. Esc clears the search, then closes.
    /// ⌘D marks the selected row done; ⌘⌫ hides it (with an empty search, else it edits the text).
    /// ⌘1 to ⌘5 pick the tile All, Last Call, On Tap, Served, Aged; ⌘Z and ⇧⌘Z undo and redo (marks and search typing share the window's undo stack).
    private func handle(_ event: NSEvent) -> Bool {
        let editor = panel?.firstResponder as? NSTextView
        // While an input method composes text, its keys belong to it.
        if let editor, editor.hasMarkedText() { return false }
        if event.keyCode == 53 {
            if model.query.isEmpty { close() } else { model.query = "" }
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let digit = event.charactersIgnoringModifiers.flatMap { Int($0) } ?? 0
        switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "d"):
            if let row = row(state.selectedId) { markDone(row) }
            return true
        case (.command, "s"):
            // The row under the pointer, else the selected row.
            if let row = row(state.hoveredId ?? state.selectedId) { toggleStar(row) }
            return true
        case (.command, _) where event.keyCode == 51 && model.query.isEmpty:
            if let row = row(state.selectedId) { toggleHidden(row) }
            return true
        case (.command, _) where (1...StatusFilter.allCases.count).contains(digit):
            show(StatusFilter.allCases[digit - 1])
            return true
        case (.command, "z"): panel?.undoManager?.undo(); return true
        case ([.command, .shift], "z"): panel?.undoManager?.redo(); return true
        default: break
        }
        guard editor?.isFieldEditor != false else { return false }
        let rows = visibleRows()
        let index = rows.firstIndex { $0.id == state.selectedId }
        switch Int(event.keyCode) {
        case 125: state.selectedId = rows.isEmpty ? nil : rows[min((index ?? -1) + 1, rows.count - 1)].id
        case 126: state.selectedId = rows.isEmpty ? nil : rows[max((index ?? 1) - 1, 0)].id
        // Return opens the selected row, or with none selected the first row shown (type, then Return).
        case 36, 76: if let row = index.map({ rows[$0] }) ?? rows.first { open(row) }
        default: return false
        }
        return true
    }

    private func makePanel() -> NSWindow {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: PanelView(model: model, state: state, controller: self))
        host.sceneBridgingOptions = [.toolbars, .title]  // SwiftUI .toolbar and .searchable become the window's toolbar
        panel.contentViewController = host
        panel.minSize = NSSize(width: 360, height: EdgeDrawer.minHeight)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // Demo mode neither reads nor saves the frame.
        if Demo.isOn || !panel.setFrameUsingName(Self.frameName),
           let frame = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            panel.setContentSize(NSSize(width: 420, height: 560))
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height / 3 - size.height / 2))
        }
        if !Demo.isOn { panel.setFrameAutosaveName(Self.frameName) }
        return panel
    }
}
