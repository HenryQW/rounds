import AppKit
import RoundsCore
import SwiftUI

/// One look per standard state (GLOSSARY.md): filled for states that want the user (orange, red, green), a ring once
/// seen and for quiet ones, a dashed ring when the live state is unknown.
struct StatusDot: View {
    let status: SessionStatus
    /// A session in Your Turn that the user opened since is a ring, not a filled dot.
    var seen = false

    var body: some View {
        switch status.state {
        case .needsInput: dot(seen ? "circle" : "circle.fill", .orange)
        case .failed: dot(seen ? "circle" : "circle.fill", .red)
        case .working: dot("circle.fill", .blue).symbolEffect(.pulse)
        case .background: dot("circle", .blue)
        case .ready: dot(seen ? "circle" : "circle.fill", .green)
        case .finished, .stopped: dot("circle", .gray)
        case .offline: dot("circle.dashed", .gray)
        }
    }

    /// An 8 pt column whatever the glyph's own width, so the icon and the title land on the grid (spec 5.2).
    private func dot(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(color).frame(width: 8)
    }
}

/// A small glass for live work (spec 5.2) that fills and empties while the agent works: it fills to 80 % in 70 % of a
/// pour, stays full, and empties to 10 %. The seed picks the speed (2.4 to 3.2 s a pour) and the start, so glasses
/// never fill in step; the same seed keeps the same glass. Two-thirds full and still with Reduce Motion. Blue in a grey
/// outline, or white on a selected row.
struct PourGlass: View {
    let seed: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.backgroundProminence) private var prominence

    /// A tumbler: wide at the rim, narrow at the base.
    private struct Glass: Shape {
        func path(in r: CGRect) -> Path {
            let inset = r.width * 0.12
            return Path { $0.addLines([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                       CGPoint(x: r.maxX - inset, y: r.maxY), CGPoint(x: r.minX + inset, y: r.maxY)]); $0.closeSubpath() }
        }
    }

    /// The level (0...1) at `t`, a part of one pour (0..<1).
    private static func level(_ t: Double) -> CGFloat {
        let ease = { (x: Double) in x * x * (3 - 2 * x) }
        return 0.1 + 0.7 * (t < 0.7 ? ease(t / 0.7) : t < 0.85 ? 1 : 1 - ease((t - 0.85) / 0.15))
    }

    /// A number in 0..<1 from a seed and an index (SplitMix64).
    private static func unit(_ seed: Int, _ i: Int) -> Double {
        var z = UInt64(bitPattern: Int64(seed)) &+ UInt64(bitPattern: Int64(i)) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }

    private func glass(_ level: CGFloat) -> some View {
        let selected = prominence == .increased
        return (selected ? Color.white : .blue).scaleEffect(x: 1, y: level, anchor: .bottom)
            .clipShape(Glass())
            .overlay(Glass().stroke(selected ? .white : .secondary, lineWidth: 1))
    }

    var body: some View {
        Group {
            if reduceMotion {
                glass(0.66)
            } else {
                let period = 2.4 + 0.8 * Self.unit(seed, 1), start = 100 * Self.unit(seed, 2)
                TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                    let t = (context.date.timeIntervalSinceReferenceDate + start) / period
                    glass(Self.level(t - t.rounded(.down)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A broken glass for a failure (spec 5.2): a tumbler whose rim lost a shard. `broken` runs the break from 0 (whole) to
/// 1: a crack runs down from the rim in the first half, and the shard tips off in the second. Still on a row (only live
/// work moves there); the failed pill shakes it and breaks it as it peeks. Red, or white on a selected row; `color` sets
/// it on the pill.
struct BrokenGlass: View {
    var broken = 1.0
    var color: Color = .red
    var lineWidth: CGFloat = 1
    @Environment(\.backgroundProminence) private var prominence

    /// Lines through points of the glass's unit square: a tumbler 12 % narrower at the base; the shard is the right of
    /// the rim, down to 35 % of the right side.
    private struct Lines: Shape {
        let points: [CGPoint]
        func path(in r: CGRect) -> Path {
            Path { $0.addLines(points.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) }) }
        }
    }
    private static let outline = [CGPoint(x: 0.7, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0.12, y: 1), CGPoint(x: 0.88, y: 1), CGPoint(x: 0.958, y: 0.35)]
    private static let crack = [CGPoint(x: 0.7, y: 0), CGPoint(x: 0.75, y: 0.2), CGPoint(x: 0.6, y: 0.5), CGPoint(x: 0.68, y: 0.8)]
    private static let split = [CGPoint(x: 0.75, y: 0.2), CGPoint(x: 0.958, y: 0.35)]
    private static let shard = [CGPoint(x: 0.7, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0.958, y: 0.35), CGPoint(x: 0.75, y: 0.2), CGPoint(x: 0.7, y: 0)]

    var body: some View {
        let ink = prominence == .increased ? Color.white : color
        let crack = min(broken * 2, 1), fall = max(broken * 2 - 1, 0)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        ZStack {
            Lines(points: Self.outline).stroke(ink, style: style)
            Lines(points: Self.crack).trim(from: 0, to: crack).stroke(ink, style: style)
            Lines(points: Self.split).trim(from: 0, to: crack).stroke(ink, style: style)
            // Whole, the shard's own break line is hidden, so the rim reads as one line.
            Lines(points: Array(Self.shard.prefix(fall > 0 ? 5 : 3))).stroke(ink, style: style)
                // A small tip, so the glass keeps about the width of the pour glass.
                .rotationEffect(.degrees(15 * fall), anchor: UnitPoint(x: 0.96, y: 0.35))
                .offset(x: 0.5 * fall, y: 2.5 * fall)
        }
        .accessibilityHidden(true)
    }
}

extension Color {
    /// The Rounds blue (#0A6BDB): the app icon, the running pill and "Another Round?". White on it keeps about 5:1.
    static let roundsBlue = Color(red: 0.04, green: 0.42, blue: 0.86)
}

/// The session window's content: one section per project, a status filter and search in the toolbar; actions are in
/// the row menu. Session details are read in Claude. The rows are a plain stack in a scroll view, so SwiftUI knows
/// their real height and the window fits it (spec 5.7).
struct PanelView: View {
    @Bindable var model: AppModel
    @Bindable var state: PanelState
    let controller: PanelController
    @FocusState private var searchFocused: Bool

    /// Three left edges on a 4 pt grid (spec 5.2): 16 for the bars, the section icon and the chevron; 40 for the section
    /// name and the row dot under it; 82 for the row title, where children start. Fills start 8 from the window edge.
    /// A top-level row's chevron column: the chevron of a parent row, empty on other rows, so the titles line up.
    static let disclosureWidth: CGFloat = 16, disclosureSpacing: CGFloat = 8
    /// From a top-level row's leading edge to its title: child rows and task lines start there.
    static let childInset = disclosureWidth + disclosureSpacing + ContextRow.titleInset

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy (at most about 100 rows): every row is laid out, so the height is real.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.sections()) { section($0) }
                    // In the content, not an overlay, so the window fits it: an overlay got what the bars left of the
                    // minimum height, and showed only a scroll bar.
                    if anotherRound {
                        AnotherRound(model: model, state: state, controller: controller).padding(.vertical, 24)
                    } else if controller.sections().isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: "spigot").padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(state.windowAtMaxHeight ? .automatic : .never)
            // The rows and the bars around them (the scroll view's insets): the height the window fits.
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentSize.height, $0.contentInsets.top, $0.contentInsets.bottom] } action: { old, parts in
                let height = parts.reduce(0, +)
                frameLog.debug("content \(old.reduce(0, +), privacy: .public) -> \(height, privacy: .public) list=\(parts[0], privacy: .public) top=\(parts[1], privacy: .public) bottom=\(parts[2], privacy: .public) rows=\(controller.visibleRows().count) yourTurn=\(model.groups.yourTurn.count) filter=\(state.filter.rawValue, privacy: .public) query=\(model.query.count)")
                state.contentHeight = height
                EdgeDrawer.shared.fitSoon()
            }
            // ↑ and ↓ move the selection (PanelController.handle); the selected row scrolls into view.
            .onChange(of: state.selectedId) { _, id in if let id { proxy.scrollTo(id) } }
        }
        // The toolbar search field takes the free toolbar width, so the filter sits in a bar below it (like Finder's search scopes).
        .safeAreaInset(edge: .top, spacing: 0) {
            FilterBar(model: model, state: state, controller: controller)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        // A bar, not an inset: the list gets a hard scroll edge under it, so rows do not show behind the buttons.
        .safeAreaBar(edge: .bottom) {
            HStack(alignment: .center, spacing: 8) {
                // The brand mark: the app icon and name (spec 5.2).
                Label { Text("Rounds").foregroundStyle(.secondary) } icon: {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 16, height: 16)
                }
                .font(.caption)
                if let notice { Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings (⌘,)")
                    .accessibilityLabel("Settings")
                // Red: quitting stops the pill and every alert.
                Button("Quit Rounds", systemImage: "power") { state.confirmQuit = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Quit Rounds")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .navigationTitle("Rounds")
        .alert("Quit Rounds?", isPresented: $state.confirmQuit) {
            Button("Quit", role: .destructive) { NSApp.terminate(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The pill and its alerts stop until you open Rounds again.")
        }
        // The search field takes the toolbar width; the title still names the window in Mission Control.
        .toolbar(removing: .title)
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search Sessions")
        .searchFocused($searchFocused)
        .frame(minWidth: 360)
        .onChange(of: state.focusToken) { searchFocused = true }
        .onChange(of: model.groups) {
            if state.selectedId != nil, controller.row(state.selectedId) == nil { state.selectedId = nil }
        }
    }

    /// Under Last Call, with no session of a shown source in Your Turn, no search and a source on (spec 5.2); starred
    /// rows stay above it.
    private var anotherRound: Bool {
        state.filter == .yourTurn && model.query.isEmpty && !model.newSessionApps.isEmpty
            && !model.allGroups.sessions.contains { $0.status.group == .yourTurn && !state.hiddenSources.contains($0.sourceName) }
    }

    private var emptyTitle: String {
        if !model.query.isEmpty { return "No Matches" }
        switch state.filter {
        case .all: return "No Sessions"
        case .yourTurn: return "Nothing Needs You"
        case .running: return "Nothing on Tap"
        case .quiet: return "Nothing Served"
        case .older: return "Nothing Aged"
        }
    }

    private var notice: String? {
        if let banner = model.banner { return banner }
        if !model.claudeOn { return "Claude Code is off. Install its hooks in Settings to turn it on." }
        return nil
    }

    @ViewBuilder
    private func actions(_ row: SessionRow) -> some View {
        // Shortcuts are shown here; PanelController handles the keys.
        Button(row.openLabel) { controller.open(row) }.keyboardShortcut(.return, modifiers: [])
        Button("Mark as Done") { controller.markDone(row) }.keyboardShortcut("d")
        if row.session?.isStarred == true {
            Text("Starred in Claude")
        } else {
            Button(model.marks.starred.contains(row.id) ? "Unstar" : "Star") { controller.toggleStar(row) }.keyboardShortcut("s")
        }
        Button(model.isHidden(row) ? "Unhide" : "Hide") { controller.toggleHidden(row) }.keyboardShortcut(.delete)
        Divider()
        ForEach(row.pullRequests, id: \.url) { pr in
            Button(pr.openLabel) { NSWorkspace.shared.open(pr.url) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.cwd)]) }
        if let branch = row.branch {
            Button("Copy Branch Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(branch, forType: .string)
            }
        }
    }

    /// A project's header and, unless it is folded, its rows. A click on the header folds or unfolds the section.
    @ViewBuilder
    private func section(_ project: ProjectSection) -> some View {
        let folded = state.collapsed.contains(project.id), hoverId = "section:" + project.id
        Button {
            if folded { state.collapsed.remove(project.id) } else { state.collapsed.insert(project.id) }
        } label: {
            HStack(spacing: 8) {
                if project.id == ProjectSection.starredId {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).frame(width: 16)
                } else {
                    Badge.project(project.id, name: project.name, size: 16)
                }
                // A small tracked label, as section names are taxonomy, not titles.
                Text(project.name).foregroundStyle(.secondary).tracking(0.4)
                Text("\(project.rows.count)").foregroundStyle(.tertiary).monospacedDigit()
                Spacer(minLength: 0)
                // As in a sidebar, the chevron shows under the pointer.
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .opacity(state.hoveredControl == hoverId ? 1 : 0)
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(state.hoveredControl == hoverId ? 0.08 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 16)
        .onHover { hover(hoverId, $0) }
        .help(project.id == ProjectSection.starredId ? "Sessions you starred here (⌘S) or in Claude" : project.id)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(folded ? "Folded" : "Unfolded")
        if !folded {
            ForEach(project.rows) { row in
                if row.isContext {
                    // Under a filter: the parent of the matching children, grey and without a dot; the children start
                    // under its title.
                    ContextRow(row: row).padding(.leading, Self.disclosureWidth + Self.disclosureSpacing).rowInsets()
                    ForEach(row.children) { rowView($0, subtitle: label($0.status), child: true) }
                } else {
                    rowView(row, subtitle: row.subtitle(folded: !controller.isExpanded(row), label: label(row.status)))
                    if controller.isExpanded(row) {
                        // Child sessions are rows like any other; background tasks are lines that cannot be selected.
                        ForEach(row.children) { rowView($0, subtitle: label($0.status), child: true) }
                        ForEach(Array(row.status.tasks.enumerated()), id: \.offset) {
                            TaskLine(task: $1).childLine().padding(.leading, Self.childInset).rowInsets()
                        }
                    }
                }
            }
        }
    }

    /// Under a status filter the filter names the state, so a row says only its detail (spec 5.2).
    private func label(_ status: SessionStatus) -> String { state.filter == .all ? status.label : status.shortLabel }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { state.hoveredControl = id } else if state.hoveredControl == id { state.hoveredControl = nil }
    }

    /// A session row: a click selects it, and opens it with one click to open; a double-click opens it with two. The
    /// selected row has the accent fill of a sidebar selection, the row under the pointer the grey hover fill.
    private func rowView(_ row: SessionRow, subtitle: String, child: Bool = false) -> some View {
        let selected = state.selectedId == row.id, hovered = state.hoveredId == row.id
        let content = SessionRowView(row: row, subtitle: subtitle, icon: !child, state: state)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { controller.open(row) }
        return Group {
            if child {
                content.childLine().padding(.leading, Self.childInset)
            } else {
                content.padding(.leading, Self.disclosureWidth + Self.disclosureSpacing)
            }
        }
        .rowInsets()
        .contentShape(.rect)
        .onTapGesture {
            state.selectedId = row.id
            if DrawerSettings.shared.openClicks == 1 { controller.open(row) }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if DrawerSettings.shared.openClicks == 2 { controller.open(row) } })
        // After the clicks above, so a click on the chevron only folds or unfolds.
        .overlay(alignment: .leading) { if !child { disclosure(row).padding(.leading, 8) } }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .environment(\.backgroundProminence, selected ? .increased : .standard)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(hovered ? 0.08 : 0)))
                .animation(.smooth(duration: 0.15), value: hovered)
        }
        .onHover { inside in
            if inside { state.hoveredId = row.id } else if state.hoveredId == row.id { state.hoveredId = nil }
        }
        .contextMenu { actions(row) }
        .id(row.id)
    }

    /// The chevron of a row with child sessions or background tasks; other rows keep the column empty.
    @ViewBuilder
    private func disclosure(_ row: SessionRow) -> some View {
        if row.children.isEmpty && row.status.tasks.isEmpty {
            Color.clear.frame(width: Self.disclosureWidth)
        } else {
            let open = controller.isExpanded(row)
            Button {
                if open { state.expanded.remove(row.id) } else { state.expanded.insert(row.id) }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: Self.disclosureWidth, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Hide Child Sessions" : "Show Child Sessions")
        }
    }
}

