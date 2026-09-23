import Foundation
import Hotkey
import Testing

@Suite("HotkeyBinding")
struct HotkeyBindingTests {
    private static let space: UInt16 = 49
    private static let keyZ: UInt16 = 6
    private static let f5: UInt16 = 96

    // MARK: - Defaults and display names

    @Test func defaultsAreFnAndControlOptionZ() {
        #expect(HotkeyBinding.defaultDictation == .modifierKey(.fn))
        #expect(HotkeyBinding.defaultUndo == .keyCombo(keyCode: Self.keyZ, modifiers: [.control, .option]))
        #expect(HotkeyBinding.defaultDictation.isValid)
        #expect(HotkeyBinding.defaultUndo.isValid)
    }

    @Test("Display names", arguments: [
        (HotkeyBinding.modifierKey(.fn), "fn (\u{1F310})"),
        (.modifierKey(.rightOption), "Right ⌥ Option"),
        (.keyCombo(keyCode: 49, modifiers: [.control, .option]), "⌃⌥Space"),
        (.keyCombo(keyCode: 6, modifiers: [.option, .control]), "⌃⌥Z"),
        (.keyCombo(keyCode: 36, modifiers: [.command, .shift]), "⇧⌘Return"),
        (.keyCombo(keyCode: 96, modifiers: [.command, .shift, .option, .control]), "⌃⌥⇧⌘F5"),
        (.keyCombo(keyCode: 126, modifiers: [.control]), "⌃↑"),
        (.keyCombo(keyCode: 29, modifiers: [.command]), "⌘0"),
    ])
    func displayNames(binding: HotkeyBinding, expected: String) {
        #expect(binding.displayName == expected)
    }

    @Test("Key names", arguments: [
        (UInt16(0), "A"), (6, "Z"), (18, "1"), (29, "0"), (49, "Space"), (36, "Return"), (48, "Tab"),
        (53, "Esc"), (51, "Delete"), (122, "F1"), (111, "F12"), (90, "F20"), (123, "←"), (124, "→"),
        (125, "↓"), (126, "↑"), (82, "Keypad 0"), (76, "Enter"), (116, "Page Up"),
    ])
    func keyNames(keyCode: UInt16, expected: String) {
        #expect(HotkeyBinding.keyName(for: keyCode) == expected)
    }

    @Test func unknownKeysAreNamedByCode() {
        #expect(HotkeyBinding.keyName(for: 200) == "Key 200")
    }

    // MARK: - Validation

    @Test("Combinations need command, option or control", arguments: [
        ModifierSet(), [.shift],
    ])
    func combosWithoutAGuardModifierAreRejected(modifiers: ModifierSet) {
        let binding = HotkeyBinding.keyCombo(keyCode: Self.space, modifiers: modifiers)
        #expect(!binding.isValid)
        #expect(throws: HotkeyBindingError.needsCommandOptionOrControl) {
            try binding.validate()
        }
    }

    @Test("Any guard modifier makes a combination valid", arguments: [
        ModifierSet.command, .option, .control, [.shift, .command], [.control, .option],
    ])
    func combosWithAGuardModifierAreAccepted(modifiers: ModifierSet) throws {
        // F5 is in no standard shortcut, so only the modifiers decide.
        let binding = try HotkeyBinding.validatedKeyCombo(keyCode: Self.f5, modifiers: modifiers)
        #expect(binding == .keyCombo(keyCode: Self.f5, modifiers: modifiers))
    }

    @Test("A modifier cannot be the main key", arguments: Array(UInt16(54)...63))
    func modifierMainKeysAreRejected(keyCode: UInt16) {
        #expect(throws: HotkeyBindingError.modifierAsMainKey) {
            try HotkeyBinding.validatedKeyCombo(keyCode: keyCode, modifiers: [.command])
        }
    }

    @Test func everyModifierKeyBindingIsValid() {
        #expect(ModifierKey.allCases.allSatisfy { HotkeyBinding.modifierKey($0).isValid })
    }

    @Test func errorsExplainTheFix() {
        #expect(HotkeyBindingError.needsCommandOptionOrControl.errorDescription?.contains("⌘ Command") == true)
        #expect(HotkeyBindingError.modifierAsMainKey.errorDescription?.isEmpty == false)
        #expect(HotkeyBindingError.reserved(shortcut: "⌘C", action: "Copy").errorDescription
            == "⌘C is the standard macOS shortcut for Copy. Choose another combination.")
    }

    // MARK: - Storage

    @Test("Storage strings", arguments: [
        (HotkeyBinding.modifierKey(.fn), "modifier:fn"),
        (.modifierKey(.rightCommand), "modifier:rightCommand"),
        (.keyCombo(keyCode: 49, modifiers: [.option, .control]), "combo:49:control,option"),
        (.keyCombo(keyCode: 6, modifiers: [.command, .shift, .option, .control]), "combo:6:control,option,shift,command"),
    ])
    func storageStrings(binding: HotkeyBinding, expected: String) {
        #expect(binding.storageString == expected)
        #expect(HotkeyBinding(storageString: expected) == binding)
    }

    @Test func everyModifierKeyRoundTrips() {
        for key in ModifierKey.allCases {
            let binding = HotkeyBinding.modifierKey(key)
            #expect(HotkeyBinding(storageString: binding.storageString) == binding)
        }
    }

    @Test func modifierOrderInStorageDoesNotMatterWhenReading() {
        #expect(HotkeyBinding(storageString: "combo:49:option,control") == .keyCombo(keyCode: 49, modifiers: [.control, .option]))
    }

    @Test("Unknown, malformed and invalid strings are rejected", arguments: [
        "", "fn", "modifier", "modifier:", "modifier:globe", "modifier:fn:extra", "Modifier:fn",
        "combo", "combo:49", "combo:49:", "combo::control", "combo:x:control", "combo:-1:control",
        "combo:+49:control", "combo:65536:control", "combo:49:ctrl", "combo:49:control,", "combo:49:control:option",
        "combo:49:shift", "combo:56:command", "keyCombo:49:control",
    ])
    func rejectsBadStrings(string: String) {
        #expect(HotkeyBinding(storageString: string) == nil)
    }

    @Test func codableUsesTheStorageString() throws {
        let bindings: [HotkeyBinding] = [.defaultDictation, .defaultUndo]
        let data = try JSONEncoder().encode(bindings)
        #expect(String(decoding: data, as: UTF8.self) == #"["modifier:fn","combo:6:control,option"]"#)
        #expect(try JSONDecoder().decode([HotkeyBinding].self, from: data) == bindings)
    }

    @Test func aStoredStandardShortcutIsRejected() {
        // A hand-edited ⌘C falls back to the default instead of taking Copy from every app.
        #expect(HotkeyBinding(storageString: "combo:8:command") == nil)
    }

    @Test func decodingAnInvalidBindingFails() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(HotkeyBinding.self, from: Data(#""combo:49:shift""#.utf8))
        }
    }
}
