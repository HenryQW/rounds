import Foundation

/// Common places for a project's icon, best first: app icons, square icons, logos, then favicons
/// (seen in Xcode, Next.js, Vite and static-site projects). A folder with none of them gets no icon.
let projectIconCandidates = [
    "Resources/AppIcon.icns", "AppIcon.icns", "icon.icns",
    "apple-touch-icon.png", "public/apple-touch-icon.png",
    "icon.png", "icon.svg", "logo.png", "logo.svg",
    "assets/icon.png", "assets/icon.svg", "assets/logo.png", "assets/logo.svg",
    "app/icon.png", "app/icon.svg", "src/app/icon.png", "src/app/icon.svg",
    "public/favicon.svg", "public/favicon.png", "public/favicon.ico",
    "app/favicon.ico", "src/app/favicon.ico", "static/favicon.png", "static/favicon.ico",
    "favicon.svg", "favicon.png", "favicon.ico",
    "docs/icon.png", "docs/logo.png", ".github/logo.png",
]

/// The first common icon file in `directory`, or nil.
public func projectIcon(in directory: URL) -> URL? {
    let fm = FileManager.default
    for path in projectIconCandidates {
        let url = directory.appending(path: path)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue { return url }
    }
    return nil
}
