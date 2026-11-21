import Darwin
import Foundation

public struct HarnessHostHealth: Decodable, Sendable {
    public let version: Int
    public let id: String
    public let command: String
    public let ok: Bool
    public let commit: String
    public let scheduling: String
}

public struct HarnessHostError: LocalizedError, Sendable {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

public struct HarnessMonitorFailure: LocalizedError, Sendable {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = "The Harness health check failed: \(message)" }
}

/// One paused Harness in a Node process group. No conversation or tool runs in slice 02a.
public actor NodeHarnessHost {
    public static let sourceCommit = "5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9"
    private let executable: URL, script: URL, dataFolder: URL
    private let requestWait: Duration, exitWait: Duration
    private var child: pid_t?
    private var exitStatus: Int32?
    private var monitorFailure: String?
    private var input: FileHandle?, output: FileHandle?
    private var lock: Int32 = -1
    private var record: HostProcessRecord?
    private var busy = false

    public init(executable: URL, script: URL, dataFolder: URL) {
        self.init(executable: executable, script: script, dataFolder: dataFolder,
                  requestWait: .seconds(10), exitWait: .seconds(2))
    }

    init(executable: URL, script: URL, dataFolder: URL, requestWait: Duration, exitWait: Duration) {
        (self.executable, self.script, self.dataFolder) = (executable, script, dataFolder)
        (self.requestWait, self.exitWait) = (requestWait, exitWait)
    }

    deinit {
        if lock >= 0 { _ = flock(lock, LOCK_UN); Darwin.close(lock) }
    }

    public func start() async throws -> HarnessHostHealth {
        try await enter()
        defer { busy = false }
        monitorFailure = nil
        reap()
        if child != nil {
            do { return try await checkedHealth() }
            catch is HostExited { /* checkedHealth has already completed verified cleanup. */ }
        }
        do {
            if record != nil { try await cleanup(graceful: false) }
            try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if lock == -1 { try acquireLock() }
            if let leftover = try readRecord() {
                record = leftover
                try await terminate(leftover, graceful: false)
                try clearRecord()
            }
            try spawn()
            return try await checkedHealth()
        } catch {
            let original = error
            // A failed cleanup keeps its ownership record and lock until stop is retried.
            try await cleanup(graceful: false)
            throw original
        }
    }

    public func health() async throws -> HarnessHostHealth {
        try await enter()
        defer { busy = false }
        return try await checkedHealth()
    }

    public func stop() async throws {
        try await enter()
        defer { busy = false }
        try await cleanup(graceful: true)
        if let failure = monitorFailure {
            monitorFailure = nil
            throw HarnessMonitorFailure(failure)
        }
    }

    /// Clears a health failure after the caller shows it to the user.
    public func acknowledgeMonitorFailure() { monitorFailure = nil }

    /// Checks the running host until it fails or the caller cancels the monitor.
    public func monitor(interval: Duration = .seconds(1)) async throws {
        while true {
            try await Task.sleep(for: interval)
            let check = Task.detached { try await self.health() }
            do { _ = try await check.value } catch {
                monitorFailure = error.localizedDescription
                throw error
            }
            try Task.checkCancellation()
        }
    }

    private func enter() async throws {
        while busy { try await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation()
        busy = true
    }

    private var recordURL: URL { dataFolder.appending(path: "host-process.json") }

    private func acquireLock() throws {
        let fd = open(dataFolder.appending(path: "host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HarnessHostError("Cannot open the Harness lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw HarnessHostError("Another host owns the Harness folder.")
        }
        lock = fd
    }

    private func readRecord() throws -> HostProcessRecord? {
        do { return try JSONDecoder().decode(HostProcessRecord.self, from: Data(contentsOf: recordURL)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    private func clearRecord() throws {
        do { try FileManager.default.removeItem(at: recordURL) }
        catch CocoaError.fileNoSuchFile { /* Verified termination also clears a record that was not persisted. */ }
        record = nil
    }

    private func spawn() throws {
        let stdin = Pipe(), stdout = Pipe()
        let errors = open(dataFolder.appending(path: "host.log").path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0o600)
        guard errors >= 0 else { throw HarnessHostError("Cannot open the Harness log.") }
        defer { close(errors) }
        var actions: posix_spawn_file_actions_t?
        var attrs: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attrs))
        defer { posix_spawnattr_destroy(&attrs) }
        try check(posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, STDIN_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, errors, STDERR_FILENO))
        try check(posix_spawnattr_setpgroup(&attrs, 0))
        try check(posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        let marker = UUID().uuidString
        let args = [executable.path, script.path, dataFolder.path, "ROUNDS_HARNESS_RUN_ID=\(marker)"].map { value in value.withCString { strdup($0) } } + [nil]
        let env = ["PATH=/usr/bin:/bin", "ROUNDS_HARNESS_RUN_ID=\(marker)"].map { value in value.withCString { strdup($0) } } + [nil]
        defer { for item in args + env { free(item) } }
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable.path, &actions, &attrs, args, env))
        child = pid
        exitStatus = nil
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        try stdin.fileHandleForReading.close()
        try stdout.fileHandleForWriting.close()
        try check(fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 ? 0 : errno)
        try check(fcntl(output!.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 ? 0 : errno)
        guard let info = HostProcessRecord.info(pid) else {
            // This PID is our unreaped child, so it cannot have been reused.
            kill(pid, SIGKILL)
            throw HarnessHostError("Cannot read the new Harness process identity.")
        }
        record = HostProcessRecord(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec,
                                   uid: getuid(), marker: marker)
        try JSONEncoder().encode(record).write(to: recordURL, options: [.atomic])
    }

    private func check(_ code: Int32) throws {
        guard code == 0 else { throw HarnessHostError("Harness process error: \(String(cString: strerror(code))).") }
    }

    private func write(_ command: String, id: String) throws {
        guard let input, child != nil else { throw HarnessHostError("The Harness host is not running.") }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "id": id, "command": command]) + Data([10])
        let count = data.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress, $0.count) }
        guard count == data.count else {
            if count < 0, errno == EPIPE { throw HostExited() }
            throw HarnessHostError("Cannot write the Harness request.")
        }
    }

    private func checkedHealth() async throws -> HarnessHostHealth {
        do {
            let id = UUID().uuidString
            try write("health", id: id)
            let response = try JSONDecoder().decode(HarnessHostHealth.self, from: await readLine())
            guard response.version == 1, response.id == id, response.command == "health", response.ok,
                  response.commit == Self.sourceCommit, response.scheduling == "paused" else {
                throw HarnessHostError("Invalid Harness health response.")
            }
            if var record {
                record.descendants = try await verifiedMembers(record).filter { $0 != record.pid }.map { pid in
                    guard let info = HostProcessRecord.info(pid) else { throw HarnessHostError("A Harness child changed during inspection.") }
                    return HostProcessIdentity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
                }
                try JSONEncoder().encode(record).write(to: recordURL, options: [.atomic])
                self.record = record
            }
            return response
        } catch {
            let original = error
            try await cleanup(graceful: false)
            throw original
        }
    }

    private func readLine(wait: Duration? = nil) async throws -> Data {
        guard let output else { throw HarnessHostError("The Harness output is closed.") }
        let deadline = ContinuousClock.now + (wait ?? requestWait)
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline {
            let count = read(output.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                result.append(contentsOf: bytes.prefix(count))
                if result.count > 65_536 { throw HarnessHostError("Harness response exceeds 65536 bytes.") }
                if let end = result.firstIndex(of: 10) {
                    guard end == result.count - 1 else { throw HarnessHostError("Unexpected Harness output.") }
                    return result.prefix(upTo: end)
                }
            } else if count == 0 {
                throw HostExited()
            } else if errno != EAGAIN && errno != EINTR {
                throw HarnessHostError("Cannot read the Harness response.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HarnessHostError("The Harness host did not answer in time.")
    }

    private func cleanup(graceful: Bool) async throws {
        var closeFailure: Error?
        let closeDeadline = ContinuousClock.now + exitWait
        if graceful, child != nil {
            do {
                let id = UUID().uuidString
                try write("shutdown", id: id)
                let response = try JSONDecoder().decode(ShutdownResponse.self, from: await readLine(wait: exitWait))
                guard response.version == 1, response.id == id, response.command == "shutdown", response.ok,
                      response.commit == Self.sourceCommit else {
                    throw HarnessHostError("Invalid Harness shutdown response.")
                }
            } catch { closeFailure = error }
        }
        try input?.close()
        input = nil
        if let record {
            try await terminate(record, graceful: graceful, gracefulWait: max(.zero, ContinuousClock.now.duration(to: closeDeadline)))
            try clearRecord()
        }
        reap()
        // spawn can fail before an ownership record exists.
        if let child {
            kill(child, SIGKILL)
            var status: Int32 = 0
            waitpid(child, &status, 0)
            exitStatus = status
            self.child = nil
        }
        try output?.close()
        output = nil
        if lock >= 0 {
            try check(flock(lock, LOCK_UN) == 0 ? 0 : errno)
            close(lock)
            lock = -1
        }
        if graceful, let status = exitStatus, status != 0 {
            exitStatus = nil
            let detail = status & 0x7f == 0 ? "status \(status >> 8)" : "signal \(status & 0x7f)"
            throw HarnessHostError("The Harness host exited with \(detail). Check host.log.")
        }
        exitStatus = nil
        if let closeFailure {
            throw HarnessHostError("The Harness close failed: \(closeFailure.localizedDescription)")
        }
    }

    private func terminate(_ record: HostProcessRecord, graceful: Bool, gracefulWait: Duration? = nil) async throws {
        if graceful, try await waitForGroup(record, for: gracefulWait ?? exitWait) { return }
        for signal in [SIGTERM, SIGKILL] {
            if try await verifiedMembers(record).isEmpty { reap(); return }
            // members() checks every live member immediately before each group signal.
            if kill(-record.pid, signal) != 0, errno != ESRCH { try check(errno) }
            if try await waitForGroup(record, for: exitWait) { return }
        }
        throw HarnessHostError("The Harness process group did not stop.")
    }

    private func waitForGroup(_ record: HostProcessRecord, for wait: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + wait
        repeat {
            reap()
            if try await verifiedMembers(record).isEmpty { return true }
            // Cleanup must finish even when its caller was cancelled.
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return false
    }

    private func verifiedMembers(_ record: HostProcessRecord) async throws -> [pid_t] {
        let deadline = ContinuousClock.now + exitWait
        while true {
            do { return try record.members() }
            catch is HostInspectionPending {
                guard ContinuousClock.now < deadline else { throw HarnessHostError("Cannot verify a Harness group member.") }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func reap() {
        guard let child else { return }
        var status: Int32 = 0
        if waitpid(child, &status, WNOHANG) == child {
            exitStatus = status
            self.child = nil
        }
    }
}

/// A record is a claim. Kernel birth identity, user, group and the leader argument marker must agree.
struct HostProcessRecord: Codable, Sendable {
    let pid: pid_t
    let seconds: UInt64
    let microseconds: UInt64
    let uid: uid_t
    let marker: String
    var descendants: [HostProcessIdentity] = []

    static func info(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    func members() throws -> [pid_t] {
        guard pid > 1, uid == getuid(), UUID(uuidString: marker) != nil else {
            throw HarnessHostError("Invalid Harness process record. Cleanup stopped.")
        }
        if let leader = Self.info(pid) {
            guard leader.pbi_start_tvsec == seconds, leader.pbi_start_tvusec == microseconds else {
                throw HarnessHostError("Harness process identity changed. Cleanup stopped.")
            }
        }
        let needed = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), nil, 0)
        guard needed >= 0 else { throw HarnessHostError("Cannot inspect the Harness process group.") }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 32)
        let size = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), &pids, size)
        guard count >= 0, count < size else { throw HarnessHostError("Cannot inspect the full Harness process group.") }
        var live: [pid_t: proc_bsdinfo] = [:]
        for member in pids.prefix(Int(count) / MemoryLayout<pid_t>.stride) where member > 0 {
            guard let info = Self.info(member) else {
                var state = kinfo_proc()
                var stateSize = MemoryLayout<kinfo_proc>.stride
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, member]
                if sysctl(&mib, 4, &state, &stateSize, nil, 0) == 0,
                   stateSize == 0 || state.kp_proc.p_stat == Int8(SZOMB) { continue }
                if kill(member, 0) != 0, errno == ESRCH { continue }
                throw HostInspectionPending()
            }
            if info.pbi_status == SZOMB { continue }
            guard info.pbi_uid == uid, info.pbi_pgid == pid else {
                throw HarnessHostError("Harness group ownership could not be proved. Cleanup stopped.")
            }
            live[member] = info
        }
        var verified: Set<pid_t> = []
        if live[pid] != nil {
            let args = arguments(pid)
            if args.isEmpty { throw HostInspectionPending() }
            guard args.contains("ROUNDS_HARNESS_RUN_ID=\(marker)") else {
                throw HarnessHostError("Harness run marker changed. Cleanup stopped.")
            }
            verified.insert(pid)
        }
        for known in descendants {
            if let info = live[known.pid] {
                guard known.seconds == info.pbi_start_tvsec, known.microseconds == info.pbi_start_tvusec else {
                    throw HarnessHostError("Harness child identity changed. Cleanup stopped.")
                }
                verified.insert(known.pid)
            }
        }
        // Only an observed parent chain can admit a new member. Recorded births also work after reparenting.
        var changed = true
        while changed {
            changed = false
            for (member, info) in live where !verified.contains(member) && verified.contains(Int32(info.pbi_ppid)) {
                verified.insert(member)
                changed = true
            }
        }
        guard verified.count == live.count else {
            throw HarnessHostError("Harness group ownership could not be proved. Cleanup stopped.")
        }
        return Array(verified)
    }

    private func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0, argc < size else { return [] }
        var index = 4
        func string() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        _ = string()
        while index < size, bytes[index] == 0 { index += 1 }
        return (0..<argc).compactMap { _ in string() }
    }
}

struct HostProcessIdentity: Codable, Sendable {
    let pid: pid_t
    let seconds: UInt64
    let microseconds: UInt64
}

private struct ShutdownResponse: Decodable {
    let version: Int
    let id, command: String
    let ok: Bool
    let commit: String
}

private struct HostInspectionPending: Error {}

private struct HostExited: LocalizedError {
    let errorDescription: String? = "The Harness host closed its output. Check host.log."
}
