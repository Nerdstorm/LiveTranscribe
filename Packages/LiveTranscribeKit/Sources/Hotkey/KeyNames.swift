import Foundation

/// Names for macOS virtual key codes, as shown in shortcuts ("⌃⌥Space", "⌃⌥Z").
///
/// Letter and punctuation names are those of the US (ANSI) layout, where the key codes are
/// defined. On another layout a letter key may print a different character; the shortcut still
/// fires on the same physical key, which is what the name describes.
enum KeyNames {
    /// The name for `keyCode`, or "Key 123" for a code the table does not know.
    static func name(for keyCode: UInt16) -> String {
        table[keyCode] ?? "Key \(keyCode)"
    }

    /// Whether `keyCode` is a modifier key (⌘, ⇧, Caps Lock, ⌥, ⌃, fn), which never sends
    /// `keyDown` and so cannot be the main key of a combination.
    static func isModifier(_ keyCode: UInt16) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    /// Right ⌘ 54, ⌘ 55, ⇧ 56, Caps Lock 57, ⌥ 58, ⌃ 59, right ⇧ 60, right ⌥ 61, right ⌃ 62, fn 63.
    private static let modifierKeyCodes: ClosedRange<UInt16> = 54...63

    private static let table: [UInt16: String] = {
        var names: [UInt16: String] = [
            // Letters (ANSI positions).
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            // Digits on the main keyboard.
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            // Punctuation.
            24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/",
            47: ".", 50: "`",
            // Editing and whitespace.
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 117: "Forward Delete",
            114: "Help", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            // Arrows, printed as macOS menus print them.
            123: "←", 124: "→", 125: "↓", 126: "↑",
            // Keypad.
            65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /",
            76: "Enter", 78: "Keypad -", 81: "Keypad =",
        ]
        let functionKeys: [(UInt16, Int)] = [
            (122, 1), (120, 2), (99, 3), (118, 4), (96, 5), (97, 6), (98, 7), (100, 8), (101, 9),
            (109, 10), (103, 11), (111, 12), (105, 13), (107, 14), (113, 15), (106, 16), (64, 17),
            (79, 18), (80, 19), (90, 20),
        ]
        for (code, number) in functionKeys {
            names[code] = "F\(number)"
        }
        let keypadDigits: [(UInt16, Int)] = [
            (82, 0), (83, 1), (84, 2), (85, 3), (86, 4), (87, 5), (88, 6), (89, 7), (91, 8), (92, 9),
        ]
        for (code, digit) in keypadDigits {
            names[code] = "Keypad \(digit)"
        }
        return names
    }()
}
