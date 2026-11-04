import Foundation

public enum TicketService: String, Codable, Sendable { case linear, github, pullRequest }

/// Why a ticket shows only its ID and link.
public enum TicketProblem: String, Codable, Sendable { case noKey, otherWorkspace, notFound, noAccess }

public struct Ticket: Codable, Equatable, Sendable {
    public var url: URL
    public var identifier: String
    public var service: TicketService
    public var repository: String?
    public var title: String?
    public var stateName: String?
    public var stateType: String?
    public var person: String?
    public var updatedAt: Date?
    public var archived: Bool
    public var problem: TicketProblem?

    public init(url: URL, identifier: String, service: TicketService, repository: String? = nil, title: String? = nil,
                stateName: String? = nil, stateType: String? = nil, person: String? = nil, updatedAt: Date? = nil,
                archived: Bool = false, problem: TicketProblem? = nil) {
        self.url = url; self.identifier = identifier; self.service = service; self.repository = repository
        self.title = title; self.stateName = stateName; self.stateType = stateType; self.person = person
        self.updatedAt = updatedAt; self.archived = archived; self.problem = problem
    }
}

/// What a request asks a service for.
public enum Lookup: Hashable, Codable, Sendable {
    case branch(String)
    case pr(URL)
    case ref(TicketRef)
}

public enum TicketDataError: Error, Equatable {
    case server(String)
    case invalidResponse
}

private let maxLookups = 20

// MARK: Linear

private let linearFragment = "fragment F on Issue { identifier title url state { name type } assignee { name } updatedAt archivedAt }"

/// Team key and number of an identifier like `BBQ-12`; nil when the number does not parse.
private func identifierParts(_ id: String) -> (key: String, number: Int)? {
    guard let dash = id.lastIndex(of: "-"), let n = Int(id[id.index(after: dash)...]) else { return nil }
    return (String(id[..<dash]), n)
}

private func linearID(_ lookup: Lookup) -> String? {
    switch lookup {
    case .ref(.linearID(let id)), .ref(.linearURL(_, let id)): return id
    default: return nil
    }
}

/// One aliased query for at most 20 lookups. Every user value is a variable. Github refs are skipped.
/// `issue(id:)` is non-null in Linear's schema, so one unknown ID would lose the whole response. All identifier
/// lookups share one `issues` alias with a filter instead.
public func linearRequest(_ lookups: [Lookup]) -> (body: Data, aliases: [String: [Lookup]]) {
    precondition(lookups.count <= maxLookups)
    var aliases: [String: [Lookup]] = [:]
    var variables: [String: Any] = [:]
    var types: [String] = []
    var fields: [String] = []
    var idLookups: [Lookup] = []
    var filters: [[String: Any]] = []
    for lookup in lookups {
        if let id = linearID(lookup) {
            guard let p = identifierParts(id) else { continue }
            idLookups.append(lookup)
            let f: [String: Any] = ["team": ["key": ["eq": p.key]], "number": ["eq": p.number]]
            if !filters.contains(where: { NSDictionary(dictionary: $0).isEqual(f) }) { filters.append(f) }
            continue
        }
        let alias = "l\(aliases.count)"
        switch lookup {
        case .branch(let b):
            fields.append("\(alias): issueVcsBranchSearch(branchName: $\(alias)) { ...F }"); variables[alias] = b; types.append("$\(alias): String!")
        case .pr(let url):
            fields.append("\(alias): attachmentsForURL(url: $\(alias)) { nodes { issue { ...F } } }"); variables[alias] = url.absoluteString; types.append("$\(alias): String!")
        default: continue
        }
        aliases[alias] = [lookup]
    }
    if !idLookups.isEmpty {
        let alias = "l\(aliases.count)"
        fields.append("\(alias): issues(filter: $\(alias), first: 50, includeArchived: true) { nodes { ...F } }")
        variables[alias] = ["or": filters]
        types.append("$\(alias): IssueFilter")
        aliases[alias] = idLookups
    }
    let query = "query\(types.isEmpty ? "" : "(\(types.joined(separator: ", ")))") { \(fields.joined(separator: " ")) organization { urlKey } } \(linearFragment)"
    let body = try! JSONSerialization.data(withJSONObject: ["query": query, "variables": variables], options: [.sortedKeys])
    return (body, aliases)
}

