import Foundation

/// Standard macOS shortcuts that the dictation and undo shortcuts must leave alone.
///
/// The hotkey tap swallows its shortcuts in every app, so a shortcut such as ⌘C would stop
/// copying everywhere. ``HotkeyBinding/validate()`` refuses the combinations listed here:
/// - the Edit and Format menus: undo, redo, cut, copy, paste, select all, find, bold, italic,
///   underline;
/// - the File, app and window menus: new, open, save, print, close, quit, hide, minimize,
///   settings, help, full screen, and cycling through windows;
/// - system shortcuts that macOS turns on by default: switching apps, Spotlight, Emoji &
///   Symbols, the previous input source (⌃Space), Mission Control and switching Spaces (⌃ and
///   an arrow), hiding the Dock, force quit, lock screen, log out and screenshots.
///
/// The list is kept short and exact: only these modifier sets are refused, so ⌃⌘C or ⌥⌘C stay
/// available. ⌃⌥Space is allowed on purpose: macOS uses it only to step through several input
/// sources, and apps leave it alone, whereas ⌃Space is also completion in many code editors.
///
/// Keys are matched by virtual key code, which names the key's position on a US keyboard, as
/// everywhere else in the hotkey code (see `KeyNames`).
enum ReservedShortcuts {
    /// What the shortcut does in macOS ("Copy", "Spotlight"), or `nil` if it is not reserved.
    static func action(forKeyCode keyCode: UInt16, modifiers: ModifierSet) -> String? {
        table[Shortcut(keyCode: keyCode, modifiers: modifiers)]
    }

    private struct Shortcut: Hashable {
        let keyCode: UInt16
        let modifiers: ModifierSet
    }

    // Virtual key codes (US layout positions).
    private static let keyA: UInt16 = 0, keyS: UInt16 = 1, keyD: UInt16 = 2, keyF: UInt16 = 3, keyH: UInt16 = 4
    private static let keyG: UInt16 = 5, keyZ: UInt16 = 6, keyX: UInt16 = 7, keyC: UInt16 = 8
    private static let keyV: UInt16 = 9, keyB: UInt16 = 11, keyQ: UInt16 = 12, keyW: UInt16 = 13
    private static let keyT: UInt16 = 17, keyO: UInt16 = 31, keyU: UInt16 = 32, keyI: UInt16 = 34
    private static let keyP: UInt16 = 35, keyN: UInt16 = 45, keyM: UInt16 = 46
    private static let digit3: UInt16 = 20, digit4: UInt16 = 21, digit5: UInt16 = 23
    private static let comma: UInt16 = 43, slash: UInt16 = 44, grave: UInt16 = 50
    private static let tab: UInt16 = 48, space: UInt16 = 49, escape: UInt16 = 53
    private static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126

    private static let entries: [(UInt16, ModifierSet, String)] = [
        // Edit and Format menus.
        (keyZ, [.command], "Undo"),
        (keyZ, [.shift, .command], "Redo"),
        (keyX, [.command], "Cut"),
        (keyC, [.command], "Copy"),
        (keyV, [.command], "Paste"),
        (keyV, [.option, .shift, .command], "Paste and Match Style"),
        (keyA, [.command], "Select All"),
        (keyF, [.command], "Find"),
        (keyG, [.command], "Find Next"),
        (keyG, [.shift, .command], "Find Previous"),
        (keyB, [.command], "Bold"),
        (keyI, [.command], "Italic"),
        (keyU, [.command], "Underline"),
        // File, app and window menus.
        (keyN, [.command], "New"),
        (keyO, [.command], "Open"),
        (keyS, [.command], "Save"),
        (keyS, [.shift, .command], "Save As"),
        (keyP, [.command], "Print"),
        (keyT, [.command], "New Tab"),
        (keyW, [.command], "Close"),
        (keyW, [.option, .command], "Close All"),
        (keyQ, [.command], "Quit"),
        (keyH, [.command], "Hide"),
        (keyH, [.option, .command], "Hide Others"),
        (keyM, [.command], "Minimize"),
        (comma, [.command], "Settings"),
        (slash, [.shift, .command], "Help"),
        (keyF, [.control, .command], "Full Screen"),
        (grave, [.command], "Next Window"),
        (grave, [.shift, .command], "Previous Window"),
        // System.
        (tab, [.command], "switching apps"),
        (tab, [.shift, .command], "switching apps"),
        (space, [.command], "Spotlight"),
        (space, [.option, .command], "Finder search"),
        (space, [.control, .command], "Emoji & Symbols"),
        (space, [.control], "the previous input source"),
        (up, [.control], "Mission Control"),
        (down, [.control], "showing an app's windows"),
        (left, [.control], "switching Spaces"),
        (right, [.control], "switching Spaces"),
        (keyD, [.option, .command], "hiding the Dock"),
        (escape, [.option, .command], "Force Quit"),
        (keyQ, [.control, .command], "Lock Screen"),
        (keyQ, [.shift, .command], "Log Out"),
        (digit3, [.shift, .command], "screenshots"),
        (digit4, [.shift, .command], "screenshots"),
        (digit5, [.shift, .command], "screenshots"),
        (digit3, [.control, .shift, .command], "screenshots"),
        (digit4, [.control, .shift, .command], "screenshots"),
    ]

    private static let table: [Shortcut: String] = Dictionary(
        entries.map { (Shortcut(keyCode: $0.0, modifiers: $0.1), $0.2) },
        uniquingKeysWith: { first, _ in first }
    )
}
