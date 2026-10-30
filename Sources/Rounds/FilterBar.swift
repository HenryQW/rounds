import RoundsCore
import SwiftUI

/// The session window's filters (spec 5.2): four neutral status tiles with a hairline, each a symbol in its status
/// colour and a count in the text colour, and one toggle per source with its icon and count. Names are in the hints and accessibility labels. A click on the
/// selected tile goes back to All. Counts are of sessions, child sessions too, and never follow the search; the tile
/// counts leave out hidden sources; the source counts leave out older rows (starred ones), so they add up to the tiles.
struct FilterBar: View {
    @Bindable var model: AppModel
    @Bindable var state: PanelState
    let controller: PanelController

    var body: some View {
        let rows = model.allGroups.sessions
        let shown = rows.filter { !state.hiddenSources.contains($0.sourceName) }
        let count = { (group: StatusGroup) in shown.count { $0.status.group == group } }
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                tile(.yourTurn, "Last Call", "Your Turn", "waits, and results you have not opened", "exclamationmark.circle.fill", .orange, count(.yourTurn), key: 2)
                    .contextMenu { Button("Mark All as Seen") { model.markAllSeen() } }
                tile(.running, "On Tap", "Running", "sessions at work", "spigot.fill", .blue, count(.running), key: 3)
                tile(.quiet, "Served", "Quiet", "opened results, stopped or offline sessions", "checkmark.circle.fill", .secondary, count(.quiet), key: 4)
                tile(.older, "Aged", "Older", "quiet for more than a day", "clock", .gray, nil, key: 5)
            }
            HStack(spacing: 8) {
                ForEach(sources(rows), id: \.self) { name in sourceToggle(name, count: rows.count { $0.sourceName == name && $0.status.group != .older }) }
                Spacer(minLength: 0)
            }
        }
    }

    /// Known sources first (Claude, Codex, pi), then other herdr agents by name; a hidden source stays so it can come back.
    private func sources(_ rows: [SessionRow]) -> [String] {
        let names = Set(rows.map(\.sourceName)).union(state.hiddenSources)
        let known = KnownAgent.allCases.map(\.rawValue).filter(names.contains)
        return known + names.subtracting(known).sorted()
    }

    /// Every tile counts the sessions it lists (Last Call too, decided 2026-10-30: the waits you opened are in it); the
    /// pill alone counts what you have not seen.
    private func tile(_ filter: StatusFilter, _ caption: String, _ name: String, _ about: String, _ symbol: String, _ color: Color, _ count: Int?,
                      key: Int) -> some View {
        let selected = state.filter == filter
        let empty = count == 0
        return Button { controller.show(selected ? .all : filter) } label: {
            VStack(spacing: 2) {
            HStack(spacing: 4) {
                // Colour is on the symbol only; the count is text.
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
                if let count { Text("\(count)").font(.system(size: 15, weight: .semibold).monospacedDigit()).tracking(-0.2) }
            }
            .foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            // One height for the symbol line, with or without a count, so every tile name sits on one line.
            .frame(height: 20)
            // The tile's name, so the symbol needs no hint to be read.
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            // The selected tile lifts to the control surface with a stronger hairline; the others are a faint fill.
            .background(selected ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                        : AnyShapeStyle(Color.primary.opacity(state.hoveredControl == caption ? 0.08 : 0.03)), in: .rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? AnyShapeStyle(.primary.opacity(0.3)) : AnyShapeStyle(.separator), lineWidth: 0.5) }
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover(caption, $0) }
        .help(selected ? "Show all sessions (⌘1)" : "\(name): \(about) (⌘\(key))")
        .accessibilityLabel("\(caption), \(name)")
        .accessibilityValue(count.map { "\($0)" } ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { state.hoveredControl = id } else if state.hoveredControl == id { state.hoveredControl = nil }
    }

    private func sourceToggle(_ name: String, count: Int) -> some View {
        let hidden = state.hiddenSources.contains(name)
        let title = KnownAgent(rawValue: name).map(\.displayName) ?? name
        return Button {
            if hidden { state.hiddenSources.remove(name) } else { state.hiddenSources.insert(name) }
            state.selectedId = nil
        } label: {
            HStack(spacing: 4) {
                Badge.origin(name, size: 20)
                Text("\(count)").font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.primary.opacity(state.hoveredControl == name ? 0.08 : 0), in: .capsule)
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .opacity(hidden ? 0.35 : 1)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hover(name, $0) }
        .help(hidden ? "Show \(title) sessions" : "Hide \(title) sessions")
        .accessibilityLabel(title)
        .accessibilityValue(hidden ? "Hidden" : "\(count) sessions")
    }
}

/// The empty Last Call list (spec 5.2): "🍹 Another round?" and one button per source that is on, with its icon and
/// name; a click starts a new session in that source.
struct AnotherRound: View {
    @Bindable var model: AppModel
    @Bindable var state: PanelState
    let controller: PanelController

    var body: some View {
        ContentUnavailableView {
            Label { Text("Another round?").foregroundStyle(Color.roundsBlue) } icon: { Text("🍹").font(.system(size: 40)) }
        } actions: {
            HStack(spacing: 8) {
                ForEach(model.newSessionApps, id: \.self) { app in
                    let id = "new:" + app.sourceName
                    Button {
                        model.startNewSession(app)
                        controller.close()
                    } label: {
                        HStack(spacing: 6) {
                            Badge.origin(app.sourceName, size: 20)
                            Text(KnownAgent(rawValue: app.sourceName)?.displayName ?? app.sourceName)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Color.primary.opacity(state.hoveredControl == id ? 0.08 : 0), in: .rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.roundsBlue.opacity(0.45), lineWidth: 0.5))
                        .contentShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { state.hoveredControl = id } else if state.hoveredControl == id { state.hoveredControl = nil }
                    }
                    .help(app.menuTitle)
                    .accessibilityLabel(app.menuTitle)
                }
            }
        }
    }
}
