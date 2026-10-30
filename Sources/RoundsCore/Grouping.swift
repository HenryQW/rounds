import Foundation

/// One list row: a Claude desktop session, a herdr agent or a Codex thread, with the fields both share.
public struct SessionRow: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable {
        case claude(DesktopSession)
        case herdr(HerdrAgent)
        case codex(CodexThread)
    }

    public let source: Source
    /// The group is the classifier's, or where `LastCallRule` puts the row (`group`).
    public internal(set) var status: SessionStatus
    public let id: String
    /// A child's title can change under its parent (`group`).
    public internal(set) var title: String
    public let cwd: String
    public let branch: String?
    public let pullRequests: [PullRequestLink]
    /// Claude: the desktop's last activity. herdr: the last state change. Codex: the thread's last update.
    public let lastActivityAt: Date
    /// The row id of the session that started this one (a side session, fork or sub-agent); nil for a session of its own.
    public let parentId: String?
    /// The user opened the session since its current state began (`group`): from Rounds, or in Claude desktop.
    public internal(set) var isSeen = false
    /// Child sessions shown under this row (`group`), in status order.
    public internal(set) var children: [SessionRow] = []
    /// Under a status filter, a row that does not match itself but has matching children only names their parent.
    public internal(set) var isContext = false
    /// A child that works in its own folder (a worktree), not in its parent's folder: isolated, else direct (`group`).
    public internal(set) var isIsolated = false

    public init(session: DesktopSession, status: SessionStatus) {
        (source, self.status, id, title, cwd) = (.claude(session), status, session.id, session.title, session.cwd)
        (branch, pullRequests, lastActivityAt) = (session.branch, session.pullRequests, session.lastActivityAt)
        parentId = session.spawnedFrom?.sessionId
    }

    public init(agent: HerdrAgent, status: SessionStatus) {
        (source, self.status, id, title, cwd) = (.herdr(agent), status, agent.id, agent.title, agent.cwd)
        (branch, pullRequests, lastActivityAt, parentId) = (nil, [], status.since, agent.parentId)
    }

    public init(thread: CodexThread, status: SessionStatus) {
        (source, self.status, id, title, cwd) = (.codex(thread), status, "codex:" + thread.id, thread.title, thread.cwd)
        (branch, pullRequests, lastActivityAt, parentId) = (thread.branch, [], thread.updatedAt, thread.parentId.map { "codex:" + $0 })
    }

    /// The Claude desktop session, for Claude rows.
    public var session: DesktopSession? {
        if case .claude(let s) = source { s } else { nil }
    }

    public var withChildren: [SessionRow] { [self] + children }

    /// The list group of the row with its children: the most urgent of their groups.
    public var listGroup: StatusGroup { children.map(\.status.group).reduce(status.group) { $1.rawValue < $0.rawValue ? $1 : $0 } }

    /// A side session or fork that kept its parent's title shows as "Fork", or as the title it was started with.
    func titled(under parent: SessionRow) -> SessionRow {
        guard let from = session?.spawnedFrom, title == parent.title else { return self }
        var r = self
        r.title = from.userFork || from.title.isEmpty ? "Fork" : from.title
        return r
    }
}

/// The user's local marks (Rounds only; Claude desktop is never changed).
public struct SessionMarks: Codable, Equatable, Sendable {
    /// Session id to the time it was marked done. Done hides a session until it has newer activity.
    public private(set) var done: [String: Date] = [:]
    /// Hidden sessions show only in search, until unhidden.
    public private(set) var hidden: Set<String> = []
    /// Sessions the user starred in Rounds (any source); a Claude session can also carry Claude desktop's own star.
    public private(set) var starred: Set<String> = []
    /// Session id to the time the user last opened it from Rounds.
    public private(set) var seen: [String: Date] = [:]

    public init() {}

