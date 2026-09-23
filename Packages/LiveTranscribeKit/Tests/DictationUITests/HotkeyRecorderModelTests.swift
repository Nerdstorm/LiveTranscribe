@testable import DictationUI
import Hotkey
import Testing

@Suite("HotkeyRecorderModel")
struct HotkeyRecorderModelTests {
    // MARK: - Event helpers

    private static let fnCode: UInt16 = 63
    private static let rightCommandCode: UInt16 = 54
    private static let leftCommandCode: UInt16 = 55
    private static let leftOptionCode: UInt16 = 58
    private static let leftControlCode: UInt16 = 59
    private static let capsLockCode: UInt16 = 57
    private static let spaceCode: UInt16 = 49
    private static let zCode: UInt16 = 6
    private static let cCode: UInt16 = 8
    private static let escapeCode: UInt16 = 53

    /// A modifier going down or up; `others` are the flags of modifiers still held.
    private func flags(_ code: UInt16, down: Bool, others: KeyEventFlags = []) -> KeyEventInfo {
        KeyEventInfo(type: .flagsChanged, keyCode: code, flags: down ? others.union(Self.flagsFor(code)) : others, isAutorepeat: false)
    }

    private func key(_ code: UInt16, _ flags: KeyEventFlags = [], repeat isRepeat: Bool = false) -> KeyEventInfo {
        KeyEventInfo(type: .keyDown, keyCode: code, flags: flags, isAutorepeat: isRepeat)
    }

    /// The device-dependent and device-independent bits macOS sets while a modifier is down.
    private static func flagsFor(_ code: UInt16) -> KeyEventFlags {
        switch code {
        case fnCode: [.secondaryFn]
        case rightCommandCode: [.command, .rightCommand]
        case leftCommandCode: [.command, .leftCommand]
        case leftOptionCode: [.option, .leftOption]
        case leftControlCode: [.control, .leftControl]
        case capsLockCode: [.capsLock]
        default: []
        }
    }

    private func recorder(modifierOnly: Bool = true, other: HotkeyBinding? = nil) -> HotkeyRecorderModel {
        var model = HotkeyRecorderModel(configuration: .init(
            allowsModifierOnly: modifierOnly,
            otherShortcut: other,
            otherShortcutPurpose: "Undo AI edit"
        ))
        model.start()
        return model
    }

    private func feed(_ model: inout HotkeyRecorderModel, _ events: [KeyEventInfo]) -> [HotkeyRecorderModel.Outcome] {
        events.map { model.handle($0) }
    }

    // MARK: - Lone modifiers

    @Test func fnPressedAndReleasedAloneIsRecorded() {
        var model = recorder()
        let outcomes = feed(&model, [flags(Self.fnCode, down: true), flags(Self.fnCode, down: false)])
        #expect(outcomes == [.updated, .recorded(.modifierKey(.fn))])
        #expect(!model.isRecording)
        #expect(model.problem == nil)
    }

    @Test func rightCommandAloneIsRecorded() {
        var model = recorder()
        let outcomes = feed(&model, [flags(Self.rightCommandCode, down: true), flags(Self.rightCommandCode, down: false)])
        #expect(outcomes.last == .recorded(.modifierKey(.rightCommand)))
    }

    @Test func twoModifiersTogetherAreNotALoneModifier() {
        var model = recorder()
        let outcomes = feed(&model, [
            flags(Self.leftControlCode, down: true),
            flags(Self.leftOptionCode, down: true, others: Self.flagsFor(Self.leftControlCode)),
            flags(Self.leftOptionCode, down: false, others: Self.flagsFor(Self.leftControlCode)),
            flags(Self.leftControlCode, down: false),
        ])
        #expect(!outcomes.contains { if case .recorded = $0 { true } else { false } })
        #expect(model.isRecording)
    }

    @Test func rollingOffAChordInEitherOrderRecordsNothing() {
        // ⌃ then ⌥ down, ⌃ released first: the ⌥ left held was never pressed on its own.
        var model = recorder()
        let outcomes = feed(&model, [
            flags(Self.leftControlCode, down: true),
            flags(Self.leftOptionCode, down: true, others: Self.flagsFor(Self.leftControlCode)),
            flags(Self.leftControlCode, down: false, others: Self.flagsFor(Self.leftOptionCode)),
            flags(Self.leftOptionCode, down: false),
        ])
        #expect(!outcomes.contains { if case .recorded = $0 { true } else { false } })
        #expect(model.isRecording)
    }

