import Darwin
import Foundation

public enum OrganizationPolicyError: Error, Equatable {
    case invalidName, duplicateOrganization, unknownOrganization
    case invalidRule, duplicateRule, unknownRule, invalidDestination, duplicateGrant
    case malformedData, invalidFile, changedOnDisk, interruptedWrite
    case conflict, inheritedRule, assignedChildren, remoteRulesUnavailable, anotherInstance
}

/// Organization rules and destination-specific consent. No rule or grant permits transmission by itself.
public struct OrganizationPolicy: Sendable {
    public struct Organization: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
    }

    public struct Rule: Equatable, Sendable {
        public let organizationID: UUID
        public let match: OrganizationBoundaryRule.Match
        fileprivate let resolvedDirectory: String?
        fileprivate let directoryDevice: String?
        fileprivate let directoryInode: String?
    }

    public struct Grant: Equatable, Sendable {
        public let organizationID: UUID
        public let service: String
        public let destinationIdentity: String
    }

    public private(set) var organizations: [Organization] = []
    public private(set) var rules: [Rule] = []
    public private(set) var grants: [Grant] = []

    public init() {}

    @discardableResult
    public mutating func addOrganization(name: String) throws -> UUID {
        try validateName(name)
        let id = UUID()
        organizations.append(Organization(id: id, name: name))
        return id
    }

    public mutating func renameOrganization(id: UUID, name: String) throws {
        guard let index = organizations.firstIndex(where: { $0.id == id }) else { throw OrganizationPolicyError.unknownOrganization }
        try validateName(name, excluding: id)
        organizations[index] = Organization(id: id, name: name)
    }

    /// Removing an organization also removes its rules and grants.
    public mutating func removeOrganization(id: UUID) throws {
        guard organizations.contains(where: { $0.id == id }) else { throw OrganizationPolicyError.unknownOrganization }
        organizations.removeAll { $0.id == id }
        rules.removeAll { $0.organizationID == id }
        grants.removeAll { $0.organizationID == id }
    }

    /// Directory rules must exist when added. The caller must supply a secret-free remote; credential-bearing URL
    /// user info, queries, and fragments are rejected. SSH usernames are permitted.
    public mutating func addRule(organizationID: UUID, match: OrganizationBoundaryRule.Match) throws {
        try requireOrganization(organizationID)
        guard validRule(match, requireExistingDirectory: true) else { throw OrganizationPolicyError.invalidRule }
        guard !rules.contains(where: { $0.organizationID == organizationID && sameMatch($0.match, match) }) else {
            throw OrganizationPolicyError.duplicateRule
        }
        let resolved: String?, device: String?, inode: String?
        if case .directory(let path) = match {
            guard let identity = directoryIdentity(path) else { throw OrganizationPolicyError.invalidRule }
            resolved = identity.path
            device = identity.device
            inode = identity.inode
        } else {
            (resolved, device, inode) = (nil, nil, nil)
        }
        rules.append(Rule(organizationID: organizationID, match: match, resolvedDirectory: resolved,
                          directoryDevice: device, directoryInode: inode))
    }

    /// Move one folder only when no nested assignment or unchecked remote rule can change the result.
    public mutating func assignDirectory(_ path: String, to organizationID: UUID?) throws {
        guard !rules.contains(where: { if case .gitRemote = $0.match { true } else { false } }) else {
            throw OrganizationPolicyError.remoteRulesUnavailable
        }
        let parent = URL(fileURLWithPath: path).standardizedFileURL.path
        let resolvedParent = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let children = rules.filter { rule in
            guard case .directory(let child) = rule.match, child != path else { return false }
            let original = URL(fileURLWithPath: child).standardizedFileURL.path
            let resolved = URL(fileURLWithPath: child).resolvingSymlinksInPath().standardizedFileURL.path
            return original.hasPrefix(parent == "/" ? "/" : parent + "/") ||
                resolved.hasPrefix(resolvedParent == "/" ? "/" : resolvedParent + "/")
        }
        if organizationID != nil && !children.isEmpty { throw OrganizationPolicyError.assignedChildren }
        var result = self
        for rule in result.rules {
            if case .directory(let existing) = rule.match,
               existing == path || (organizationID == nil && children.contains(rule)) {
                try result.removeRule(organizationID: rule.organizationID, match: rule.match)
            }
        }
        if let organizationID { try result.addRule(organizationID: organizationID, match: .directory(path)) }
        let match = result.classify(sessionDirectory: path, gitRemote: .unknown)
        if let organizationID {
            guard match == .classified(organizationID: organizationID.uuidString) else { throw OrganizationPolicyError.conflict }
        } else {
            if case .classified = match { throw OrganizationPolicyError.inheritedRule }
            for rule in children {
                if case .directory(let child) = rule.match,
                   case .classified = result.classify(sessionDirectory: child, gitRemote: .unknown) {
                    throw OrganizationPolicyError.inheritedRule
                }
            }
        }
        self = result
    }

    public mutating func removeRule(organizationID: UUID, match: OrganizationBoundaryRule.Match) throws {
        try requireOrganization(organizationID)
        guard let index = rules.firstIndex(where: { $0.organizationID == organizationID && sameMatch($0.match, match) }) else {
            throw OrganizationPolicyError.unknownRule
        }
        rules.remove(at: index)
    }

    /// The caller must compute a non-secret identity for the concrete destination. Never pass a credential or URL.
    /// Service and identity are case-sensitive ASCII tokens; allowed characters are letters, digits, '.', '_', '-', ':'.
    public mutating func grant(organizationID: UUID, service: String, destinationIdentity: String) throws {
        try requireOrganization(organizationID)
        guard validToken(service), validToken(destinationIdentity) else { throw OrganizationPolicyError.invalidDestination }
        guard !grants.contains(where: { $0.organizationID == organizationID && $0.service == service && $0.destinationIdentity == destinationIdentity }) else {
            throw OrganizationPolicyError.duplicateGrant
        }
        grants.append(Grant(organizationID: organizationID, service: service, destinationIdentity: destinationIdentity))
    }

    /// Remove previous consent when a configured destination changes.
    public mutating func revokeAll(service: String) {
        grants.removeAll { $0.service == service }
    }

    /// Keep only consent for the account that is currently configured.
    public mutating func retainGrants(service: String, destinationIdentity: String) {
        grants.removeAll { $0.service == service && $0.destinationIdentity != destinationIdentity }
    }

    fileprivate mutating func clearGrants() { grants.removeAll() }

    /// Revocation is idempotent for an existing organization.
    public mutating func revoke(organizationID: UUID, service: String, destinationIdentity: String) throws {
        try requireOrganization(organizationID)
        guard validToken(service), validToken(destinationIdentity) else { throw OrganizationPolicyError.invalidDestination }
        grants.removeAll { $0.organizationID == organizationID && $0.service == service && $0.destinationIdentity == destinationIdentity }
    }

    /// Supply the trusted checkout's complete remote list. Resolve again when paths or remotes can change.
    public func classify(sessionDirectory: String?, gitRemote: OrganizationBoundaryRemote) -> OrganizationBoundaryResult {
        for rule in rules {
            if case .directory(let path) = rule.match {
                guard let identity = directoryIdentity(path),
                      identity.path.utf8.elementsEqual((rule.resolvedDirectory ?? "").utf8),
                      identity.device == rule.directoryDevice, identity.inode == rule.directoryInode else {
                    return .localOnly(.invalidRule)
                }
            }
        }
        return resolveOrganizationBoundary(rules: rules.map { OrganizationBoundaryRule(organizationID: $0.organizationID.uuidString, match: $0.match) },
                                           sessionDirectory: sessionDirectory, gitRemote: gitRemote)
    }

    /// Reclassifies at the point of the check. Missing, invalid, or changed destinations do not match a grant.
    public func allowsTransmission(sessionDirectory: String?, gitRemote: OrganizationBoundaryRemote,
                                   service: String, destinationIdentity: String?) -> Bool {
        guard let destinationIdentity, validToken(service), validToken(destinationIdentity),
              case .classified(let id) = classify(sessionDirectory: sessionDirectory, gitRemote: gitRemote),
              let organizationID = UUID(uuidString: id) else { return false }
        return grants.contains { $0.organizationID == organizationID && $0.service == service && $0.destinationIdentity == destinationIdentity }
    }

    private func requireOrganization(_ id: UUID) throws {
        guard organizations.contains(where: { $0.id == id }) else { throw OrganizationPolicyError.unknownOrganization }
    }

    private func validateName(_ name: String, excluding id: UUID? = nil) throws {
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw OrganizationPolicyError.invalidName
        }
        guard !organizations.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw OrganizationPolicyError.duplicateOrganization
        }
    }

    fileprivate init(document: PolicyDocument) throws {
        self.init()
        for row in document.organizations {
            guard row.count == 2, let id = UUID(uuidString: row[0]), !organizations.contains(where: { $0.id == id }) else {
                throw OrganizationPolicyError.malformedData
            }
            try validateName(row[1])
            organizations.append(Organization(id: id, name: row[1]))
        }
        for row in document.rules {
            guard row.count == 6, let id = UUID(uuidString: row[0]) else { throw OrganizationPolicyError.malformedData }
            let match: OrganizationBoundaryRule.Match
            switch row[1] {
            case "directory": match = .directory(row[2])
            case "gitRemote": match = .gitRemote(row[2])
            default: throw OrganizationPolicyError.malformedData
            }
            try requireOrganization(id)
            guard validRule(match, requireExistingDirectory: false),
                  !rules.contains(where: { $0.organizationID == id && sameMatch($0.match, match) }) else {
                throw OrganizationPolicyError.malformedData
            }
            let resolved: String?, device: String?, inode: String?
            switch match {
            case .directory:
                guard row[3].hasPrefix("/"), !row[3].utf8.contains(0), Int64(row[4]) != nil, UInt64(row[5]) != nil else {
                    throw OrganizationPolicyError.malformedData
                }
                (resolved, device, inode) = (row[3], row[4], row[5])
            case .gitRemote:
                guard row[3...5].allSatisfy(\.isEmpty) else { throw OrganizationPolicyError.malformedData }
                (resolved, device, inode) = (nil, nil, nil)
            }
            rules.append(Rule(organizationID: id, match: match, resolvedDirectory: resolved,
                              directoryDevice: device, directoryInode: inode))
        }
        for row in document.grants {
            guard row.count == 3, let id = UUID(uuidString: row[0]) else { throw OrganizationPolicyError.malformedData }
            try grant(organizationID: id, service: row[1], destinationIdentity: row[2])
        }
    }
}