    /// Marks saved before a field existed load with that field empty.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        done = try c.decodeIfPresent([String: Date].self, forKey: .done) ?? [:]
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        starred = try c.decodeIfPresent(Set<String>.self, forKey: .starred) ?? []
        seen = try c.decodeIfPresent([String: Date].self, forKey: .seen) ?? [:]
    }

    public mutating func markDone(_ id: String, at date: Date) { done[id] = date }
    public mutating func hide(_ id: String) { hidden.insert(id) }
    public mutating func unhide(_ id: String) { hidden.remove(id) }
    public mutating func toggleStar(_ id: String) { if starred.remove(id) == nil { starred.insert(id) } }
    public func isStarred(_ r: SessionRow) -> Bool { starred.contains(r.id) || r.session?.isStarred == true }
    public mutating func markSeen(_ id: String, at date: Date) { seen[id] = date }
    /// Opened, here or in Claude desktop, since the current state began; a new wait makes the session unseen again.
    public func isSeen(_ r: SessionRow) -> Bool {
        [seen[r.id], r.session?.lastFocusedAt].compactMap { $0 }.contains { $0 >= r.status.since }
    }

    public func isDone(_ r: SessionRow) -> Bool { done[r.id].map { r.lastActivityAt <= $0 } ?? false }
}

public struct GroupedSessions: Sendable, Equatable {
    /// Starred rows, whatever their state; they show in every filter (spec 3.2).
    public var starred: [SessionRow] = []
    public var yourTurn: [SessionRow] = []
    public var running: [SessionRow] = []
    public var quiet: [SessionRow] = []
    public var older: [SessionRow] = []
    public var hidden: [SessionRow] = []

    public init() {}

    /// Every session of the list groups, children too: the filter and pill counts.
    public var sessions: [SessionRow] { (starred + yourTurn + running + quiet).flatMap(\.withChildren) }
    /// Last Call sessions the user has not opened since: the pill and the Last Call tile count these.
    public var unseenYourTurn: Int { sessions.count { $0.status.group == .yourTurn && !$0.isSeen } }
    /// The unseen results among them (not Needs input or Failed): while these are all, the pill is green and still (spec 5.7).
    public var unseenResults: Int {
        sessions.count { $0.status.group == .yourTurn && !$0.isSeen && $0.status.state != .needsInput && $0.status.state != .failed }
    }
    /// The unseen Failed ones: while one waits, the pill is red, over orange (spec 5.7).
    public var unseenFailed: Int { sessions.count { $0.status.state == .failed && $0.status.group == .yourTurn && !$0.isSeen } }
}

/// What Last Call counts and when a session is Older (Settings > Filters; spec 3.2, decided 2026-10-30). Last Call
/// takes an unseen session (not opened since its state began) in one of `states`, and with `keepWaiting` a waiting one
/// (Needs input, Failed) also after the user opened it, until it goes on. A sub-agent (Codex, herdr) counts only with
/// `subAgents`: the agent that started it handles its result and asks the user itself. Out of Last Call, Needs input
/// is Running (its work waits to go on) and the rest Quiet. A row with no activity for `agedHours` is Older, unless it
/// runs or waits.
public struct LastCallRule: Sendable, Equatable {
    public static let counted: [SessionState] = [.needsInput, .failed, .ready, .finished, .stopped]
    public var states: Set<SessionState> = Set(counted)
    public var keepWaiting = true
    public var subAgents = false
    public var agedHours = 24
    public var agedAfter: TimeInterval { TimeInterval(agedHours) * 3600 }

    public init() {}

    func place(_ r: SessionRow, seen: Bool, now: Date) -> SessionRow {
        let s = r.status
        guard s.group != .hidden else { return r }
        let waiting = s.state == .needsInput || s.state == .failed, runs = s.state.group == .running
        let subAgent = r.parentId != nil && r.session == nil
        let group: StatusGroup = if !waiting && !runs && now.timeIntervalSince(r.lastActivityAt) > agedAfter { .older }
            else if states.contains(s.state) && (!subAgent || subAgents) && (!seen || keepWaiting && waiting) { .yourTurn }
            else if runs || s.state == .needsInput { .running }
            else { .quiet }
        var placed = r
        placed.status = SessionStatus(s.state, s.detail, since: s.since, group: group, tasks: s.tasks)
        return placed
    }
}

