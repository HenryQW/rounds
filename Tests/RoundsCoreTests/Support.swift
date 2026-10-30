import Foundation
import Testing

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "rounds-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

import Synchronization
typealias Locked<T: Sendable> = Mutex<T>
