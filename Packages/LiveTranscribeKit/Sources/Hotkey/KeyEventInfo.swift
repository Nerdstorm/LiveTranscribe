import Foundation

/// The kind of keyboard event an event tap delivers.
public enum KeyEventType: Sendable, Equatable {
    /// A modifier key (fn, ⌥, ⌘, ⌃, ⇧, Caps Lock) went down or up.
    case flagsChanged
    case keyDown
    case keyUp
}

/// The modifier bits of a keyboard event, mirroring `CGEventFlags` bit for bit.
///
/// A plain value type so the hotkey logic can be tested without Core Graphics. The raw value is
/// the `CGEventFlags` raw value, so converting either way is a copy.
public struct KeyEventFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    // MARK: Device-independent bits (`CGEventFlags`)

    /// Caps Lock is on.
    public static let capsLock = KeyEventFlags(rawValue: 0x0001_0000)
    public static let shift = KeyEventFlags(rawValue: 0x0002_0000)
    public static let control = KeyEventFlags(rawValue: 0x0004_0000)
    public static let option = KeyEventFlags(rawValue: 0x0008_0000)
    public static let command = KeyEventFlags(rawValue: 0x0010_0000)
    /// Set for keys on the numeric keypad, and by macOS for the arrow keys.
    public static let numericPad = KeyEventFlags(rawValue: 0x0020_0000)
    public static let help = KeyEventFlags(rawValue: 0x0040_0000)
    /// The fn key is down. macOS also sets it for the arrow and function keys.
    public static let secondaryFn = KeyEventFlags(rawValue: 0x0080_0000)

    // MARK: Device-dependent bits (`NX_DEVICE*KEYMASK` in IOKit's IOLLEvent.h)

    public static let leftControl = KeyEventFlags(rawValue: 0x0000_0001)
    public static let leftShift = KeyEventFlags(rawValue: 0x0000_0002)
    public static let rightShift = KeyEventFlags(rawValue: 0x0000_0004)
    public static let leftCommand = KeyEventFlags(rawValue: 0x0000_0008)
    public static let rightCommand = KeyEventFlags(rawValue: 0x0000_0010)
    public static let leftOption = KeyEventFlags(rawValue: 0x0000_0020)
    public static let rightOption = KeyEventFlags(rawValue: 0x0000_0040)
    public static let rightControl = KeyEventFlags(rawValue: 0x0000_2000)
}

/// The parts of a keyboard event the hotkey logic needs.
///
/// The event tap converts each `CGEvent` into this, so ``HotkeyMatcher`` never touches Core
/// Graphics and can be tested with plain values.
public struct KeyEventInfo: Sendable, Equatable {
    public var type: KeyEventType
    /// The macOS virtual key code: for `flagsChanged`, the modifier key that changed.
    public var keyCode: UInt16
    public var flags: KeyEventFlags
    /// A repeat generated while a key is held, rather than a new press.
    public var isAutorepeat: Bool
    /// Posted by this app itself, such as the ⌘V of a paste or the ⌘Z of *Undo AI edit*: the
    /// event carries `SyntheticEventMarker`. Never a hotkey, whatever its key. Events other apps
    /// post count as typing.
    public var isSynthetic: Bool

    public init(type: KeyEventType, keyCode: UInt16, flags: KeyEventFlags, isAutorepeat: Bool, isSynthetic: Bool = false) {
        self.type = type
        self.keyCode = keyCode
        self.flags = flags
        self.isAutorepeat = isAutorepeat
        self.isSynthetic = isSynthetic
    }
}