private func directoryIdentity(_ path: String) -> (path: String, device: String, inode: String)? {
    guard let bytes = canonicalDirectory(path), let resolved = String(bytes: bytes, encoding: .utf8) else { return nil }
    var info = stat()
    guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
    return (resolved, String(info.st_dev), String(info.st_ino))
}

private func validToken(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
    }
}

private func sameMatch(_ lhs: OrganizationBoundaryRule.Match, _ rhs: OrganizationBoundaryRule.Match) -> Bool {
    switch (lhs, rhs) {
    case (.directory(let a), .directory(let b)), (.gitRemote(let a), .gitRemote(let b)):
        a.utf8.elementsEqual(b.utf8)
    default: false
    }
}

private func validRule(_ match: OrganizationBoundaryRule.Match, requireExistingDirectory: Bool) -> Bool {
    switch match {
    case .directory(let path):
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        if !requireExistingDirectory { return true }
    case .gitRemote(let remote):
        // URL user info, queries and fragments can contain credentials. SSH usernames are permitted.
        guard !remote.contains("?"), !remote.contains("#") else { return false }
        if remote.contains("://") {
            guard let components = URLComponents(string: remote), components.password == nil,
                  components.query == nil, components.fragment == nil,
                  components.user == nil || components.scheme?.lowercased() == "ssh" else { return false }
        }
    }
    let rule = OrganizationBoundaryRule(organizationID: "validation", match: match)
    return resolveOrganizationBoundary(rules: [rule], sessionDirectory: nil, gitRemote: .unknown) != .localOnly(.invalidRule)
}