/// Under a status filter, the parent of matching children that does not match itself: its icon and title in grey,
/// no dot, not selectable.
struct ContextRow: View {
    /// From a row's leading edge to its title: the dot, the icon and their spacing. Children start there.
    static let titleInset: CGFloat = 8 + 8 + 18 + 8
    let row: SessionRow

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: row.status).hidden()
            Badge.origin(row.sourceName, size: 18).opacity(0.45)
            Text(row.title).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// One background task under its session: a symbol for its type and its description, in one line.
struct TaskLine: View {
    let task: RoundsCore.BackgroundTask

    var body: some View {
        Label(task.description.isEmpty ? task.type : task.description, systemImage: symbol)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    private var symbol: String {
        switch task.type {
        case "shell": "terminal"
        case "subagent": "person.crop.circle"
        case "workflow": "flowchart"
        default: "gearshape"
        }
    }
}

extension View {
    /// The thin line on the leading side of a parent row's children.
    func childLine() -> some View {
        overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1).padding(.vertical, -3).offset(x: -10) }
    }

    /// The space between a row's edge (its selection and hover fill) and its content, as in a sidebar list.
    fileprivate func rowInsets() -> some View { padding(.horizontal, 8).padding(.vertical, 4) }
}

struct SessionRowView: View {
    /// Direct: in the parent's folder; Isolated: in a folder of its own, by name (spec 5.2).
    private var kind: Text {
        row.isIsolated
            ? Text("\(Image(systemName: "arrow.triangle.branch")) Isolated: \(URL(fileURLWithPath: row.cwd).lastPathComponent)")
            : Text("\(Image(systemName: "folder")) Direct")
    }

