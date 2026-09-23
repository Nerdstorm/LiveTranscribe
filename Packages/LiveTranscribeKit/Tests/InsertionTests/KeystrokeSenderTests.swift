import CoreGraphics
@testable import Insertion
import Shared
import Testing

/// The events are built but never posted, so no real keys are pressed.
@Suite("CGEventKeystrokeSender")
struct KeystrokeSenderTests {
    /// The app's hotkey tap lets through only events with the tag: an untagged ⌘Z posted while the
    /// Z of ⌃⌥Z is still held would be swallowed, and undo would add text instead of replacing it.
    @Test("⌘V and ⌘Z are tagged as the app's own, down and up", arguments: [
        CGEventKeystrokeSender.vKeyCode, CGEventKeystrokeSender.zKeyCode,
    ])
    func eventsCarryTheMarker(keyCode: CGKeyCode) throws {
        let events = try #require(CGEventKeystrokeSender.shortcutEvents(commandWith: keyCode))

        for event in [events.down, events.up] {
            #expect(event.getIntegerValueField(.eventSourceUserData) == SyntheticEventMarker.value)
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode))
            #expect(event.flags == .maskCommand, "only ⌘, whatever modifiers are physically held")
        }
        #expect(events.down.type == .keyDown)
        #expect(events.up.type == .keyUp)
    }
}