/// The array-only format rejects duplicate object keys and extra fields instead of choosing one value.
private struct PolicyDocument: Codable {
    let organizations: [[String]]
    let rules: [[String]]
    let grants: [[String]]

    init(_ policy: OrganizationPolicy) {
        organizations = policy.organizations.map { [$0.id.uuidString, $0.name] }
        rules = policy.rules.map { rule in
            switch rule.match {
            case .directory(let path): [rule.organizationID.uuidString, "directory", path, rule.resolvedDirectory ?? "", rule.directoryDevice ?? "", rule.directoryInode ?? ""]
            case .gitRemote(let remote): [rule.organizationID.uuidString, "gitRemote", remote, "", "", ""]
            }
        }
        grants = policy.grants.map { [$0.organizationID.uuidString, $0.service, $0.destinationIdentity] }
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard try container.decode(Int.self) == 1 else { throw OrganizationPolicyError.malformedData }
        organizations = try container.decode([[String]].self)
        rules = try container.decode([[String]].self)
        grants = try container.decode([[String]].self)
        guard container.isAtEnd else { throw OrganizationPolicyError.malformedData }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(1)
        try container.encode(organizations)
        try container.encode(rules)
        try container.encode(grants)
    }
}

/// The rules were committed. A marker issue may require recovery or make it necessary after a restart.
public enum OrganizationPolicyWriteResult: Equatable {
    case saved, savedMarkerNotDurable, savedNeedsRecovery
}

/// Holds the exclusive right to manage destination settings and start outbound requests for this policy.
public final class OrganizationPolicyLease {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }
}

