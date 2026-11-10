import RoundsCore
import Foundation

func append(_ text: String, to file: URL) throws {
    let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    let bytes = Array(text.utf8)
    guard write(fd, bytes, bytes.count) == bytes.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

// Claude Code async hook: append one state line for this session (spec 2.3).
do {
    let (id, line, cwd) = try HookLine.from(payload: FileHandle.standardInput.readDataToEndOfFile(), now: Date())
    let dir = hookStateDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = dir.appending(path: id)
    try append(line.encoded, to: file)
    // A tool that ran after a permission request: keep the rule that the user approved, in the approvals log.
    if ["PostToolUse", "PostToolUseFailure"].contains(line.event) {
        let lines = String(decoding: try Data(contentsOf: file), as: UTF8.self).split(separator: "\n")
            .compactMap(HookLine.init(encoded:)).sorted { $0.at < $1.at }
        if let i = lines.lastIndex(of: line), let rule = approvedRule(Array(lines[...i])) {
            let approvals = approvalsDirectory()
            try FileManager.default.createDirectory(at: approvals, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.dateFormat = "yyyy-MM-dd"
            try append(approvalLine(at: line.at, sessionId: id, cwd: cwd, rule: rule), to: approvals.appending(path: day.string(from: line.at) + ".tsv"))
        }
    }
} catch {
    FileHandle.standardError.write(Data("rounds-hook: \(error)\n".utf8))
    exit(1)
}
