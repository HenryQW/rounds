import Darwin
import Foundation

/// One user-defined rule. Directory rules include the directory and its descendants.
public struct OrganizationBoundaryRule: Equatable, Sendable {
    public enum Match: Equatable, Sendable {
        case directory(String)
        case gitRemote(String)
    }

    public let organizationID: String
    public let match: Match

    public init(organizationID: String, match: Match) {
        self.organizationID = organizationID
        self.match = match
    }
}

/// Whether the caller observed all remotes, confirmed there are none, or could not determine them.
public enum OrganizationBoundaryRemote: Equatable, Sendable {
    case observed([String])
    case absent
    case unknown
}

/// Classification alone does not permit remote transmission; the organization's policy must also permit it.
public enum OrganizationBoundaryResult: Equatable, Sendable {
    public enum LocalOnlyReason: Equatable, Sendable {
        case unmatched, conflicting, invalidRule, unknownInput
    }

    case classified(organizationID: String)
    case localOnly(LocalOnlyReason)
}

/// Resolve all rules without reading Git configuration or contacting a remote.
/// Directory paths must be absolute existing directories. Remote strings must be canonical URLs or scp-style Git
/// remotes and match byte for byte. The caller must supply all remotes from a trusted checkout. A remote string alone
/// does not prove ownership. A nil directory or unknown remote blocks classification when a rule needs it.
/// The result is a snapshot; resolve again at the point of use if paths or remotes can change.
public func resolveOrganizationBoundary(rules: [OrganizationBoundaryRule], sessionDirectory: String?,
                                        gitRemote: OrganizationBoundaryRemote) -> OrganizationBoundaryResult {
    var directories: [(id: String, path: [UInt8])] = []
    var remotes: [(id: String, remote: [UInt8])] = []
    for rule in rules {
        guard !rule.organizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rule.organizationID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .localOnly(.invalidRule)
        }
        switch rule.match {
        case .directory(let path):
            guard let path = canonicalDirectory(path) else { return .localOnly(.invalidRule) }
            directories.append((rule.organizationID, path))
        case .gitRemote(let remote):
            guard validGitRemote(remote) else { return .localOnly(.invalidRule) }
            remotes.append((rule.organizationID, Array(remote.utf8)))
        }
    }

    let directory: [UInt8]?
    if let sessionDirectory {
        guard let path = canonicalDirectory(sessionDirectory) else { return .localOnly(.unknownInput) }
        directory = path
    } else {
        guard directories.isEmpty else { return .localOnly(.unknownInput) }
        directory = nil
    }

    let observedRemotes: [[UInt8]]
    switch gitRemote {
    case .observed(let values):
        guard !values.isEmpty, values.allSatisfy(validGitRemote) else { return .localOnly(.unknownInput) }
        observedRemotes = values.map { Array($0.utf8) }
    case .absent:
        observedRemotes = []
    case .unknown:
        guard remotes.isEmpty else { return .localOnly(.unknownInput) }
        observedRemotes = []
    }

    var matches: [[UInt8]: String] = [:]
    if let directory {
        for rule in directories where containsDirectory(rule.path, directory) {
            matches[Array(rule.id.utf8)] = rule.id
        }
    }
    for remote in observedRemotes {
        for rule in remotes where remote == rule.remote {
            matches[Array(rule.id.utf8)] = rule.id
        }
    }
    if matches.count > 1 { return .localOnly(.conflicting) }
    guard let id = matches.values.first else { return .localOnly(.unmatched) }
    return .classified(organizationID: id)
}

func canonicalDirectory(_ path: String) -> [UInt8]? {
    guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
    // Resolve symlinks before processing subsequent `..`. Check both paths because realpath can accept `file/..`.
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    var originalInfo = stat(), resolvedInfo = stat()
    guard stat(path, &originalInfo) == 0, stat(resolved, &resolvedInfo) == 0,
          originalInfo.st_mode & S_IFMT == S_IFDIR, resolvedInfo.st_mode & S_IFMT == S_IFDIR,
          originalInfo.st_dev == resolvedInfo.st_dev, originalInfo.st_ino == resolvedInfo.st_ino,
          let value = String(validatingCString: resolved) else { return nil }
    return Array(value.utf8)
}

private func containsDirectory(_ parent: [UInt8], _ path: [UInt8]) -> Bool {
    parent == path || (parent == [47] ? path.first == 47 : path.starts(with: parent + [47]))
}

private func validGitRemote(_ value: String) -> Bool {
    guard !value.isEmpty, !value.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
    }) else { return false }
    if value.contains("://") {
        guard let components = URLComponents(string: value), let roundTrip = components.string,
              value.utf8.elementsEqual(roundTrip.utf8), let scheme = components.scheme,
              let host = components.host, !components.percentEncodedPath.isEmpty,
              components.percentEncodedPath.hasPrefix("/") else { return false }
        return !host.isEmpty || scheme.lowercased() == "file"
    }
    // Git's scp syntax has an optional user, a host and a nonempty path. Brackets permit an IPv6 host.
    return value.range(of: #"^([^@/:\s]+@)?(\[[0-9A-Fa-f:.]+\]|[^@/:\[\]\s]+):[^\s]+$"#,
                       options: .regularExpression) != nil
}
