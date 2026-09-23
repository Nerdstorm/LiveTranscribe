import Foundation

/// The key a user holds (or presses) to dictate, or to undo the last AI edit.
///
/// Either a modifier on its own (fn, right ⌥, …), which is held for push-to-talk, or a key
/// combination guarded by ⌘, ⌥ or ⌃, so that ordinary typing can never trigger it.
///
/// Encodes as its ``storageString``, so a stored value stays readable and stable.
public enum HotkeyBinding: Sendable, Hashable {
    case modifierKey(ModifierKey)
    case keyCombo(keyCode: UInt16, modifiers: ModifierSet)

    /// Fn (the globe key): a key few people press on its own, and the one other dictation tools use.
    public static let defaultDictation = HotkeyBinding.modifierKey(.fn)

    /// ⌃⌥Z: undo the last AI edit (see docs/dictation.md, "Undo AI edit").
    public static let defaultUndo = HotkeyBinding.keyCombo(keyCode: 6, modifiers: [.control, .option])

    /// The name shown in Settings and menus: "fn" with the globe symbol, "⌃⌥Space", "⌃⌥Z".
    public var displayName: String {
        switch self {
        case .modifierKey(let key):
            key.displayName
        case .keyCombo(let keyCode, let modifiers):
            modifiers.displayName + Self.keyName(for: keyCode)
        }
    }

    /// The printed name of a macOS virtual key code ("Z", "Space", "F5", "←"), for shortcut
    /// recorders that show a key before the binding is complete.
    public static func keyName(for keyCode: UInt16) -> String {
        KeyNames.name(for: keyCode)
    }

    // MARK: - Validation

    /// Throws when the binding would capture ordinary typing or could never fire.
    ///
    /// A combination must include ⌘, ⌥ or ⌃: without one, the event tap would swallow a plain
    /// key (or ⇧ plus a key, which is a capital letter) in every app. Its main key must not be a
    /// modifier, because modifiers never send the key-down event a combination waits for.
    public func validate() throws(HotkeyBindingError) {
        guard case .keyCombo(let keyCode, let modifiers) = self else { return }
        guard !KeyNames.isModifier(keyCode) else { throw .modifierAsMainKey }
        guard modifiers.containsCommandOptionOrControl else { throw .needsCommandOptionOrControl }
    }

    /// Whether ``validate()`` accepts the binding.
    public var isValid: Bool {
        do {
            try validate()
            return true
        } catch {
            return false
        }
    }

    /// A key-combination binding, checked by ``validate()``. Shortcut recorders call this, so an
    /// invalid combination is refused with a message the user can act on.
    public static func validatedKeyCombo(keyCode: UInt16, modifiers: ModifierSet) throws(HotkeyBindingError) -> HotkeyBinding {
        let binding = HotkeyBinding.keyCombo(keyCode: keyCode, modifiers: modifiers)
        try binding.validate()
        return binding
    }

    // MARK: - Storage

    private static let modifierPrefix = "modifier"
    private static let comboPrefix = "combo"

    /// A stable, human-readable form for UserDefaults: "modifier:fn", "combo:49:control,option".
    ///
    /// Modifiers are listed in macOS order (control, option, shift, command) so equal bindings
    /// always store the same string.
    public var storageString: String {
        switch self {
        case .modifierKey(let key):
            "\(Self.modifierPrefix):\(key.rawValue)"
        case .keyCombo(let keyCode, let modifiers):
            "\(Self.comboPrefix):\(keyCode):\(modifiers.storageNames.joined(separator: ","))"
        }
    }

    /// Parses a ``storageString``. Returns `nil` for anything unknown, malformed or invalid, so
    /// a damaged or hand-edited setting falls back to the default instead of capturing typing.
    public init?(storageString: String) {
        let parts = storageString.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case Self.modifierPrefix:
            guard parts.count == 2, let key = ModifierKey(rawValue: parts[1]) else { return nil }
            self = .modifierKey(key)
        case Self.comboPrefix:
            guard parts.count == 3,
                  !parts[1].isEmpty,
                  parts[1].allSatisfy({ ("0"..."9").contains($0) }),
                  let keyCode = UInt16(parts[1]),
                  let modifiers = ModifierSet(storageNames: parts[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init))
            else { return nil }
            let binding = HotkeyBinding.keyCombo(keyCode: keyCode, modifiers: modifiers)
            guard binding.isValid else { return nil }
            self = binding
        default:
            return nil
        }
    }
}

extension HotkeyBinding: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let binding = HotkeyBinding(storageString: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not a valid hotkey binding: \(string)"
            )
        }
        self = binding
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageString)
    }
}

/// Why a key combination cannot be used as a hotkey.
public enum HotkeyBindingError: LocalizedError, Equatable {
    /// No ⌘, ⌥ or ⌃: the shortcut would swallow ordinary typing.
    case needsCommandOptionOrControl
    /// The main key is itself a modifier, which never sends a key-down event.
    case modifierAsMainKey

    public var errorDescription: String? {
        switch self {
        case .needsCommandOptionOrControl:
            "Include ⌘ Command, ⌥ Option or ⌃ Control in the shortcut, so that ordinary typing never triggers it."
        case .modifierAsMainKey:
            "Finish the shortcut with a key that isn't a modifier, or choose the modifier on its own."
        }
    }
}