    @Test func aModifierHeldBeforeRecordingStartedIsNotRecorded() {
        var model = recorder()
        // Only its release is seen.
        let outcome = model.handle(flags(Self.leftOptionCode, down: false))
        #expect(outcome == .updated)
        #expect(model.isRecording)
    }

    @Test func aKeyPressedWhileTheModifierIsHeldCancelsTheLoneModifier() {
        var model = recorder()
        let outcomes = feed(&model, [
            flags(Self.fnCode, down: true),
            key(123, [.secondaryFn, .numericPad]), // fn+← is a shortcut, not the fn hotkey
            flags(Self.fnCode, down: false),
        ])
        #expect(outcomes == [.updated, .updated, .updated])
        #expect(model.problem == .invalidCombination(.needsCommandOptionOrControl))
        #expect(model.isRecording)
    }

    @Test func leftCommandAloneIsRefusedWithAReason() {
        var model = recorder()
        _ = feed(&model, [flags(Self.leftCommandCode, down: true), flags(Self.leftCommandCode, down: false)])
        #expect(model.problem == .modifierNotAllowedAlone)
        #expect(model.isRecording)
    }

    @Test func undoRecorderRefusesALoneModifier() {
        var model = recorder(modifierOnly: false)
        _ = feed(&model, [flags(Self.fnCode, down: true), flags(Self.fnCode, down: false)])
        #expect(model.problem == .needsKeyCombination)
        #expect(model.isRecording)
    }

    @Test func undoRecorderAsksForACombinationEvenForLeftCommand() {
        // Not "try fn or a key on the right": this recorder refuses those too.
        var model = recorder(modifierOnly: false)
        _ = feed(&model, [flags(Self.leftCommandCode, down: true), flags(Self.leftCommandCode, down: false)])
        #expect(model.problem == .needsKeyCombination)
    }

    @Test func capsLockIsIgnored() {
        var model = recorder()
        #expect(model.handle(flags(Self.capsLockCode, down: true)) == .ignored)
        #expect(model.isRecording)
    }

    @Test func heldModifiersArePreviewed() {
        var model = recorder()
        _ = model.handle(flags(Self.leftControlCode, down: true))
        _ = model.handle(flags(Self.leftOptionCode, down: true, others: Self.flagsFor(Self.leftControlCode)))
        #expect(model.heldModifiersDisplay == "⌃⌥")
        _ = model.handle(flags(Self.fnCode, down: true))
        #expect(model.heldModifiersDisplay == "fn")
    }

    // MARK: - Key combinations

    @Test func aValidCombinationIsRecorded() {
        var model = recorder()
        let outcome = model.handle(key(Self.spaceCode, [.control, .leftControl, .option, .leftOption]))
        #expect(outcome == .recorded(.keyCombo(keyCode: Self.spaceCode, modifiers: [.control, .option])))
        #expect(!model.isRecording)
    }

    @Test func aPlainKeyIsRefusedAndRecordingContinues() {
        var model = recorder()
        #expect(model.handle(key(Self.spaceCode)) == .updated)
        #expect(model.problem == .invalidCombination(.needsCommandOptionOrControl))
        #expect(model.isRecording)
        // The next attempt can succeed, and clears the problem.
        #expect(model.handle(key(Self.zCode, [.command, .option])) == .recorded(.keyCombo(keyCode: Self.zCode, modifiers: [.command, .option])))
        #expect(model.problem == nil)
    }

    @Test("A standard shortcut is refused by name and recording continues", arguments: [true, false])
    func aStandardShortcutIsRefused(modifierOnly: Bool) {
        // Both recorders: the dictation and the undo shortcut would each take ⌘C from every app.
        var model = recorder(modifierOnly: modifierOnly)
        #expect(model.handle(key(Self.cCode, [.command, .leftCommand])) == .updated)
        #expect(model.problem == .invalidCombination(.reserved(shortcut: "⌘C", action: "Copy")))
        #expect(model.problem?.message == "⌘C is the standard macOS shortcut for Copy. Choose another combination.")
        #expect(model.isRecording)
    }

