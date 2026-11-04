import AppKit
import Observation
import RoundsCore
import SwiftUI

/// The card of a ticket mark or a PR mark (spec 5.2): it shows after 0.6 s on the mark, stays while the pointer is on
/// the mark or the card, and closes 0.2 s after the pointer leaves both, or when the session window hides. A child
/// panel of the session window that never becomes key or main and never activates Rounds, so the other app keeps focus.
@MainActor @Observable
final class HoverCard {
    static let shared = HoverCard()

    enum Kind { case tickets, pullRequests }

    /// The row and the mark the card shows; nil while it is closed.
    private(set) var shown: (row: SessionRow, kind: Kind)?
    /// The item under the pointer (its URL), drawn with the grey hover fill.
    var hoveredItem: URL?
    /// The pointer is on the card: the session window then stays open too (`EdgeDrawer.checkPointer`).
    @ObservationIgnored private(set) var onCard = false
    /// Each mark's frame in the session window's SwiftUI space, by hover id, from layout.
    @ObservationIgnored var frames: [String: CGRect] = [:]
    /// The mark the card shows, or waits to show, for.
    @ObservationIgnored private var mark: String?
    @ObservationIgnored private var onMark = false
    /// The mark's frame on the screen; the card hangs under it.
    @ObservationIgnored private var anchor = NSRect.zero
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var panel: NSPanel?

    /// The pointer entered or left a mark.
    func hover(_ id: String, row: SessionRow, kind: Kind, inside: Bool) {
        if inside {
            // Back on the mark of the open card: it stays.
            if id == mark {
                onMark = true
                timer?.cancel()
                return
            }
            close()
            (mark, onMark) = (id, true)
            later(0.6) { self.open(id, row: row, kind: kind) }
        } else if id == mark {
            onMark = false
            if shown == nil { close() } else { closeLater() }
        }
    }

    /// The pointer entered or left the card.
    func hoverCard(_ inside: Bool) {
        onCard = inside
        if inside { timer?.cancel() } else { closeLater() }
    }

    func close() {
        timer?.cancel()
        (mark, onMark, onCard, shown, hoveredItem) = (nil, false, false, nil, nil)
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// The card's size changed (data came): it keeps its place under the mark.
    func resize(_ size: CGSize) {
        guard shown != nil, size.width > 0, size.height > 0 else { return }
        place(size)
    }

    private func open(_ id: String, row: SessionRow, kind: Kind) {
        guard let window = PanelController.shared.panel, window.isVisible, let view = window.contentView, let frame = frames[id] else { return }
        anchor = window.convertToScreen(view.convert(frame, to: nil))
        shown = (row, kind)
        // Data older than 1 minute is fetched again.
        TicketStore.shared.hovered(row)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // SwiftUI lays out the card now, so it shows at its size.
        panel.contentView?.layoutSubtreeIfNeeded()
        place(panel.contentView?.fittingSize ?? .zero)
        window.addChildWindow(panel, ordered: .above)
    }

    /// Under the mark, with its trailing edge on the mark's; above the mark when there is no room below; inside the screen.
    private func place(_ size: CGSize) {
        guard let panel, let visible = PanelController.shared.panel?.screen?.visibleFrame else { return }
        var origin = NSPoint(x: anchor.maxX - size.width, y: anchor.minY - 4 - size.height)
        if origin.y < visible.minY { origin.y = anchor.maxY + 4 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func closeLater() {
        later(0.2) { if !self.onMark && !self.onCard { self.close() } }
    }

    private func later(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        timer?.cancel()
        timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { action() }
        }
    }

    /// Borderless, so it cannot become key; non-activating, so a click on it leaves the other app in front.
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // It shows and hides with the session window only (a panel hides when its app is not active by default).
        panel.hidesOnDeactivate = false
        // As the session window: it shows on the active Space and over full-screen apps.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: HoverCardView(card: self))
        // The card sets its own frame (`place`); the window must not follow SwiftUI's sizes as well.
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

/// At most three items, then "and 2 more". Tickets come from the row as the list shows it now; a PR's data from
/// `TicketStore`, so the card changes when data comes.
private struct HoverCardView: View {
    let card: HoverCard

    var body: some View {
        if let shown = card.shown {
            let items = items(shown.row, shown.kind)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items.prefix(3), id: \.url) { item($0) }
                if items.count > 3 {
                    Text("and \(items.count - 3) more").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                }
            }
            .padding(4)
            .frame(width: 280, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // Flat, with a hairline and no shadow (DESIGN.md).
            .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            .onHover { card.hoverCard($0) }
            // The row lost its last ticket (or PR) while the card was open: no empty card.
            .onChange(of: items.isEmpty, initial: true) { _, empty in if empty { card.close() } }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { card.resize($0) }
        }
    }

    private func items(_ snapshot: SessionRow, _ kind: HoverCard.Kind) -> [Ticket] {
        let row = PanelController.shared.row(snapshot.id) ?? snapshot
        switch kind {
        case .tickets: return row.tickets
        case .pullRequests:
            // The newest first, as the mark shows it.
            return row.pullRequests.sorted { $0.number > $1.number }.map {
                TicketStore.shared.pullRequest($0.url) ?? Ticket(url: $0.url, identifier: "#" + String($0.number), service: .pullRequest)
            }
        }
    }

    private func item(_ ticket: Ticket) -> some View {
        let text = ticketCardText(ticket, now: .now, offline: offline(ticket.service), unavailable: unavailable(ticket.service))
        return Button {
            NSWorkspace.shared.open(ticket.url)
            card.close()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(text.heading).font(.caption).foregroundStyle(.secondary)
                if let title = text.title { Text(title).fontWeight(.medium).lineLimit(2) }
                if let details = text.details { Text(details).font(.caption).foregroundStyle(.secondary) }
                ForEach(text.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(card.hoveredItem == ticket.url ? 0.08 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { card.hoveredItem = ticket.url } else if card.hoveredItem == ticket.url { card.hoveredItem = nil }
        }
    }

    private func offline(_ service: TicketService) -> Bool {
        service == .linear ? TicketStore.shared.linearStatus == .offline : TicketStore.shared.githubStatus == .offline
    }

    /// Why a service cannot answer, in the words Settings uses; nil while it can.
    private func unavailable(_ service: TicketService) -> String? {
        if service == .linear { return TicketStore.shared.linearStatus == .invalidKey ? "Linear key not valid" : nil }
        switch TicketStore.shared.githubStatus {
        case .notFound: return "gh not found"
        case .notSignedIn: return "gh not signed in"
        // nil: the launch check has not answered, so the card says "Loading…".
        case .signedIn, .offline, nil: return nil
        }
    }
}
