import Darwin
import Foundation
import Testing
@testable import RoundsCore

private struct HarnessFixture {
    let folder: URL
    let script: URL

    init(_ behavior: String = "") throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "rounds-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        script = folder.appending(path: "host.sh")
        try """
        #!/bin/sh
        folder="$1"
        echo $$ > "$folder/fixture-pid"
        \(behavior)
        while IFS= read -r line; do
            id=${line#*'"id":"'}
            id=${id%%'"'*}
            case "$line" in
                *shutdown*) echo shutdown > "$folder/stopped"; printf '{"version":1,"id":"%s","command":"shutdown","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)"}\\n' "$id"; exit 0 ;;
            esac
            printf '{"version":1,"id":"%s","command":"health","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id"
        done
        """.write(to: script, atomically: true, encoding: .utf8)
    }

    func host(requestWait: Duration = .seconds(2), exitWait: Duration = .milliseconds(150)) -> NodeHarnessHost {
        NodeHarnessHost(executable: URL(fileURLWithPath: "/bin/sh"), script: script, dataFolder: folder,
                        requestWait: requestWait, exitWait: exitWait)
    }

    func record() throws -> HostProcessRecord {
        try JSONDecoder().decode(HostProcessRecord.self, from: Data(contentsOf: folder.appending(path: "host-process.json")))
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}

private func withHarness(_ fixture: HarnessFixture, requestWait: Duration = .seconds(2),
                         exitWait: Duration = .milliseconds(150),
                         _ body: (NodeHarnessHost) async throws -> Void) async throws {
    let host = fixture.host(requestWait: requestWait, exitWait: exitWait)
    do {
        try await body(host)
        try await host.stop()
        fixture.remove()
    } catch {
        try? await host.stop()
        fixture.remove()
        throw error
    }
}

@Test func harnessHostStartsOnceAndStopsCooperatively() async throws {
    let fixture = try HarnessFixture()
    try await withHarness(fixture) { host in
        let health = try await host.start(), first = try fixture.record()
        #expect(health.scheduling == "paused")
        #expect(health.commit == NodeHarnessHost.sourceCommit)
        _ = try await host.start()
        #expect(try fixture.record().pid == first.pid)
        #expect(try await host.health().scheduling == "paused")
        try await host.stop()
        #expect(try String(contentsOf: fixture.folder.appending(path: "stopped"), encoding: .utf8) == "shutdown\n")
        #expect(HostProcessRecord.info(first.pid) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appending(path: "host-process.json").path))
        try await host.stop()
    }
}

@Test func harnessBouncerReadsEventsBetweenResponses() async throws {
    let fixture = try HarnessFixture("""
        while IFS= read -r line; do
            id=${line#*'"id":"'}
            id=${id%%'"'*}
            command=${line#*'"command":"'}
            command=${command%%'"'*}
            case "$command" in
                bouncerOpen)
                    printf '%s\\n' '{"version":1,"event":"started","model":"magpie/team/model"}' \\
                        '{"version":1,"event":"model","model":"magpie/team/model"}'
                    ;;
                bouncerSend)
                    [ "${#line}" -gt 32000 ] || exit 1
                    printf '%s\\n' '{"version":1,"event":"reply","itemID":"r"}' \\
                        '{"version":1,"event":"replying","replying":true}'
                    ;;
            esac
            printf '{"version":1,"id":"%s","command":"%s","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id" "$command"
            case "$command" in
                bouncerSend)
                    sleep 0.05
                    printf '%s\\n' '{"version":1,"event":"delta","itemID":"r","text":"Streamed"}'
                    ;;
                shutdown) exit 0 ;;
            esac
        done
        exit 0
        """)
    try await withHarness(fixture) { host in
        _ = try await host.start()
        let bouncer = HarnessBouncer(host: host)
        try await bouncer.start()
        let monitor = Task { try await host.monitor(interval: .seconds(10)) }
        defer { monitor.cancel() }
        try await bouncer.send(String(repeating: "a", count: 40_000))
        let events = await withTaskGroup(of: [BouncerEvent].self) { group in
            group.addTask {
                var events: [BouncerEvent] = []
                for await event in bouncer.events {
                    events.append(event)
                    if case .textDelta = event { break }
                }
                return events
            }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return [] }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
        #expect(events == [.started(model: "magpie/team/model", selection: nil), .availableModel("magpie/team/model"),
                           .item(.reply(id: "r", text: "", toolSteps: 0)), .replying(true), .textDelta(id: "r", text: "Streamed")])
    }
}