private struct LinearIssue: Decodable {
    struct State: Decodable { var name: String; var type: String }
    struct Person: Decodable { var name: String }
    var identifier: String, title: String, url: URL
    var state: State, assignee: Person?
    var updatedAt: String, archivedAt: String?
}

private struct LinearIssues: Decodable { var nodes: [LinearIssue] }

private struct LinearAttachments: Decodable {
    struct Node: Decodable { var issue: LinearIssue? }
    var nodes: [Node]
}

/// An error on one alias, or a value that does not decode, gives its lookups no result (not even "none"), so they can
/// be asked again; "not found" is "none". Only an error that names no alias throws; null data with alias errors gives no result.
public func decodeLinear(_ data: Data, aliases: [String: [Lookup]]) throws -> [Lookup: [Ticket]] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw TicketDataError.invalidResponse }
    var missing = Set<String>(), failed = Set<String>()
    for e in (root["errors"] as? [[String: Any]]) ?? [] {
        let message = e["message"] as? String ?? ""
        guard let alias = (e["path"] as? [Any])?.first as? String, aliases[alias] != nil else { throw TicketDataError.server(message) }
        if message.lowercased().contains("not found") { missing.insert(alias) } else { failed.insert(alias) }
    }
    if root["data"] is NSNull && !(missing.isEmpty && failed.isEmpty) { return [:] }
    guard let fields = root["data"] as? [String: Any],
          let urlKey = (fields["organization"] as? [String: Any])?["urlKey"] as? String else { throw TicketDataError.invalidResponse }
    var result: [Lookup: [Ticket]] = [:]
    for (alias, lookups) in aliases where !failed.contains(alias) {
        let value = fields[alias]
        let empty = missing.contains(alias) || value == nil || value is NSNull
        do {
            for lookup in lookups {
                switch lookup {
                case .pr:
                    result[lookup] = empty ? [] : try decode(value!, LinearAttachments.self).nodes.compactMap { $0.issue }.map(linearTicket)
                case .branch:
                    result[lookup] = empty ? [] : [try linearTicket(try decode(value!, LinearIssue.self))]
                default:
                    let id = linearID(lookup)!
                    if case .ref(.linearURL(let ws, _)) = lookup, ws.lowercased() != urlKey.lowercased() {
                        result[lookup] = [problem(.otherWorkspace, ws, id)]
                        continue
                    }
                    let nodes = empty ? [] : try decode(value!, LinearIssues.self).nodes
                    if let node = nodes.first(where: { $0.identifier.lowercased() == id.lowercased() }) {
                        result[lookup] = [try linearTicket(node)]
                    } else if case .ref(.linearURL) = lookup {
                        result[lookup] = [problem(.notFound, urlKey, id)]
                    } else {
                        result[lookup] = []
                    }
                }
            }
        } catch {
            for lookup in lookups { result[lookup] = nil }
        }
    }
    return result
}

/// A Linear answer that stops requests: a key that is not valid (401, or HTTP 400 with an authentication error), or a
/// rate limit (429, or the `RATELIMITED` code).
public enum LinearFailure: Equatable, Sendable { case invalidKey, rateLimited }

public func linearFailure(status: Int, body: Data) -> LinearFailure? {
    let errors = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["errors"] as? [[String: Any]] ?? []
    let extensions = errors.compactMap { $0["extensions"] as? [String: Any] }
    if status == 401 || extensions.contains(where: { $0["code"] as? String == "AUTHENTICATION_ERROR" || ($0["type"] as? String)?.lowercased() == "authentication error" }) {
        return .invalidKey
    }
    if status == 429 || extensions.contains(where: { $0["code"] as? String == "RATELIMITED" }) { return .rateLimited }
    return nil
}

private func problem(_ p: TicketProblem, _ workspace: String, _ id: String) -> Ticket {
    Ticket(url: URL(string: "https://linear.app/\(workspace)/issue/\(id)")!, identifier: id, service: .linear, problem: p)
}

/// Linear's issue URL without its title slug, as a prompt's Linear URL gives it, so the two compare equal.
private func linearTicket(_ i: LinearIssue) throws -> Ticket {
    let parts = i.url.pathComponents
    let url = parts.count > 4 && parts[2] == "issue" ? URL(string: "https://linear.app/\(parts[1])/issue/\(parts[3])") ?? i.url : i.url
    return Ticket(url: url, identifier: i.identifier, service: .linear, title: i.title, stateName: i.state.name, stateType: i.state.type,
           person: i.assignee?.name, updatedAt: try date(i.updatedAt), archived: i.archivedAt != nil)
}

