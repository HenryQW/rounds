import Foundation
import Testing
@testable import RoundsCore

private func json(_ s: String) -> Data { Data(s.utf8) }
private let issueJSON = #"{"identifier":"BBQ-12","title":"Fix login","url":"https://linear.app/acme/issue/BBQ-12/fix-login","state":{"name":"In Progress","type":"started"},"assignee":{"name":"Ada"},"updatedAt":"2026-11-04T10:00:00.000Z","archivedAt":null}"#
private let branch = Lookup.branch("ada/bbq-12-fix-login")

@Test func linearRequestPutsValuesInVariablesNotTheQuery() throws {
    let url = URL(string: "https://github.com/o/r/pull/5")!
    let (body, aliases) = linearRequest([branch, .pr(url), .ref(.linearID("BBQ-1")), .ref(.github(owner: "o", repo: "r", number: 1)), .ref(.linearURL(workspace: "acme", id: "BBQ-2")), .ref(.linearID("NOPE"))])
    let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let query = try #require(obj["query"] as? String)
    let vars = try #require(obj["variables"] as? [String: Any])
    #expect(vars["l0"] as? String == "ada/bbq-12-fix-login" && vars["l1"] as? String == url.absoluteString)
    let or = try #require((vars["l2"] as? [String: Any])?["or"] as? [[String: Any]])
    #expect(or.count == 2 && (or[0]["team"] as? [String: [String: String]])?["key"]?["eq"] == "BBQ" && (or[1]["number"] as? [String: Int])?["eq"] == 2)
    #expect(!query.contains("ada/bbq") && !query.contains("github.com") && !query.contains("BBQ"))
    #expect(query.contains("l0: issueVcsBranchSearch(branchName: $l0)") && query.contains("l1: attachmentsForURL(url: $l1)"))
    #expect(query.contains("l2: issues(filter: $l2, first: 50, includeArchived: true)") && query.contains("$l2: IssueFilter") && query.contains("organization { urlKey }"))
    #expect(aliases == ["l0": [branch], "l1": [.pr(url)], "l2": [.ref(.linearID("BBQ-1")), .ref(.linearURL(workspace: "acme", id: "BBQ-2"))]])
}