    @Test func shiftAloneDoesNotGuardACombination() {
        var model = recorder()
        _ = model.handle(key(Self.zCode, [.shift, .leftShift]))
        #expect(model.problem == .invalidCombination(.needsCommandOptionOrControl))
    }

    @Test func theOtherShortcutIsRefused() {
        var model = recorder(other: .defaultUndo)
        #expect(model.handle(key(Self.zCode, [.control, .option])) == .updated)
        #expect(model.problem == .alreadyUsed(purpose: "Undo AI edit"))
        #expect(model.isRecording)
    }

    @Test func autorepeatIsIgnored() {
        var model = recorder()
        #expect(model.handle(key(Self.spaceCode, repeat: true)) == .ignored)
        #expect(model.problem == nil)
    }

    // MARK: - Esc, cancel and idle

    @Test func escCancels() {
        var model = recorder()
        #expect(model.handle(key(Self.escapeCode)) == .cancelled)
        #expect(!model.isRecording)
    }

    @Test func escWithAModifierIsTreatedAsACombination() {
        var model = recorder()
        let outcome = model.handle(key(Self.escapeCode, [.control, .option]))
        #expect(outcome == .recorded(.keyCombo(keyCode: Self.escapeCode, modifiers: [.control, .option])))
    }

    @Test func eventsAreIgnoredWhenNotRecording() {
        var model = HotkeyRecorderModel(configuration: .init(allowsModifierOnly: true, otherShortcut: nil, otherShortcutPurpose: ""))
        #expect(model.handle(key(Self.zCode, [.command])) == .ignored)
        #expect(!model.swallows(key(Self.zCode, [.command])))
        #expect(model.cancel() == .ignored)
    }

    @Test func onlyKeyPressesAreSwallowedWhileRecording() {
        let model = recorder()
        #expect(model.swallows(key(Self.zCode)))
        #expect(!model.swallows(flags(Self.fnCode, down: true)))
    }

    @Test func startingAgainClearsTheProblem() {
        var model = recorder()
        _ = model.handle(key(Self.spaceCode))
        #expect(model.problem != nil)
        #expect(model.cancel() == .cancelled)
        model.start()
        #expect(model.problem == nil)
        #expect(model.isRecording)
    }

    // MARK: - Reset

    @Test func resetStoresTheDefaultAndEndsRecording() {
        var model = recorder(other: .defaultDictation)
        _ = model.handle(key(Self.spaceCode))
        #expect(model.reset(to: .defaultUndo) == .defaultUndo)
        #expect(!model.isRecording)
        #expect(model.problem == nil)
    }

    @Test func resetToTheOtherShortcutIsRefused() {
        // Dictation was moved to ⌃⌥Z, so resetting undo to ⌃⌥Z would silently turn undo off.
        var model = recorder(modifierOnly: false, other: .defaultUndo)
        #expect(model.reset(to: .defaultUndo) == nil)
        #expect(model.problem == .alreadyUsed(purpose: "Undo AI edit"))
        #expect(!model.isRecording)
    }

    // MARK: - Stored values

    @Test func aStoredValueFallsBackToTheDefaultWhenDamaged() {
        #expect(HotkeyRecorderModel.binding(storage: "modifier:rightOption", fallback: .defaultDictation) == .modifierKey(.rightOption))
        #expect(HotkeyRecorderModel.binding(storage: "nonsense", fallback: .defaultDictation) == .defaultDictation)
        #expect(HotkeyRecorderModel.binding(storage: "combo:49:shift", fallback: .defaultUndo) == .defaultUndo)
    }

    @Test func everyProblemHasAMessage() {
        let problems: [HotkeyRecorderModel.Problem] = [
            .invalidCombination(.needsCommandOptionOrControl), .invalidCombination(.modifierAsMainKey),
            .invalidCombination(.reserved(shortcut: "⌘C", action: "Copy")),
            .needsKeyCombination, .modifierNotAllowedAlone, .alreadyUsed(purpose: "dictation"),
        ]
        for problem in problems {
            #expect(!problem.message.isEmpty)
        }
        #expect(HotkeyRecorderModel.Problem.alreadyUsed(purpose: "dictation").message.contains("dictation"))
    }
}
