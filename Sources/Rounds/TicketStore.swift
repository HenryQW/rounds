import Foundation
import Observation
import RoundsCore
import Security

/// Linear and GitHub tickets of the rows the window lists (spec "Tickets"). It finds each row's lookups (branch, PRs,
/// first-prompt refs), fetches the due ones from Linear (HTTP) and GitHub (`gh`), and keeps them in a cache file.
/// The Linear key lives only in the Keychain. Only refs, branch names, PR URLs and identifiers leave the Mac.
@MainActor @Observable
final class TicketStore {
    static let shared = TicketStore()

    enum LinearStatus: Equatable { case noKey, connected(String), invalidKey, offline }
    enum GitHubStatus: Equatable { case signedIn(String), notFound, notSignedIn, offline }

    /// `.noKey` also while a key waits for its first answer (`hasLinearKey` tells the two apart), so nothing says
    /// offline before a request failed.
    private(set) var linearStatus = LinearStatus.noKey
    /// nil until the first check of `gh` answers.
    private(set) var githubStatus: GitHubStatus?
    private(set) var hasLinearKey = false

    /// Called once after new data or new lookups, so the app regroups (and sets each row's tickets again).
    @ObservationIgnored var onChange: @MainActor () -> Void = {}
    /// The app's parsed pi sessions by path: a herdr agent's prompt refs come from its pi session.
    @ObservationIgnored var piSessions: [String: PiSession] = [:]

    /// Observed, so an open hover card shows a PR's data when it comes.
    private var cache = TicketCache()
    /// nil until the Keychain is read; empty when there is no key.
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var keyLoading = false
    /// The team keys of the key's workspace, from each Linear answer: a bare identifier with another prefix is no ticket.
    @ObservationIgnored private var teamKeys: Set<String> = []
    @ObservationIgnored private var listed: [SessionRow] = []
    /// First-prompt refs of Claude and Codex rows, by row id; read once per session.
    @ObservationIgnored private var promptRefs: [String: [TicketRef]] = [:]
    /// Rows whose prompt file was read since the last full scan without a prompt in it.
    @ObservationIgnored private var tried: Set<String> = []
    /// The git branches of each session folder, by cwd; read again every 30 s, so pi and herdr rows follow the folder.
    @ObservationIgnored private var folders: [String: GitFolder] = [:]
    @ObservationIgnored private var lastScan = Date.distantPast
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var linear = Channel()
    /// Lookups whose alias had an error, by service, until they may be asked again (10 minutes), so they block no others.
    @ObservationIgnored private var retry: [TicketService: [Lookup: Date]] = [:]
    @ObservationIgnored private var github = Channel()
    /// Found again on each check of `gh`, so a `gh` installed after launch is used.
    @ObservationIgnored private var gh: String?
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var changePending = false

    private let projectsRoot = URL.homeDirectory.appending(path: ".claude/projects")

    private init() {
        // Demo mode: fixed tickets, and no network, Keychain or cache file.
        if Demo.isOn {
            for (lookup, service, tickets) in Demo.tickets() { cache.store(tickets, for: lookup, service: service, at: Date()) }
            (linearStatus, githubStatus, hasLinearKey) = (.connected("example"), .signedIn("demo"), true)
            return
        }
        if let data = try? Data(contentsOf: ticketCacheURL) {
            if let saved = try? JSONDecoder().decode(TicketCache.self, from: data) { cache = saved }
            else { try? FileManager.default.removeItem(at: ticketCacheURL) }
        }
        checkGitHub()
    }

    // MARK: Rows

    /// The tickets a row shows, from the cache; placeholders for refs without data.
    func tickets(for row: SessionRow) -> [Ticket] {
        let p = parts(row)
        return rowTickets(branch: p.branch, pullRequests: p.prs, refs: p.refs, linearKey: key != "") { cache.tickets(for: $0, service: $1) }
    }

    /// The PR itself, for the PR card.
    func pullRequest(_ url: URL, number: Int) -> Ticket {
        pullRequestTicket(url, number: number, stored: cache.tickets(for: .pr(url), service: .github))
    }

