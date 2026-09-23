import Hotkey
import Testing

/// Rules that keep the tap from swallowing ordinary typing or leaving a recording running.
@Suite("HotkeyMatcher safety")
struct HotkeyMatcherSafetyTests {
    @Test("An invalid combination is never matched or swallowed", arguments: [
        HotkeyBinding.keyCombo(keyCode: Keys.keyA, modifiers: []),
        .keyCombo(keyCode: Keys.keyA, modifiers: [.shift]),
        .keyCombo(keyCode: 55, modifiers: [.command]),
    ])
    func invalidDictationCombo(binding: HotkeyBinding) {
        guard case .keyCombo(let keyCode, let modifiers) = binding else { return }
        var flags: KeyEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        var matcher = HotkeyMatcher(binding: binding, undoBinding: nil)
        let decisions = [Keys.down(keyCode, flags), Keys.up(keyCode, flags)].map {
            matcher.match($0, capturingEscape: false)
        }
        #expect(decisions == [.passThrough, .passThrough])
        #expect(!matcher.isHotkeyHeld)
    }

    @Test("Only a valid combination other than the hotkey can undo", arguments: [
        (HotkeyBinding?.none, HotkeyBinding?.none),
        (.some(.defaultUndo), .some(.defaultUndo)),
        (.some(.modifierKey(.rightCommand)), nil),
        (.some(.keyCombo(keyCode: Keys.keyZ, modifiers: [.shift])), nil),
        (.some(.defaultDictation), nil),
    ])
    func effectiveUndo(undo: HotkeyBinding?, expected: HotkeyBinding?) {
        #expect(HotkeyMatcher.effectiveUndoBinding(undo, dictation: .defaultDictation) == expected)
        #expect(HotkeyMatcher(binding: .defaultDictation, undoBinding: undo).undoBinding == expected)
    }

    @Test func anInvalidUndoComboIsNeverSwallowed() {
        var matcher = HotkeyMatcher(binding: .defaultDictation, undoBinding: .keyCombo(keyCode: Keys.keyZ, modifiers: []))
        #expect(matcher.match(Keys.down(Keys.keyZ), capturingEscape: false) == .passThrough)
    }

    /// With left ⌃ as the dictation hotkey, ⌃⌥Z first starts a recording: undo must cancel it
    /// as any other shortcut would, or the silence would be transcribed and inserted.
    @Test func undoWhileAModifierHotkeyIsHeldAlsoInterruptsIt() {
        var matcher = HotkeyMatcher(binding: .modifierKey(.leftControl), undoBinding: .defaultUndo)
        _ = matcher.match(Keys.flagsChanged(59, [.control, .leftControl]), capturingEscape: false)
        let match = matcher.match(Keys.down(Keys.keyZ, [.control, .leftControl, .option, .leftOption]), capturingEscape: false)
        #expect(match == HotkeyMatch(meaning: .undo, consumes: true, interruptsHotkey: true))
        #expect(match.events == [.otherKey, .undo])
    }

    @Test func undoWhileNothingIsHeldIsJustUndo() {
        var matcher = HotkeyMatcher(binding: .modifierKey(.leftControl), undoBinding: .defaultUndo)
        let match = matcher.match(Keys.down(Keys.keyZ, [.control, .option]), capturingEscape: false)
        #expect(match.events == [.undo])
    }

    @Test("Events for each decision", arguments: [
        (HotkeyMatch(meaning: .hotkeyDown, consumes: false), [HotkeyEvent.pressed]),
        (HotkeyMatch(meaning: .hotkeyUp, consumes: true), [.released]),
        (HotkeyMatch(meaning: .escape, consumes: true), [.escape]),
        (HotkeyMatch(meaning: .otherKey, consumes: false), [.otherKey]),
        (HotkeyMatch(meaning: .otherKey, consumes: false, interruptsHotkey: true), [.otherKey]),
        (HotkeyMatch(meaning: .undo, consumes: true), [.undo]),
        (HotkeyMatch(meaning: .none, consumes: true), []),
        (.passThrough, []),
    ])
    func eventsForMatches(match: HotkeyMatch, expected: [HotkeyEvent]) {
        #expect(match.events == expected)
    }
}
