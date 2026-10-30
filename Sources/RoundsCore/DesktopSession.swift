import Foundation

/// Desktop end-of-turn status written by Claude Code (`postTurnSummary`).
public struct PostTurnSummary: Sendable, Equatable {
    public let category: String
    /// The step the summary asks of the user; empty when there is none.
    public let needsAction: String
    public let summarizesUuid: String

    public init(category: String, needsAction: String = "", summarizesUuid: String) {
        self.category = category
        self.needsAction = needsAction
        self.summarizesUuid = summarizesUuid
    }
}

/// A pull request Claude desktop linked to the session (`prs`).
public struct PullRequestLink: Sendable, Equatable {
    /// GitHub's state, as Claude desktop last saw it (`state`).
    public enum State: String, Sendable { case open = "OPEN", merged = "MERGED", closed = "CLOSED" }

    public let number: Int
    public let url: URL
    /// Nil when the file has no state, or one this app does not know.
    public let state: State?

    public init(number: Int, url: URL, state: State? = nil) {
        self.number = number
        self.url = url
        self.state = state
    }
}

/// The session a side session or fork was started from (`spawnedFrom`).
public struct SpawnedFrom: Sendable, Equatable {
    /// The parent's `sessionId`.
    public let sessionId: String
    public let title: String
    /// The user forked the parent; else the parent's agent started a side session.
    public let userFork: Bool

    public init(sessionId: String, title: String, userFork: Bool) {
        (self.sessionId, self.title, self.userFork) = (sessionId, title, userFork)
    }
}

public enum DesktopSessionError: Error, Equatable {
    case invalidJSON
    case missingKey(String)
}

/// One Claude desktop Code-tab session, read from `claude-code-sessions/*/*/local_*.json` (spec 2.1).
public struct DesktopSession: Sendable, Equatable, Identifiable {
    public let id: String
    public let cliSessionId: String
    public let title: String
    public let cwd: String
    public let branch: String?
    public let pullRequests: [PullRequestLink]
    public let isArchived: Bool
    /// The star the user set in Claude desktop.
    public let isStarred: Bool
    /// When the user last had the session open in Claude desktop.
    public let lastFocusedAt: Date?
    public let lastActivityAt: Date
    public let lastTurnEdgeAt: Date?
    public let lastAssistantUuid: String?
    public let hasWrapUp: Bool
    public let wrapUpNeedsUser: String?
    public let summary: PostTurnSummary?
    public let errorAt: Date?
    public let interruptedAwaitingPerson: Bool
    public let isRemote: Bool
    public let spawnedFrom: SpawnedFrom?

    public init(json: Data) throws(DesktopSessionError) {
        guard let d = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { throw .invalidJSON }
        func required<T>(_ key: String, _: T.Type) throws(DesktopSessionError) -> T {
            guard let v = d[key] as? T else { throw .missingKey(key) }
            return v
        }
        func date(_ v: Any?) -> Date? { (v as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }

        id = try required("sessionId", String.self)
        cliSessionId = try required("cliSessionId", String.self)
        cwd = try required("cwd", String.self)
        let rawTitle = try required("title", String.self)
        title = rawTitle.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : rawTitle
        isArchived = try required("isArchived", Bool.self)
        isStarred = d["isStarred"] as? Bool ?? false
        lastFocusedAt = date(d["lastFocusedAt"])
        guard let activity = date(d["lastActivityAt"]) else { throw .missingKey("lastActivityAt") }
        lastActivityAt = activity
        branch = d["branch"] as? String
        pullRequests = (d["prs"] as? [[String: Any]] ?? []).compactMap { pr in
            guard let number = pr["prNumber"] as? Int, let url = (pr["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return PullRequestLink(number: number, url: url, state: (pr["state"] as? String).flatMap(PullRequestLink.State.init))
        }
        lastTurnEdgeAt = date(d["lastTurnEdgeAt"])
        lastAssistantUuid = d["lastAssistantUuid"] as? String
        let wrapUp = d["turnWrapUp"] as? [String: Any]
        hasWrapUp = wrapUp != nil
        wrapUpNeedsUser = wrapUp?["needsUser"] as? String
        summary = (d["postTurnSummary"] as? [String: Any]).flatMap { s in
            (s["status_category"] as? String).map {
                PostTurnSummary(category: $0, needsAction: s["needs_action"] as? String ?? "", summarizesUuid: s["summarizes_uuid"] as? String ?? "")
            }
        }
        errorAt = date(d["errorAt"])
        interruptedAwaitingPerson = d["interruptedAwaitingPerson"] as? Bool ?? false
        spawnedFrom = (d["spawnedFrom"] as? [String: Any]).flatMap { f in
            (f["sessionId"] as? String).map { SpawnedFrom(sessionId: $0, title: f["title"] as? String ?? "", userFork: f["userFork"] as? Bool ?? false) }
        }
        isRemote = !(d["sshConfig"] is NSNull || d["sshConfig"] == nil) || !(d["remoteTarget"] is NSNull || d["remoteTarget"] == nil)
    }
}

/// Reads every `local_*.json` two levels under `root` (account/org folders). Unchanged files come from `cache`.
public func loadDesktopSessions(
    root: URL, cache: FileCache<Result<DesktopSession, DesktopSessionError>> = FileCache()
) -> (sessions: [DesktopSession], failures: [(url: URL, error: DesktopSessionError)]) {
    var sessions: [DesktopSession] = []
    var failures: [(url: URL, error: DesktopSessionError)] = []
    var seen = Set<URL>()
    let fm = FileManager.default
    for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
        for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                seen.insert(file)
                let result = cache.value(at: file) { data in Result { () throws(DesktopSessionError) in try DesktopSession(json: data) } }
                switch result {
                case .success(let session): sessions.append(session)
                case .failure(let error): failures.append((file, error))
                case nil: failures.append((file, .invalidJSON))
                }
            }
        }
    }
    cache.keep(only: seen)
    return (sessions, failures)
}
