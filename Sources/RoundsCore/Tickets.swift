import Foundation

/// A ticket that a first prompt names (spec "Discovery"): a Linear or GitHub issue, a GitHub PR (the row looks it up as
/// one of its PRs), or a `#N` after a keyword (`rowRefs` gives it the repository of the session folder).
public enum TicketRef: Hashable, Codable, Sendable {
    case linearURL(workspace: String, id: String)
    case linearID(String)
    case github(owner: String, repo: String, number: Int)
    case githubPR(owner: String, repo: String, number: Int)
    case githubNumber(Int)
}

/// A repository on github.com, from a folder's `origin` remote.
public struct GitHubRepository: Hashable, Sendable {
    public var owner: String
    public var name: String
    public init(owner: String, name: String) { (self.owner, self.name) = (owner, name) }
}

private let promptLimit = 65_536
private let refLimit = 20
private let rowRefLimit = 5
// In this order: a URL up to the next space; `owner/repo#N` that no name character touches; `#N` after a closing or
// reference word and spaces or a colon; a bare Linear identifier that no letter, digit or hyphen touches, not a version
// (`ios-1.57`) and with no leading zero. Scheme, host and words ignore case.
private let refPattern = try! NSRegularExpression(pattern: #"((?i:https?)://\S+)"#
    + #"|(?<![A-Za-z0-9_./-])([A-Za-z0-9-]{1,39})/([A-Za-z0-9._-]{1,100})#([1-9][0-9]{0,8})(?![A-Za-z0-9_])"#
    + #"|\b(?i:close[sd]?|fix(?:es|ed)?|resolve[sd]?|issue|refs?)[ \t:]+#([1-9][0-9]{0,8})(?![A-Za-z0-9_])"#
    + #"|(?<![A-Za-z0-9-])([A-Za-z][A-Za-z0-9]{0,9}-[1-9][0-9]{0,6})(?![A-Za-z0-9-]|\.[0-9])"#)
private let linearPath = try! NSRegularExpression(pattern: #"^(?i:https://linear\.app)/([^/]+)/issue/([A-Za-z][A-Za-z0-9]{0,9}-[0-9]{1,7})(/.*)?$"#)
private let githubPath = try! NSRegularExpression(pattern: #"^(?i:https://github\.com)/([^/]+)/([^/]+)/issues/([0-9]+)/?$"#)
private let githubPullPath = try! NSRegularExpression(pattern: #"^(?i:https://github\.com)/([^/]+)/([^/]+)/pull/([0-9]+)(/.*)?$"#)

/// The ticket references in the first 64 KB of a prompt, in order of first appearance, without duplicates, at most 20.
/// Bare identifiers are not checked here (`rowRefs` does). A match that ends at the cut can be cut itself, so it is dropped.
public func ticketRefs(inPrompt text: String) -> [TicketRef] {
    var head = text
    if text.utf8.count > promptLimit {
        var n = promptLimit
        while String(text.utf8.prefix(n)) == nil { n -= 1 }
        head = String(text.utf8.prefix(n))!
    }
    let ns = head as NSString, wasCut = head.utf8.count < text.utf8.count
    var refs: [TicketRef] = []
    for m in refPattern.matches(in: head, range: NSRange(location: 0, length: ns.length)) where !(wasCut && NSMaxRange(m.range) == ns.length) {
        let ref: TicketRef?
        if m.range(at: 1).location != NSNotFound {
            var url = ns.substring(with: m.range(at: 1))
            while let last = url.last, ".,;:!?)]>'\"".contains(last) { url.removeLast() }
            if let cut = url.firstIndex(where: { $0 == "?" || $0 == "#" }) { url = String(url[..<cut]) }
            ref = urlRef(url)
        } else if m.range(at: 2).location != NSNotFound {
            ref = Int(ns.substring(with: m.range(at: 4))).map { .github(owner: ns.substring(with: m.range(at: 2)), repo: ns.substring(with: m.range(at: 3)), number: $0) }
        } else if m.range(at: 5).location != NSNotFound {
            ref = Int(ns.substring(with: m.range(at: 5))).map(TicketRef.githubNumber)
        } else {
            ref = .linearID(ns.substring(with: m.range(at: 6)).uppercased())
        }
        if let ref, !refs.contains(ref) { refs.append(ref) }
        if refs.count == refLimit { break }
    }
    return refs
}

private func urlRef(_ url: String) -> TicketRef? {
    let ns = url as NSString, all = NSRange(location: 0, length: ns.length)
    func group(_ m: NSTextCheckingResult, _ i: Int) -> String { ns.substring(with: m.range(at: i)) }
    // Linear workspace keys are lower case.
    if let m = linearPath.firstMatch(in: url, range: all) { return .linearURL(workspace: group(m, 1).lowercased(), id: group(m, 2).uppercased()) }
    if let m = githubPath.firstMatch(in: url, range: all), let n = Int(group(m, 3)) { return .github(owner: group(m, 1), repo: group(m, 2), number: n) }
    if let m = githubPullPath.firstMatch(in: url, range: all), let n = Int(group(m, 3)) { return .githubPR(owner: group(m, 1), repo: group(m, 2), number: n) }
    return nil
}

/// The refs of a row, which it looks up and shows: a bare identifier only when its team key is one of the workspace's
/// (`teamKeys`, upper case; empty until Linear names them), a `#N` as an issue of `repository` (none without one), then
/// the first 5 without duplicates.
public func rowRefs(_ refs: [TicketRef], teamKeys: Set<String>, repository: GitHubRepository?) -> [TicketRef] {
    var row: [TicketRef] = []
    for ref in refs where row.count < rowRefLimit {
        let ref: TicketRef? = switch ref {
        case .linearID(let id): teamKeys.contains(String(id.prefix { $0 != "-" })) ? ref : nil
        case .githubNumber(let n): repository.map { .github(owner: $0.owner, repo: $0.name, number: n) }
        default: ref
        }
        if let ref, !row.contains(ref) { row.append(ref) }
    }
    return row
}

/// The branch to look up, or nil when it says nothing about a ticket: none, or the default branch.
public func lookupBranch(_ branch: String?, defaultBranch: String?) -> String? {
    guard let branch, !branch.isEmpty, !["main", "master", "develop", "trunk"].contains(branch), branch != defaultBranch else { return nil }
    return branch
}

/// The current branch of a folder, the branch `origin/HEAD` names and the GitHub repository of `origin`, read from the
/// git files (no `git` process). A worktree has a `.git` file that names its git folder. A detached `HEAD` gives no branch.
public func gitBranch(folder: URL) -> (branch: String?, defaultBranch: String?, repository: GitHubRepository?) {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    let dot = folder.appendingPathComponent(".git")
    guard fm.fileExists(atPath: dot.path, isDirectory: &isDir) else { return (nil, nil, nil) }
    func read(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var gitDir = dot
    if !isDir.boolValue {
        guard let line = read(dot), line.hasPrefix("gitdir:") else { return (nil, nil, nil) }
        let path = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
        gitDir = URL(fileURLWithPath: path, relativeTo: folder).standardizedFileURL
    }
    var common = gitDir
    if let rel = read(gitDir.appendingPathComponent("commondir")) { common = URL(fileURLWithPath: rel, relativeTo: gitDir).standardizedFileURL }
    func name(_ file: URL, _ prefix: String) -> String? {
        guard let head = read(file), head.hasPrefix(prefix) else { return nil }
        return String(head.dropFirst(prefix.count))
    }
    return (name(gitDir.appendingPathComponent("HEAD"), "ref: refs/heads/"),
            name(common.appendingPathComponent("refs/remotes/origin/HEAD"), "ref: refs/remotes/origin/"),
            read(common.appendingPathComponent("config")).flatMap { githubRepository(gitConfig: $0) })
}

private let githubRemote = try! NSRegularExpression(pattern: #"^(?i:git@github\.com:|ssh://git@github\.com/|https://github\.com/)([A-Za-z0-9-]+)/([A-Za-z0-9._-]+?)(?:\.git)?/?$"#)

/// The repository of the `url` of `[remote "origin"]` in a git `config` file; nil when it is not on github.com.
public func githubRepository(gitConfig: String) -> GitHubRepository? {
    var origin = false
    for line in gitConfig.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
        if line.hasPrefix("[") { origin = line == #"[remote "origin"]"#; continue }
        let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard origin, pair.count == 2, pair[0].lowercased() == "url" else { continue }
        let ns = pair[1] as NSString
        guard let m = githubRemote.firstMatch(in: pair[1], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return GitHubRepository(owner: ns.substring(with: m.range(at: 1)), name: ns.substring(with: m.range(at: 2)))
    }
    return nil
}

/// The folder at or above `path` that has a `.git` folder or file, or nil when none has one.
public func gitFolder(above path: String) -> URL? {
    var folder = URL(fileURLWithPath: path).standardizedFileURL
    while true {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return folder }
        guard folder.path != "/" else { return nil }
        folder.deleteLastPathComponent()
    }
}

/// The wait before the next request after `failures` failures in a row: 30 s, doubling to 10 minutes.
public func retryDelay(failures: Int) -> TimeInterval {
    min(30 * pow(2, Double(failures - 1)), 600)
}
