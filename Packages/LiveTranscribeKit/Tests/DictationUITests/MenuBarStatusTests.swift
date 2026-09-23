import AppKit
import Capture
import Dictation
@testable import DictationUI
import Session
import Shared
import Testing

@Suite("Menu bar status")
struct MenuBarStatusTests {
    private func status(
        phase: DictationController.Phase = .idle,
        hotkey: HotkeyState = .running(hotkey: "fn (🌐)"),
        session: SessionPhase = .ready,
        progress: [ModelLoadProgress] = [],
        microphone: MicrophonePermissionStatus = .granted,
        hasLastDictation: Bool = true
    ) -> MenuBarStatus {
        MenuBarStatus(
            phase: phase, hotkey: hotkey, session: session, modelProgress: progress, microphone: microphone,
            hasLastDictation: hasLastDictation
        )
    }

    private static let everyIndicator: [MenuBarIndicator] = [
        .ready(hotkey: "fn (🌐)"), .recording(handsFree: false), .recording(handsFree: true), .processing,
        .needsAccessibility, .needsMicrophone, .hotkeyFailed("x"), .modelsFailed("x"),
        .modelsLoading(percent: nil), .modelsLoading(percent: 5), .modelsNotLoaded, .liveTranscriptRunning, .off,
    ]

    // MARK: - Status line

    @Test func readyNamesTheHotkey() {
        #expect(status().indicator == .ready(hotkey: "fn (🌐)"))
        #expect(status().indicator.statusText == "Hold fn (🌐) to dictate")
    }

    @Test func aDictationInProgressOutranksEverythingElse() {
        let busy = status(phase: .recording(handsFree: true), hotkey: .needsAccessibility, session: .loading, microphone: .denied)
        #expect(busy.indicator == .recording(handsFree: true))
        #expect(busy.indicator.statusText == "Listening, hands-free…")
        #expect(status(phase: .recording(handsFree: false)).indicator.statusText == "Listening…")
        #expect(status(phase: .processing, hotkey: .failed("x")).indicator.statusText == "Transcribing…")
    }

    @Test func missingPermissionsOutrankLoadingModels() {
        #expect(status(hotkey: .needsAccessibility, session: .loading).indicator == .needsAccessibility)
        #expect(status(session: .loading, microphone: .denied).indicator == .needsMicrophone)
        #expect(status(hotkey: .needsAccessibility).indicator.statusText == "Dictation needs Accessibility access")
        #expect(status(microphone: .denied).indicator.statusText == "Dictation needs microphone access")
    }

    @Test func anUndecidedMicrophoneIsNotAProblem() {
        // The first dictation shows the system prompt.
        #expect(status(microphone: .undetermined).indicator == .ready(hotkey: "fn (🌐)"))
    }

