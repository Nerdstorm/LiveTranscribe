import Foundation
import Hotkey
import Testing

@Suite("ModifierKey and ModifierSet")
struct ModifierKeyTests {
    @Test("Key codes and held flags", arguments: [
        (ModifierKey.fn, UInt16(63), KeyEventFlags.secondaryFn, "fn (\u{1F310})"),
        (.rightOption, 61, .rightOption, "Right ⌥ Option"),
        (.rightCommand, 54, .rightCommand, "Right ⌘ Command"),
        (.rightControl, 62, .rightControl, "Right ⌃ Control"),
        (.rightShift, 60, .rightShift, "Right ⇧ Shift"),
        (.leftOption, 58, .leftOption, "Left ⌥ Option"),
        (.leftControl, 59, .leftControl, "Left ⌃ Control"),
    ])
    func modifierKeys(key: ModifierKey, keyCode: UInt16, flag: KeyEventFlags, name: String) {
        #expect(key.keyCode == keyCode)
        #expect(key.heldFlag == flag)
        #expect(key.displayName == name)
    }

    @Test func deviceBitsMatchIOKit() {
        // NX_DEVICE*KEYMASK values from IOKit/hidsystem/IOLLEvent.h.
        #expect(KeyEventFlags.rightOption.rawValue == 0x40)
        #expect(KeyEventFlags.leftOption.rawValue == 0x20)
        #expect(KeyEventFlags.rightCommand.rawValue == 0x10)
        #expect(KeyEventFlags.rightControl.rawValue == 0x2000)
        #expect(KeyEventFlags.leftControl.rawValue == 0x1)
        #expect(KeyEventFlags.rightShift.rawValue == 0x4)
    }

    @Test func modifierKeysStoreAsTheirRawValue() throws {
        let data = try JSONEncoder().encode([ModifierKey.rightOption])
        #expect(String(decoding: data, as: UTF8.self) == #"["rightOption"]"#)
    }

    @Test("Modifier sets print in macOS order", arguments: [
        (ModifierSet(), ""),
        ([.command], "⌘"),
        ([.command, .control], "⌃⌘"),
        ([.shift, .option], "⌥⇧"),
        ([.command, .shift, .option, .control], "⌃⌥⇧⌘"),
    ] as [(ModifierSet, String)])
    func displayOrder(modifiers: ModifierSet, expected: String) {
        #expect(modifiers.displayName == expected)
    }

    @Test func guardModifiers() {
        #expect(!ModifierSet().containsCommandOptionOrControl)
        #expect(!ModifierSet.shift.containsCommandOptionOrControl)
        #expect(ModifierSet([.shift, .option]).containsCommandOptionOrControl)
    }

    @Test func eventFlagsIgnoreCapsLockFnKeypadAndSides() {
        let flags: KeyEventFlags = [.control, .option, .capsLock, .secondaryFn, .numericPad, .rightOption, .leftControl]
        #expect(ModifierSet(eventFlags: flags) == [.control, .option])
        #expect(ModifierSet(eventFlags: [.shift, .command]) == [.shift, .command])
        #expect(ModifierSet(eventFlags: []) == [])
    }

    @Test func modifierSetsAreCodable() throws {
        let set: ModifierSet = [.control, .shift]
        let data = try JSONEncoder().encode(set)
        #expect(try JSONDecoder().decode(ModifierSet.self, from: data) == set)
    }
}
