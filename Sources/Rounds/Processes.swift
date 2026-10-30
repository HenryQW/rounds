import Darwin

/// The process table (same user and others; names and parents only).
enum Processes {
    static func all() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return Array(pids.prefix(max(count, 0)))
    }

    static func isRunning(_ name: String) -> Bool { all().contains { self.name(of: $0) == name } }

    static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// From `sysctl`, as `ps` reads it: `proc_pidinfo` cannot read root processes such as `login`, which sit
    /// between a terminal app and its shells.
    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// A pi process. pi runs in Node and sets `process.title`, so `proc_name` says node and `argv[0]` says pi.
    static func isPi(_ pid: pid_t) -> Bool {
        switch name(of: pid) {
        case "pi": true
        case "node": arguments(of: pid).args.first?.trimmingCharacters(in: .whitespaces) == "pi"
        default: false
        }
    }

    /// One environment variable of a process (same user).
    static func environment(of pid: pid_t, _ name: String) -> String? {
        let prefix = name + "="
        return arguments(of: pid).env.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// The arguments and environment of a process (same user), from `KERN_PROCARGS2`:
    /// argc, the executable path, padding, argc argument strings, then the environment strings.
    private static func arguments(of pid: pid_t) -> (args: [String], env: [String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return ([], []) }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > 4 else { return ([], []) }
        let argc = Int(bytes.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        func string() -> String? {
            guard i < size else { return nil }
            let start = i
            while i < size, bytes[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }
        _ = string()
        while i < size, bytes[i] == 0 { i += 1 }
        let args = (0..<argc).compactMap { _ in string() }
        var env: [String] = []
        while let entry = string(), !entry.isEmpty { env.append(entry) }
        return (args, env)
    }
}
