import AppKit
import Sparkle

/// Updates through Sparkle (spec 5.8): it reads the appcast of the chosen channel once a day and shows its own window
/// for a new version. An update must carry an EdDSA signature from the Rounds key (`SUPublicEDKey`). Demo runs do not
/// check.
@MainActor @Observable
final class Updater {
    enum Channel: String, CaseIterable { case release, beta }

    static let shared = Updater()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    /// Sparkle keeps a weak reference to its delegate.
    @ObservationIgnored private let feed: Feed

    /// Check for updates automatically (Settings > General); Sparkle keeps it in the user defaults.
    var automaticChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticChecks }
    }
    /// Download a new version and install it when Rounds quits; Sparkle keeps it in the user defaults.
    var automaticInstall: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticInstall }
    }
    /// Release: the latest GitHub release (`SUFeedURL`). Beta: the `beta` prerelease, a build of each push to main.
    var channel: Channel {
        didSet {
            appDefaults.set(channel.rawValue, forKey: "updateChannel")
            feed.beta = channel == .beta
        }
    }

    private init() {
        let channel = appDefaults.string(forKey: "updateChannel").flatMap(Channel.init) ?? .release
        self.channel = channel
        let feed = Feed(beta: channel == .beta)
        self.feed = feed
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: feed, userDriverDelegate: nil)
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        automaticInstall = controller.updater.automaticallyDownloadsUpdates
    }

    func start() {
        if !Demo.isOn { controller.startUpdater() }
    }

    /// Check for Updates…: Rounds has no menu bar, so it comes to the front for Sparkle's window.
    func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Gives Sparkle the beta feed in place of `SUFeedURL`. Sparkle never installs an older version, so a beta stays
    /// until a release is newer.
    private final class Feed: NSObject, SPUUpdaterDelegate {
        var beta: Bool

        init(beta: Bool) { self.beta = beta }

        func feedURLString(for updater: SPUUpdater) -> String? {
            beta ? "https://github.com/HenryQW/rounds/releases/download/beta/appcast.xml" : nil
        }
    }
}
