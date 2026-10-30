import RoundsCore
import Foundation

// Claude Code async hook: append one state line for this session (spec 2.3).
do {
    let (id, line) = try HookLine.from(payload: FileHandle.standardInput.readDataToEndOfFile(), now: Date())
    let dir = hookStateDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fd = open(dir.appending(path: id).path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    let bytes = Array(line.encoded.utf8)
    guard write(fd, bytes, bytes.count) == bytes.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
} catch {
    FileHandle.standardError.write(Data("rounds-hook: \(error)\n".utf8))
    exit(1)
}
