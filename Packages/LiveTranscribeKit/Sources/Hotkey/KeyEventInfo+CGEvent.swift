import CoreGraphics
import Foundation

extension KeyEventInfo {
    /// The hotkey-relevant parts of a tapped event; `nil` for event types the matcher ignores.
    init?(event: CGEvent, type: CGEventType) {
        let kind: KeyEventType
        switch type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return nil
        }
        self.init(
            type: kind,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: KeyEventFlags(rawValue: event.flags.rawValue),
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
    }
}
