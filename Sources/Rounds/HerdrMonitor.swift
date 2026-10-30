import AppKit
import Darwin
import RoundsCore
import Foundation

/// Live herdr agents over herdr's socket API (spec 2.4): one request per connection, plus one subscription
/// connection that stays open. Any event re-reads `agent.list`; a changed pane set subscribes again.
final class HerdrMonitor: @unchecked Sendable {
    enum Status: Equatable {
        case notInstalled, notRunning
        case connected(Int)
    }

    static let socketPath = URL.homeDirectory.appending(path: ".config/herdr/herdr.sock").path
    /// Requests and state run on `queue`; the subscription's blocking reads run on their own thread.
    private let queue = DispatchQueue(label: "com.henryqw.rounds.herdr")
    private let onUpdate: @MainActor ([HerdrAgent], Status) -> Void
    /// Pane ids and socket of the open subscription; touched only on `queue`.
    private var subscribedPanes: Set<String> = []
    private var subscription: Int32 = -1
    private var listPending = false
    /// The last list and status sent to the app; touched only on `queue`.
    private var lastReport: ([HerdrAgent], Status)?

    init(onUpdate: @escaping @MainActor ([HerdrAgent], Status) -> Void) {
        self.onUpdate = onUpdate
        Thread.detachNewThread { [self] in loop() }
    }

    /// Re-reads the agent list now (also called by the app's 30 s timer, so a missed event heals). It always reports,
    /// so the app's time windows move on.
    func refresh() {
        queue.async { self.list(always: true) }
    }

    /// Selects the agent's pane in herdr, then shows herdr: the exact terminal pane of a local herdr client, or,
    /// when every client is remote (over SSH, tsshd), a new terminal window that runs herdr.
    func focus(_ agent: HerdrAgent) {
        queue.async {
            do {
                _ = try Self.request("agent.focus", ["target": agent.paneId])
            } catch {
                log.error("herdr focus failed: \(String(describing: error), privacy: .public)")
            }
            let client = Self.localClient()
            DispatchQueue.main.async { MainActor.assumeIsolated { TerminalOpener.show(client) } }
        }
    }

    /// Shows herdr: the terminal of a local client, else a new terminal window that runs herdr.
    func show() {
        queue.async {
            let client = Self.localClient()
            DispatchQueue.main.async { MainActor.assumeIsolated { TerminalOpener.show(client) } }
        }
    }

    /// On the subscription thread: list, subscribe until the connection ends or the pane set changes, repeat.
    private func loop() {
        while true {
            guard let panes = queue.sync(execute: { list() }) else {
                Thread.sleep(forTimeInterval: 5)
                continue
            }
            subscribe(to: panes)
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func subscribe(to panes: Set<String>) {
        let types = ["pane.created", "pane.closed", "pane.exited", "pane.agent_detected", "pane.updated"]
        let subscriptions: [[String: String]] = types.map { ["type": $0] }
            + panes.sorted().map { ["type": "pane.agent_status_changed", "pane_id": $0] }
        guard let fd = try? Self.connect() else { return }
        defer { close(fd) }
        guard (try? Self.send(fd, "events.subscribe", ["subscriptions": subscriptions])) != nil else { return }
        queue.sync {
            subscription = fd
            subscribedPanes = panes
        }
        var reader = LineReader(fd: fd)
        while reader.next() != nil {
            queue.async { self.listOncePerBurst() }
        }
        queue.sync { subscription = -1 }
    }

    // MARK: - On `queue`

    /// Reads `agent.list` and reports it when it changed (the 5 s retry while herdr is not running reads the same).
    /// Returns the pane ids, or nil when herdr is not reachable.
    @discardableResult
    private func list(always: Bool = false) -> Set<String>? {
        let agents = (try? parseHerdrAgents(Self.request("agent.list", [:])))
        let installed = FileManager.default.fileExists(atPath: URL.homeDirectory.appending(path: ".config/herdr").path)
        let report = (agents ?? [], agents.map { .connected($0.count) } ?? (installed ? Status.notRunning : .notInstalled))
        if always || lastReport.map({ $0 != report }) ?? true {
            lastReport = report
            let update = onUpdate
            DispatchQueue.main.async { MainActor.assumeIsolated { update(report.0, report.1) } }
        }
        guard let agents else { return nil }
        let panes = Set(agents.map(\.paneId))
        // A new or closed pane needs a new subscription list; closing the socket ends `subscribe`.
        if subscription >= 0, panes != subscribedPanes { shutdown(subscription, SHUT_RDWR) }
        return panes
    }

    /// Events come in bursts (a status change also updates the pane); read the list once per burst.
    private func listOncePerBurst() {
        guard !listPending else { return }
        listPending = true
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.listPending = false
            self?.list()
        }
    }

    // MARK: - Socket

    private static func request(_ method: String, _ params: [String: Any]) throws -> Data {
        let fd = try connect()
        defer { close(fd) }
        try send(fd, method, params)
        var reader = LineReader(fd: fd)
        guard let line = reader.next() else { throw HerdrError.invalidResponse }
        return line
    }

    private static func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }
        return fd
    }

    private static func send(_ fd: Int32, _ method: String, _ params: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": params])
        data.append(UInt8(ascii: "\n"))
        let sent = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// A local herdr client: the regular app above it (its terminal) and, in rootshell, the client's pane UUID.
    /// Remote clients have no app above them.
    private static func localClient() -> TerminalOpener.Client? {
        Processes.all().lazy.filter { Processes.name(of: $0) == "herdr" }.compactMap(TerminalOpener.client(above:)).first
    }
}