private func decode<T: Decodable>(_ any: Any, _ type: T.Type) throws -> T {
    do {
        let data = try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: data)
    } catch { throw TicketDataError.invalidResponse }
}

private func date(_ s: String) throws -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: s) { return d }
    throw TicketDataError.invalidResponse
}

// MARK: GitHub

private let githubName = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_.-]+$"#)
private let githubPull = try! NSRegularExpression(pattern: #"^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)$"#)
private let githubIssueFragment = "fragment I on Issue { number title state stateReason url updatedAt assignees(first: 1) { nodes { login } } repository { nameWithOwner } }"

private func pullParts(_ url: URL) -> (owner: String, repo: String, number: Int)? {
    let s = url.absoluteString as NSString
    guard let m = githubPull.firstMatch(in: s as String, range: NSRange(location: 0, length: s.length)),
          let n = Int32(s.substring(with: m.range(at: 3))) else { return nil }
    return (s.substring(with: m.range(at: 1)), s.substring(with: m.range(at: 2)), Int(n))
}

private func isName(_ s: String) -> Bool { githubName.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }

/// Values are inlined, so only lookups with a safe owner and repository name are used.
public func githubQuery(_ lookups: [Lookup]) -> (query: String, aliases: [String: Lookup]) {
    precondition(lookups.count <= maxLookups)
    var aliases: [String: Lookup] = [:]
    var fields: [String] = []
    for lookup in lookups {
        let owner: String, repo: String, inner: String
        switch lookup {
        case .pr(let url):
            guard let p = pullParts(url) else { continue }
            (owner, repo) = (p.owner, p.repo)
            inner = "pullRequest(number: \(p.number)) { number title state url updatedAt author { login } closingIssuesReferences(first: 10) { nodes { ...I } } }"
        case .ref(.github(let o, let r, let n)):
            guard isName(o), isName(r), n <= Int(Int32.max) else { continue }
            (owner, repo) = (o, r)
            inner = "issue(number: \(n)) { ...I }"
        default: continue
        }
        let alias = "g\(aliases.count)"
        aliases[alias] = lookup
        fields.append("\(alias): repository(owner: \"\(owner)\", name: \"\(repo)\") { \(inner) }")
    }
    return ("query { \(fields.joined(separator: " ")) } \(githubIssueFragment)", aliases)
}

private struct GitHubIssue: Decodable {
    struct Assignees: Decodable { struct Node: Decodable { var login: String }; var nodes: [Node] }
    struct Repo: Decodable { var nameWithOwner: String }
    var number: Int, title: String, state: String, stateReason: String?, url: URL, updatedAt: String
    var assignees: Assignees, repository: Repo
}

private struct GitHubPull: Decodable {
    struct Author: Decodable { var login: String }
    struct Closing: Decodable { var nodes: [GitHubIssue] }
    var number: Int, title: String, state: String, url: URL, updatedAt: String
    var author: Author?, closingIssuesReferences: Closing
}

/// As `decodeLinear`: an error on one alias gives its lookup no result; `NOT_FOUND` is "none". `FORBIDDEN` (an
/// organization's SSO, say) gives a placeholder that says so.
public func decodeGitHub(_ data: Data, aliases: [String: Lookup]) throws -> [Lookup: [Ticket]] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw TicketDataError.invalidResponse }
    var missing = Set<String>(), forbidden = Set<String>(), failed = Set<String>()
    for e in (root["errors"] as? [[String: Any]]) ?? [] {
        guard let alias = (e["path"] as? [Any])?.first as? String, aliases[alias] != nil else { throw TicketDataError.server(e["message"] as? String ?? "") }
        if e["type"] as? String == "NOT_FOUND" { missing.insert(alias) }
        else if e["type"] as? String == "FORBIDDEN" || (e["extensions"] as? [String: Any])?["saml_failure"] != nil { forbidden.insert(alias) }
        else { failed.insert(alias) }
    }
    if root["data"] is NSNull && !(missing.isEmpty && forbidden.isEmpty && failed.isEmpty) { return [:] }
    guard let fields = root["data"] as? [String: Any] else { throw TicketDataError.invalidResponse }
    var result: [Lookup: [Ticket]] = [:]
    for (alias, lookup) in aliases where !failed.contains(alias) {
        let repo = fields[alias] as? [String: Any]
        // A value that does not decode fails only its alias.
        do {
            switch lookup {
            case .pr(let url):
                if forbidden.contains(alias), let p = pullParts(url) {
                    result[lookup] = [Ticket(url: url, identifier: "#\(p.number)", service: .pullRequest, repository: "\(p.owner)/\(p.repo)", problem: .noAccess)]
                    continue
                }
                guard !missing.contains(alias), let pr = repo?["pullRequest"], !(pr is NSNull) else { result[lookup] = []; continue }
                let p = try decode(pr, GitHubPull.self)
                let name = p.url.pathComponents.dropFirst().prefix(2).joined(separator: "/")
                let state = p.state.lowercased()
                let pull = Ticket(url: p.url, identifier: "#\(p.number)", service: .pullRequest, repository: name, title: p.title,
                                  stateName: state.capitalized, stateType: state, person: p.author?.login, updatedAt: try date(p.updatedAt))
                result[lookup] = [pull] + (try p.closingIssuesReferences.nodes.map(githubTicket))
            case .ref(.github(let owner, let name, let number)):
                guard !missing.contains(alias), !forbidden.contains(alias), let issue = repo?["issue"], !(issue is NSNull) else {
                    result[lookup] = [Ticket(url: URL(string: "https://github.com/\(owner)/\(name)/issues/\(number)")!, identifier: "#\(number)",
                                             service: .github, repository: "\(owner)/\(name)", problem: forbidden.contains(alias) ? .noAccess : .notFound)]
                    continue
                }
                result[lookup] = [try githubTicket(try decode(issue, GitHubIssue.self))]
            default: break
            }
        } catch {
            result[lookup] = nil
        }
    }
    return result
}

