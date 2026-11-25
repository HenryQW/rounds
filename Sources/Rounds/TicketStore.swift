import Foundation
import Observation
import RoundsCore

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
    /// nil until the first check of `gh` answers. A change regroups, as rows hide their guesses without `gh`.
    private(set) var githubStatus: GitHubStatus? { didSet { if githubStatus != oldValue { changed() } } }
    private(set) var hasLinearKey = false
    private(set) var linearKeyBusy = false
    private(set) var linearKeychainError: LinearKeychainError?
    private(set) var linearPermissionError: String?

    enum LinearKeychainError: String {
        case read = "Could not read the Linear key from Keychain."
        case save = "Could not save the Linear key to Keychain."
        case remove = "Could not remove the Linear key from Keychain."
    }

    var organizationDestinations: [OrganizationDestination] {
        var result: [OrganizationDestination] = []
        if let key, !key.isEmpty,
           let destination = makeOrganizationDestination(service: "ticket-linear", fields: ["endpoint": "https://api.linear.app/graphql", "key": key],
                                                     title: "Linear", detail: workspace ?? "api.linear.app") {
            result.append(destination)
        }
        if case .signedIn(let login) = githubStatus,
           let destination = makeOrganizationDestination(service: "ticket-github", fields: ["endpoint": "https://api.github.com", "account": login],
                                                     title: "GitHub", detail: "github.com · \(login)") {
            result.append(destination)
        }
        return result
    }

    private func organizationDestination(for service: TicketService) -> OrganizationDestination? {
        organizationDestinations.first { $0.service == "ticket-\(service.rawValue)" }
    }

    /// Called once after new data or new lookups, so the app regroups (and sets each row's tickets again).
    @ObservationIgnored var onChange: @MainActor () -> Void = {}
    /// The app's parsed pi sessions by path: a herdr agent's prompt refs come from its pi session.
    @ObservationIgnored var piSessions: [String: PiSession] = [:]

    /// Observed, so an open hover card shows a PR's data when it comes.
    private var cache = TicketCache()
    /// nil until the Keychain is read; empty when there is no key.
    @ObservationIgnored private var key: String?
    /// The team keys of the key's workspace, from each Linear answer: a bare identifier with another prefix is no ticket.
    @ObservationIgnored private var teamKeys: Set<String> = []
    /// The workspace of the last answer that named one: an answer with null data names none but proves the key works.
    @ObservationIgnored private var workspace: String?
    @ObservationIgnored private var listed: [SessionRow] = []
    /// First-prompt refs, bound to the session, folder and transcript used to read them.
    @ObservationIgnored private var promptRefs: [PromptKey: [TicketRef]] = [:]
    /// Prompt sources read since the last full scan without a prompt in them.
    @ObservationIgnored private var tried: Set<PromptKey> = []
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
    @ObservationIgnored private var checkingGitHub = false
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
            if let saved = try? JSONDecoder().decode(TicketCache.self, from: data) {
                cache = saved
                cache.removeOld(now: Date())
                // Bare identifiers of cached teams show before Linear answers (offline, say).
                teamKeys = cache.linearTeamKeys
            }
            else { try? FileManager.default.removeItem(at: ticketCacheURL) }
        }
        checkGitHub()
    }

    // MARK: Rows

    /// The tickets a row shows, from the cache; placeholders for refs without data. A guess (`#N`, `owner/repo#N`) that
    /// GitHub does not know as an issue (a PR, say) shows nothing once GitHub answers, and nothing without `gh`.
    func tickets(for row: SessionRow) -> [Ticket] {
        let p = parts(row)
        let noGitHub = githubStatus == .notFound || githubStatus == .notSignedIn
        return rowTickets(branch: p.branch, pullRequests: p.prs, refs: p.refs, linearKey: key != "") { lookup, service in
            let stored = cache.tickets(for: lookup, service: service)
            guard p.guesses.contains(lookup) else { return stored }
            return noGitHub ? [] : stored?.filter { $0.problem != .notFound }
        }
    }

    /// The PR itself, for the PR card.
    func pullRequest(_ url: URL, number: Int) -> Ticket {
        pullRequestTicket(url, number: number, stored: cache.tickets(for: .pr(url), service: .github))
    }

    /// The rows the window lists, after each regroup: only their lookups are fetched.
    func list(_ rows: [SessionRow]) {
        guard !Demo.isOn else { return }
        listed = rows
        prepareOrganizationDestinations()
        scan()
        fetch(rows, hover: false)
    }

    func prepareOrganizationDestinations() {
        guard !Demo.isOn, key == nil, !linearKeyBusy, linearKeychainError == nil else { return }
        // At first need, off the main thread, so a Keychain prompt never blocks launch.
        linearKeyBusy = true
        keychainIO.async {
            let result = Result { try LinearKey.read() }
            DispatchQueue.main.async {
                self.linearKeyBusy = false
                switch result {
                case .success(let key): self.use(key)
                case .failure: self.linearKeychainError = .read
                }
            }
        }
    }

    func retryLinearKey() {
        guard linearKeychainError == .read else { return }
        linearKeychainError = nil
        prepareOrganizationDestinations()
    }

    /// A row under the pointer: its tickets are fetched again after 1 minute, not 10.
    func hovered(_ row: SessionRow) {
        guard !Demo.isOn, let current = listed.first(where: { $0.id == row.id }) else { return }
        fetch([current], hover: true)
    }

    /// The lookup branch, PR URLs (the row's, then the prompt's) and other prompt refs of a row, from what is known now
    /// (no file reads), and the lookups of guesses that no issue URL also names.
    private func parts(_ r: SessionRow) -> (branch: String?, prs: [URL], refs: [TicketRef], guesses: Set<Lookup>) {
        let folder = folders[r.cwd]
        let branch: String?, refs: [TicketRef]
        switch r.source {
        case .claude, .codex: (branch, refs) = (r.branch, promptKey(r).flatMap { promptRefs[$0] } ?? [])
        case .pi(let s): (branch, refs) = (folder?.branch, s.ticketRefs)
        case .herdr(let a): (branch, refs) = (folder?.branch, a.sessionPath.flatMap { piSessions[$0] }?.ticketRefs ?? [])
        }
        let repository = folder?.repository
        var prs = r.pullRequests.map(\.url), other: [TicketRef] = []
        for ref in rowRefs(refs, teamKeys: teamKeys, repository: repository) {
            guard case .githubPR(let owner, let repo, let number) = ref else { other.append(ref); continue }
            let url = URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")!
            if !prs.contains(url) { prs.append(url) }
        }
        let guesses = refs.compactMap { ref -> TicketRef? in
            guard case .githubNumber(let n, let own) = ref, let repo = own ?? repository else { return nil }
            return .github(owner: repo.owner, repo: repo.name, number: n)
        }
        return (lookupBranch(branch, defaultBranch: folder?.defaultBranch), prs, other, Set(guesses.filter { !refs.contains($0) }.map(Lookup.ref)))
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
        let prompts = listed.compactMap { promptKey($0) }.filter { promptRefs[$0] == nil && (full || !tried.contains($0)) }
        guard !cwds.isEmpty || !prompts.isEmpty else { return }
        if full { (lastScan, tried) = (now, []) }
        tried.formUnion(prompts)
        scanning = true
        let root = projectsRoot
        ticketIO.async {
            let result = readLookups(cwds: Array(cwds), prompts: prompts, projectsRoot: root)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.scanned(result) } }
        }
    }

    private func promptKey(_ row: SessionRow) -> PromptKey? {
        promptFile(row).map { PromptKey(id: row.id, cwd: row.cwd, file: $0) }
    }

    private func promptFile(_ r: SessionRow) -> PromptFile? {
        switch r.source {
        case .claude(let s): s.cliSessionId.map { .claude(cwd: s.cwd, id: $0) }
        case .codex(let t): t.rolloutPath.isEmpty ? nil : .codex(t.rolloutPath)
        case .pi, .herdr: nil
        }
    }

    private func scanned(_ result: (folders: [String: GitFolder], refs: [PromptKey: [TicketRef]])) {
        scanning = false
        var new = false
        for (cwd, f) in result.folders where folders[cwd] != f { (folders[cwd], new) = (f, true) }
        let current = Set(listed.compactMap { promptKey($0) })
        promptRefs = promptRefs.filter { current.contains($0.key) }
        tried.formIntersection(current)
        for (key, refs) in result.refs where current.contains(key) {
            promptRefs[key] = refs
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
        var sources: [TicketService: [Lookup: [SessionRow]]] = [:]
        // One policy read and one destination each for all rows: a regroup can list hundreds of lookups.
        let destinations = Dictionary(uniqueKeysWithValues: [TicketService.linear, .github].compactMap { s in organizationDestination(for: s).map { (s, $0) } })
        let policy = try? OrganizationSettingsState.shared.withPolicy { $0 }
        for r in rows where folders[r.cwd] != nil {
            for (lookup, service) in lookups(r) {
                guard let policy, let destination = destinations[service],
                      policy.allowsTransmission(sessionDirectory: r.cwd, gitRemote: .unknown,
                                                service: destination.service, destinationIdentity: destination.identity) else { continue }
                sources[service, default: [:]][lookup, default: []].append(r)
                guard seen[service, default: []].insert(lookup).inserted,
                      cache.due(lookup, service: service, now: now, hover: hover),
                      retry[service]?[lookup].map({ now >= $0 }) ?? true else { continue }
                due[service, default: []].append(lookup)
            }
        }
        if let key, !key.isEmpty, linearStatus != .invalidKey, linear.ready(now) {
            var sent = false
            if let destination = organizationDestination(for: .linear) {
                _ = try? OrganizationSettingsState.shared.withPolicy { policy in
                    let batch = linearBatch(due[.linear] ?? [], folders: (sources[.linear] ?? [:]).mapValues { $0.map(\.cwd) },
                                            policy: policy, destination: destination)
                    guard !batch.isEmpty else { return }
                    let (body, aliases) = linearRequest(batch)
                    // A lookup the request cannot ask about has no result.
                    let asked = Set(aliases.values.joined())
                    store([:], for: batch.filter { !asked.contains($0) }, .linear)
                    if !aliases.isEmpty {
                        sent = true
                        sendLinear(body, aliases: aliases, batch: batch.filter(asked.contains), key: key)
                    }
                }
            }
            if !sent, case .connected = linearStatus {} else if !sent, OrganizationSettingsState.shared.hasLease {
                // Nothing due: a small request still shows Settings whether the key works.
                sendLinear(try! JSONSerialization.data(withJSONObject: ["query": "{ \(linearWorkspaceFields) }"]), aliases: [:], batch: [], key: key)
            }
        }
        if let gh, github.ready(now), let lookups = due[.github] {
            let batch = Array(lookups.prefix(20))
            let (_, aliases) = githubQuery(batch)
            // A lookup the query cannot ask about (not a github.com PR, or an unsafe name) has no result.
            let asked = Set(aliases.values)
            store([:], for: batch.filter { !asked.contains($0) }, .github)
            if !aliases.isEmpty, let destination = organizationDestination(for: .github), case .signedIn(let login) = githubStatus {
                sendGitHub(gh, batch: batch.filter(asked.contains), sources: sources[.github] ?? [:], destination: destination, login: login)
            }
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
        OutboundSession.noRedirects.dataTask(with: request) { data, response, _ in
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
            if let w = linearWorkspace(data) {
                workspace = w.urlKey
                // New team keys change which bare identifiers rows show and look up.
                if w.teamKeys != teamKeys {
                    teamKeys = w.teamKeys
                    changed()
                }
            }
            // Null data (every alias failed) names no workspace: the last one stays.
            if let workspace { linearStatus = .connected(workspace) }
            log.info("tickets: linear, \(size) lookups, ok, \(batch.count { result[$0] == nil }) failed")
            storeAnswer(result, for: batch, .linear)
        } catch {
            linear.failed()
            linearStatus = .offline
            log.info("tickets: linear, \(size) lookups, failed (HTTP \(status))")
        }
        fetch(listed, hover: false)
    }

    private func sendGitHub(_ gh: String, batch: [Lookup], sources: [Lookup: [SessionRow]], destination: OrganizationDestination, login: String) {
        github.busy = true
        DispatchQueue.global(qos: .utility).async {
            // Use one credential for the account check and lookup; do not refresh it in the background.
            let environment = ProcessInfo.processInfo.environment
            let inherited = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"]
            let token = inherited ?? runCommand(gh, ["auth", "token", "--hostname", "github.com", "--no-refresh"])
                .flatMap { $0.status == 0 ? String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            guard let token, !token.isEmpty else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.github.busy = false
                        // The backoff stops a fetch loop while `gh` gives no token.
                        self.github.failed()
                        self.checkGitHub()
                    }
                }
                return
            }
            var account = URLRequest(url: URL(string: "https://api.github.com/user")!)
            account.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            account.setValue("Rounds", forHTTPHeaderField: "User-Agent")
            account.timeoutInterval = 15
            OutboundSession.noRedirects.dataTask(with: account) { data, response, _ in
                let currentLogin = (response as? HTTPURLResponse)?.statusCode == 200
                    ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["login"] as? String : nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard currentLogin == login, self.gh == gh,
                              self.organizationDestination(for: .github) == destination else {
                            self.github.busy = false
                            if currentLogin != login {
                                self.github.failed()
                                self.checkGitHub()
                            }
                            return
                        }
                        let started = (try? OrganizationSettingsState.shared.withPolicy { policy in
                            let allowed = batch.filter { lookup in
                                (sources[lookup] ?? []).contains { source in
                                    self.listed.contains { current in
                                        current.id == source.id && current.cwd == source.cwd &&
                                            self.lookups(current).contains { $0.0 == lookup && $0.1 == .github } &&
                                            policy.allowsTransmission(sessionDirectory: current.cwd, gitRemote: .unknown,
                                                                      service: destination.service, destinationIdentity: destination.identity)
                                    }
                                }
                            }
                            let (query, aliases) = githubQuery(allowed)
                            guard !aliases.isEmpty else { return false }
                            var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
                            request.httpMethod = "POST"
                            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
                            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            request.setValue("Rounds", forHTTPHeaderField: "User-Agent")
                            request.timeoutInterval = 30
                            OutboundSession.noRedirects.dataTask(with: request) { data, response, _ in
                                let status = (response as? HTTPURLResponse)?.statusCode
                                let out = status.map { CommandOutput(status: $0 == 200 ? 0 : 2, stdout: data ?? Data(), stderr: Data(), timedOut: false) }
                                DispatchQueue.main.async { MainActor.assumeIsolated { self.githubDone(out, aliases: aliases) } }
                            }.resume()
                            return true
                        }) ?? false
                        if !started { self.github.busy = false }
                    }
                }
            }.resume()
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
    /// out: the login for Settings. A change to signed in makes the GitHub lookups due that waited for it. One check
    /// at a time.
    func checkGitHub() {
        // An app started from Finder has no shell PATH.
        gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", URL.homeDirectory.appending(path: ".local/bin/gh").path]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let gh else { return githubStatus = .notFound }
        guard OrganizationSettingsState.shared.hasLease else { return githubStatus = .offline }
        guard !checkingGitHub else { return }
        checkingGitHub = true
        DispatchQueue.global(qos: .utility).async {
            let out = runCommand(gh, ["api", "--hostname", "github.com", "user", "--jq", ".login"])
            if out?.timedOut == true { log.info("tickets: github, timeout") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.checkingGitHub = false
                    let login = out.flatMap { $0.status == 0 ? String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil }
                    var status: GitHubStatus = login.flatMap { $0.isEmpty ? nil : .signedIn($0) } ?? (self.signInProblem(out) ? .notSignedIn : .offline)
                    if case .signedIn(let account) = status,
                       let destination = makeOrganizationDestination(service: "ticket-github", fields: ["endpoint": "https://api.github.com", "account": account], title: "GitHub", detail: "github.com · \(account)"),
                       !OrganizationSettingsState.shared.reconcilePermissions(service: destination.service, destinationIdentity: destination.identity) {
                        status = .offline
                    } else if status == .notSignedIn,
                              !OrganizationSettingsState.shared.resetPermissions(service: "ticket-github") {
                        status = .offline
                    }
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
    /// again after 10 minutes. Waits that are over are dropped.
    private func storeAnswer(_ result: [Lookup: [Ticket]], for lookups: [Lookup], _ service: TicketService) {
        let now = Date()
        retry[service] = retry[service]?.filter { $0.value > now }
        for lookup in lookups { retry[service, default: [:]][lookup] = result[lookup] == nil ? now + 600 : nil }
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

    func setLinearKey(_ newKey: String, onSave: @escaping @MainActor @Sendable () -> Void) {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        updateLinearKey(key, onSuccess: onSave)
    }

    func removeLinearKey() {
        updateLinearKey("") {}
    }

    private func updateLinearKey(_ newKey: String, onSuccess: @escaping @MainActor @Sendable () -> Void) {
        guard !Demo.isOn, !linearKeyBusy else { return }
        if newKey == key {
            linearPermissionError = nil
            linearKeychainError = nil
            onSuccess()
            return
        }
        // Revoke first so a restart after a Keychain write cannot restore an old grant.
        guard OrganizationSettingsState.shared.resetPermissions(service: "ticket-linear") else {
            linearPermissionError = "Could not update organization permissions. Open Organizations to resolve the error."
            return
        }
        linearPermissionError = nil
        linearKeychainError = nil
        linearKeyBusy = true
        keychainIO.async {
            let result = Result {
                if newKey.isEmpty { try LinearKey.delete() }
                else { try LinearKey.save(newKey) }
            }
            DispatchQueue.main.async {
                self.linearKeyBusy = false
                switch result {
                case .success:
                    self.changeKey(newKey)
                    onSuccess()
                case .failure:
                    self.linearKeychainError = newKey.isEmpty ? .remove : .save
                }
            }
        }
    }

    /// A new key clears `.invalidKey` and the wait, and makes every Linear lookup due.
    private func changeKey(_ k: String) {
        cache.removeAll(service: .linear)
        save()
        (linear.failures, linear.retryAt, retry[.linear]) = (0, .distantPast, nil)
        (teamKeys, workspace) = ([], nil)
        use(k)
    }

    private func use(_ k: String) {
        key = k
        hasLinearKey = !k.isEmpty
        linearStatus = .noKey
        changed()
        fetch(listed, hover: false)
    }
}

/// The due Linear lookups that a session folder with a grant for the destination asks for, at most 20 per request.
func linearBatch(_ due: [Lookup], folders: [Lookup: [String]], policy: OrganizationPolicy,
                 destination: OrganizationDestination) -> [Lookup] {
    Array(due.filter { lookup in
        (folders[lookup] ?? []).contains { folder in
            policy.allowsTransmission(sessionDirectory: folder, gitRemote: .unknown,
                                      service: destination.service, destinationIdentity: destination.identity)
        }
    }.prefix(20))
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
    var repository: GitHubRepository?
}

private enum PromptFile: Hashable, Sendable {
    case claude(cwd: String, id: String)
    case codex(String)
}

private struct PromptKey: Hashable, Sendable {
    let id: String
    let cwd: String
    let file: PromptFile
}

struct CommandOutput: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
}

/// File reads and writes of the store, in order, off the main thread.
private let ticketIO = DispatchQueue(label: "com.henryqw.rounds.tickets")
/// Keychain reads and writes, in order, apart from `ticketIO`, so a Keychain prompt stops no scan or save.
let keychainIO = DispatchQueue(label: "com.henryqw.rounds.keychain")
private let ticketCacheURL = URL.applicationSupportDirectory.appending(path: "Rounds/tickets.json")

/// The branches of each cwd's repository (the first folder up that has `.git`), and the refs of each prompt file's
/// first 64 KB. A file without a prompt in it is read again later, unless its head is full.
private func readLookups(cwds: [String], prompts: [PromptKey], projectsRoot: URL) -> (folders: [String: GitFolder], refs: [PromptKey: [TicketRef]]) {
    var folders: [String: GitFolder] = [:], refs: [PromptKey: [TicketRef]] = [:]
    for cwd in cwds {
        // An empty cwd (a herdr agent without one) would resolve against the app's own folder.
        let git = cwd.hasPrefix("/") ? gitFolder(above: cwd).map(gitBranch) : nil
        folders[cwd] = GitFolder(branch: git?.branch, defaultBranch: git?.defaultBranch, repository: git?.repository)
    }
    for key in prompts {
        let file = key.file
        let url: URL? = switch file {
        case .claude(let cwd, let session): transcriptURL(cwd: cwd, cliSessionId: session, projectsRoot: projectsRoot, allowFallback: false)
        case .codex(let path): URL(fileURLWithPath: path)
        }
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { continue }
        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        try? handle.close()
        let prompt = if case .claude = file { firstUserPrompt(claudeTranscript: data) } else { firstUserPrompt(codexRollout: data) }
        if let prompt { refs[key] = ticketRefs(inPrompt: prompt) } else if data.count == 65_536 { refs[key] = [] }
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

/// Exit status, stdout and stderr of a command; nil when it does not start. A command that runs past `timeout` is stopped
/// (`timedOut`; a crash is not a timeout). A child of the command can keep a pipe open after the command ends, so the
/// pipes get at most 2 s after the exit; output not read by then is empty.
func runCommand(_ path: String, _ arguments: [String], timeout: TimeInterval = 30) -> CommandOutput? {
    let process = Process(), out = Pipe(), err = Pipe()
    (process.executableURL, process.arguments, process.standardOutput, process.standardError) = (URL(fileURLWithPath: path), arguments, out, err)
    guard (try? process.run()) != nil else { return nil }
    nonisolated(unsafe) var stopped = false, stdout = Data(), stderr = Data()
    let stop = DispatchWorkItem {
        guard process.isRunning else { return }
        stopped = true
        process.terminate()
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: stop)
    // Each pipe on its own thread, so a full pipe cannot block the command.
    let pipes = DispatchGroup()
    DispatchQueue.global(qos: .utility).async(group: pipes) { stdout = out.fileHandleForReading.readDataToEndOfFile() }
    DispatchQueue.global(qos: .utility).async(group: pipes) { stderr = err.fileHandleForReading.readDataToEndOfFile() }
    process.waitUntilExit()
    stop.cancel()
    let read = pipes.wait(timeout: .now() + 2) == .success
    return CommandOutput(status: process.terminationStatus, stdout: read ? stdout : Data(), stderr: read ? stderr : Data(), timedOut: stopped)
}
