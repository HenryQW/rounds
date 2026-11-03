import AppKit
import Sparkle

/// Updates through Sparkle (spec 5.8): it reads the appcast of the latest GitHub release once a day and shows its own
/// window for a new version. An update must carry an EdDSA signature from the Rounds key (`SUPublicEDKey`), as Rounds
/// has only an ad-hoc code signature. Demo runs do not check.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    @ObservationIgnored private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    /// Check for updates automatically (Settings > General); Sparkle keeps it in the user defaults.
    var automaticChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticChecks }
    }

    private init() { automaticChecks = controller.updater.automaticallyChecksForUpdates }

    func start() {
        if !Demo.isOn { controller.startUpdater() }
    }

    /// Check for Updates…: Rounds has no menu bar, so it comes to the front for Sparkle's window.
    func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
