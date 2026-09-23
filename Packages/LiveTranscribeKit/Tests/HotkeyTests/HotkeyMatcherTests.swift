import Hotkey
import Testing

/// Builders for key events, shared by the matcher and router tests.
enum Keys {
    static let space: UInt16 = 49
    static let keyZ: UInt16 = 6
    static let keyA: UInt16 = 0
    static let escape: UInt16 = 53
    static let controlOption = HotkeyBinding.keyCombo(keyCode: space, modifiers: [.control, .option])

    static func flagsChanged(_ keyCode: UInt16, _ flags: KeyEventFlags) -> KeyEventInfo {
        KeyEventInfo(type: .flagsChanged, keyCode: keyCode, flags: flags, isAutorepeat: false)
    }

    static func down(_ keyCode: UInt16, _ flags: KeyEventFlags = [], repeat isAutorepeat: Bool = false) -> KeyEventInfo {
        KeyEventInfo(type: .keyDown, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat)
    }

    static func up(_ keyCode: UInt16, _ flags: KeyEventFlags = []) -> KeyEventInfo {
        KeyEventInfo(type: .keyUp, keyCode: keyCode, flags: flags, isAutorepeat: false)
    }
}

@Suite("HotkeyMatcher")
struct HotkeyMatcherTests {
    private static let down = HotkeyMatch(meaning: .hotkeyDown, consumes: false)
    private static let up = HotkeyMatch(meaning: .hotkeyUp, consumes: false)
    private static let swallowed = HotkeyMatch(meaning: .none, consumes: true)

    /// Matches `events` in order and returns each decision.
    private static func match(
        _ matcher: inout HotkeyMatcher,
        _ events: [KeyEventInfo],
        capturingEscape: Bool = false
    ) -> [HotkeyMatch] {
        events.map { matcher.match($0, capturingEscape: capturingEscape) }
    }

    // MARK: - Modifier-only bindings

    @Test("Each modifier key presses and releases from its own flag", arguments: ModifierKey.allCases)
    func modifierPressAndRelease(key: ModifierKey) {
        var matcher = HotkeyMatcher(binding: .modifierKey(key), undoBinding: nil)
        let decisions = Self.match(&matcher, [
            Keys.flagsChanged(key.keyCode, key.heldFlag),
            Keys.flagsChanged(key.keyCode, []),
        ])
        #expect(decisions == [Self.down, Self.up], "flagsChanged is reported but never swallowed")
    }

    @Test func fnUsesTheSecondaryFnFlag() {
        var matcher = HotkeyMatcher(binding: .defaultDictation, undoBinding: nil)
        #expect(matcher.match(Keys.flagsChanged(63, [.secondaryFn]), capturingEscape: false) == Self.down)
        #expect(matcher.isHotkeyHeld)
        #expect(matcher.match(Keys.flagsChanged(63, []), capturingEscape: false) == Self.up)
        #expect(!matcher.isHotkeyHeld)
    }

    @Test func theOtherSideOfTheSameModifierIsNotTheHotkey() {
        var matcher = HotkeyMatcher(binding: .modifierKey(.rightOption), undoBinding: nil)
        let decisions = Self.match(&matcher, [
            Keys.flagsChanged(58, [.option, .leftOption]), // left ⌥ down
            Keys.flagsChanged(61, [.option, .leftOption, .rightOption]), // right ⌥ down
            Keys.flagsChanged(58, [.option, .rightOption]), // left ⌥ up
            Keys.flagsChanged(61, []), // right ⌥ up
        ])
        #expect(decisions == [.passThrough, Self.down, .passThrough, Self.up])
    }

    @Test func releasingTheHotkeyWhileTheOtherSideIsHeldIsARelease() {
        var matcher = HotkeyMatcher(binding: .modifierKey(.rightOption), undoBinding: nil)
        let decisions = Self.match(&matcher, [
            Keys.flagsChanged(61, [.option, .rightOption]),
            Keys.flagsChanged(58, [.option, .rightOption, .leftOption]),
            // Right ⌥ up: `.option` stays set for the left key, but the right-hand bit clears.
            Keys.flagsChanged(61, [.option, .leftOption]),
        ])
        #expect(decisions == [Self.down, .passThrough, Self.up])
    }

