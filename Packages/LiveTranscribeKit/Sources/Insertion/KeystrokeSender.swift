import CoreGraphics
import Shared

/// Posts the two shortcuts insertion needs, behind a protocol so tests never press real keys.
public protocol KeystrokeSender: Sendable {
    /// Whether macOS lets this process post keystrokes at all. When it doesn't, ``sendPaste()``
    /// and ``sendUndo()`` post nothing and return `false`.
    func canPost() -> Bool
    /// Posts ⌘V. `true` means the events were posted, not that the app pasted.
    func sendPaste() -> Bool
    /// Posts ⌘Z. `true` means the events were posted, not that the app undid anything.
    func sendUndo() -> Bool
}

/// ``KeystrokeSender`` that posts synthetic key events at the HID level, where they reach the app
/// with keyboard focus as if typed. Each event is tagged with `SyntheticEventMarker`, so the
/// app's own hotkey tap never mistakes it for the user's typing.
///
/// Uses virtual key codes (V is 9, Z is 6), which name physical key positions. Layouts that move
/// letters (Dvorak without the "QWERTY ⌘" variant) may map those positions to other shortcuts.
public struct CGEventKeystrokeSender: KeystrokeSender {
    static let vKeyCode: CGKeyCode = 9
    static let zKeyCode: CGKeyCode = 6

    public init() {}

    public func canPost() -> Bool {
        CGPreflightPostEventAccess()
    }

    public func sendPaste() -> Bool {
        post(commandWith: Self.vKeyCode, name: "⌘V")
    }

    public func sendUndo() -> Bool {
        post(commandWith: Self.zKeyCode, name: "⌘Z")
    }

    private func post(commandWith keyCode: CGKeyCode, name: String) -> Bool {
        // Without permission to post events the system drops them silently; checking first lets
        // the caller fall back to the clipboard instead of reporting a paste that never happened.
        guard canPost() else {
            Log.insertion.error("\(name, privacy: .public) not sent: no permission to post keyboard events")
            return false
        }
        guard let events = Self.shortcutEvents(commandWith: keyCode) else {
            Log.insertion.error("\(name, privacy: .public) not sent: the key events could not be created")
            return false
        }
        events.down.post(tap: .cghidEventTap)
        events.up.post(tap: .cghidEventTap)
        return true
    }

    /// The key-down and key-up of ⌘ and `keyCode`, tagged as the app's own; `nil` if Core
    /// Graphics cannot create them.
    ///
    /// Only ⌘, whatever modifiers are physically held (the hotkey may still be down). Both events
    /// carry `SyntheticEventMarker` so the app's hotkey tap lets them through: the ⌘Z of *Undo AI
    /// edit* is usually posted while the Z of ⌃⌥Z is still held, and would otherwise be swallowed
    /// as that key's repeat.
    static func shortcutEvents(commandWith keyCode: CGKeyCode) -> (down: CGEvent, up: CGEvent)? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return nil }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.value)
        }
        return (down, up)
    }
}
