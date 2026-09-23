import Foundation
import Hotkey
import Testing

/// Standard macOS shortcuts cannot become the dictation or undo shortcut: the tap would take
/// them from every app.
@Suite("Reserved shortcuts")
struct ReservedShortcutsTests {
    // Virtual key codes (US layout positions).
    private static let keyA: UInt16 = 0, keyS: UInt16 = 1, keyF: UInt16 = 3, keyH: UInt16 = 4
    private static let keyZ: UInt16 = 6, keyX: UInt16 = 7, keyC: UInt16 = 8, keyV: UInt16 = 9
    private static let keyQ: UInt16 = 12, keyW: UInt16 = 13, keyT: UInt16 = 17, keyO: UInt16 = 31
    private static let keyP: UInt16 = 35, keyN: UInt16 = 45, keyM: UInt16 = 46
    private static let tab: UInt16 = 48, space: UInt16 = 49, grave: UInt16 = 50
    private static let keyD: UInt16 = 2, digit4: UInt16 = 21, left: UInt16 = 123, up: UInt16 = 126

    /// A standard shortcut, with its name and what the message says it does.
    struct Standard: Sendable, CustomTestStringConvertible {
        let keyCode: UInt16
        let modifiers: ModifierSet
        let shortcut: String
        let action: String

        init(_ keyCode: UInt16, _ modifiers: ModifierSet, _ shortcut: String, _ action: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.shortcut = shortcut
            self.action = action
        }

        var testDescription: String { shortcut }
    }

    static let standard: [Standard] = [
        Standard(keyC, [.command], "⌘C", "Copy"),
        Standard(keyV, [.command], "⌘V", "Paste"),
        Standard(keyX, [.command], "⌘X", "Cut"),
        Standard(keyZ, [.command], "⌘Z", "Undo"),
        Standard(keyZ, [.shift, .command], "⇧⌘Z", "Redo"),
        Standard(keyA, [.command], "⌘A", "Select All"),
        Standard(keyS, [.command], "⌘S", "Save"),
        Standard(keyW, [.command], "⌘W", "Close"),
        Standard(keyQ, [.command], "⌘Q", "Quit"),
        Standard(keyN, [.command], "⌘N", "New"),
        Standard(keyT, [.command], "⌘T", "New Tab"),
        Standard(keyO, [.command], "⌘O", "Open"),
        Standard(keyP, [.command], "⌘P", "Print"),
        Standard(keyF, [.command], "⌘F", "Find"),
        Standard(keyH, [.command], "⌘H", "Hide"),
        Standard(keyM, [.command], "⌘M", "Minimize"),
        Standard(tab, [.command], "⌘Tab", "switching apps"),
        Standard(space, [.command], "⌘Space", "Spotlight"),
        Standard(grave, [.command], "⌘`", "Next Window"),
        Standard(space, [.control], "⌃Space", "the previous input source"),
        Standard(up, [.control], "⌃↑", "Mission Control"),
        Standard(left, [.control], "⌃←", "switching Spaces"),
        Standard(keyD, [.option, .command], "⌥⌘D", "hiding the Dock"),
        Standard(digit4, [.shift, .command], "⇧⌘4", "screenshots"),
        Standard(digit4, [.control, .shift, .command], "⌃⇧⌘4", "screenshots"),
    ]

    @Test("Standard shortcuts are refused, naming what they do", arguments: standard)
    func standardShortcutsAreRefused(_ standard: Standard) {
        let binding = HotkeyBinding.keyCombo(keyCode: standard.keyCode, modifiers: standard.modifiers)
        #expect(!binding.isValid)
        #expect(throws: HotkeyBindingError.reserved(shortcut: standard.shortcut, action: standard.action)) {
            try HotkeyBinding.validatedKeyCombo(keyCode: standard.keyCode, modifiers: standard.modifiers)
        }
    }

    static let nearby: [HotkeyBinding] = [
        .keyCombo(keyCode: keyZ, modifiers: [.control, .option]), // the default undo shortcut
        .keyCombo(keyCode: space, modifiers: [.control, .option]), // allowed on purpose, unlike ⌃Space
        .keyCombo(keyCode: keyC, modifiers: [.control, .command]),
        .keyCombo(keyCode: keyC, modifiers: [.option, .command]),
        .keyCombo(keyCode: keyZ, modifiers: [.option, .command]),
        .keyCombo(keyCode: keyV, modifiers: [.control, .option]),
        .keyCombo(keyCode: space, modifiers: [.control, .option, .shift, .command]),
        .keyCombo(keyCode: up, modifiers: [.control, .option]),
        .keyCombo(keyCode: digit4, modifiers: [.control, .command]),
    ]

    @Test("Only the exact standard modifiers are reserved", arguments: nearby)
    func nearbyCombinationsStayAvailable(_ binding: HotkeyBinding) throws {
        try binding.validate()
        #expect(HotkeyBinding(storageString: binding.storageString) == binding, "it can be stored and read back")
    }

    @Test func bothDefaultsAreAllowed() {
        #expect(HotkeyBinding.defaultDictation.isValid)
        #expect(HotkeyBinding.defaultUndo.isValid)
    }

    @Test func aStandardShortcutCannotBeTheUndoShortcut() {
        let copy = HotkeyBinding.keyCombo(keyCode: Self.keyC, modifiers: [.command])
        #expect(HotkeyMatcher.effectiveUndoBinding(copy, dictation: .defaultDictation) == nil)
    }

    @Test func theMessageSaysWhatToDo() throws {
        let error = HotkeyBindingError.reserved(shortcut: "⌘Space", action: "Spotlight")
        let message = try #require(error.errorDescription)
        #expect(message.contains("⌘Space"))
        #expect(message.contains("Spotlight"))
        #expect(message.contains("Choose another combination"))
    }
}