    /// The rows the window lists, after each regroup: only their lookups are fetched.
    func list(_ rows: [SessionRow]) {
        guard !Demo.isOn else { return }
        listed = rows
        // At first need, off the main thread, so a Keychain prompt never blocks launch.
        if key == nil && !keyLoading {
            keyLoading = true
            keychainIO.async {
                let key = LinearKey.read() ?? ""
                DispatchQueue.main.async { MainActor.assumeIsolated { if self.key == nil { self.use(key) } } }
            }
        }
        scan()
        fetch(rows, hover: false)
    }

    /// A row under the pointer: its tickets are fetched again after 1 minute, not 10.
    func hovered(_ row: SessionRow) {
        guard !Demo.isOn else { return }
        fetch([row], hover: true)
    }

    /// The lookup branch, PR URLs and prompt refs of a row, from what is known now (no file reads).
    private func parts(_ r: SessionRow) -> (branch: String?, prs: [URL], refs: [TicketRef]) {
        let folder = folders[r.cwd]
        let branch: String?, refs: [TicketRef]
        switch r.source {
        case .claude, .codex: (branch, refs) = (r.branch, promptRefs[r.id] ?? [])
        case .pi(let s): (branch, refs) = (folder?.branch, s.ticketRefs)
        case .herdr(let a): (branch, refs) = (folder?.branch, a.sessionPath.flatMap { piSessions[$0] }?.ticketRefs ?? [])
        }
        return (lookupBranch(branch, defaultBranch: folder?.defaultBranch), r.pullRequests.map(\.url), rowRefs(refs, teamKeys: teamKeys))
    }

    /// Linear gets the branch, the PRs and the Linear refs; GitHub gets the PRs and the GitHub refs.
    private func lookups(_ r: SessionRow) -> [(Lookup, TicketService)] {
        let p = parts(r)
        var all: [(Lookup, TicketService)] = p.branch.map { [(.branch($0), .linear)] } ?? []
        for url in p.prs { all += [(.pr(url), .linear), (.pr(url), .github)] }
        for ref in p.refs {
            if case .github = ref { all.append((.ref(ref), .github)) } else { all.append((.ref(ref), .linear)) }
        }
        return all
    }

