import Capture
import Cleanup
import Foundation
import MLXSupport
import Persistence
import Segmentation
import Session
import Shared
import Testing
import Transcription

extension Tag {
    /// Needs downloaded models and a GPU; opt in with LT_RUN_MODEL_TESTS=1.
    @Tag static var models: Self
}

private let modelTestsEnabled = ProcessInfo.processInfo.environment["LT_RUN_MODEL_TESTS"] == "1"

private struct GrantedMicrophone: MicrophonePermissionProviding {
    func status() -> MicrophonePermissionStatus { .granted }
    func request() async -> Bool { true }
}

@Suite(
    "End to end with real models",
    .tags(.models),
    .enabled(if: modelTestsEnabled, "set LT_RUN_MODEL_TESTS=1 (TEST_RUNNER_LT_RUN_MODEL_TESTS=1 with xcodebuild)"),
    .serialized
)
struct EndToEndTests {
    @Test(.timeLimit(.minutes(30)))
    func everyFixtureProducesAJSONLTranscriptWithoutStageErrors() async throws {
        let settings = AppSettings.defaults
        MLXRuntime.configure(gpuCacheLimitMB: settings.gpuCacheLimitMB)
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("Audio")
        let clips = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!clips.isEmpty, "No test audio: run scripts/generate-test-audio.sh, then rebuild the tests")

        // Loaded once, shared by every clip's session.
        let segmenter = SileroSegmenter(modelID: settings.vadModel, config: SegmentationConfig(settings: settings))
        let transcriber = MLXTranscriber(modelID: settings.sttModel)
        let cleaner = MLXCleaner(configuration: .init(settings: settings))
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveTranscribeE2E-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        for clip in clips {
            let coordinator = SessionCoordinator(
                settings: settings,
                dependencies: .init(
                    makeAudioSource: { FileAudioSource(url: clip, pacing: .asFastAsPossible) },
                    segmenter: segmenter,
                    transcriber: transcriber,
                    cleaner: cleaner,
                    makeSink: { try JSONLSessionSink(directory: outputDirectory, sessionID: $0) },
                    microphonePermission: GrantedMicrophone()
                )
            )
            let collected = Task { await Self.collectSession(coordinator.events) }
            await coordinator.prepare()
            await coordinator.start()
            let events = await collected.value
            await coordinator.shutdown()

            let name = clip.lastPathComponent
            #expect(!events.contains { if case .phase(.failed) = $0 { true } else { false } }, "\(name): a stage failed")
            #expect(!events.contains { if case .warning = $0 { true } else { false } }, "\(name): warnings")
            #expect(events.contains(.cleanupAvailability(.available)), "\(name): cleanup model unavailable")

            let file = try #require(events.compactMap { event -> URL? in
                if case .sessionStarted(_, let url) = event { url } else { nil }
            }.first)
            let records = try JSONLSessionSink.readRecords(at: file)
            #expect(!records.isEmpty, "\(name): no segments")
            #expect(records.allSatisfy { !$0.rawText.isEmpty && $0.cleanedText != nil }, "\(name): incomplete records")

            let reference = try String(contentsOf: clip.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
            let rawWER = EditDistance.wordErrorRate(reference: reference, hypothesis: records.map(\.rawText).joined(separator: " "))
            let cleanedWER = EditDistance.wordErrorRate(
                reference: reference,
                hypothesis: records.compactMap(\.cleanedText).joined(separator: " ")
            )
            #expect(rawWER < 0.25, "\(name): raw WER \(rawWER)")
            #expect(cleanedWER <= rawWER + 0.02, "\(name): cleanup made it worse (\(rawWER) → \(cleanedWER))")
        }
    }

    /// Collects events until the listening session has fully finished.
    private static func collectSession(_ stream: AsyncStream<SessionEvent>) async -> [SessionEvent] {
        var events: [SessionEvent] = []
        var sawListening = false
        for await event in stream {
            events.append(event)
            switch event {
            case .phase(.listening): sawListening = true
            case .phase(.ready) where sawListening: return events
            case .phase(.failed): return events
            default: break
            }
        }
        return events
    }
}
