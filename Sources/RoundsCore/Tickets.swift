import Foundation

/// A ticket that a first prompt names (spec "Discovery"). Linear and GitHub issues only; a pull request is not one.
public enum TicketRef: Hashable, Codable, Sendable {
    case linearURL(workspace: String, id: String)
    case linearID(String)
    case github(owner: String, repo: String, number: Int)
}

private let promptLimit = 65_536
private let refLimit = 20
private let rowRefLimit = 5
// A URL up to the next space, or a bare Linear identifier that no letter, digit or hyphen touches. Scheme and host
// ignore case.
private let refPattern = try! NSRegularExpression(pattern: #"((?i:https?)://\S+)|(?<![A-Za-z0-9-])([A-Za-z][A-Za-z0-9]{0,9}-[0-9]{1,7})(?![A-Za-z0-9-])"#)
private let linearPath = try! NSRegularExpression(pattern: #"^(?i:https://linear\.app)/([^/]+)/issue/([A-Za-z][A-Za-z0-9]{0,9}-[0-9]{1,7})(/.*)?$"#)
private let githubPath = try! NSRegularExpression(pattern: #"^(?i:https://github\.com)/([^/]+)/([^/]+)/issues/([0-9]+)/?$"#)

/// The ticket references in the first 64 KB of a prompt, in order of first appearance, without duplicates, at most 20.
/// Bare identifiers are not checked here (`rowRefs` does). A match that ends at the cut can be cut itself, so it is dropped.
public func ticketRefs(inPrompt text: String) -> [TicketRef] {
    var head = text
    if text.utf8.count > promptLimit {
        var n = promptLimit
        while String(text.utf8.prefix(n)) == nil { n -= 1 }
        head = String(text.utf8.prefix(n))!
    }
    let ns = head as NSString, cut = head.utf8.count < text.utf8.count
    var refs: [TicketRef] = []
    for m in refPattern.matches(in: head, range: NSRange(location: 0, length: ns.length)) where !(cut && NSMaxRange(m.range) == ns.length) {
        let ref: TicketRef?
        if m.range(at: 1).location != NSNotFound {
            var url = ns.substring(with: m.range(at: 1))
            while let last = url.last, ".,;:!?)]>'\"".contains(last) { url.removeLast() }
            if let cut = url.firstIndex(where: { $0 == "?" || $0 == "#" }) { url = String(url[..<cut]) }
            ref = urlRef(url)
        } else {
            ref = .linearID(ns.substring(with: m.range(at: 2)).uppercased())
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
    return nil
}

/// The refs of a row, which it looks up and shows: a bare identifier only when its team key is one of the workspace's
/// (`teamKeys`, upper case; empty until Linear names them), then the first 5.
public func rowRefs(_ refs: [TicketRef], teamKeys: Set<String>) -> [TicketRef] {
    Array(refs.filter { ref in
        guard case .linearID(let id) = ref else { return true }
        return teamKeys.contains(String(id.prefix { $0 != "-" }))
    }.prefix(rowRefLimit))
}

/// The branch to look up, or nil when it says nothing about a ticket: none, or the default branch.
public func lookupBranch(_ branch: String?, defaultBranch: String?) -> String? {
    guard let branch, !branch.isEmpty, !["main", "master", "develop", "trunk"].contains(branch), branch != defaultBranch else { return nil }
    return branch
}

/// The current branch of a folder and the branch `origin/HEAD` names, read from the git files (no `git` process).
/// A worktree has a `.git` file that names its git folder. A detached `HEAD` gives no branch.
public func gitBranch(folder: URL) -> (branch: String?, defaultBranch: String?) {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    let dot = folder.appendingPathComponent(".git")
    guard fm.fileExists(atPath: dot.path, isDirectory: &isDir) else { return (nil, nil) }
    func read(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var gitDir = dot
    if !isDir.boolValue {
        guard let line = read(dot), line.hasPrefix("gitdir:") else { return (nil, nil) }
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
            name(common.appendingPathComponent("refs/remotes/origin/HEAD"), "ref: refs/remotes/origin/"))
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