@Test(arguments: ["lost reply", "unconfirmed error", "rejected"], ["send", "answer", "dismiss"])
func harnessBouncerDistinguishesUnconfirmedSendsFromRejections(outcome: String, operation: String) async throws {
    let fixture = try HarnessFixture("""
        while IFS= read -r line; do
            id=${line#*'"id":"'}
            id=${id%%'"'*}
            command=${line#*'"command":"'}
            command=${command%%'"'*}
            case "$command" in
                bouncerSend|bouncerAnswer)
                    printf '%s\\n' "$line" >> "$folder/received"
                    case "\(outcome)" in
                        'lost reply') exit 0 ;;
                        'unconfirmed error') failure='"error":"Rounds could not complete the Bouncer command."' ;;
                        rejected) failure='"rejected":true,"error":"Choose a Magpie model first."' ;;
                    esac
                    printf '{"version":1,"id":"%s","command":"%s","ok":false,"commit":"\(NodeHarnessHost.sourceCommit)",%s}\\n' "$id" "$command" "$failure"
                    continue
                    ;;
            esac
            printf '{"version":1,"id":"%s","command":"%s","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id" "$command"
            if [ "$command" = shutdown ]; then exit 0; fi
        done
        """)
    try await withHarness(fixture, exitWait: .seconds(2)) { host in
        _ = try await host.start()
        let bouncer = HarnessBouncer(host: host)
        try await bouncer.start()
        let text = "  Keep this text.\n"
        do {
            if operation == "send" { try await bouncer.send(text) }
            else { try await bouncer.answer("question", operation == "answer" ? .text(text) : .dismissed) }
            Issue.record("The fixture returned no successful send reply.")
        } catch {
            #expect((error is BouncerSendUnconfirmed) == (outcome != "rejected"))
            if outcome == "rejected" {
                #expect(error.localizedDescription == "Choose a Magpie model first.")
                #expect(try await host.health().scheduling == "paused")
            } else {
                let subject = operation == "send" ? "message was sent" : "answer was saved"
                #expect(error.localizedDescription.hasPrefix("Rounds could not confirm that the \(subject)."))
                #expect(!FileManager.default.fileExists(atPath: fixture.folder.appending(path: "host-process.json").path),
                        "Send error: \(error.localizedDescription)")
            }
        }
        let data = try Data(contentsOf: fixture.folder.appending(path: "received"))
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if operation == "send" { #expect(request["text"] as? String == text) }
        else {
            let answer = try #require(request["answer"] as? [String: Any])
            #expect(answer["kind"] as? String == (operation == "answer" ? "text" : "dismissed"))
            if operation == "answer" { #expect(answer["text"] as? String == text) }
        }
    }
}

@Test func harnessBouncerRestartsAfterAnUnansweredOpen() async throws {
    let fixture = try HarnessFixture("""
        while IFS= read -r line; do
            id=${line#*'"id":"'}
            id=${id%%'"'*}
            command=${line#*'"command":"'}
            command=${command%%'"'*}
            if [ "$command" = bouncerOpen ] && [ ! -f "$folder/opened" ]; then
                : > "$folder/opened"
                continue
            fi
            printf '{"version":1,"id":"%s","command":"%s","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id" "$command"
            if [ "$command" = shutdown ]; then exit 0; fi
        done
        exit 0
        """)
    try await withHarness(fixture) { host in
        _ = try await host.start()
        let first = try fixture.record()
        let bouncer = HarnessBouncer(host: host)
        await #expect(throws: HarnessHostError.self) { try await bouncer.start() }
        #expect(HostProcessRecord.info(first.pid) == nil)
        _ = try await host.start()
        #expect(try fixture.record().pid != first.pid)
        try await bouncer.start()
    }
}

@Test func cancelledBouncerOpenCleansTheHostBeforeReturning() async throws {
    let fixture = try HarnessFixture("""
        while IFS= read -r line; do
            id=${line#*'"id":"'}
            id=${id%%'"'*}
            command=${line#*'"command":"'}
            command=${command%%'"'*}
            if [ "$command" = bouncerOpen ]; then
                : > "$folder/opening"
                continue
            fi
            printf '{"version":1,"id":"%s","command":"%s","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id" "$command"
        done
        """)
    try await withHarness(fixture, requestWait: .seconds(10), exitWait: .seconds(2)) { host in
        _ = try await host.start()
        let record = try fixture.record()
        let opening = Task { try await HarnessBouncer(host: host).start() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: fixture.folder.appending(path: "opening").path),
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "opening").path))
        let cancelledAt = ContinuousClock.now
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(cancelledAt.duration(to: .now) < .seconds(3))
        #expect(try record.members().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appending(path: "host-process.json").path))
        try await host.stop()
    }
}

