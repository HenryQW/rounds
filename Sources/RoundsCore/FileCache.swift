import Foundation

/// The values `FileCache` compares. A directory listing that prefetches them saves one stat per file.
public let fileCacheKeys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]

/// Decoded file contents, reused until the file's modification date or size changes.
public final class FileCache<Value> {
    private var entries: [URL: (modified: Date, size: Int, value: Value)] = [:]

    public init() {}

    public var count: Int { entries.count }

    /// `read` loads the bytes to decode (default: the whole file); nil when the file cannot be read.
    public func value(at url: URL, read: (URL) -> Data? = { try? Data(contentsOf: $0) }, decode: (Data) -> Value) -> Value? {
        // A URL keeps its resource values until the end of the run loop pass, so a prefetched listing is not read again.
        guard let values = try? url.resourceValues(forKeys: Set(fileCacheKeys)),
              let modified = values.contentModificationDate else {
            entries[url] = nil
            return nil
        }
        let size = values.fileSize ?? 0
        if let hit = entries[url], hit.modified == modified, hit.size == size { return hit.value }
        // The pool frees the decoder's temporary objects now: the first refresh runs in App.init, before the run loop
        // drains anything.
        guard let value = autoreleasepool(invoking: { read(url).map(decode) }) else { return nil }
        entries[url] = (modified, size, value)
        return value
    }

    /// Drops entries for files that are gone.
    public func keep(only urls: Set<URL>) {
        entries = entries.filter { urls.contains($0.key) }
    }
}