/// Shows a terminal program (herdr, a pi session) through AppleScript (macOS asks the user once per app).
@MainActor
enum TerminalOpener {
    struct Client: Sendable {
        let app: NSRunningApplication
        /// rootshell's `LC_ROOTSHELL_PANE` of the client shell; nil in other terminals.
        let rootshellPane: UUID?
    }

    static let rootshell = "com.kk2.rootshell"
    static let ghostty = "com.mitchellh.ghostty"

    /// The terminal a local process runs in: the regular app above it and, in rootshell, the process's pane UUID.
    /// A process over SSH has no app above it.
    nonisolated static func client(above pid: pid_t) -> Client? {
        var current = pid
        for _ in 0..<12 {
            guard let parent = Processes.parent(of: current), parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                return Client(app: app, rootshellPane: Processes.environment(of: pid, "LC_ROOTSHELL_PANE").flatMap(UUID.init(uuidString:)))
            }
            current = parent
        }
        return nil
    }

    /// A local client: its exact rootshell pane, else its app. No local client: `command` in `directory`, in a new tab
    /// of a running rootshell (a new window when it has none), else a new rootshell window, else a new Ghostty window.
    /// herdr attaches to its session with the agent already selected.
    static func show(_ client: Client?, command: String = "herdr", directory: String? = nil) {
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let arguments = "with command \(quoted(command))" + (directory.map { " in directory \(quoted($0))" } ?? "")
        if let client {
            if client.app.bundleIdentifier == rootshell, let pane = client.rootshellPane {
                run("tell application id \"\(rootshell)\" to focus pane with id \"\(pane.uuidString)\"")
            }
            client.app.activate()
        } else if NSWorkspace.shared.urlForApplication(withBundleIdentifier: rootshell) != nil {
            // `create tab` needs a front window; with none, it fails and a new window opens.
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: rootshell).isEmpty
            if !(running && run("tell application id \"\(rootshell)\"\ncreate tab \(arguments)\nactivate\nend tell")) {
                run("tell application id \"\(rootshell)\"\ncreate window \(arguments)\nactivate\nend tell")
            }
        } else if NSWorkspace.shared.urlForApplication(withBundleIdentifier: ghostty) != nil {
            let input = (directory.map { "cd '\($0.replacingOccurrences(of: "'", with: "'\\''"))' && " } ?? "") + command
            run("tell application id \"\(ghostty)\"\nnew window with configuration {initial input:\(quoted(input)) & linefeed}\nactivate\nend tell")
        }
    }

    @discardableResult
    private static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { log.error("AppleScript failed: \(error, privacy: .public)") }
        return error == nil
    }
}

/// Newline-framed reads from a socket; `next()` returns nil at end of stream or on error.
private struct LineReader {
    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    mutating func next() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk.prefix(n))
        }
    }
}
