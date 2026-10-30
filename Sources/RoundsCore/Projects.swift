import Foundation

/// The folder a session belongs to for grouping: the main checkout of its git repository (worktrees and
/// subfolders join their repository), else the session folder itself.
public func projectRoot(for cwd: String) -> String {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: cwd).standardizedFileURL
    while dir.path != "/" {
        let git = dir.appending(path: ".git")
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: git.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return dir.path }
            // A worktree's .git file says "gitdir: <repo>/.git/worktrees/<name>".
            if let text = try? String(contentsOf: git, encoding: .utf8), text.hasPrefix("gitdir:") {
                let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                let gitdir = target.hasPrefix("/") ? target : dir.appending(path: target).standardizedFileURL.path
                if let range = gitdir.range(of: "/.git/worktrees/") { return String(gitdir[..<range.lowerBound]) }
            }
            return dir.path
        }
        dir.deleteLastPathComponent()
    }
    return cwd
}

public enum StatusFilter: String, Sendable, CaseIterable {
    case all, yourTurn, running, quiet, older
}

/// One project folder in the session window, with its rows in status order.
public struct ProjectSection: Sendable, Equatable, Identifiable {
    /// The id of the Starred section, which comes before the projects.
    public static let starredId = "starred"
    public let id: String
    public let name: String
    public internal(set) var rows: [SessionRow]
}

/// Buckets grouped rows by project, leaving out the sources the user hid. Projects with waiting work come first,
/// then running, then the most recent. A status filter keeps only the sessions in that group, starred ones too: a
/// parent that is not in it stays only as the context of its matching children (`isContext`).
public func projectSections(_ g: GroupedSessions, filter: StatusFilter, hiddenSources: Set<String> = [],
                            root: (String) -> String) -> [ProjectSection] {
    let want: StatusGroup? = switch filter {
    case .all: nil
    case .yourTurn: .yourTurn
    case .running: .running
    case .quiet: .quiet
    case .older: .older
    }
    func matching(_ r: SessionRow) -> SessionRow? {
        guard let want else { return r }
        let children = r.children.filter { $0.status.group == want }
        guard r.status.group == want || !children.isEmpty else { return nil }
        var r = r
        (r.children, r.isContext) = (children, r.status.group != want)
        return r
    }
    let rows = want == nil ? g.yourTurn + g.running + g.quiet + g.older + g.hidden
        : (g.yourTurn + g.running + g.quiet + g.older).compactMap(matching)
    var sections: [ProjectSection] = []
    var index: [String: Int] = [:]
    for r in rows where !hiddenSources.contains(r.sourceName) {
        let id = root(r.cwd)
        if let i = index[id] {
            sections[i].rows.append(r)
        } else {
            index[id] = sections.count
            sections.append(ProjectSection(id: id, name: URL(fileURLWithPath: id).lastPathComponent, rows: [r]))
        }
    }
    func rank(_ s: ProjectSection) -> (Int, Double) {
        (s.rows.map(\.listGroup.rawValue).min() ?? Int.max, -(s.rows.map(\.lastActivityAt.timeIntervalSince1970).max() ?? 0))
    }
    let starred = g.starred.compactMap(matching).filter { !hiddenSources.contains($0.sourceName) }
    return (starred.isEmpty ? [] : [ProjectSection(id: ProjectSection.starredId, name: "Starred", rows: starred)])
        + sections.sorted { rank($0) < rank($1) }
}