    @Test("Left keys ignore their right-hand twins", arguments: [
        (ModifierKey.leftOption, UInt16(61), KeyEventFlags([.option, .rightOption])),
        (.leftControl, 62, [.control, .rightControl]),
        (.rightControl, 59, [.control, .leftControl]),
        (.rightShift, 56, [.shift, .leftShift]),
        (.rightCommand, 55, [.command, .leftCommand]),
    ] as [(ModifierKey, UInt16, KeyEventFlags)])
    func twinsAreIgnored(key: ModifierKey, twinKeyCode: UInt16, twinFlags: KeyEventFlags) {
        var matcher = HotkeyMatcher(binding: .modifierKey(key), undoBinding: nil)
        #expect(matcher.match(Keys.flagsChanged(twinKeyCode, twinFlags), capturingEscape: false) == .passThrough)
        #expect(!matcher.isHotkeyHeld)
    }

    @Test func aRepeatedDownOrAStrayUpIsIgnored() {
        var matcher = HotkeyMatcher(binding: .defaultDictation, undoBinding: nil)
        let decisions = Self.match(&matcher, [
            Keys.flagsChanged(63, []), // up while not held
            Keys.flagsChanged(63, [.secondaryFn]),
            Keys.flagsChanged(63, [.secondaryFn, .shift]), // still down
        ])
        #expect(decisions == [.passThrough, Self.down, .passThrough])
    }

    @Test func anotherKeyWhileAModifierHotkeyIsHeldIsReportedButNotSwallowed() {
        var matcher = HotkeyMatcher(binding: .defaultDictation, undoBinding: nil)
        let decisions = Self.match(&matcher, [
            Keys.down(Keys.keyA), // not held yet
            Keys.flagsChanged(63, [.secondaryFn]),
            Keys.down(123, [.secondaryFn, .numericPad]), // fn+←
            Keys.down(123, [.secondaryFn, .numericPad], repeat: true),
            Keys.up(123, [.secondaryFn, .numericPad]),
            Keys.flagsChanged(56, [.secondaryFn, .shift, .leftShift]), // another modifier
        ])
        let otherKey = HotkeyMatch(meaning: .otherKey, consumes: false)
        #expect(decisions == [.passThrough, Self.down, otherKey, otherKey, .passThrough, .passThrough])
    }

    // MARK: - Key combinations