/// Spec 3.2 order. Older, done and hidden rows show only when searching (older ones also with `includeOlder`, for the
/// Older filter); hidden rows in their own group. A child session goes under its root session when that session is
/// listed, and the row takes the most urgent group of the two; else the child is a row of its own.
/// `trackSeen` off: no row is seen, so every session that needs input counts in the pill. `rule` places each row
/// (Last Call, Older); without it the classifier's groups stay.
public func group(_ rows: [SessionRow], query: String, marks: SessionMarks = SessionMarks(), includeOlder: Bool = false,
                  trackSeen: Bool = true, rule: LastCallRule? = nil, now: Date = Date()) -> GroupedSessions {
    let rows = rule.map { rule in rows.map { rule.place($0, seen: trackSeen && marks.isSeen($0), now: now) } } ?? rows
    let q = query.trimmingCharacters(in: .whitespaces)
    func matches(_ r: SessionRow) -> Bool {
        guard !q.isEmpty else {
            return (includeOlder || r.status.group != .older || marks.isStarred(r)) && !marks.hidden.contains(r.id) && !marks.isDone(r)
        }
        let fields = [r.title, URL(fileURLWithPath: r.cwd).lastPathComponent, r.branch ?? ""]
        return fields.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
    // Listed: not archived, and without a search also not older, hidden or done.
    func listed(_ r: SessionRow) -> Bool { r.status.group != .hidden && (!q.isEmpty || matches(r)) }
    let byId = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
    func root(of r: SessionRow) -> SessionRow? {
        var seen: Set = [r.id], root: SessionRow?
        while let id = (root ?? r).parentId, let parent = byId[id], listed(parent), seen.insert(id).inserted { root = parent }
        return root
    }
    var children: [String: [SessionRow]] = [:]
    var top: [SessionRow] = []
    for r in rows {
        if let parent = root(of: r) { children[parent.id, default: []].append(r) } else { top.append(r) }
    }
    var g = GroupedSessions()
    for var r in top {
        // A search shows a matching row with all its children, else the row with its matching children.
        let shown = (children[r.id] ?? []).filter { $0.status.group != .hidden && (!q.isEmpty && matches(r) || matches($0)) }
        guard matches(r) || !shown.isEmpty else { continue }
        r.isSeen = trackSeen && marks.isSeen(r)
        r.children = shown.map { child in
            var c = child.titled(under: r)
            c.isSeen = trackSeen && marks.isSeen(c)
            c.isIsolated = URL(fileURLWithPath: c.cwd).standardizedFileURL.path != URL(fileURLWithPath: r.cwd).standardizedFileURL.path
            return c
        }
            .sorted { ($0.status.group.rawValue, $1.lastActivityAt) < ($1.status.group.rawValue, $0.lastActivityAt) }
        if marks.hidden.contains(r.id) {
            if r.status.group != .hidden { g.hidden.append(r) }
            continue
        }
        if marks.isStarred(r), r.status.group != .hidden {
            g.starred.append(r)
            continue
        }
        switch r.listGroup {
        case .yourTurn: g.yourTurn.append(r)
        case .running: g.running.append(r)
        case .quiet: g.quiet.append(r)
        case .older: g.older.append(r)
        case .hidden: break
        }
    }
    // The longest wait of the row or a child that needs input.
    func waitingSince(_ r: SessionRow) -> Date {
        r.withChildren.filter { $0.status.group == .yourTurn }.map(\.status.since).min() ?? r.status.since
    }
    g.yourTurn.sort { waitingSince($0) < waitingSince($1) }
    g.starred.sort { ($0.listGroup.rawValue, $1.lastActivityAt) < ($1.listGroup.rawValue, $0.lastActivityAt) }
    for keyPath in [\GroupedSessions.running, \.quiet, \.older, \.hidden] {
        g[keyPath: keyPath].sort { $0.lastActivityAt > $1.lastActivityAt }
    }
    return g
}
