import Foundation
import Testing
import RoundsCore
@testable import Rounds

@Test
func sourceRefreshReplacesRowsAndTheirClassifierInputsTogether() throws {
    let now = Date()
    let thread = CodexThread(id: "thread", title: "Thread", cwd: "/project", branch: nil, updatedAt: now, rolloutPath: "")
    let turn = CodexTurn(kind: .started, at: now)
    let status = classifyCodex(thread, hook: nil, turn: turn, live: true)
    let row = SessionRow(thread: thread, status: status)
    var snapshot = SessionSnapshot([thread]) { (SessionRow(thread: $0, status: status), .codex($0, hook: nil, turn: turn, live: true)) }

    #expect(snapshot.rows == [row])
    let input = try #require(snapshot.input(for: row))
    #expect(input.explain().status == row.status)

    let completed = CodexTurn(kind: .completed, at: now)
    let refreshed = SessionSnapshot([row]) { ($0, .codex(thread, hook: nil, turn: completed, live: true)) }
    #expect(refreshed == snapshot)
    snapshot = refreshed
    let updated = try #require(snapshot.input(for: row))
    #expect(updated.explain().status == classifyCodex(thread, hook: nil, turn: completed, live: true))

    snapshot = SessionSnapshot([row]) { ($0, nil) }
    #expect(snapshot.rows == [row])
    #expect(snapshot.input(for: row) == nil)

    snapshot = SessionSnapshot()
    #expect(snapshot.rows.isEmpty)
    #expect(snapshot.input(for: row) == nil)
}
