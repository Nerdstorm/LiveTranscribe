@testable import Dictation
import Foundation
import Hotkey
import Testing

/// Pausing the shortcuts while Settings records a new one: the tap must not see the keys, and
/// the shortcuts must always come back.
@MainActor
@Suite("DictationController hotkey suspension")
struct DictationControllerSuspensionTests {
    private let fn = HotkeyBinding.defaultDictation.displayName

    @Test func suspendingStopsTheShortcutsAndEndingRestartsThem() async {
        let h = Harness()
        h.controller.start()
        #expect(h.hotkeys.isRunning)

        let suspension = h.controller.suspendHotkeys()
        #expect(!h.hotkeys.isRunning, "fn goes to the recorder, not the tap")
        #expect(h.controller.hotkeysSuspended)
        #expect(h.controller.hotkeyState == .running(hotkey: fn), "the menu still offers the shortcut")

        suspension.end()
        #expect(!h.controller.hotkeysSuspended)
        #expect(h.hotkeys.startedBindings == [.defaultDictation, .defaultDictation])
        #expect(h.hotkeys.send(.pressed), "the monitor runs again")
        #expect(await eventually { h.controller.phase == .recording(handsFree: false) }, "and its events arrive")
        h.controller.cancel()
        await h.controller.settle()
    }

    @Test func overlappingSuspensionsResumeAfterTheLastOne() {
        let h = Harness()
        h.controller.start()
        let first = h.controller.suspendHotkeys()
        let second = h.controller.suspendHotkeys()
        #expect(h.hotkeys.startedBindings.count == 1)

        first.end()
        first.end()
        #expect(!h.hotkeys.isRunning, "ending one twice does not end the other")
        #expect(h.controller.hotkeysSuspended)

        second.end()
        #expect(h.hotkeys.isRunning)
        #expect(h.hotkeys.startedBindings.count == 2)
    }

    @Test func aRecordingInProgressIsDiscardedSilently() async throws {
        let h = Harness()
        h.controller.start()
        await h.hold(milliseconds: 500)
        #expect(h.controller.phase == .recording(handsFree: false))

        let suspension = h.controller.suspendHotkeys()
        await h.controller.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.controller.notice == nil)
        #expect(await !h.source.isOpen)
        await h.release()
        #expect(await h.delivery.inserted.isEmpty)
        #expect(try await h.history.all().isEmpty)

        suspension.end()
        await h.hold(milliseconds: 500)
        await h.release()
        #expect(await h.delivery.inserted == ["Ship it on friday."], "the next dictation works")
    }

    @Test func aMenuDictationInProgressIsDiscardedSilently() async {
        let h = Harness()
        h.controller.start()
        h.controller.toggleDictation()
        await h.controller.settle()
        #expect(h.controller.phase == .recording(handsFree: true))

        let suspension = h.controller.suspendHotkeys()
        await h.controller.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.controller.notice == nil)
        #expect(await !h.source.isOpen)
        suspension.end()
    }

    @Test func aPressQueuedJustBeforeSuspendingNeverOpensTheMicrophone() async {
        let h = Harness()
        h.controller.start()
        h.controller.handle(.pressed)
        let suspension = h.controller.suspendHotkeys()
        await h.controller.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.controller.notice == nil)
        #expect(await h.source.starts == 0)
        suspension.end()
    }

    @Test func theMenuCannotStartADictationWhileSuspended() async {
        let h = Harness()
        h.focus.set(FakeFocus.field(caret: CGRect(x: 10, y: 20, width: 2, height: 16)))
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        #expect(h.controller.caretRect != nil)

        let suspension = h.controller.suspendHotkeys()
        h.controller.toggleDictation()
        await h.controller.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.controller.notice == .recordingShortcut)
        #expect(h.controller.caretRect == nil, "the notice is not placed at the last dictation's caret")
        #expect(await h.source.starts == 1, "only the first dictation opened the microphone")
        suspension.end()
    }

    @Test func settingsAppliedWhileSuspendedTakeEffectOnResume() {
        let settings = SettingsBox()
        let h = Harness(settings: settings)
        h.controller.start()
        let suspension = h.controller.suspendHotkeys()

        settings.update { $0.dictation.hotkey = HotkeyBinding.modifierKey(.rightOption).storageString }
        h.controller.applySettings()
        #expect(!h.hotkeys.isRunning, "applying settings does not restart the tap mid-recording")
        #expect(h.hotkeys.startedBindings == [.defaultDictation])

        suspension.end()
        #expect(h.hotkeys.startedBindings == [.defaultDictation, .modifierKey(.rightOption)])
        #expect(h.controller.hotkeyState == .running(hotkey: HotkeyBinding.modifierKey(.rightOption).displayName))
    }

    @Test func turningDictationOffWhileSuspendedShowsAtOnceAndLasts() {
        let settings = SettingsBox()
        let h = Harness(settings: settings)
        h.controller.start()
        let suspension = h.controller.suspendHotkeys()

        settings.update { $0.dictation.enabled = false }
        h.controller.applySettings()
        #expect(h.controller.hotkeyState == .disabled)

        suspension.end()
        #expect(!h.hotkeys.isRunning)
        #expect(h.controller.hotkeyState == .disabled)
    }

    @Test func aSuspensionDroppedWithoutEndingStillResumes() async {
        let h = Harness()
        h.controller.start()
        _ = h.controller.suspendHotkeys()
        #expect(!h.hotkeys.isRunning, "paused until the dropped suspension ends itself")
        #expect(await eventually { h.hotkeys.isRunning })
        #expect(!h.controller.hotkeysSuspended)
    }

    @Test func aStoppedControllerDoesNotRestartOnResume() {
        let h = Harness()
        h.controller.start()
        let suspension = h.controller.suspendHotkeys()
        h.controller.stop()
        suspension.end()
        #expect(!h.hotkeys.isRunning)
        #expect(h.controller.hotkeyState == .stopped)
    }

    @Test func startingWhileSuspendedWaitsForTheResume() {
        let h = Harness()
        let suspension = h.controller.suspendHotkeys()
        h.controller.start()
        #expect(h.hotkeys.startedBindings.isEmpty)

        suspension.end()
        #expect(h.hotkeys.isRunning)
        #expect(h.controller.hotkeyState == .running(hotkey: fn))
    }
}

@MainActor
@Suite("HotkeySuspension")
struct HotkeySuspensionTests {
    /// Counts how often a suspension ended.
    @MainActor
    private final class Ends {
        var count = 0
    }

    @Test func endsOnceHoweverOftenItIsEnded() {
        let ends = Ends()
        let suspension = HotkeySuspension { ends.count += 1 }
        #expect(suspension.isActive)
        suspension.end()
        suspension.end()
        #expect(ends.count == 1)
        #expect(!suspension.isActive)
    }

    @Test func oneDroppedWithoutEndingEndsItself() async {
        let ends = Ends()
        _ = HotkeySuspension { ends.count += 1 }
        #expect(ends.count == 0, "ended on the next turn of the main actor, not inside deinit")
        #expect(await eventually { ends.count == 1 })
    }

    @Test func oneEndedAndDroppedDoesNotEndAgain() async throws {
        let ends = Ends()
        HotkeySuspension { ends.count += 1 }.end()
        try await Task.sleep(for: .milliseconds(20))
        #expect(ends.count == 1)
    }
}
