import Foundation

public enum TicketService: String, Codable, Sendable { case linear, github, pullRequest }

/// Why a ticket shows only its ID and link.
public enum TicketProblem: String, Codable, Sendable { case noKey, otherWorkspace, notFound }

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

/// One aliased query for at most 20 lookups. Every user value is a variable. Github refs are skipped.
public func linearRequest(_ lookups: [Lookup]) -> (body: Data, aliases: [String: Lookup]) {
    precondition(lookups.count <= maxLookups)
    var aliases: [String: Lookup] = [:]
    var variables: [String: String] = [:]
    var fields: [String] = []
    for lookup in lookups {
        let alias = "l\(aliases.count)"
        let field: String, value: String
        switch lookup {
        case .branch(let b): field = "issueVcsBranchSearch(branchName: $\(alias)) { ...F }"; value = b
        case .pr(let url): field = "attachmentsForURL(url: $\(alias)) { nodes { issue { ...F } } }"; value = url.absoluteString
        case .ref(.linearID(let id)), .ref(.linearURL(_, let id)): field = "issue(id: $\(alias)) { ...F }"; value = id
        case .ref(.github): continue
        }
        aliases[alias] = lookup
        variables[alias] = value
        fields.append("\(alias): \(field)")
    }
    let declared = (0..<aliases.count).map { "$l\($0): String!" }.joined(separator: ", ")
    let query = "query\(declared.isEmpty ? "" : "(\(declared))") { \(fields.joined(separator: " ")) organization { urlKey } } \(linearFragment)"
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

private struct LinearAttachments: Decodable {
    struct Node: Decodable { var issue: LinearIssue? }
    var nodes: [Node]
}

public func decodeLinear(_ data: Data, aliases: [String: Lookup]) throws -> [Lookup: [Ticket]] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw TicketDataError.invalidResponse }
    var missing = Set<String>()
    for e in (root["errors"] as? [[String: Any]]) ?? [] {
        let message = e["message"] as? String ?? ""
        if let alias = (e["path"] as? [Any])?.first as? String, aliases[alias] != nil, message.lowercased().contains("not found") {
            missing.insert(alias)
        } else {
            throw TicketDataError.server(message)
        }
    }
    guard let fields = root["data"] as? [String: Any],
          let urlKey = (fields["organization"] as? [String: Any])?["urlKey"] as? String else { throw TicketDataError.invalidResponse }
    func issue(_ any: Any?) throws -> LinearIssue? {
        guard let any, !(any is NSNull) else { return nil }
        return try decode(any, LinearIssue.self)
    }
    var result: [Lookup: [Ticket]] = [:]
    for (alias, lookup) in aliases {
        let value = fields[alias]
        if case .ref(.linearURL(let ws, let id)) = lookup {
            if ws != urlKey { result[lookup] = [problem(.otherWorkspace, ws, id)]; continue }
            if missing.contains(alias) || value == nil || value is NSNull { result[lookup] = [problem(.notFound, urlKey, id)]; continue }
        }
        if missing.contains(alias) || value == nil || value is NSNull { result[lookup] = []; continue }
        switch lookup {
        case .pr:
            let nodes = try decode(value!, LinearAttachments.self).nodes
            result[lookup] = try nodes.compactMap { $0.issue }.map(linearTicket)
        default:
            result[lookup] = try issue(value).map { [try linearTicket($0)] } ?? []
        }
    }
    return result
}

private func problem(_ p: TicketProblem, _ workspace: String, _ id: String) -> Ticket {
    Ticket(url: URL(string: "https://linear.app/\(workspace)/issue/\(id)")!, identifier: id, service: .linear, problem: p)
}

private func linearTicket(_ i: LinearIssue) throws -> Ticket {
    Ticket(url: i.url, identifier: i.identifier, service: .linear, title: i.title, stateName: i.state.name, stateType: i.state.type,
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
          let n = Int(s.substring(with: m.range(at: 3))) else { return nil }
    return (s.substring(with: m.range(at: 1)), s.substring(with: m.range(at: 2)), n)
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
            guard isName(o), isName(r) else { continue }
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

public func decodeGitHub(_ data: Data, aliases: [String: Lookup]) throws -> [Lookup: [Ticket]] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw TicketDataError.invalidResponse }
    var missing = Set<String>()
    for e in (root["errors"] as? [[String: Any]]) ?? [] {
        if e["type"] as? String == "NOT_FOUND", let alias = (e["path"] as? [Any])?.first as? String, aliases[alias] != nil {
            missing.insert(alias)
        } else {
            throw TicketDataError.server(e["message"] as? String ?? "")
        }
    }
    let fields = root["data"] as? [String: Any] ?? [:]
    var result: [Lookup: [Ticket]] = [:]
    for (alias, lookup) in aliases {
        let repo = fields[alias] as? [String: Any]
        switch lookup {
        case .pr:
            guard !missing.contains(alias), let pr = repo?["pullRequest"], !(pr is NSNull) else { result[lookup] = []; continue }
            let p = try decode(pr, GitHubPull.self)
            let name = p.url.pathComponents.dropFirst().prefix(2).joined(separator: "/")
            let state = p.state.lowercased()
            let pull = Ticket(url: p.url, identifier: "#\(p.number)", service: .pullRequest, repository: name, title: p.title,
                              stateName: state.capitalized, stateType: state, person: p.author?.login, updatedAt: try date(p.updatedAt))
            result[lookup] = [pull] + (try p.closingIssuesReferences.nodes.map(githubTicket))
        case .ref(.github(let owner, let name, let number)):
            guard !missing.contains(alias), let issue = repo?["issue"], !(issue is NSNull) else {
                result[lookup] = [Ticket(url: URL(string: "https://github.com/\(owner)/\(name)/issues/\(number)")!, identifier: "#\(number)",
                                         service: .github, repository: "\(owner)/\(name)", problem: .notFound)]
                continue
            }
            result[lookup] = [try githubTicket(try decode(issue, GitHubIssue.self))]
        default: break
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

    /// No entry: due. An empty result waits 1 day, else 10 minutes (1 minute on hover).
    public func due(_ lookup: Lookup, service: TicketService, now: Date, hover: Bool) -> Bool {
        guard let e = entries[Key(service: service, lookup: lookup)] else { return true }
        let age = now.timeIntervalSince(e.fetched)
        return age >= (e.tickets.isEmpty ? 86_400 : hover ? 60 : 600)
    }
}
