import Foundation

/// A single modifier key that works as a push-to-talk hotkey on its own.
///
/// Only keys that are rarely used alone are offered. Left ⌘ and left ⇧ are left out on purpose:
/// they begin most shortcuts and capitals, so holding them is not a deliberate "start dictating".
/// The raw values are persisted in settings; never rename them.
public enum ModifierKey: String, Codable, Sendable, CaseIterable {
    case fn
    case rightOption
    case rightCommand
    case rightControl
    case rightShift
    case leftOption
    case leftControl

    /// The macOS virtual key code, which `flagsChanged` events carry for the key that changed.
    public var keyCode: UInt16 {
        switch self {
        case .fn: 63
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .rightShift: 60
        case .leftOption: 58
        case .leftControl: 59
        }
    }

    /// The name shown in Settings and menus, with the symbol printed on the key.
    public var displayName: String {
        switch self {
        case .fn: "fn (\(Self.globeSymbol))"
        case .rightOption: "Right ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .rightControl: "Right ⌃ Control"
        case .rightShift: "Right ⇧ Shift"
        case .leftOption: "Left ⌥ Option"
        case .leftControl: "Left ⌃ Control"
        }
    }

    /// The flag that is set while this key is down.
    ///
    /// Right and left modifiers share one device-independent flag (both ⌥ keys set `.option`),
    /// so the device-dependent bit is what tells them apart. Fn has only the one flag.
    public var heldFlag: KeyEventFlags {
        switch self {
        case .fn: .secondaryFn
        case .rightOption: .rightOption
        case .rightCommand: .rightCommand
        case .rightControl: .rightControl
        case .rightShift: .rightShift
        case .leftOption: .leftOption
        case .leftControl: .leftControl
        }
    }

    /// The globe printed on the fn key of recent Mac keyboards (U+1F310), as macOS labels it.
    static let globeSymbol = "\u{1F310}"
}

/// The modifiers of a key-combination hotkey.
///
/// Only the device-independent modifiers count: a combination does not care which ⌥ key is held.
/// The raw values are persisted by `Codable`; never renumber them.
public struct ModifierSet: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let control = ModifierSet(rawValue: 1 << 2)
    public static let shift = ModifierSet(rawValue: 1 << 3)

    /// Every modifier in the order macOS prints them (⌃⌥⇧⌘), with its storage name and symbol.
    static let ordered: [(modifier: ModifierSet, name: String, symbol: String)] = [
        (.control, "control", "⌃"),
        (.option, "option", "⌥"),
        (.shift, "shift", "⇧"),
        (.command, "command", "⌘"),
    ]

    /// The symbols in macOS order, as menus show them: `[.command, .control]` is "⌃⌘".
    public var displayName: String {
        Self.ordered.filter { contains($0.modifier) }.map(\.symbol).joined()
    }

    /// Whether the set can guard a shortcut. Shift alone cannot: ⇧ plus a key is ordinary typing.
    public var containsCommandOptionOrControl: Bool {
        !isDisjoint(with: [.command, .option, .control])
    }

    /// Storage names in macOS order, for ``HotkeyBinding/storageString``.
    var storageNames: [String] {
        Self.ordered.filter { contains($0.modifier) }.map(\.name)
    }

    /// The set named by storage names; `nil` if any name is unknown.
    init?(storageNames: [String]) {
        var set: ModifierSet = []
        for name in storageNames {
            guard let entry = Self.ordered.first(where: { $0.name == name }) else { return nil }
            set.insert(entry.modifier)
        }
        self = set
    }

    /// The device-independent modifiers held in an event. Caps Lock, fn, the numeric pad bit and
    /// the left/right bits are ignored, so a combination matches whichever side is used.
    public init(eventFlags: KeyEventFlags) {
        var set: ModifierSet = []
        if eventFlags.contains(.control) { set.insert(.control) }
        if eventFlags.contains(.option) { set.insert(.option) }
        if eventFlags.contains(.shift) { set.insert(.shift) }
        if eventFlags.contains(.command) { set.insert(.command) }
        self = set
    }
}