@Test func harnessHostRestartsAnExitedChildOnTheFirstAttempt() async throws {
    let fixture = try HarnessFixture()
    try await withHarness(fixture) { host in
        _ = try await host.start()
        let first = try fixture.record()
        kill(first.pid, SIGKILL)
        let deadline = ContinuousClock.now + .seconds(2)
        while let info = HostProcessRecord.info(first.pid), info.pbi_status != SZOMB, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await host.start().ok)
        #expect(try fixture.record().pid != first.pid)
    }
}

@Test func harnessHostRecoversFromAClosedInputPipe() async throws {
    let fixture = try HarnessFixture("""
        IFS= read -r line
        id=${line#*'"id":"'}
        id=${id%%'"'*}
        exec 0<&-
        printf '{"version":1,"id":"%s","command":"health","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id"
        /bin/sleep 1000
        exit 0
        """)
    try await withHarness(fixture) { host in
        _ = try await host.start()
        let first = try fixture.record()
        #expect(try await host.start().ok)
        #expect(try fixture.record().pid != first.pid)
        #expect(try first.members().isEmpty)
        await #expect(throws: (any Error).self) { try await host.stop() }
    }
}

@Test func harnessHostReportsUnexpectedExit() async throws {
    let fixture = try HarnessFixture()
    try await withHarness(fixture) { host in
        _ = try await host.start()
        let record = try fixture.record()
        let monitor = Task { try await host.monitor(interval: .milliseconds(20)) }
        kill(record.pid, SIGKILL)
        await #expect(throws: (any Error).self) { try await monitor.value }
        #expect(try record.members().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appending(path: "host-process.json").path))
        await host.acknowledgeMonitorFailure()
        try await host.stop()
    }
}

@Test func harnessMonitorCancellationKeepsShutdownCooperative() async throws {
    let fixture = try HarnessFixture("""
        count=0
        while IFS= read -r line; do
            id=${line#*'"id":"'}
            id=${id%%'"'*}
            case "$line" in
                *shutdown*) printf '{"version":1,"id":"%s","command":"shutdown","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)"}\\n' "$id"; exit 0 ;;
            esac
            count=$((count + 1))
            if [ "$count" -gt 1 ]; then
                echo checking > "$folder/checking"
                /bin/sleep 0.2
            fi
            printf '{"version":1,"id":"%s","command":"health","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id"
        done
        """)
    try await withHarness(fixture) { host in
        _ = try await host.start()
        let monitor = Task { try await host.monitor(interval: .milliseconds(20)) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: fixture.folder.appending(path: "checking").path),
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "checking").path))
        monitor.cancel()
        await #expect(throws: CancellationError.self) { try await monitor.value }
        try await host.stop()
    }
}

