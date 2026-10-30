import Foundation
import Testing
@testable import RoundsCore

/// Every source Rounds names must ship its icon: adding a source without one fails here.
@Test(arguments: KnownAgent.allCases)
func knownAgentShipsAnIcon(agent: KnownAgent) {
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Resources").standardizedFileURL
    #expect(FileManager.default.fileExists(atPath: resources.appending(path: agent.iconFile).path), "missing Resources/\(agent.iconFile)")
}

@Test func rowsMapToKnownAgents() throws {
    let agents = try parseHerdrAgents(Data(#"{"id":"1","result":{"agents":[{"agent":"pi","pane_id":"a"},{"agent":"droid","pane_id":"b"}]}}"#.utf8))
    let status = SessionStatus(.finished, since: .distantPast)
    #expect(agents.map { SessionRow(agent: $0, status: status).knownAgent } == [.pi, nil])
}