/// Atomic local storage. Callers must use `update` for writes and reload before an outbound check.
/// The lock serializes cooperating stores. External writers must use the same lock.
public struct OrganizationPolicyStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Only one Rounds process may use cached credentials and manage the shared policy at a time.
    public func acquireLease() throws -> OrganizationPolicyLease {
        guard url.isFileURL else { throw OrganizationPolicyError.invalidFile }
        let descriptor = open(url.appendingPathExtension("lease").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(descriptor)
            throw OrganizationPolicyError.invalidFile
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw OrganizationPolicyError.anotherInstance }
            throw posixError(code)
        }
        return OrganizationPolicyLease(descriptor: descriptor)
    }

    /// A missing file starts empty. A corrupt or unreadable file throws and is not replaced.
    public func load() throws -> OrganizationPolicy {
        try withPolicy { $0 }
    }

    /// Hold the policy lock until the caller has started an authorized operation.
    public func withPolicy<T>(_ body: (OrganizationPolicy) throws -> T) throws -> T {
        try withLock { lock in
            try requireClean(lock)
            return try body(decode(readData(at: url)))
        }
    }

    /// The closure edits a fresh copy. A thrown closure leaves the file unchanged.
    @discardableResult
    public func update(_ edit: (inout OrganizationPolicy) throws -> Void) throws -> OrganizationPolicyWriteResult {
        try withLock { lock in
            try requireClean(lock)
            let original = try readData(at: url)
            var policy = try decode(original)
            try edit(&policy)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(PolicyDocument(policy))
            guard try readData(at: url) == original else { throw OrganizationPolicyError.changedOnDisk }
            try markInterrupted(lock)
            try replace(with: data, original: original)
            return clearInterrupted(lock)
        }
    }

    /// Recover an interrupted write without restoring any remote permissions.
    /// Call only after the user confirms that all destination permissions will be removed.
    @discardableResult
    public func recoverInterruptedWrite() throws -> OrganizationPolicyWriteResult {
        try withLock { lock in
            var info = stat()
            guard fstat(lock, &info) == 0 else { throw posixError() }
            guard info.st_size > 0 else { return .saved }
            let original = try readData(at: url)
            var policy = try decode(original)
            policy.clearGrants()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(PolicyDocument(policy))
            try replace(with: data, original: original)
            return clearInterrupted(lock)
        }
    }

    private func requireClean(_ lock: Int32) throws {
        var info = stat()
        guard fstat(lock, &info) == 0 else { throw posixError() }
        guard info.st_size == 0 else { throw OrganizationPolicyError.interruptedWrite }
    }

    private func markInterrupted(_ lock: Int32) throws {
        var marker: UInt8 = 1
        guard pwrite(lock, &marker, 1, 0) == 1, fcntl(lock, F_FULLFSYNC) == 0 else { throw posixError() }
    }

    /// The policy is already durable before the marker is cleared. A failed marker sync can only require
    /// recovery after a crash; the caller must report that uncertainty without claiming the update failed.
    private func clearInterrupted(_ lock: Int32) -> OrganizationPolicyWriteResult {
        guard ftruncate(lock, 0) == 0 else { return .savedNeedsRecovery }
        return fcntl(lock, F_FULLFSYNC) == 0 ? .saved : .savedMarkerNotDurable
    }

    private func withLock<T>(_ body: (Int32) throws -> T) throws -> T {
        guard url.isFileURL else { throw OrganizationPolicyError.invalidFile }
        let lock = open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw posixError() }
        defer { close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw OrganizationPolicyError.invalidFile }
        guard flock(lock, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(lock, LOCK_UN) }
        return try body(lock)
    }

    private func replace(with data: Data, original: Data?) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".rounds-policy-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var canRemoveTemporary = true
        defer {
            close(descriptor)
            if canRemoveTemporary { unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw posixError() }
        if let original {
            guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, url.path, UInt32(RENAME_SWAP)) == 0 else {
                let code = errno
                if code == ENOENT { throw OrganizationPolicyError.changedOnDisk }
                throw posixError(code)
            }
            // The temporary path now holds the exact file replaced by the swap.
            canRemoveTemporary = false
            guard (try? readData(at: temporary)) == original else {
                if renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, url.path, UInt32(RENAME_SWAP)) == 0,
                   (try? readData(at: temporary)) == data {
                    canRemoveTemporary = true
                    try syncDirectory()
                }
                throw OrganizationPolicyError.changedOnDisk
            }
        } else {
            guard link(temporary.path, url.path) == 0 else {
                let code = errno
                if code == EEXIST { throw OrganizationPolicyError.changedOnDisk }
                throw posixError(code)
            }
        }
        try syncDirectory()
        canRemoveTemporary = true
    }

    private func syncDirectory() throws {
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw posixError() }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw posixError() }
    }

    private func readData(at file: URL) throws -> Data? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw OrganizationPolicyError.invalidFile }
        return try handle.readToEnd() ?? Data()
    }

    private func decode(_ data: Data?) throws -> OrganizationPolicy {
        guard let data else { return OrganizationPolicy() }
        do {
            return try OrganizationPolicy(document: JSONDecoder().decode(PolicyDocument.self, from: data))
        } catch {
            throw OrganizationPolicyError.malformedData
        }
    }
}

private func posixError(_ code: Int32 = errno) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}