@Test func decodesABranchHit() throws {
    let data = json(#"{"data":{"l0":\#(issueJSON),"organization":{"urlKey":"acme"}}}"#)
    let t = try decodeLinear(data, aliases: ["l0": [branch]])[branch]
    #expect(t?.count == 1)
    #expect(t?[0].identifier == "BBQ-12" && t?[0].stateType == "started" && t?[0].person == "Ada" && t?[0].archived == false)
    #expect(t?[0].updatedAt == Date(timeIntervalSince1970: 1_793_786_400))
}

@Test func decodesANullBranchAsNoTicket() throws {
    let data = json(#"{"data":{"l0":null,"organization":{"urlKey":"acme"}}}"#)
    #expect(try decodeLinear(data, aliases: ["l0": [branch]]) == [branch: []])
}

@Test func decodesPullRequestAttachments() throws {
    let pr = Lookup.pr(URL(string: "https://github.com/o/r/pull/5")!)
    let data = json(#"{"data":{"l0":{"nodes":[{"issue":\#(issueJSON)},{"issue":null}]},"organization":{"urlKey":"acme"}}}"#)
    #expect(try decodeLinear(data, aliases: ["l0": [pr]])[pr]?.map(\.identifier) == ["BBQ-12"])
}

@Test func missingIdentifierDoesNotAffectFoundOnesOrABranch() throws {
    let found = Lookup.ref(.linearID("bbq-12")), gone = Lookup.ref(.linearID("BBQ-99"))
    let data = json(#"{"data":{"l0":\#(issueJSON),"l1":{"nodes":[\#(issueJSON)]},"organization":{"urlKey":"acme"}}}"#)
    let r = try decodeLinear(data, aliases: ["l0": [branch], "l1": [found, gone]])
    #expect(r[branch]?.count == 1 && r[found]?.first?.identifier == "BBQ-12" && r[gone] == [])
}

@Test func linearURLOtherWorkspaceAndNotFound() throws {
    let other = Lookup.ref(.linearURL(workspace: "zeta", id: "BBQ-12")), gone = Lookup.ref(.linearURL(workspace: "acme", id: "BBQ-99"))
    let data = json(#"{"data":{"l0":{"nodes":[\#(issueJSON)]},"organization":{"urlKey":"acme"}}}"#)
    let r = try decodeLinear(data, aliases: ["l0": [other, gone]])
    #expect(r[other] == [Ticket(url: URL(string: "https://linear.app/zeta/issue/BBQ-12")!, identifier: "BBQ-12", service: .linear, problem: .otherWorkspace)])
    #expect(r[gone] == [Ticket(url: URL(string: "https://linear.app/acme/issue/BBQ-99")!, identifier: "BBQ-99", service: .linear, problem: .notFound)])
}

@Test func linearWorkspaceCompareIgnoresCase() throws {
    let ref = Lookup.ref(.linearURL(workspace: "Acme", id: "BBQ-12"))
    let data = json(#"{"data":{"l0":{"nodes":[\#(issueJSON)]},"organization":{"urlKey":"acme"}}}"#)
    #expect(try decodeLinear(data, aliases: ["l0": [ref]])[ref]?.first?.problem == nil)
}

@Test func linearOtherErrorsThrow() {
    let data = json(#"{"errors":[{"message":"Rate limited","path":["l0"]}],"data":null}"#)
    #expect(throws: TicketDataError.server("Rate limited")) { try decodeLinear(data, aliases: ["l0": [branch]]) }
    #expect(throws: TicketDataError.invalidResponse) { try decodeLinear(json(#"{"data":{"l0":{"x":1},"organization":{"urlKey":"a"}}}"#), aliases: ["l0": [branch]]) }
}

@Test func githubQueryInlinesOnlySafeValues() {
    let pr = URL(string: "https://github.com/o/r/pull/5")!
    let (query, aliases) = githubQuery([.branch("x"), .ref(.linearID("A-1")), .pr(URL(string: "https://github.com/o/r/issues/5")!),
                                        .ref(.github(owner: "bad\"owner", repo: "r", number: 1)), .pr(pr), .ref(.github(owner: "o", repo: "r", number: 9))])
    #expect(aliases == ["g0": .pr(pr), "g1": .ref(.github(owner: "o", repo: "r", number: 9))])
    #expect(query.contains(#"g0: repository(owner: "o", name: "r") { pullRequest(number: 5)"#) && query.contains("g1: repository(owner: \"o\", name: \"r\") { issue(number: 9)"))
}

private func ghIssue(_ n: Int, _ state: String, _ reason: String) -> String {
    #"{"number":\#(n),"title":"T\#(n)","state":"\#(state)","stateReason":\#(reason),"url":"https://github.com/o/other/issues/\#(n)","updatedAt":"2026-11-04T10:00:00Z","assignees":{"nodes":[{"login":"ada"}]},"repository":{"nameWithOwner":"o/other"}}"#
}

@Test func decodesAPullRequestWithClosingIssues() throws {
    let pr = Lookup.pr(URL(string: "https://github.com/o/r/pull/42")!)
    let data = json(#"{"data":{"g0":{"pullRequest":{"number":42,"title":"Fix","state":"MERGED","url":"https://github.com/o/r/pull/42","updatedAt":"2026-11-04T10:00:00Z","author":{"login":"ada"},"closingIssuesReferences":{"nodes":[\#(ghIssue(7, "CLOSED", "\"COMPLETED\"")),\#(ghIssue(8, "OPEN", "null"))]}}}}}"#)
    let t = try #require(try decodeGitHub(data, aliases: ["g0": pr])[pr])
    #expect(t.map(\.identifier) == ["#42", "#7", "#8"])
    #expect(t[0].service == .pullRequest && t[0].stateType == "merged" && t[0].stateName == "Merged" && t[0].person == "ada" && t[0].repository == "o/r")
    #expect(t[1].stateType == "completed" && t[1].stateName == "Closed" && t[1].repository == "o/other" && t[2].stateType == "open")
}

@Test func decodesIssuesCompletedAndNotPlanned() throws {
    let a = Lookup.ref(.github(owner: "o", repo: "r", number: 1)), b = Lookup.ref(.github(owner: "o", repo: "r", number: 2))
    let data = json(#"{"data":{"g0":{"issue":\#(ghIssue(1, "CLOSED", "\"COMPLETED\""))},"g1":{"issue":\#(ghIssue(2, "CLOSED", "\"NOT_PLANNED\""))}}}"#)
    let r = try decodeGitHub(data, aliases: ["g0": a, "g1": b])
    #expect(r[a]?[0].stateType == "completed" && r[b]?[0].stateType == "not_planned" && r[b]?[0].person == "ada")
}

@Test func githubNotFoundKeepsTheOtherAliases() throws {
    let gone = Lookup.ref(.github(owner: "o", repo: "r", number: 3)), ok = Lookup.ref(.github(owner: "o", repo: "r", number: 1))
    let pr = Lookup.pr(URL(string: "https://github.com/o/r/pull/9")!)
    let data = json(#"{"data":{"g0":{"issue":null},"g1":{"issue":\#(ghIssue(1, "OPEN", "null"))},"g2":{"pullRequest":null}},"errors":[{"type":"NOT_FOUND","path":["g0","issue"],"message":"x"},{"type":"NOT_FOUND","path":["g2","pullRequest"],"message":"y"}]}"#)
    let r = try decodeGitHub(data, aliases: ["g0": gone, "g1": ok, "g2": pr])
    #expect(r[gone]?.first?.problem == .notFound && r[gone]?.first?.url.absoluteString == "https://github.com/o/r/issues/3")
    #expect(r[ok]?.first?.identifier == "#1" && r[pr] == [])
}

@Test func githubUnknownErrorThrows() {
    let data = json(#"{"data":null,"errors":[{"type":"FORBIDDEN","path":["g0"],"message":"SSO"}]}"#)
    #expect(throws: TicketDataError.server("SSO")) { try decodeGitHub(data, aliases: ["g0": .ref(.github(owner: "o", repo: "r", number: 1))]) }
}

@Test func dueFollowsTheCacheRules() {
    var cache = TicketCache()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let ticket = Ticket(url: URL(string: "https://x.test/1")!, identifier: "BBQ-1", service: .linear)
    #expect(cache.due(branch, service: .linear, now: t0, hover: false))
    cache.store([ticket], for: branch, service: .linear, at: t0)
    #expect(!cache.due(branch, service: .linear, now: t0 + 599, hover: false) && cache.due(branch, service: .linear, now: t0 + 600, hover: false))
    #expect(!cache.due(branch, service: .linear, now: t0 + 59, hover: true) && cache.due(branch, service: .linear, now: t0 + 60, hover: true))
    #expect(cache.due(branch, service: .github, now: t0, hover: false))
    cache.store([], for: branch, service: .github, at: t0)
    #expect(!cache.due(branch, service: .github, now: t0 + 86_399, hover: true) && cache.due(branch, service: .github, now: t0 + 86_400, hover: true))
}

@Test func cacheRoundTripsThroughJSON() throws {
    var cache = TicketCache()
    let ref = Lookup.ref(.linearURL(workspace: "acme", id: "BBQ-1"))
    let ticket = Ticket(url: URL(string: "https://x.test/1")!, identifier: "BBQ-1", service: .linear, title: "T", updatedAt: Date(timeIntervalSince1970: 5))
    cache.store([ticket], for: ref, service: .linear, at: Date(timeIntervalSince1970: 9))
    cache.store([], for: branch, service: .github, at: Date(timeIntervalSince1970: 9))
    let back = try JSONDecoder().decode(TicketCache.self, from: JSONEncoder().encode(cache))
    #expect(back.tickets(for: ref, service: .linear) == [ticket] && back.tickets(for: branch, service: .github) == [])
}

@Test func githubBodyWithoutDataThrows() {
    #expect(throws: TicketDataError.invalidResponse) {
        try decodeGitHub(json(#"{"message":"Bad credentials"}"#), aliases: ["g0": .ref(.github(owner: "o", repo: "r", number: 1))])
    }
}

@Test func githubQuerySkipsNumbersAboveInt32() {
    let big = Lookup.ref(.github(owner: "o", repo: "r", number: Int(Int32.max) + 1))
    let bigPR = Lookup.pr(URL(string: "https://github.com/o/r/pull/2147483648")!)
    let ok = Lookup.ref(.github(owner: "o", repo: "r", number: Int(Int32.max)))
    #expect(githubQuery([big, bigPR, ok]).aliases == ["g0": ok])
}

@Test func removeAllDropsOneServiceOnly() {
    var cache = TicketCache()
    let t0 = Date(timeIntervalSince1970: 9)
    cache.store([], for: branch, service: .linear, at: t0)
    cache.store([], for: branch, service: .github, at: t0)
    cache.removeAll(service: .linear)
    #expect(cache.tickets(for: branch, service: .linear) == nil && cache.tickets(for: branch, service: .github) == [])
}

private func ticket(_ url: String, _ id: String, _ service: TicketService = .linear) -> Ticket {
    Ticket(url: URL(string: url)!, identifier: id, service: service, title: "T")
}

@Test func rowTicketsKeepSpecOrderOnePerURLAndDropThePullRequest() {
    let pr = URL(string: "https://github.com/o/r/pull/5")!
    let bbq1 = ticket("https://linear.app/a/issue/BBQ-1", "BBQ-1"), bbq2 = ticket("https://linear.app/a/issue/BBQ-2", "BBQ-2")
    let issue = ticket("https://github.com/o/r/issues/9", "#9", .github)
    let stored: [Lookup: [Ticket]] = [.branch("b"): [bbq1], .pr(pr): [bbq1, bbq2], .ref(.linearID("BBQ-2")): [bbq2]]
    let github: [Lookup: [Ticket]] = [.pr(pr): [ticket(pr.absoluteString, "#5", .pullRequest), issue], .ref(.github(owner: "o", repo: "r", number: 9)): [issue]]
    let r = rowTickets(branch: "b", pullRequests: [pr], refs: [.linearID("BBQ-2"), .github(owner: "o", repo: "r", number: 9)], linearKey: true) {
        $1 == .linear ? stored[$0] : github[$0]
    }
    #expect(r.map(\.identifier) == ["BBQ-1", "BBQ-2", "#9"])
}

@Test func rowTicketsShowPlaceholdersUntilDataComes() {
    let refs: [TicketRef] = [.linearURL(workspace: "a", id: "BBQ-3"), .linearID("BBQ-4"), .github(owner: "o", repo: "r", number: 7)]
    let withKey = rowTickets(branch: nil, pullRequests: [], refs: refs, linearKey: true) { _, _ in nil }
    #expect(withKey.map(\.url.absoluteString) == ["https://linear.app/a/issue/BBQ-3", "https://github.com/o/r/issues/7"])
    #expect(withKey.map(\.identifier) == ["BBQ-3", "#7"] && withKey.allSatisfy { $0.problem == nil && $0.title == nil })
    #expect(withKey[1].repository == "o/r" && withKey[1].service == .github)
}

@Test func rowTicketsWithoutALinearKeyShowOnlyLinearURLs() {
    let bbq1 = ticket("https://linear.app/a/issue/BBQ-1", "BBQ-1")
    let r = rowTickets(branch: "b", pullRequests: [], refs: [.linearURL(workspace: "a", id: "BBQ-3"), .linearID("BBQ-1")], linearKey: false) { _, _ in [bbq1] }
    #expect(r.map(\.identifier) == ["BBQ-3"] && r[0].problem == .noKey)
}
