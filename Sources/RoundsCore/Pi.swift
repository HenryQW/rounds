import Foundation

/// One pi session (spec 2.7), from its session file `~/.pi/agent/sessions/--<cwd>--/<time>_<id>.jsonl`.
public struct PiSession: Sendable, Equatable {
    public let id: String
    /// The session file: the row id and the key herdr reports for the same session.
    public let path: String
    public let cwd: String
    /// The session file of the session this one was forked or cloned from.
    public let parentPath: String?
    /// The session name, else the first line of the first prompt, else the folder.
    public let title: String
    public let updatedAt: Date
    /// The last turn edge in the file: the state when no extension reports one.
    public let turn: PiTurn?

    public init(id: String, path: String, cwd: String, parentPath: String?, title: String, updatedAt: Date, turn: PiTurn?) {
        (self.id, self.path, self.cwd, self.parentPath, self.title, self.updatedAt, self.turn) = (id, path, cwd, parentPath, title, updatedAt, turn)
    }
}

/// What the last message in a session file says.
public struct PiTurn: Sendable, Equatable {
    public enum Kind: Sendable { case working, done, error, stopped }
    public let kind: Kind
    public let detail: String
    public let at: Date

    public init(kind: Kind, detail: String = "", at: Date) {
        (self.kind, self.detail, self.at) = (kind, detail, at)
    }
}

/// Decodes a session file, or its first and last bytes (see `readPiSession`): the header line, the first prompt, the
/// last session name and the last message. Only those lines are decoded; replies and the system prompt can be large.
public func parsePiSession(_ data: Data, path: String, updatedAt: Date) -> PiSession? {
    let marks = [#""role":"user""#, #""role":"assistant""#, #""role":"toolResult""#, #""type":"session_info""#].map { Array($0.utf8) }
    // Byte search with memchr and memmem, and few decodes: decoding every line takes most of a second on 300 files.
    var first: Range<Int>?, lines: [(range: Range<Int>, mark: Int)] = []
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var start = 0
        while start < raw.count {
            let end = memchr(base + start, Int32(UInt8(ascii: "\n")), raw.count - start).map { base.distance(to: $0) } ?? raw.count
            if first == nil { first = start..<end }
            else if let mark = marks.firstIndex(where: { memmem(base + start, min(240, end - start), $0, $0.count) != nil }) {
                lines.append((start..<end, mark))
            }
            start = end + 1
        }
    }
    func json(_ r: Range<Int>) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data.subdata(in: data.startIndex + r.lowerBound..<data.startIndex + r.upperBound))) as? [String: Any]
    }
    guard let header = first.flatMap(json), header["type"] as? String == "session", let id = header["id"] as? String,
          let cwd = header["cwd"] as? String else { return nil }
    let prompt = lines.lazy.filter { $0.mark == 0 }.compactMap { json($0.range)?["message"] as? [String: Any] }
        .first { $0["role"] as? String == "user" }.flatMap { firstLine(piText($0["content"])) }
    let name = lines.last { $0.mark == 3 }.flatMap { json($0.range)?["name"] as? String }.flatMap { $0.isEmpty ? nil : $0 }
    let turn = lines.last { $0.mark < 3 }.flatMap { line -> PiTurn? in
        guard let entry = json(line.range), let message = entry["message"] as? [String: Any],
              let at = (entry["timestamp"] as? String).flatMap(piDate) else { return nil }
        return switch (message["role"] as? String, message["stopReason"] as? String) {
        case ("assistant", "stop"): PiTurn(kind: .done, at: at)
        case ("assistant", "error"): PiTurn(kind: .error, detail: firstLine(message["errorMessage"] as? String ?? "") ?? "", at: at)
        case ("assistant", "aborted"): PiTurn(kind: .stopped, at: at)
        default: PiTurn(kind: .working, at: at)
        }
    }
    let title = name ?? prompt ?? URL(fileURLWithPath: cwd).lastPathComponent
    return PiSession(id: id, path: path, cwd: cwd, parentPath: header["parentSession"] as? String, title: title, updatedAt: updatedAt, turn: turn)
}

/// A whole small file; of a large one the first `head` bytes (the header and the first prompt) and the last `tail`
/// bytes, each cut to whole lines.
public func readPiSession(_ url: URL, head: Int = 262_144, tail: Int = 65_536) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
          let start = try? handle.read(upToCount: head) else { return nil }
    guard size > UInt64(head + tail) else { return start + ((try? handle.readToEnd()) ?? Data()) }
    let whole = start.lastIndex(of: UInt8(ascii: "\n")).map { start[...$0] } ?? Data()
    return whole + readTail(url, maxBytes: tail)
}

private func piText(_ content: Any?) -> String {
    if let text = content as? String { return text }
    return (content as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
}

private func firstLine(_ text: String) -> String? {
    let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    return line.isEmpty ? nil : String(line.prefix(120))
}

private func piDate(_ stamp: String) -> Date? {
    (try? Date(stamp, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))) ?? (try? Date(stamp, strategy: .iso8601))
}

/// The state the Rounds pi extension (`Resources/rounds-pi.ts`) last wrote for a session: one line,
/// `<unix ms>\t<state>\t<detail>\t<pid>\t<session file>`.
public struct PiState: Sendable, Equatable {
    public let at: Date
    /// pi's program status: working, blocked, done, error, stopped or idle.
    public let state: String
    public let detail: String
    public let pid: Int32
    public let sessionPath: String

    public init(at: Date, state: String, detail: String, pid: Int32, sessionPath: String) {
        (self.at, self.state, self.detail, self.pid, self.sessionPath) = (at, state, detail, pid, sessionPath)
    }

    public init?(_ contents: String) {
        let f = contents.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false)
        guard f.count == 5, let ms = Int64(f[0]), !f[1].isEmpty, let pid = Int32(f[3]), !f[4].isEmpty else { return nil }
        self.init(at: Date(timeIntervalSince1970: Double(ms) / 1000), state: String(f[1]), detail: String(f[2]), pid: pid, sessionPath: String(f[4]))
    }
}

/// `~/Library/Application Support/Rounds/pi`: the folder the pi extension writes to.
public func piStateDirectory() -> URL {
    hookStateDirectory().deletingLastPathComponent().appending(path: "pi")
}

/// A pi session's state: the newer of the extension's state and the last message in the session file. The extension
/// carries the waiting state and the process; the file covers sessions that ran without it. `live`: the session's pi
/// process runs (with no extension state: any pi process runs).
public func classifyPi(_ session: PiSession, state: PiState?, live: Bool) -> SessionStatus {
    func quiet(_ s: SessionState) -> SessionStatus { SessionStatus(s, since: session.updatedAt) }
    if let turn = session.turn, state.map({ turn.at > $0.at }) ?? true {
        switch turn.kind {
        case .working: return live ? SessionStatus(.working, since: turn.at) : quiet(.offline)
        case .done: return quiet(.finished)
        case .error: return SessionStatus(.failed, turn.detail, since: turn.at)
        case .stopped: return quiet(.stopped)
        }
    }
    guard let state else { return quiet(.finished) }
    switch state.state {
    case "blocked": return live ? SessionStatus(.needsInput, state.detail, since: state.at) : quiet(.offline)
    case "working": return live ? SessionStatus(.working, state.detail, since: state.at) : quiet(.offline)
    case "error": return SessionStatus(.failed, state.detail, since: state.at)
    case "stopped": return SessionStatus(.stopped, since: state.at)
    case "idle": return quiet(.finished)
    default: return SessionStatus(.finished, since: state.at)
    }
}