private func githubTicket(_ i: GitHubIssue) throws -> Ticket {
    let open = i.state == "OPEN"
    return Ticket(url: i.url, identifier: "#\(i.number)", service: .github, repository: i.repository.nameWithOwner, title: i.title,
                  stateName: open ? "Open" : "Closed", stateType: open ? "open" : (i.stateReason == "NOT_PLANNED" ? "not_planned" : "completed"),
                  person: i.assignees.nodes.first?.login, updatedAt: try date(i.updatedAt))
}

/// The PR of a PR card from GitHub's last result for its lookup (`stored`, nil before the first). A result without the
/// PR (GitHub does not know it, or the URL is not a github.com PR) says "Not found"; no result yet says "Loading…".
public func pullRequestTicket(_ url: URL, number: Int, stored: [Ticket]?) -> Ticket {
    stored?.first { $0.service == .pullRequest }
        ?? Ticket(url: url, identifier: "#\(number)", service: .pullRequest, problem: stored == nil ? nil : .notFound)
}

// MARK: Cache

/// Tickets by service and lookup, with the time of the fetch.
public struct TicketCache: Codable, Sendable {
    private struct Key: Hashable, Codable, Sendable { var service: TicketService; var lookup: Lookup }
    private struct Entry: Codable, Sendable { var tickets: [Ticket]; var fetched: Date }
    private var entries: [Key: Entry] = [:]

    public init() {}

    public func tickets(for lookup: Lookup, service: TicketService) -> [Ticket]? {
        entries[Key(service: service, lookup: lookup)]?.tickets
    }

    public mutating func store(_ tickets: [Ticket], for lookup: Lookup, service: TicketService, at date: Date) {
        entries[Key(service: service, lookup: lookup)] = Entry(tickets: tickets, fetched: date)
    }

    /// Makes every lookup of a service due (a new Linear key can see another workspace).
    public mutating func removeAll(service: TicketService) {
        entries = entries.filter { $0.key.service != service }
    }

    /// No entry: due. An empty result waits 1 day, else 10 minutes (1 minute on hover).
    public func due(_ lookup: Lookup, service: TicketService, now: Date, hover: Bool) -> Bool {
        guard let e = entries[Key(service: service, lookup: lookup)] else { return true }
        let age = now.timeIntervalSince(e.fetched)
        return age >= (e.tickets.isEmpty ? 86_400 : hover ? 60 : 600)
    }
}

// MARK: Rows

