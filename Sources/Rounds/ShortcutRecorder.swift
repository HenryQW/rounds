import AppKit
import Carbon
import Observation
import SwiftUI

@MainActor @Observable
final class RecorderState {
    var recording = false
    var message: String?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private weak var window: NSWindow?

    /// Records the next key press in the window that is key now; keys in other windows pass through.
    func start(onCommit: @escaping (Shortcut?) -> Bool) {
        stop()
        recording = true
        message = nil
        window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.handle(event, onCommit: onCommit)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func handle(_ event: NSEvent, onCommit: (Shortcut?) -> Bool) {
        let code = Int(event.keyCode)
        switch code {
        case kVK_Escape:
            stop()
            return
        case kVK_Delete, kVK_ForwardDelete:
            _ = onCommit(nil)
            stop()
            return
        default:
            break
        }
        let flags = event.modifierFlags
        var mask = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.shift) { mask |= shiftKey }
        let isFunctionKey = Self.functionKeys[code] != nil
        guard mask & (cmdKey | optionKey | controlKey) != 0 || isFunctionKey else {
            message = "Use ⌘, ⌥ or ⌃ with the key"
            return
        }
        let key = Self.functionKeys[code] ?? Self.namedKeys[code] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        if !onCommit(Shortcut(keyCode: UInt32(code), modifiers: UInt32(mask), key: key)) { message = "Another app uses this shortcut." }
        stop()
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]
}

/// Click, then press a key combination (spec 5.4). Esc cancels; Delete or the clear button in the field removes it.
/// A fixed width keeps it from jumping.
struct ShortcutRecorder: View {
    let shortcut: Shortcut?
    let state: RecorderState
    let onCommit: (Shortcut?) -> Bool

    var body: some View {
        Button {
            state.recording ? state.stop() : state.start(onCommit: onCommit)
        } label: {
            Group {
                if state.recording { Text("Press Keys…") }
                else if let shortcut { Text(shortcut.display).monospacedDigit().padding(.trailing, 14) }
                else { Text("Record Shortcut").foregroundStyle(.secondary) }
            }
            .frame(width: 120)
        }
        .overlay(alignment: .trailing) {
            if shortcut != nil && !state.recording {
                Button("Remove Shortcut", systemImage: "xmark.circle.fill") { _ = onCommit(nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove Shortcut")
                    .padding(.trailing, 8)
            }
        }
        .accessibilityLabel("Shortcut")
        .accessibilityValue(state.recording ? "Recording" : (shortcut?.display ?? "None"))
        .accessibilityHint("Click, then press the new key combination")
    }
}