    /// Reads the git folders of new cwds (all of them every 30 s) and the prompt files of new Claude and Codex rows.
    private func scan() {
        guard !scanning else { return }
        let now = Date()
        let full = now.timeIntervalSince(lastScan) >= 30
        let cwds = Set(listed.map(\.cwd)).filter { full || folders[$0] == nil }
        let prompts = listed.compactMap { r in promptRefs[r.id] == nil && (full || !tried.contains(r.id)) ? promptFile(r).map { (r.id, $0) } : nil }
        guard !cwds.isEmpty || !prompts.isEmpty else { return }
        if full { (lastScan, tried) = (now, []) }
        tried.formUnion(prompts.map(\.0))
        scanning = true
        let root = projectsRoot
        ticketIO.async {
            let result = readLookups(cwds: Array(cwds), prompts: prompts, projectsRoot: root)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.scanned(result) } }
        }
    }

    private func promptFile(_ r: SessionRow) -> PromptFile? {
        switch r.source {
        case .claude(let s): .claude(cwd: s.cwd, id: s.cliSessionId)
        case .codex(let t): t.rolloutPath.isEmpty ? nil : .codex(t.rolloutPath)
        case .pi, .herdr: nil
        }
    }

    private func scanned(_ result: (folders: [String: GitFolder], refs: [String: [TicketRef]])) {
        scanning = false
        var new = false
        for (cwd, f) in result.folders where folders[cwd] != f { (folders[cwd], new) = (f, true) }
        for (id, refs) in result.refs {
            promptRefs[id] = refs
            new = new || !refs.isEmpty
        }
        if new { changed() }
    }

    // MARK: Fetch

    /// Sends the due lookups of the rows, at most 20 per request and one request per service at a time. Rows whose
    /// folder is not read yet wait for the scan, which knows the default branch.
    private func fetch(_ rows: [SessionRow], hover: Bool) {
        let now = Date()
        var due: [TicketService: [Lookup]] = [:], seen: [TicketService: Set<Lookup>] = [:]
        for r in rows where folders[r.cwd] != nil {
            for (lookup, service) in lookups(r) where seen[service, default: []].insert(lookup).inserted
                && cache.due(lookup, service: service, now: now, hover: hover) && retry[service]?[lookup].map({ now >= $0 }) ?? true {
                due[service, default: []].append(lookup)
            }
        }
        if let key, !key.isEmpty, linearStatus != .invalidKey, linear.ready(now) {
            let batch = Array((due[.linear] ?? []).prefix(20))
            if !batch.isEmpty {
                let (body, aliases) = linearRequest(batch)
                // A lookup the request cannot ask about has no result.
                let asked = Set(aliases.values.joined())
                store([:], for: batch.filter { !asked.contains($0) }, .linear)
                if !aliases.isEmpty { sendLinear(body, aliases: aliases, batch: batch.filter(asked.contains), key: key) }
            } else if case .connected = linearStatus {} else {
                // Nothing due: a small request still shows Settings whether the key works.
                sendLinear(try! JSONSerialization.data(withJSONObject: ["query": "{ \(linearWorkspaceFields) }"]), aliases: [:], batch: [], key: key)
            }
        }
        if let gh, github.ready(now), let lookups = due[.github] {
            let batch = Array(lookups.prefix(20))
            let (query, aliases) = githubQuery(batch)
            // A lookup the query cannot ask about (not a github.com PR, or an unsafe name) has no result.
            let asked = Set(aliases.values)
            store([:], for: batch.filter { !asked.contains($0) }, .github)
            if !aliases.isEmpty { sendGitHub(gh, query: query, aliases: aliases) }
        }
    }

    private func sendLinear(_ body: Data, aliases: [String: [Lookup]], batch: [Lookup], key: String) {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Personal API keys have no Bearer prefix.
        request.setValue(key, forHTTPHeaderField: "Authorization")
        linear.busy = true
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            let reset = http?.value(forHTTPHeaderField: "X-RateLimit-Requests-Reset")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.linearDone(data, status: http?.statusCode, reset: reset, aliases: aliases, batch: batch, key: key) }
            }
        }.resume()
    }

    private func linearDone(_ data: Data?, status: Int?, reset: String?, aliases: [String: [Lookup]], batch: [Lookup], key sent: String) {
        linear.busy = false
        // The key changed while the request ran: its answer is not for this key.
        guard sent == key else { return fetch(listed, hover: false) }
        let size = batch.count
        guard let data, let status else {
            linear.failed()
            linearStatus = .offline
            return log.info("tickets: linear, \(size) lookups, network error")
        }
        switch linearFailure(status: status, body: data) {
        case .invalidKey:
            linearStatus = .invalidKey
            return log.info("tickets: linear, \(size) lookups, key not valid")
        case .rateLimited:
            linear.wait(until: reset.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date() + 60)
            return log.info("tickets: linear, \(size) lookups, rate limited")
        case nil: break
        }
        do {
            let result = try decodeLinear(data, aliases: aliases)
            linear.succeeded()
            // Null data (every alias failed) has no workspace: the status stays.
            if let w = linearWorkspace(data) {
                linearStatus = .connected(w.urlKey)
                // New team keys change which bare identifiers rows show and look up.
                if w.teamKeys != teamKeys {
                    teamKeys = w.teamKeys
                    changed()
                }
            }
            log.info("tickets: linear, \(size) lookups, ok, \(batch.count { result[$0] == nil }) failed")
            storeAnswer(result, for: batch, .linear)
        } catch {
            linear.failed()
            linearStatus = .offline
            log.info("tickets: linear, \(size) lookups, failed (HTTP \(status))")
        }
        fetch(listed, hover: false)
    }

    private func sendGitHub(_ gh: String, query: String, aliases: [String: Lookup]) {
        github.busy = true
        DispatchQueue.global(qos: .utility).async {
            let out = runCommand(gh, ["api", "graphql", "-f", "query=\(query)"])
            DispatchQueue.main.async { MainActor.assumeIsolated { self.githubDone(out, aliases: aliases) } }
        }
    }

    /// Exit 1 with JSON is a partial answer (an alias not found).
    private func githubDone(_ out: CommandOutput?, aliases: [String: Lookup]) {
        github.busy = false
        let size = aliases.count
        if let out, out.status == 0 || out.status == 1, let result = try? decodeGitHub(out.stdout, aliases: aliases) {
            github.succeeded()
            log.info("tickets: github, \(size) lookups, ok, \(aliases.values.count { result[$0] == nil }) failed")
            if case .signedIn = githubStatus {} else { checkGitHub() }
            storeAnswer(result, for: Array(aliases.values), .github)
        } else {
            github.failed()
            githubStatus = signInProblem(out) ? .notSignedIn : .offline
            if out?.timedOut == true { log.info("tickets: github, timeout") }
            else { log.info("tickets: github, \(size) lookups, failed (exit \(out?.status ?? -1))") }
        }
        fetch(listed, hover: false)
    }

    /// `gh api user` at launch, when Settings opens while not signed in, and after a good answer that came while signed
    /// out: the login for Settings. A change to signed in makes the GitHub lookups due that waited for it.
    func checkGitHub() {
        // An app started from Finder has no shell PATH.
        gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", URL.homeDirectory.appending(path: ".local/bin/gh").path]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let gh else { return githubStatus = .notFound }
        DispatchQueue.global(qos: .utility).async {
            let out = runCommand(gh, ["api", "user", "--jq", ".login"])
            if out?.timedOut == true { log.info("tickets: github, timeout") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let login = out.flatMap { $0.status == 0 ? String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil }
                    let status: GitHubStatus = login.flatMap { $0.isEmpty ? nil : .signedIn($0) } ?? (self.signInProblem(out) ? .notSignedIn : .offline)
                    let was = self.githubStatus
                    self.githubStatus = status
                    if case .signedIn = status, status != was {
                        self.github.succeeded()
                        self.fetch(self.listed, hover: false)
                    }
                }
            }
        }
    }

    private func signInProblem(_ out: CommandOutput?) -> Bool {
        let text = String(decoding: out?.stderr ?? Data(), as: UTF8.self)
        return text.contains("auth login") || text.contains("not logged")
    }

    /// A lookup without a result had an error on its alias: not stored (a GitHub ref keeps its placeholder), and asked
    /// again after 10 minutes.
    private func storeAnswer(_ result: [Lookup: [Ticket]], for lookups: [Lookup], _ service: TicketService) {
        for lookup in lookups { retry[service, default: [:]][lookup] = result[lookup] == nil ? Date() + 600 : nil }
        store(result, for: lookups.filter { result[$0] != nil }, service)
    }

    /// Stores a result for each lookup of a request (a lookup missing from the result has none), then saves.
    private func store(_ result: [Lookup: [Ticket]], for lookups: [Lookup], _ service: TicketService) {
        guard !lookups.isEmpty else { return }
        let now = Date()
        var new = false
        for lookup in lookups {
            let tickets = result[lookup] ?? []
            new = new || cache.tickets(for: lookup, service: service) != tickets
            cache.store(tickets, for: lookup, service: service, at: now)
        }
        save()
        if new { changed() }
    }

    /// One callback for any number of changes, after the current regroup (a fetch can start inside one).
    private func changed() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.changePending = false
                self.onChange()
            }
        }
    }

    /// At most one write per second, off the main thread.
    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                self.saving = false
                guard let data = try? JSONEncoder().encode(self.cache) else { return }
                ticketIO.async { writeCache(data) }
            }
        }
    }

    // MARK: Key

    func setLinearKey(_ newKey: String) {
        let k = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Demo.isOn, !k.isEmpty else { return }
        keychainIO.async { LinearKey.save(k) }
        changeKey(k)
    }

    func removeLinearKey() {
        guard !Demo.isOn else { return }
        keychainIO.async { LinearKey.delete() }
        changeKey("")
    }

    /// A new key clears `.invalidKey` and the wait, and makes every Linear lookup due.
    private func changeKey(_ k: String) {
        cache.removeAll(service: .linear)
        save()
        (linear.failures, linear.retryAt, retry[.linear]) = (0, .distantPast, nil)
        use(k)
    }

    private func use(_ k: String) {
        (key, teamKeys) = (k, [])
        hasLinearKey = !k.isEmpty
        linearStatus = .noKey
        changed()
        fetch(listed, hover: false)
    }
}