@Test func harnessMonitorRetainsFailureDuringCancellation() async throws {
    let fixture = try HarnessFixture("""
        count=0
        while IFS= read -r line; do
            id=${line#*'"id":"'}
            id=${id%%'"'*}
            count=$((count + 1))
            if [ "$count" -gt 1 ]; then
                echo checking > "$folder/checking"
                /bin/sleep 0.1
                exit 1
            fi
            printf '{"version":1,"id":"%s","command":"health","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id"
        done
        """)
    try await withHarness(fixture) { host in
        _ = try await host.start()
        let monitor = Task { try await host.monitor(interval: .milliseconds(20)) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: fixture.folder.appending(path: "checking").path),
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "checking").path))
        monitor.cancel()
        await #expect(throws: (any Error).self) { try await monitor.value }
        do {
            try await host.stop()
            Issue.record("Health failure was lost")
        } catch {
            #expect(error is HarnessMonitorFailure)
            #expect(error.localizedDescription.contains("health check failed"))
        }
    }
}

@Test func harnessHostRejectsInvalidShutdownReply() async throws {
    let fixture = try HarnessFixture("""
        while IFS= read -r line; do
            id=${line#*'"id":"'}
            id=${id%%'"'*}
            case "$line" in
                *shutdown*) printf '{"version":1,"id":"wrong","command":"shutdown","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)"}\\n'; exit 0 ;;
            esac
            printf '{"version":1,"id":"%s","command":"health","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id"
        done
        """)
    try await withHarness(fixture) { host in
        _ = try await host.start()
        do {
            try await host.stop()
            Issue.record("Invalid shutdown reply was accepted")
        } catch {
            #expect(error.localizedDescription.contains("Invalid Harness shutdown response"))
        }
    }
}

@Test(arguments: [false, true])
func harnessHostReportsFailedClose(afterResponse: Bool) async throws {
    let fixture = try HarnessFixture("""
        while IFS= read -r line; do
            id=${line#*'"id":"'}
            id=${id%%'"'*}
            case "$line" in
                *shutdown*)
                    if \(afterResponse ? "true" : "false"); then
                        printf '{"version":1,"id":"%s","command":"shutdown","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)"}\\n' "$id"
                    fi
                    exit 1 ;;
            esac
            printf '{"version":1,"id":"%s","command":"health","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id"
        done
        """)
    try await withHarness(fixture) { host in
        _ = try await host.start()
        let record = try fixture.record()
        do {
            try await host.stop()
            Issue.record("Failed close was accepted")
        } catch {
            #expect(error.localizedDescription.contains("status 1"))
        }
        #expect(try record.members().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appending(path: "host-process.json").path))
    }
}

@Test func harnessHostClearsAnAbsentProcessRecord() async throws {
    let fixture = try HarnessFixture()
    try await withHarness(fixture) { host in
        _ = try await host.start()
        let first = try fixture.record()
        try FileManager.default.removeItem(at: fixture.folder.appending(path: "host-process.json"))
        try await host.stop()
        #expect(HostProcessRecord.info(first.pid) == nil)
        #expect(try await host.start().ok)
        #expect(try fixture.record().pid != first.pid)
    }
}

@Test func harnessHostRejectsASecondFolderOwner() async throws {
    let fixture = try HarnessFixture()
    try await withHarness(fixture) { first in
        _ = try await first.start()
        let second = fixture.host()
        await #expect(throws: (any Error).self) { try await second.start() }
        try await second.stop()
        #expect(try await first.health().ok)
    }
}

