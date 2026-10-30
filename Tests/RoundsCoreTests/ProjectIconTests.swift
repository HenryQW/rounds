import Foundation
import Testing
@testable import RoundsCore

private func touch(_ dir: URL, _ path: String) throws {
    let url = dir.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url)
}

@Test func projectIconPrefersAppIconThenLogoThenFavicon() throws {
    let dir = try tempDir()
    #expect(projectIcon(in: dir) == nil)
    try touch(dir, "src/app/favicon.ico")
    #expect(projectIcon(in: dir)?.lastPathComponent == "favicon.ico")
    try touch(dir, "assets/logo.svg")
    #expect(projectIcon(in: dir)?.path(percentEncoded: false).hasSuffix("assets/logo.svg") == true)
    try touch(dir, "Resources/AppIcon.icns")
    #expect(projectIcon(in: dir)?.lastPathComponent == "AppIcon.icns")
}

@Test func projectIconIgnoresFoldersWithAnIconName() throws {
    let dir = try tempDir()
    try FileManager.default.createDirectory(at: dir.appending(path: "icon.png"), withIntermediateDirectories: true)
    #expect(projectIcon(in: dir) == nil)
}
