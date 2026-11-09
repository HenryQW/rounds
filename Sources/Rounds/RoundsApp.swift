import SwiftUI

// No @State here: Command Line Tools ship no SwiftUIMacros plugin, so view state lives in @Observable objects.
@main
struct RoundsApp: App {
    private let model = AppModel.shared

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