@Test(arguments: ["exit 7", "printf 'invalid\\n'; exit 0", "while :; do /bin/sleep 1; done"])
func harnessHostCleansFailedStarts(behavior: String) async throws {
    let fixture = try HarnessFixture(behavior)
    try await withHarness(fixture, requestWait: .milliseconds(100)) { host in
        await #expect(throws: (any Error).self) { try await host.start() }
        let pid = try Int32(String(contentsOf: fixture.folder.appending(path: "fixture-pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))!
        #expect(HostProcessRecord.info(pid) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appending(path: "host-process.json").path))
    }
}

@Test func harnessHostRejectsWrongHealthIdentity() async throws {
    let fixture = try HarnessFixture("""
        while IFS= read -r line; do
            printf '{"version":1,"id":"wrong","command":"health","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n'
        done
        exit 0
        """)
    try await withHarness(fixture) { host in
        await #expect(throws: (any Error).self) { try await host.start() }
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appending(path: "host-process.json").path))
    }
}

private let stubborn = """
    trap '' TERM
    /bin/sleep 1000 &
    echo $! > "$folder/fixture-child"
    while IFS= read -r line; do
        id=${line#*'"id":"'}
        id=${id%%'"'*}
        case "$line" in
            *health*) printf '{"version":1,"id":"%s","command":"health","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id" ;;
        esac
    done
    while :; do /bin/sleep 1; done
    """

@Test func harnessHostKillsAGroupThatIgnoresTermination() async throws {
    let fixture = try HarnessFixture(stubborn)
    try await withHarness(fixture) { host in
        _ = try await host.start()
        let record = try fixture.record()
        let child = try Int32(String(contentsOf: fixture.folder.appending(path: "fixture-child"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))!
        await #expect(throws: (any Error).self) { try await host.stop() }
        #expect(HostProcessRecord.info(record.pid) == nil)
        #expect(HostProcessRecord.info(child).map { $0.pbi_status == SZOMB } ?? true)
        #expect(try record.members().isEmpty)
    }
}

@Test(arguments: [false, true])
func harnessHostStopsAChildFirstSeenDuringShutdown(recordWriteFails: Bool) async throws {
    let fixture = try HarnessFixture("""
        trap 'exit 0' TERM
        while IFS= read -r line; do
            id=${line#*'"id":"'}
            id=${id%%'"'*}
            case "$line" in
                *shutdown*)
                    /bin/sh -c 'trap "" TERM; exec /bin/sleep 1000' &
                    echo $! > "$folder/fixture-child"
                    wait "$!"
                    exit 0
                    ;;
            esac
            printf '{"version":1,"id":"%s","command":"health","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id"
        done
        """)
    try await withHarness(fixture) { host in
        _ = try await host.start()
        let record = try fixture.record()
        #expect(record.descendants.isEmpty)
        let recordURL = fixture.folder.appending(path: "host-process.json")
        if recordWriteFails {
            try FileManager.default.removeItem(at: recordURL)
            try FileManager.default.createDirectory(at: recordURL, withIntermediateDirectories: false)
            try Data([1]).write(to: recordURL.appending(path: "fixture"))
        }
        do {
            try await host.stop()
            Issue.record("The host did not report the failed shutdown reply.")
        } catch {
            if recordWriteFails { #expect(error.localizedDescription.contains("Cannot save the Harness process record")) }
        }
        let text = try String(contentsOf: fixture.folder.appending(path: "fixture-child"), encoding: .utf8)
        let child = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer {
            if let info = HostProcessRecord.info(child), info.pbi_pgid == record.pid { kill(child, SIGKILL) }
        }
        #expect(HostProcessRecord.info(record.pid) == nil)
        #expect(HostProcessRecord.info(child).map { $0.pbi_status == SZOMB } ?? true)
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appending(path: "host-process.json").path))
    }
}

@Test func harnessHostCleansLeftoverGroupBeforeStart() async throws {
    let fixture = try HarnessFixture(stubborn)
    defer { fixture.remove() }
    let original = fixture.host()
    _ = try await original.start()
    let record = try fixture.record()
    // A copied record exercises recovery while the original actor cannot help with cleanup.
    kill(record.pid, SIGKILL)
    let next = try HarnessFixture()
    defer { next.remove() }
    try JSONEncoder().encode(record).write(to: next.folder.appending(path: "host-process.json"))
    let replacement = next.host()
    do {
        _ = try await replacement.start()
        #expect(try record.members().isEmpty)
        #expect(try next.record().pid != record.pid)
        try await replacement.stop()
        await #expect(throws: (any Error).self) { try await original.stop() }
    } catch {
        try? await replacement.stop()
        try? await original.stop()
        throw error
    }
}

@Test(arguments: [false, true])
func harnessHostRechecksARecordedChildOutsideTheGroup(reusedPID: Bool) async throws {
    let fixture = try HarnessFixture("""
        /usr/bin/perl -MPOSIX -e '
            my $folder = shift;
            alarm 35;
            select undef, undef, undef, 0.02 until -e "$folder/detach";
            POSIX::setsid() >= 0 or die "setsid: $!";
            sleep 30;
        ' "$folder" </dev/null >/dev/null &
        """)
    let next = try HarnessFixture()
    defer { fixture.remove(); next.remove() }
    let original = fixture.host(), replacement = next.host()
    _ = try await original.start()
    let saved = try fixture.record()
    let child = try #require(saved.descendants.first)
    func sameChild() -> proc_bsdinfo? {
        guard let info = HostProcessRecord.info(child.pid), info.pbi_start_tvsec == child.seconds,
              info.pbi_start_tvusec == child.microseconds, info.pbi_status != SZOMB else { return nil }
        return info
    }
    do {
        try Data().write(to: fixture.folder.appending(path: "detach"))
        let deadline = ContinuousClock.now + .seconds(2)
        while sameChild()?.pbi_pgid == UInt32(saved.pid), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(sameChild()?.pbi_pgid == UInt32(child.pid))
        kill(saved.pid, SIGKILL)
        var leftover = saved
        if reusedPID {
            leftover.descendants = [HostProcessIdentity(pid: child.pid, seconds: child.seconds + 1,
                                                         microseconds: child.microseconds)]
        }
        let recordURL = next.folder.appending(path: "host-process.json")
        let data = try JSONEncoder().encode(leftover)
        try data.write(to: recordURL)
        if !reusedPID {
            do {
                _ = try await replacement.start()
                Issue.record("An escaped child should block Harness startup.")
            } catch {
                #expect(error.localizedDescription.contains("A recorded Harness child left its process group"))
            }
            #expect(try Data(contentsOf: recordURL) == data)
            #expect(!FileManager.default.fileExists(atPath: next.folder.appending(path: "fixture-pid").path))
            if sameChild() != nil { kill(child.pid, SIGKILL) }
            let deadline = ContinuousClock.now + .seconds(2)
            while sameChild() != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(sameChild() == nil)
        }
        #expect(try await replacement.start().scheduling == "paused")
        if reusedPID { #expect(sameChild() != nil) }
        try await replacement.stop()
    } catch {
        if sameChild() != nil { kill(child.pid, SIGKILL) }
        try? await replacement.stop()
        try? await original.stop()
        throw error
    }
    if sameChild() != nil { kill(child.pid, SIGKILL) }
    try? await original.stop()
}

@Test func harnessHostRefusesAReusedProcessIdentity() async throws {
    let fixture = try HarnessFixture()
    let info = try #require(HostProcessRecord.info(getpid()))
    let unrelated = HostProcessRecord(pid: getpid(), seconds: info.pbi_start_tvsec + 1,
                                      microseconds: info.pbi_start_tvusec, uid: getuid(), marker: UUID().uuidString)
    try JSONEncoder().encode(unrelated).write(to: fixture.folder.appending(path: "host-process.json"))
    var failed: NodeHarnessHost? = fixture.host()
    await #expect(throws: (any Error).self) { try await failed!.start() }
    #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "host-process.json").path))
    weak let released = failed
    failed = nil
    let deadline = ContinuousClock.now + .seconds(2)
    while released != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(released == nil)
    // A new actor must acquire the folder after the failed owner is released.
    try FileManager.default.removeItem(at: fixture.folder.appending(path: "host-process.json"))
    let replacement = fixture.host()
    _ = try await replacement.start()
    try await replacement.stop()
    fixture.remove()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ROUNDS_HARNESS_PAYLOAD"] != nil))
func harnessHostRealHarnessLiveCheck() async throws {
    let env = ProcessInfo.processInfo.environment
    let payload = URL(fileURLWithPath: try #require(env["ROUNDS_HARNESS_PAYLOAD"]))
    let scratch = URL(fileURLWithPath: try #require(env["ROUNDS_HARNESS_SCRATCH"]))
    let folder = scratch.appending(path: "live-\(UUID().uuidString)")
    let host = NodeHarnessHost(executable: payload.appending(path: "node"), script: payload.appending(path: "host.mjs"),
                               dataFolder: folder)
    do {
        let health = try await host.start()
        let record = try JSONDecoder().decode(HostProcessRecord.self, from: Data(contentsOf: folder.appending(path: "host-process.json")))
        #expect(health.scheduling == "paused")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "harness.sqlite").path))
        try await host.stop()
        #expect(HostProcessRecord.info(record.pid) == nil)
        #expect(try record.members().isEmpty)
        print("Live Harness: \(health.commit), paused, SQLite created, host reaped, group empty.")
        try FileManager.default.removeItem(at: folder)
    } catch {
        try? await host.stop()
        throw error
    }
}

@Test func rejectedBouncerDraftPreservesBothTexts() {
    let original = "  Original\n"
    let restored = bouncerRejectedDraft(original, current: "")
    #expect(restored.draft == original)
    #expect(restored.copy == nil)
    let edited = bouncerRejectedDraft(original, current: "New draft")
    #expect(edited.draft == "New draft")
    #expect(edited.copy == original)
}

@Test(arguments: [false, true])
func harnessHostHandlesPermissionFailureDuringGroupSignal(groupExits: Bool) async throws {
    let fixture = try HarnessFixture("""
        trap '' TERM
        while IFS= read -r line; do
            id=${line#*'"id":"'}
            id=${id%%'"'*}
            case "$line" in
                *health*) printf '{"version":1,"id":"%s","command":"health","ok":true,"commit":"\(NodeHarnessHost.sourceCommit)","scheduling":"paused"}\\n' "$id" ;;
            esac
        done
        while :; do :; done
        """)
    let host = NodeHarnessHost(executable: URL(fileURLWithPath: "/bin/sh"), script: fixture.script,
                               dataFolder: fixture.folder, requestWait: .seconds(2), exitWait: .milliseconds(200),
                               signalGroup: { group, _ in
        if groupExits { _ = Darwin.kill(group, SIGKILL) }
        return EPERM
    })
    let recordURL = fixture.folder.appending(path: "host-process.json")
    defer { fixture.remove() }
    _ = try await host.start()
    let record = try fixture.record()
    defer {
        if let members = try? record.members(), !members.isEmpty { _ = Darwin.kill(-record.pid, SIGKILL) }
    }
    do {
        try await host.stop()
        Issue.record("The unresponsive fixture should report its failed shutdown.")
    } catch {
        if groupExits {
            #expect(!error.localizedDescription.contains("Cannot signal Harness group"))
            #expect(try record.members().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: recordURL.path))
        } else {
            #expect(error.localizedDescription.contains("Cannot signal Harness group"))
            #expect(FileManager.default.fileExists(atPath: recordURL.path))
            #expect(try fixture.record().pid == record.pid)
            #expect(try !record.members().isEmpty)
            // The recorded group was verified above and belongs to this fixture.
            _ = Darwin.kill(-record.pid, SIGKILL)
            try? await host.stop()
            #expect(try record.members().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: recordURL.path))
        }
    }
}