/// One service's request state: one request at a time, and a wait after a failure or a rate limit.
private struct Channel {
    var busy = false
    var failures = 0
    var retryAt = Date.distantPast

    func ready(_ now: Date) -> Bool { !busy && now >= retryAt }
    mutating func wait(until date: Date) { retryAt = date }
    mutating func failed() {
        failures += 1
        retryAt = Date() + retryDelay(failures: failures)
    }
    mutating func succeeded() { (failures, retryAt) = (0, .distantPast) }
}

private struct GitFolder: Equatable, Sendable {
    var branch: String?
    var defaultBranch: String?
}

private enum PromptFile: Sendable {
    case claude(cwd: String, id: String)
    case codex(String)
}

private struct CommandOutput: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
}

/// File reads and writes of the store, in order, off the main thread.
private let ticketIO = DispatchQueue(label: "com.henryqw.rounds.tickets")
/// Keychain reads and writes, in order, apart from `ticketIO`, so a Keychain prompt stops no scan or save.
private let keychainIO = DispatchQueue(label: "com.henryqw.rounds.keychain")
private let ticketCacheURL = URL.applicationSupportDirectory.appending(path: "Rounds/tickets.json")

/// The branches of each cwd's repository (the first folder up that has `.git`), and the refs of each prompt file's
/// first 64 KB. A file without a prompt in it is read again later, unless its head is full.
private func readLookups(cwds: [String], prompts: [(String, PromptFile)], projectsRoot: URL) -> (folders: [String: GitFolder], refs: [String: [TicketRef]]) {
    var folders: [String: GitFolder] = [:], refs: [String: [TicketRef]] = [:]
    for cwd in cwds {
        // An empty cwd (a herdr agent without one) would resolve against the app's own folder.
        let git = cwd.hasPrefix("/") ? gitFolder(above: cwd).map(gitBranch) : nil
        folders[cwd] = GitFolder(branch: git?.branch, defaultBranch: git?.defaultBranch)
    }
    for (id, file) in prompts {
        let url: URL? = switch file {
        case .claude(let cwd, let session): transcriptURL(cwd: cwd, cliSessionId: session, projectsRoot: projectsRoot)
        case .codex(let path): URL(fileURLWithPath: path)
        }
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { continue }
        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        try? handle.close()
        let prompt = if case .claude = file { firstUserPrompt(claudeTranscript: data) } else { firstUserPrompt(codexRollout: data) }
        if let prompt { refs[id] = ticketRefs(inPrompt: prompt) } else if data.count == 65_536 { refs[id] = [] }
    }
    return (folders, refs)
}

