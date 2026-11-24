import Foundation

/// The one remote owner of an organization: a Git host and one account on it, such as `github.com/HenryQW`.
/// The account can be a person or a GitHub organization. The host is kept in lower case.
public struct RemoteOwner: Hashable, Sendable {
    public let host: String
    public let account: String

    /// Nil unless `host` is a host name with no scheme, port or path, and `account` is one account name.
    public init?(host: String, account: String) {
        guard validOwnerHost(host), validOwnerAccount(account) else { return nil }
        self.host = host.lowercased()
        self.account = account
    }

    /// Reads `host/account`, as Settings shows it. Spaces around the text are ignored.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(host: String(parts[0]), account: String(parts[1]))
    }

    public var description: String { "\(host)/\(account)" }

    /// The account matches with no regard to case, as Git hosts do.
    func owns(host other: String, account name: String) -> Bool {
        other.lowercased() == host && name.lowercased() == account.lowercased()
    }
}

private func validOwnerHost(_ host: String) -> Bool {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    return !host.isEmpty && host.utf8.count <= 253 && labels.allSatisfy { label in
        !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") &&
            label.utf8.allSatisfy { isASCIIAlphanumeric($0) || $0 == UInt8(ascii: "-") }
    }
}

private func validOwnerAccount(_ account: String) -> Bool {
    !account.isEmpty && account.utf8.count <= 100 && account != "." && account != ".." && !account.hasPrefix("~") &&
        account.utf8.allSatisfy { isASCIIAlphanumeric($0) || "-_.".utf8.contains($0) }
}

private func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ||
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
}

/// True only when `url` (a remote URL as `git remote -v` prints it, after `insteadOf` rewrites) names a repository of
/// `owner`. Accepted forms: `https://host/account/repo(.git)` (also `http` and `git`), `ssh://[user@]host[:port]/account/repo`
/// and the scp-like `[user@]host:account/repo`. For an SSH form, `sshHostName` resolves the host, which can be an alias,
/// to the host name that SSH connects to; nil refuses. Anything that does not parse is refused.
public func remoteBelongs(_ url: String, to owner: RemoteOwner, sshHostName: (String) -> String?) -> Bool {
    guard let remote = parseRemote(url) else { return false }
    let host: String
    if remote.ssh {
        guard let resolved = sshHostName(remote.host) else { return false }
        host = resolved
    } else {
        host = remote.host
    }
    return owner.owns(host: host, account: remote.account)
}

/// The host and the first path component of a remote URL. The user information, a password included, is dropped.
private func parseRemote(_ url: String) -> (host: String, account: String, ssh: Bool)? {
    guard !url.isEmpty, !url.utf8.contains(where: { $0 <= 32 || $0 == 127 }) else { return nil }
    let host: String, path: Substring, ssh: Bool
    if let separator = url.range(of: "://") {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              ["https", "http", "git", "ssh", "git+ssh", "ssh+git"].contains(scheme),
              components.query == nil, components.fragment == nil else { return nil }
        // Read from the text too, and require both reads to agree, so URL parsing cannot move a component.
        let rest = url[separator.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let authority = rest[..<slash]
        let hostPort = authority.lastIndex(of: "@").map { authority[authority.index(after: $0)...] } ?? authority
        let name = hostPort.prefix { $0 != ":" }
        guard components.host?.lowercased() == name.lowercased() else { return nil }
        (host, path, ssh) = (String(name), rest[slash...], ["ssh", "git+ssh", "ssh+git"].contains(scheme))
    } else if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") {
        // A local path with a slash before the first colon is not scp-like syntax.
        let authority = url[..<colon]
        let name = authority.lastIndex(of: "@").map { authority[authority.index(after: $0)...] } ?? authority
        (host, path, ssh) = (String(name), url[url.index(after: colon)...], true)
    } else {
        return nil
    }
    guard validOwnerHost(host) else { return nil }
    // Percent signs could encode a slash or a dot segment in a component.
    guard !path.contains("%") else { return nil }
    var parts = path.split(separator: "/", omittingEmptySubsequences: false)
    if parts.first == "" { parts.removeFirst() }
    if parts.count > 2, parts.last == "" { parts.removeLast() }
    guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          validOwnerAccount(String(parts[0])) else { return nil }
    return (host, String(parts[0]), ssh)
}

/// The host name that SSH connects to for `alias`, from `/usr/bin/ssh -G` (which reads the SSH configuration and makes
/// no connection). Nil when the alias is not a plain host name, when ssh fails, or after `timeout`.
public func resolveSSHHostName(_ alias: String, configFile: String? = nil, timeout: TimeInterval = 2) -> String? {
    guard validOwnerHost(alias) else { return nil }
    let process = Process(), out = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = (configFile.map { ["-F", $0] } ?? []) + ["-G", "--", alias]
    (process.standardOutput, process.standardError, process.standardInput) = (out, FileHandle.nullDevice, FileHandle.nullDevice)
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { return nil }
    nonisolated(unsafe) var data = Data()
    let read = DispatchGroup()
    DispatchQueue.global(qos: .utility).async(group: read) { data = out.fileHandleForReading.readDataToEndOfFile() }
    guard exited.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        return nil
    }
    guard read.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else { return nil }
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("hostname ") {
        let name = String(line.dropFirst("hostname ".count))
        return validOwnerHost(name) ? name : nil
    }
    return nil
}
