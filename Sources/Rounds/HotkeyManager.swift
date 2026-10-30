import AppKit
import Carbon
import Observation

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon mask: cmdKey, optionKey, controlKey, shiftKey
    var key: String         // display text of the key, captured when recorded

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }
}

/// One global hotkey through Carbon `RegisterEventHotKey` (needs no Accessibility permission).
@MainActor @Observable
final class HotkeyManager {
    static let shared = HotkeyManager()
    static let defaultShortcut = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | cmdKey), key: "Space")
    private static let defaultsKey = "shortcut"

    @ObservationIgnored var onPress: () -> Void = {}
    private(set) var current: Shortcut?
    @ObservationIgnored private var ref: EventHotKeyRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotkeyManager.shared.onPress() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Saved shortcut: no key means the default; a stored `null` means none.
    static func saved() -> Shortcut? {
        guard let data = appDefaults.data(forKey: defaultsKey) else { return defaultShortcut }
        return try? JSONDecoder().decode(Shortcut?.self, from: data)
    }

    /// Registers `s` (nil clears). On failure keeps the old shortcut and returns false.
    @discardableResult
    func register(_ s: Shortcut?) -> Bool {
        let old = current
        unregister()
        guard let s else {
            current = nil
            save(nil)
            return true
        }
        if registerCarbon(s) {
            current = s
            save(s)
            return true
        }
        if let old, registerCarbon(old) { current = old }
        return false
    }

    private func registerCarbon(_ s: Shortcut) -> Bool {
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4145_4347), id: 1)  // "AECG"
        guard RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &newRef) == noErr else { return false }
        ref = newRef
        return true
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func save(_ s: Shortcut?) {
        appDefaults.set(try? JSONEncoder().encode(s), forKey: Self.defaultsKey)
    }
}
