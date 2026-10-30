import AppKit
import RoundsCore
import SwiftUI

/// Images for rows, loaded once per key and kept for the app's life.
@MainActor
enum IconCache {
    private static var images: [String: NSImage?] = [:]

    /// The image in the file `find` returns, or nil.
    static func image(_ key: String, find: () -> URL?) -> NSImage? {
        if let hit = images[key] { return hit }
        let image = find().flatMap(NSImage.init(contentsOf:))
        images[key] = image
        return image
    }
}

/// An icon, or the first letter of `name` in a rounded badge when there is no icon.
struct Badge: View {
    let icon: NSImage?
    let name: String
    let size: CGFloat
    /// The letter's font size, as a part of `size`.
    var letterScale: CGFloat = 0.7

    /// Where the activity runs: the icon a known source ships in the app bundle, else the first letter of the agent
    /// name. `name` is `SessionRow.sourceName`: claude, codex, or a herdr agent's name.
    static func origin(_ name: String, size: CGFloat) -> Badge {
        let icon = KnownAgent(rawValue: name).flatMap { agent in
            IconCache.image(agent.iconFile) { Bundle.main.url(forResource: agent.iconFile, withExtension: nil) }
        }
        return Badge(icon: icon, name: name, size: size)
    }

    /// A project's icon file (common names, spec 5.6), else its first letter.
    static func project(_ root: String, name: String, size: CGFloat) -> Badge {
        Badge(icon: IconCache.image(root) { projectIcon(in: URL(fileURLWithPath: root)) }, name: name, size: size, letterScale: 0.65)
    }

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * letterScale, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(.fill.tertiary, in: .rect(cornerRadius: size * 0.25))
        }
    }
}
