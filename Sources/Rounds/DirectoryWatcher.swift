import CoreServices
import Foundation

/// FSEvents on a set of directories; calls `onChange` with the changed paths on the main queue, coalesced by `latency`.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init(paths: [String], latency: TimeInterval = 0.2, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange((0..<count).map { String(cString: paths[$0]) })
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
