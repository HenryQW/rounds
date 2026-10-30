import Foundation

/// What the end of a session transcript says (spec 2.2). `question`: the turn ended, and its wrap-up asked the user
/// something (the desktop keeps that question only when the turn is marked as blocked).
public enum LastMessage: Sendable, Equatable {
    case interrupted, endTurn, question, inProgress, unknown

    /// `data` holds whole JSONL lines (see `readTail`); lines that do not decode are skipped.
    public static func parse(_ data: Data) -> LastMessage {
        var last: LastMessage = .unknown
        var asked = false
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let e = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = e["type"] as? String, type == "user" || type == "assistant",
                  e["isSidechain"] as? Bool != true,
                  let message = e["message"] as? [String: Any] else { continue }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if type == "assistant" {
                asked = asked || blocks.contains { b in
                    b["name"] as? String == "mcp__ccd_turn__wrap_up" && ((b["input"] as? [String: Any])?["ask"] as? String).map { !$0.isEmpty } == true
                }
                let stop = message["stop_reason"] as? String
                last = stop == "end_turn" || stop == "stop_sequence" ? .endTurn : .inProgress
            } else {
                let userText = (message["content"] as? String)
                    ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                // A new prompt starts a new turn; a tool result does not.
                if !userText.isEmpty { asked = false }
                last = userText.hasPrefix("[Request interrupted by user") ? .interrupted : .inProgress
            }
        }
        return last == .endTurn && asked ? .question : last
    }
}

/// `projectsRoot/<cwd with each non-alphanumeric char as "-">/<id>.jsonl`, else a scan of `projectsRoot/*/<id>.jsonl`.
public func transcriptURL(cwd: String, cliSessionId: String, projectsRoot: URL) -> URL? {
    let fm = FileManager.default
    let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    let direct = projectsRoot.appending(path: folder).appending(path: "\(cliSessionId).jsonl")
    if fm.fileExists(atPath: direct.path) { return direct }
    for dir in (try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? [] {
        let candidate = dir.appending(path: "\(cliSessionId).jsonl")
        if fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}

/// The last `maxBytes` of a file, without the first (partial) line when the read starts mid-file.
public func readTail(_ url: URL, maxBytes: Int = 65_536) -> Data {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return Data() }
    guard start > 0 else { return data }
    guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return Data() }
    return data[data.index(after: newline)...]
}
