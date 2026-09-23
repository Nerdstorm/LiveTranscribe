@testable import Dictation
import Foundation
import Hotkey
import Testing

/// Starting, restarting and stopping the hotkey monitor: which settings it runs with, and that
/// nothing from a monitor that has stopped reaches the dictation.
@MainActor
@Suite("DictationController hotkey lifecycle")
struct DictationHotkeyLifecycleTests {
    @Test func theHotkeyWaitsForAccessibility() async throws {
        let h = Harness(accessibilityGranted: false)
        h.controller.start()
        #expect(h.controller.hotkeyState == .needsAccessibility)
        h.hotkeys.denyPermission(false)
        h.accessibility.set(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.hotkeyState == .running(hotkey: HotkeyBinding.defaultDictation.displayName))
    }

    @Test func aDisabledHotkeyDoesNotStart() {
        let h = Harness { $0.dictation.enabled = false }
        h.controller.start()
        #expect(h.controller.hotkeyState == .disabled)
        #expect(h.hotkeys.startedBindings.isEmpty)
    }

    @Test func settingsThatKeepTheBindingsDoNotRestartTheHotkey() async {
        let settings = SettingsBox()
        let h = Harness(settings: settings)
        h.controller.start()
        settings.update { $0.cleanupLevel = .high }
        h.controller.applySettings()
        #expect(h.hotkeys.startedBindings.count == 1)

        settings.update { $0.dictation.hotkey = HotkeyBinding.modifierKey(.rightOption).storageString }
        h.controller.applySettings()
        #expect(h.hotkeys.startedBindings == [.defaultDictation, .modifierKey(.rightOption)])
    }

    @Test func timingChangedMidGestureAppliesOnceItEnds() async throws {
        let settings = SettingsBox()
        let h = Harness(settings: settings)
        h.controller.start()
        await h.hold(milliseconds: 100)
        settings.update { $0.dictation.handsFreeEnabled = false }
        h.controller.applySettings()
        await h.release()
        // Still the old timing: the tap waits for a second press.
        #expect(h.controller.phase == .recording(handsFree: false))
        try await Task.sleep(for: .milliseconds(120))
        await h.controller.settle()
        #expect(h.controller.phase == .idle)

        await h.hold(milliseconds: 100)
        await h.release()
        #expect(h.controller.phase == .idle, "with hands-free off a tap is cancelled at once")
    }

    // MARK: - Events from a stopped monitor

    @Test func aPressFromTheOldShortcutIsDroppedWhenTheShortcutChanges() async {
        let settings = SettingsBox()
        let h = Harness(settings: settings)
        h.controller.start()
        // fn goes down just as Settings switches the shortcut to right ⌥: the old monitor's press
        // has not been handled yet, and the new monitor will never report fn's release.
        #expect(h.hotkeys.send(.pressed))
        settings.update { $0.dictation.hotkey = HotkeyBinding.modifierKey(.rightOption).storageString }
        h.controller.applySettings()

        try? await Task.sleep(for: .milliseconds(20))
        await h.controller.settle()
        #expect(h.controller.phase == .idle, "a recording nothing can release would run to the time limit")
        #expect(await h.source.starts == 0)
    }

    @Test func anUndoFromThePausedMonitorIsDropped() async {
        let h = Harness(transcript: "um ship it on friday")
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        // ⌃⌥Z arrives just as a shortcut recorder pauses the shortcuts.
        #expect(h.hotkeys.send(.undo))
        let suspension = h.controller.suspendHotkeys()

        try? await Task.sleep(for: .milliseconds(20))
        await h.controller.settle()
        #expect(await h.delivery.undone.isEmpty, "the recorder has the keyboard now")
        suspension.end()
    }

    // MARK: - Stopped

    @Test func settingsAppliedAfterStoppingStartNothing() async {
        let h = Harness { $0.dictation.keepMicrophoneReady = true }
        h.controller.start()
        await h.controller.settle()
        #expect(await h.source.isOpen, "kept ready while started")

        h.controller.stop()
        h.controller.applySettings()
        await h.controller.settle()
        #expect(!h.hotkeys.isRunning)
        #expect(h.hotkeys.startedBindings.count == 1)
        #expect(h.controller.hotkeyState == .stopped)
        #expect(await !h.source.isOpen, "the microphone stays released")
    }
}
