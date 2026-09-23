import CoreGraphics
import Shared

/// Posts the two shortcuts insertion needs, behind a protocol so tests never press real keys.
public protocol KeystrokeSender: Sendable {
    /// Posts ⌘V. `true` means the events were posted, not that the app pasted.
    func sendPaste() -> Bool
    /// Posts ⌘Z. `true` means the events were posted, not that the app undid anything.
    func sendUndo() -> Bool
}

/// ``KeystrokeSender`` that posts synthetic key events at the HID level, where they reach the app
/// with keyboard focus as if typed.
///
/// Uses virtual key codes (V is 9, Z is 6), which name physical key positions. Layouts that move
/// letters (Dvorak without the "QWERTY ⌘" variant) may map those positions to other shortcuts.
public struct CGEventKeystrokeSender: KeystrokeSender {
    static let vKeyCode: CGKeyCode = 9
    static let zKeyCode: CGKeyCode = 6

    public init() {}

    public func sendPaste() -> Bool {
        post(commandWith: Self.vKeyCode, name: "⌘V")
    }

    public func sendUndo() -> Bool {
        post(commandWith: Self.zKeyCode, name: "⌘Z")
    }

    private func post(commandWith keyCode: CGKeyCode, name: String) -> Bool {
        // Without permission to post events the system drops them silently; checking first lets
        // the caller fall back to the clipboard instead of reporting a paste that never happened.
        guard CGPreflightPostEventAccess() else {
            Log.insertion.error("\(name, privacy: .public) not sent: no permission to post keyboard events")
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            Log.insertion.error("\(name, privacy: .public) not sent: the key events could not be created")
            return false
        }
        // Only ⌘, whatever modifiers are physically held (the hotkey may still be down).
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