/// A row's tickets in spec order, one per issue (by URL, and Linear also by identifier): Linear for the branch and each
/// PR, the issues each PR closes on GitHub (not the PR itself), then the prompt refs. `stored` gives a service's last result for a lookup, nil before the first.
/// Until data comes, a Linear URL or GitHub ref shows its ID and link. Without a Linear key (`linearKey` false) no Linear
/// data shows: a Linear URL says why, and a bare ID shows nothing, as only Linear can say it is real.
public func rowTickets(branch: String?, pullRequests: [URL], refs: [TicketRef], linearKey: Bool,
                       stored: (Lookup, TicketService) -> [Ticket]?) -> [Ticket] {
    var tickets: [Ticket] = []
    // A Linear issue is the same issue whatever its URL says (workspace case, a slug).
    func same(_ a: Ticket, _ b: Ticket) -> Bool {
        a.url == b.url || a.service == .linear && b.service == .linear && a.identifier.caseInsensitiveCompare(b.identifier) == .orderedSame
    }
    func add(_ more: [Ticket]) { for t in more where !tickets.contains(where: { same($0, t) }) { tickets.append(t) } }
    if linearKey {
        if let branch { add(stored(.branch(branch), .linear) ?? []) }
        for url in pullRequests { add(stored(.pr(url), .linear) ?? []) }
    }
    for url in pullRequests { add((stored(.pr(url), .github) ?? []).filter { $0.service != .pullRequest }) }
    for ref in refs {
        switch ref {
        case .linearURL(let workspace, let id):
            add((linearKey ? stored(.ref(ref), .linear) : nil)
                ?? [Ticket(url: URL(string: "https://linear.app/\(workspace)/issue/\(id)")!, identifier: id, service: .linear, problem: linearKey ? nil : .noKey)])
        case .linearID:
            if linearKey { add(stored(.ref(ref), .linear) ?? []) }
        case .github(let owner, let repo, let number):
            add(stored(.ref(ref), .github)
                ?? [Ticket(url: URL(string: "https://github.com/\(owner)/\(repo)/issues/\(number)")!, identifier: "#\(number)", service: .github, repository: "\(owner)/\(repo)")])
        }
    }
    return tickets
}

// MARK: Mark and card

extension Ticket {
    /// The mark's symbol: the mark is grey, so the shape gives the state. Linear state types and GitHub issue states
    /// share a name where they mean the same; an open GitHub issue, an unstarted Linear issue and no data are a circle.
    public var symbol: String {
        switch stateType {
        case "backlog": "circle.dotted"
        case "started": "circle.lefthalf.filled"
        case "completed": "checkmark.circle"
        case "canceled", "not_planned": "xmark.circle"
        case "triage": "circle.dashed"
        default: "circle"
        }
    }
}

/// One item of the hover card: "BBQ-123 · Linear", the title, "In Progress · Ada · updated 2 hr. ago", and notes
/// that say why data is missing or old.
public struct TicketCardText: Equatable, Sendable {
    public var heading: String
    public var title: String?
    public var details: String?
    public var notes: [String]

    public init(heading: String, title: String?, details: String?, notes: [String]) {
        (self.heading, self.title, self.details, self.notes) = (heading, title, details, notes)
    }
}

/// The card text of a ticket or a pull request. `offline`: the service's last request failed; an item with no data then
/// says only that. `unavailable`: why the service cannot answer ("gh not found"), said in place of "Loading…".
public func ticketCardText(_ t: Ticket, now: Date, offline: Bool, unavailable: String? = nil, locale: Locale = .current) -> TicketCardText {
    let heading = switch t.service {
    case .linear: t.identifier + " · Linear"
    case .github: (t.repository ?? "") + t.identifier + " · GitHub"
    case .pullRequest: t.identifier + " · GitHub"
    }
    let relative = RelativeDateTimeFormatter()
    (relative.locale, relative.unitsStyle) = (locale, .short)
    // A server clock a little ahead of this one never gives "in 0 sec.".
    let updated = t.updatedAt.map { "updated " + relative.localizedString(for: min($0, now - 1), relativeTo: now) }
    let details = [t.stateName, t.person, updated].compactMap { $0 }
    var notes: [String] = switch t.problem {
    case .noKey: ["Add a Linear API key in Settings to see the title"]
    case .otherWorkspace: ["Not in your Linear workspace"]
    case .notFound: ["Not found"]
    case .noAccess: ["No access: authorize gh for this organization"]
    case nil: t.title == nil && !offline ? [unavailable ?? "Loading…"] : []
    }
    if t.archived { notes.append("Archived") }
    if offline { notes.append("Not updated: offline") }
    return TicketCardText(heading: heading, title: t.title, details: details.isEmpty ? nil : details.joined(separator: " · "), notes: notes)
}
