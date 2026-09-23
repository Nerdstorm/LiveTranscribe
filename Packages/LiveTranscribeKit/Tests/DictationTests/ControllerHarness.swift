import Capture
@testable import Dictation
import Foundation
import Hotkey
import Permissions
import Persistence
import Shared

/// A controller wired to fakes, with handles on each.
@MainActor
struct Harness {
    let controller: DictationController
    let clock = ManualClock()
    let hotkeys = FakeHotkeyMonitor()
    let source = ScriptedAudioSource()
    let transcriber: FakeTranscriber
    let focus = FakeFocus()
    let delivery = FakeDelivery()
    let history = MemoryDictationHistory()
    let accessibility: FakeAccessibility

    init(
        transcript: String = "ship it on friday",
        readiness: DictationReadiness = .ready,
        microphone: MicrophonePermissionStatus = .granted,
        accessibilityGranted: Bool = true,
        configure: (inout AppSettings) -> Void = { _ in }
    ) {
        self.init(
            transcript: transcript,
            readiness: ReadinessSwitch(readiness),
            microphone: microphone,
            accessibilityGranted: accessibilityGranted,
            settings: SettingsBox(),
            configure: configure
        )
    }

    init(readiness: ReadinessSwitch) {
        self.init(readiness: readiness, settings: SettingsBox())
    }

    init(settings: SettingsBox) {
        self.init(readiness: ReadinessSwitch(.ready), settings: settings)
    }

    init(
        transcript: String = "ship it on friday",
        readiness: ReadinessSwitch,
        microphone: MicrophonePermissionStatus = .granted,
        accessibilityGranted: Bool = true,
        settings: SettingsBox,
        configure: (inout AppSettings) -> Void = { _ in }
    ) {
        settings.update {
            $0.cleanupLevel = .medium
            $0.dictation.tapMaxMs = 300
            $0.dictation.doubleTapWindowMs = 40
            $0.dictation.minUtteranceMs = 100
            configure(&$0)
        }
        transcriber = FakeTranscriber(transcript: transcript)
        accessibility = FakeAccessibility(granted: accessibilityGranted)
        let source = self.source
        let clock = self.clock
        let processor = DictationProcessor(transcriber: transcriber, cleaner: ScriptedCleaner { text in
            text.prefix(1).uppercased() + text.dropFirst() + "."
        })
        controller = DictationController(dependencies: .init(
            hotkeys: hotkeys,
            recorder: DictationRecorder(makeSource: { _ in source }, configuration: .init(preRollMs: 0, maxDurationSeconds: 60)),
            processor: processor,
            focus: focus,
            delivery: delivery,
            history: history,
            snippets: { [] },
            vocabulary: { [] },
            settings: { settings.current },
            readiness: { readiness.current },
            microphonePermission: FakeMicrophone(current: microphone),
            accessibility: accessibility,
            now: { clock.now() }
        ))
        if !accessibilityGranted { hotkeys.denyPermission(true) }
    }

    /// Presses the hotkey, speaks `milliseconds` of audio, and holds for that long.
    func hold(milliseconds: Int) async {
        controller.handle(.pressed)
        await controller.settle()
        await source.push([Float](repeating: 0.1, count: AudioFormat.samples(forMilliseconds: milliseconds)))
        try? await Task.sleep(for: .milliseconds(20))
        clock.advance(by: .milliseconds(milliseconds))
    }

    func release() async {
        controller.handle(.released)
        await controller.settle()
    }
}

/// Waits up to a second for `condition`, checking every few milliseconds: for work the
/// controller hands to a task, such as events from the hotkey monitor.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
