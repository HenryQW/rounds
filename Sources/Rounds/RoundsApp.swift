import SwiftUI

// No @State here: Command Line Tools ship no SwiftUIMacros plugin, so view state lives in @Observable objects.
@main
struct RoundsApp: App {
    private let model = AppModel.shared
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // Hover hints (`.help`) show after 0.5 s: the system default (key not set) felt slower than 1 s.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
        HotkeyManager.shared.onPress = { PanelController.shared.toggle() }
        HotkeyManager.shared.register(HotkeyManager.saved())
        // NSApp does not exist yet in App.init; the drawer makes its pill once the app runs. The pill is the app's only
        // visible entry point: there is no menu bar item (spec 5.1).
        DispatchQueue.main.async {
            EdgeDrawer.shared.start()
            PanelController.shared.prepare()
            BouncerModel.shared.start()
            Demo.start()
            Updater.shared.start()
        }
    }

    var body: some Scene {
        Settings {
            SettingsView(model: model, state: SettingsState.shared)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Quit waits until Pi has exited (spec 5.9): `terminateLater` keeps the main thread free, so the shutdown can run.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var replied = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await BouncerModel.shared.quit()
            self.reply()
        }
        return .terminateLater
    }

    @MainActor private func reply() {
        guard !replied else { return }
        replied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