/// Mode 0600, through a temporary file, so a reader never sees half a file.
private func writeCache(_ data: Data) {
    let fm = FileManager.default, temp = ticketCacheURL.appendingPathExtension("new")
    try? fm.createDirectory(at: ticketCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]),
          rename(temp.path, ticketCacheURL.path) == 0 else { return log.error("tickets: cache not saved") }
}

/// Exit status, stdout and stderr of a command; nil when it does not start. A command that runs for 30 s is stopped.
private func runCommand(_ path: String, _ arguments: [String]) -> CommandOutput? {
    let process = Process(), out = Pipe(), err = Pipe()
    (process.executableURL, process.arguments, process.standardOutput, process.standardError) = (URL(fileURLWithPath: path), arguments, out, err)
    guard (try? process.run()) != nil else { return nil }
    let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: stop)
    // stderr on its own thread, so a full pipe cannot block the command.
    let errDone = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var stderr = Data()
    DispatchQueue.global(qos: .utility).async {
        stderr = err.fileHandleForReading.readDataToEndOfFile()
        errDone.signal()
    }
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    errDone.wait()
    process.waitUntilExit()
    stop.cancel()
    return CommandOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: process.terminationReason == .uncaughtSignal)
}

/// The Linear key in the login Keychain: service `com.henryqw.rounds.linear`, account `api-key`. Never in a file or a log.
private enum LinearKey {
    static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.henryqw.rounds.linear", kSecAttrAccount as String: "api-key"]
    }

    static func read() -> String? {
        var data: AnyObject?
        let status = SecItemCopyMatching(item.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &data)
        if status != errSecSuccess && status != errSecItemNotFound { log.error("tickets: Keychain read failed (\(status))") }
        return (data as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    static func save(_ key: String) {
        SecItemDelete(item as CFDictionary)
        let status = SecItemAdd(item.merging([kSecValueData as String: Data(key.utf8)]) { $1 } as CFDictionary, nil)
        if status != errSecSuccess { log.error("tickets: Keychain save failed (\(status))") }
    }

    static func delete() { SecItemDelete(item as CFDictionary) }
}