    @Test func failuresShowTheirDetail() {
        #expect(status(hotkey: .failed("The event tap failed")).indicator.statusText
            == "The dictation shortcut couldn't start: The event tap failed")
        let failed = status(session: .failed(.modelLoadFailed(model: "parakeet", message: "No network")))
        #expect(failed.indicator.statusText == "Speech-to-text isn't available: No network")
        #expect(failed.indicator.needsAttention)
    }

    @Test func longOrMultilineDetailIsShortenedToOneLine() {
        let detail = String(repeating: "word ", count: 40) + "\nsecond line"
        let text = MenuBarIndicator.modelsFailed(detail).statusText
        #expect(!text.contains("\n"))
        #expect(text.hasSuffix("…"))
        #expect(text.count <= "Speech-to-text isn't available: ".count + 80)
        #expect(MenuBarIndicator.shortened("short") == "short")
    }

    @Test func loadingModelsShowsDownloadProgress() {
        let progress = [
            ModelLoadProgress(modelID: "stt", stage: .downloading, fractionCompleted: 0.8),
            ModelLoadProgress(modelID: "llm", stage: .downloading, fractionCompleted: 0.426),
            ModelLoadProgress(modelID: "vad", stage: .ready),
        ]
        #expect(status(session: .loading, progress: progress).indicator.statusText == "Downloading speech models… 42%")
        #expect(status(session: .loading).indicator.statusText == "Loading speech models…")
        #expect(status(session: .notLoaded).indicator.statusText == "Speech models aren't loaded")
    }

    @Test func downloadPercentFollowsTheSlowestDownload() {
        #expect(MenuBarStatus.downloadPercent([]) == nil)
        #expect(MenuBarStatus.downloadPercent([ModelLoadProgress(modelID: "a", stage: .loading, fractionCompleted: 0.5)]) == nil)
        #expect(MenuBarStatus.downloadPercent([ModelLoadProgress(modelID: "a", stage: .downloading)]) == nil)
        #expect(MenuBarStatus.downloadPercent([
            ModelLoadProgress(modelID: "a", stage: .downloading, fractionCompleted: 1),
            ModelLoadProgress(modelID: "b", stage: .downloading, fractionCompleted: 0.999),
        ]) == 99)
    }

    @Test func theLiveTranscriptBlocksDictation() {
        for session in [SessionPhase.listening, .stopping] {
            let blocked = status(session: session)
            #expect(blocked.indicator.statusText == "Stop the live transcript to dictate")
            #expect(!blocked.canToggleDictation)
        }
    }

    @Test func aStoppedOrDisabledHotkeySaysDictationIsOff() {
        #expect(status(hotkey: .disabled).indicator.statusText == "Dictation is off")
        #expect(status(hotkey: .stopped).indicator == .off)
    }

    @Test func dictationTurnedOffOutranksWhatWouldNotTurnItBackOn() {
        // Stopping the live transcript, loading models or allowing the microphone would not
        // start a dictation someone switched off, so the menu says it is off.
        for session in [SessionPhase.listening, .loading, .notLoaded, .failed(.modelLoadFailed(model: "m", message: "x"))] {
            #expect(status(hotkey: .disabled, session: session).indicator == .off, "\(session)")
        }
        #expect(status(hotkey: .disabled, microphone: .denied).indicator == .off)
        // A dictation started from the menu still shows while the shortcut is off.
        #expect(status(phase: .recording(handsFree: true), hotkey: .disabled).indicator == .recording(handsFree: true))
        // Not started yet (launch) stays below the models, which say more.
        #expect(status(hotkey: .stopped, session: .loading).indicator == .modelsLoading(percent: nil))
    }

    // MARK: - Controls

    @Test func startIsOfferedOnlyOnceTheModelsAreLoaded() {
        let ready = status()
        #expect(ready.toggleTitle == "Start Dictation")
        #expect(ready.canToggleDictation)
        #expect(!ready.canCancel)
        #expect(ready.canUndo)
        for session in [SessionPhase.notLoaded, .loading, .failed(.modelLoadFailed(model: "m", message: "x"))] {
            #expect(!status(session: session).canToggleDictation)
        }
        // A live transcript that failed to capture or save leaves the models loaded.
        for failure in [SessionFailure.microphonePermissionDenied, .audioCaptureFailed(message: "x"), .persistenceFailed(message: "x")] {
            #expect(MenuBarStatus.dictationCanStart(session: .failed(failure)))
        }
    }

    @Test func undoAndCopyNeedADictationFirst() {
        let fresh = status(hasLastDictation: false)
        #expect(!fresh.canUndo)
        #expect(!fresh.canCopyLastDictation)
        let dictated = status(hasLastDictation: true)
        #expect(dictated.canUndo)
        #expect(dictated.canCopyLastDictation)
        // Copying is fine during a dictation; undoing is not.
        #expect(status(phase: .processing, hasLastDictation: true).canCopyLastDictation)
    }

    @Test func aRecordingCanBeStoppedOrCancelledButNotUndone() {
        let recording = status(phase: .recording(handsFree: true), session: .loading)
        #expect(recording.toggleTitle == "Stop Dictation")
        #expect(recording.canToggleDictation)
        #expect(recording.canCancel)
        #expect(!recording.canUndo)
    }

    @Test func processingCanOnlyBeCancelled() {
        let processing = status(phase: .processing)
        #expect(!processing.canToggleDictation)
        #expect(processing.canCancel)
        #expect(!processing.canUndo)
    }

    @Test func undoNamesTheShortcutTheMonitorRuns() {
        let fn = "modifier:fn"
        #expect(MenuBarStatus.undoTitle(undoHotkey: "combo:6:control,option", dictationHotkey: fn, hotkey: .running(hotkey: "fn"))
            == "Undo AI Edit (⌃⌥Z)")
        // Unreadable values fall back to the defaults, as the controller does.
        #expect(MenuBarStatus.undoTitle(undoHotkey: "garbage", dictationHotkey: "garbage", hotkey: .running(hotkey: "fn"))
            == "Undo AI Edit (⌃⌥Z)")
        // No shortcut while the monitor is not running, or when it ignores the binding.
        #expect(MenuBarStatus.undoTitle(undoHotkey: "combo:6:control,option", dictationHotkey: fn, hotkey: .disabled)
            == "Undo AI Edit")
        #expect(MenuBarStatus.undoTitle(undoHotkey: "combo:6:control,option", dictationHotkey: "combo:6:control,option",
                                        hotkey: .running(hotkey: "⌃⌥Z")) == "Undo AI Edit")
        #expect(MenuBarStatus.undoTitle(undoHotkey: "modifier:rightOption", dictationHotkey: fn, hotkey: .running(hotkey: "fn"))
            == "Undo AI Edit")
    }

    // MARK: - Icon

    @Test func everyStateHasAnIconThatExists() {
        for indicator in Self.everyIndicator {
            #expect(NSImage(systemSymbolName: indicator.symbolName, accessibilityDescription: nil) != nil, "\(indicator)")
            #expect(indicator.accessibilityLabel.hasPrefix("Live Transcribe, "))
            #expect(!indicator.statusText.isEmpty)
        }
    }

    @Test func theIconFollowsTheDictationState() {
        func symbol(
            _ phase: DictationController.Phase = .idle,
            hotkey: HotkeyState = .running(hotkey: "fn (🌐)"),
            session: SessionPhase = .ready
        ) -> String {
            status(phase: phase, hotkey: hotkey, session: session).indicator.symbolName
        }
        #expect(symbol() == "waveform")
        #expect(symbol(.recording(handsFree: false)) == "mic.fill")
        #expect(symbol(.recording(handsFree: true)) == "mic.fill")
        #expect(symbol(.processing) == "ellipsis.circle")
        #expect(symbol(hotkey: .needsAccessibility) == "exclamationmark.triangle")
        #expect(symbol(hotkey: .failed("x")) == "exclamationmark.triangle")
        #expect(symbol(session: .loading) == "arrow.down.circle")
        #expect(symbol(session: .listening) == "captions.bubble")
        #expect(symbol(hotkey: .disabled) == "mic.slash")
        #expect(status(phase: .idle).indicator.accessibilityLabel == "Live Transcribe, ready")
        #expect(status(phase: .recording(handsFree: false)).indicator.accessibilityLabel == "Live Transcribe, listening")
    }

    @Test func iconsTellTheMainStatesApart() {
        let symbols = [
            MenuBarIndicator.ready(hotkey: "fn").symbolName,
            MenuBarIndicator.recording(handsFree: false).symbolName,
            MenuBarIndicator.processing.symbolName,
            MenuBarIndicator.needsAccessibility.symbolName,
            MenuBarIndicator.modelsLoading(percent: nil).symbolName,
        ]
        #expect(Set(symbols).count == symbols.count)
        for indicator in Self.everyIndicator where indicator.needsAttention {
            #expect(indicator.symbolName == MenuBarIndicator.needsAccessibility.symbolName)
            #expect(indicator.accessibilityLabel == "Live Transcribe, needs attention")
        }
    }
}