    let row: SessionRow
    let subtitle: String
    /// Child rows leave out the source icon (their parent shows it) and say if they work in the parent's folder.
    var icon = true
    let state: PanelState

    var body: some View {
        // The dot and the icon centre on the middle of the title's capitals, not on its baseline.
        let capMiddle = NSFont.preferredFont(forTextStyle: .body).capHeight / 2
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(status: row.status, seen: row.isSeen).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + capMiddle }
            if icon {
                Badge.origin(row.sourceName, size: 18).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + capMiddle }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).fontWeight(.medium).lineLimit(1)
                (icon ? Text(subtitle) : Text("\(subtitle) · \(kind)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if row.status.state == .working {
                PourGlass(seed: row.id.hashValue).frame(width: 12, height: 14).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + capMiddle }
            } else if row.status.state == .failed {
                BrokenGlass().frame(width: 12, height: 14).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + capMiddle }
            }
            VStack(alignment: .trailing, spacing: 2) {
                // A hook time can be a few ms ahead of this clock; never show "in 0 sec".
                Text(min(row.status.since, .now.addingTimeInterval(-1)), format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                if !row.pullRequests.isEmpty { PRMark(prs: row.pullRequests, hoverId: "pr:" + row.id, state: state) }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A row's pull requests, under its time (spec 5.2): the newest PR's symbol, coloured by its GitHub state (green open,
/// purple merged, grey closed), and its number in grey. A click opens the PR; with more than one, a menu has one item per PR.
private struct PRMark: View {
    let prs: [PullRequestLink]
    let hoverId: String
    let state: PanelState
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Group {
            if prs.count == 1 {
                Button { NSWorkspace.shared.open(prs[0].url) } label: { mark }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(prs, id: \.url) { pr in Button(pr.openLabel) { NSWorkspace.shared.open(pr.url) } }
                } label: { mark }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .onHover { inside in
            if inside { state.hoveredControl = hoverId } else if state.hoveredControl == hoverId { state.hoveredControl = nil }
        }
        .help(prs.map { "PR " + String($0.number) }.joined(separator: ", "))
        .accessibilityLabel(prs.count == 1 ? "Pull request" : "\(prs.count) pull requests")
    }

    /// The newest PR: the highest number.
    private var newest: PullRequestLink { prs.max { $0.number < $1.number }! }

    /// "#16338", or the newest PR and how many more: "#16340 +1".
    private var label: String {
        let number = "#" + String(newest.number)
        return prs.count == 1 ? number : number + " +" + String(prs.count - 1)
    }

    /// The shape says the state too, so colour is not the only cue. No state: the grey open symbol. White on a selected row.
    private var symbol: some View {
        let grey = Color(nsColor: .secondaryLabelColor)
        let (name, color): (String, Color) = switch newest.state {
        case .open: ("arrow.triangle.pull", .green)
        case .merged: ("arrow.triangle.merge", .purple)
        case .closed: ("xmark.circle", grey)
        case nil: ("arrow.triangle.pull", grey)
        }
        return Image(systemName: name).foregroundStyle(prominence == .increased ? .white : color)
    }

    private var mark: some View {
        HStack(spacing: 2) {
            symbol
            Text(label)
        }
        .font(.caption2.monospaced()).foregroundStyle(.secondary)
        .background {
            // Outside the layout, so the mark stays right-aligned under the time.
            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(state.hoveredControl == hoverId ? 0.1 : 0)).padding(-2)
        }
        .contentShape(.rect)
    }
}

extension PullRequestLink {
    /// "Open PR 16338": the number as digits, with no grouping separator.
    var openLabel: String { "Open PR " + String(number) }
}

extension SessionRow {
    /// "Question · repo" for a Claude session or Codex thread; "Blocked · pi · repo" for a herdr agent. A folded parent
    /// row adds its child sessions after the state: "Working · Bash · 1 fork · 2 sub-agents · repo".
    func subtitle(folded: Bool, label: String) -> String {
        var parts = [label]
        if folded {
            let nouns = children.map(\.childNoun)
            parts += ["fork", "session", "sub-agent"].compactMap { noun in
                let n = nouns.count { $0 == noun }
                return n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")"
            }
        }
        if case .herdr(let agent) = source { parts.append(agent.agent) }
        return (parts + [URL(fileURLWithPath: cwd).lastPathComponent]).joined(separator: " · ")
    }

    /// What a child session is to its parent: a fork the user made, a side session, or a sub-agent.
    private var childNoun: String {
        switch source {
        case .claude(let s): s.spawnedFrom?.userFork == true ? "fork" : "session"
        case .codex, .herdr: "sub-agent"
        }
    }

    var openLabel: String {
        switch source {
        case .claude: "Open in Claude"
        case .codex: "Open in Codex"
        case .herdr: "Open in herdr"
        }
    }
}