    @Test func aComboIsSwallowedFromPressToRelease() {
        var matcher = HotkeyMatcher(binding: Keys.controlOption, undoBinding: nil)
        let decisions = Self.match(&matcher, [
            Keys.down(Keys.space, [.control, .option]),
            Keys.down(Keys.space, [.control, .option], repeat: true),
            Keys.down(Keys.space, [.control], repeat: true),
            Keys.up(Keys.space), // modifiers already released
        ])
        #expect(decisions == [
            HotkeyMatch(meaning: .hotkeyDown, consumes: true), Self.swallowed, Self.swallowed,
            HotkeyMatch(meaning: .hotkeyUp, consumes: true),
        ])
    }

    @Test("Caps Lock, fn, the keypad bit and the side bits do not stop a combo", arguments: [
        KeyEventFlags([.control, .option, .capsLock]),
        [.control, .option, .secondaryFn],
        [.control, .option, .numericPad],
        [.control, .option, .rightControl, .leftOption],
    ])
    func ignoredFlags(flags: KeyEventFlags) {
        var matcher = HotkeyMatcher(binding: Keys.controlOption, undoBinding: nil)
        #expect(matcher.match(Keys.down(Keys.space, flags), capturingEscape: false) == HotkeyMatch(meaning: .hotkeyDown, consumes: true))
    }

    @Test("A combo needs exactly its modifiers", arguments: [
        KeyEventFlags(), [.control], [.option], [.control, .option, .shift], [.control, .option, .command],
    ])
    func inexactModifiersPassThrough(flags: KeyEventFlags) {
        var matcher = HotkeyMatcher(binding: Keys.controlOption, undoBinding: nil)
        #expect(Self.match(&matcher, [Keys.down(Keys.space, flags), Keys.up(Keys.space, flags)]) == [.passThrough, .passThrough])
    }

    @Test func anAutorepeatWithoutAPressIsNotTheCombo() {
        var matcher = HotkeyMatcher(binding: Keys.controlOption, undoBinding: nil)
        // Space was already held when ⌃⌥ went down: the app has been seeing the key.
        let decisions = Self.match(&matcher, [
            Keys.down(Keys.space, [.control, .option], repeat: true),
            Keys.up(Keys.space, [.control, .option]),
        ])
        #expect(decisions == [.passThrough, .passThrough])
    }

    @Test func otherKeysDuringAComboAreLeftAlone() {
        var matcher = HotkeyMatcher(binding: Keys.controlOption, undoBinding: nil)
        let decisions = Self.match(&matcher, [
            Keys.down(Keys.space, [.control, .option]),
            Keys.down(Keys.keyA, [.control, .option]),
            Keys.flagsChanged(56, [.control, .option, .shift]),
        ])
        #expect(decisions.dropFirst().allSatisfy { $0 == .passThrough })
    }

    // MARK: - Undo

    @Test func theUndoComboIsSwallowedWithItsRepeatsAndRelease() {
        var matcher = HotkeyMatcher(binding: .defaultDictation, undoBinding: .defaultUndo)
        let decisions = Self.match(&matcher, [
            Keys.down(Keys.keyZ, [.control, .option]),
            Keys.down(Keys.keyZ, [.control, .option], repeat: true),
            Keys.up(Keys.keyZ, [.control, .option]),
            Keys.down(Keys.keyZ, [.command]), // ⌘Z is the app's own undo
            Keys.up(Keys.keyZ, [.command]),
        ])
        #expect(decisions == [HotkeyMatch(meaning: .undo, consumes: true), Self.swallowed, Self.swallowed, .passThrough, .passThrough])
    }

    @Test func aModifierOnlyUndoBindingIsIgnored() {
        var matcher = HotkeyMatcher(binding: Keys.controlOption, undoBinding: .modifierKey(.rightCommand))
        #expect(matcher.undoBinding == nil)
        #expect(matcher.match(Keys.flagsChanged(54, [.command, .rightCommand]), capturingEscape: false) == .passThrough)
    }

    @Test func anUndoBindingEqualToTheHotkeyIsIgnored() {
        var matcher = HotkeyMatcher(binding: .defaultUndo, undoBinding: .defaultUndo)
        #expect(matcher.undoBinding == nil)
        #expect(matcher.match(Keys.down(Keys.keyZ, [.control, .option]), capturingEscape: false).meaning == .hotkeyDown)
    }

    @Test func theHotkeyAndUndoMayShareAKey() {
        let dictation = HotkeyBinding.keyCombo(keyCode: Keys.keyZ, modifiers: [.command, .option])
        var matcher = HotkeyMatcher(binding: dictation, undoBinding: .defaultUndo)
        let decisions = Self.match(&matcher, [
            Keys.down(Keys.keyZ, [.control, .option]), Keys.up(Keys.keyZ),
            Keys.down(Keys.keyZ, [.command, .option]), Keys.up(Keys.keyZ),
        ])
        #expect(decisions.map(\.meaning) == [.undo, .none, .hotkeyDown, .hotkeyUp])
        #expect(decisions.allSatisfy { $0.consumes })
    }

    // MARK: - Esc

    @Test func escapeIsSwallowedOnlyWhileCapturing() {
        var matcher = HotkeyMatcher(binding: .defaultDictation, undoBinding: nil)
        let captured = Self.match(&matcher, [
            Keys.down(Keys.escape), Keys.down(Keys.escape, repeat: true), Keys.up(Keys.escape),
        ], capturingEscape: true)
        #expect(captured == [HotkeyMatch(meaning: .escape, consumes: true), Self.swallowed, Self.swallowed])

        let free = Self.match(&matcher, [Keys.down(Keys.escape), Keys.up(Keys.escape)])
        #expect(free == [HotkeyMatch(meaning: .escape, consumes: false), .passThrough])
    }

    @Test func anEscapeTheAppAlreadySawIsNotCutInHalf() {
        var matcher = HotkeyMatcher(binding: .defaultDictation, undoBinding: nil)
        #expect(matcher.match(Keys.down(Keys.escape), capturingEscape: false).consumes == false)
        // Capture turns on while Esc is still down: its repeats and key-up still reach the app.
        let later = Self.match(&matcher, [Keys.down(Keys.escape, repeat: true), Keys.up(Keys.escape)], capturingEscape: true)
        #expect(later == [.passThrough, .passThrough])
    }

    @Test func aSwallowedEscapeStaysSwallowedAfterCaptureEnds() {
        var matcher = HotkeyMatcher(binding: .defaultDictation, undoBinding: nil)
        _ = matcher.match(Keys.down(Keys.escape), capturingEscape: true)
        #expect(matcher.match(Keys.up(Keys.escape), capturingEscape: false) == Self.swallowed)
    }

    @Test func escapeWhileAModifierHotkeyIsHeldIsAnEscapeNotAnotherKey() {
        var matcher = HotkeyMatcher(binding: .defaultDictation, undoBinding: nil)
        _ = matcher.match(Keys.flagsChanged(63, [.secondaryFn]), capturingEscape: true)
        #expect(matcher.match(Keys.down(Keys.escape, [.secondaryFn]), capturingEscape: true).meaning == .escape)
    }

    // MARK: - Resynchronising after missed events

    @Test("A lost release is recovered", arguments: [HotkeyBinding.defaultDictation, Keys.controlOption])
    func resynchronizeReleases(binding: HotkeyBinding) {
        var matcher = HotkeyMatcher(binding: binding, undoBinding: nil)
        let press = switch binding {
        case .modifierKey(let key): Keys.flagsChanged(key.keyCode, key.heldFlag)
        case .keyCombo(let keyCode, _): Keys.down(keyCode, [.control, .option])
        }
        _ = matcher.match(press, capturingEscape: false)
        #expect(matcher.resynchronize(isKeyDown: { _ in true }, modifierFlags: []) == .none, "still held")
        #expect(matcher.isHotkeyHeld)
        #expect(matcher.resynchronize(isKeyDown: { _ in false }, modifierFlags: []) == .hotkeyUp)
        #expect(!matcher.isHotkeyHeld)
        #expect(matcher.resynchronize(isKeyDown: { _ in false }, modifierFlags: []) == .none)
    }

    /// Whether the key-state query reports fn is not documented, so its flag counts as well.
    @Test("A held modifier hotkey is kept if either the key state or its flag says so", arguments: ModifierKey.allCases)
    func resynchronizeTrustsEitherSignal(key: ModifierKey) {
        var matcher = HotkeyMatcher(binding: .modifierKey(key), undoBinding: nil)
        _ = matcher.match(Keys.flagsChanged(key.keyCode, key.heldFlag), capturingEscape: false)
        #expect(matcher.resynchronize(isKeyDown: { _ in false }, modifierFlags: key.heldFlag) == .none)
        #expect(matcher.resynchronize(isKeyDown: { $0 == key.keyCode }, modifierFlags: []) == .none)
        #expect(matcher.isHotkeyHeld)
    }

    @Test func resynchronizeIgnoresTheOtherSidesFlag() {
        var matcher = HotkeyMatcher(binding: .modifierKey(.rightOption), undoBinding: nil)
        _ = matcher.match(Keys.flagsChanged(61, [.option, .rightOption]), capturingEscape: false)
        // Right ⌥ went up unseen while left ⌥ is still held.
        #expect(matcher.resynchronize(isKeyDown: { $0 == 58 }, modifierFlags: [.option, .leftOption]) == .hotkeyUp)
    }

    @Test func resynchronizeForgetsSwallowedKeysThatWereReleased() {
        var matcher = HotkeyMatcher(binding: .defaultDictation, undoBinding: nil)
        _ = matcher.match(Keys.down(Keys.escape), capturingEscape: true)
        _ = matcher.resynchronize(isKeyDown: { _ in false }, modifierFlags: [])
        // A later repeat of an Esc pressed afresh (not captured) is no longer swallowed.
        #expect(matcher.match(Keys.down(Keys.escape, repeat: true), capturingEscape: false) == .passThrough)
    }

    @Test func resynchronizeKeepsSwallowedKeysThatAreStillDown() {
        var matcher = HotkeyMatcher(binding: .defaultDictation, undoBinding: .defaultUndo)
        _ = matcher.match(Keys.down(Keys.keyZ, [.control, .option]), capturingEscape: false)
        _ = matcher.resynchronize(isKeyDown: { $0 == Keys.keyZ }, modifierFlags: [.control, .option])
        #expect(matcher.match(Keys.up(Keys.keyZ), capturingEscape: false) == Self.swallowed)
    }
}
