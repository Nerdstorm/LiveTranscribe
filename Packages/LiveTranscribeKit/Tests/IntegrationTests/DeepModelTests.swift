import Cleanup
import Foundation
import MLXSupport
import Shared
import Testing

/// Deep as the app runs it, with the real model and the bundled adapters: the case the level was
/// specified by, typed and as speech-to-text writes it, a correction a sentence later, and "no"
/// and "sorry" that correct nothing. `Train measure --level deep` measures the whole set in
/// Training/eval/deep.jsonl.
@Suite(
    "Deep with the real model",
    .tags(.models),
    .enabled(if: modelTestsEnabled, "set LT_RUN_MODEL_TESTS=1 (TEST_RUNNER_LT_RUN_MODEL_TESTS=1 with xcodebuild)"),
    .serialized
)
struct DeepModelTests {
    /// Loaded once, for every case.
    private static let cleaner: MLXCleaner = {
        let settings = AppSettings.defaults
        MLXRuntime.configure(gpuCacheLimitMB: settings.gpuCacheLimitMB)
        return MLXCleaner(configuration: .init(settings: settings))
    }()
    private static let loaded = Task { try await cleaner.load { _ in } }

    static let cases: [(said: String, meant: String)] = [
        (
            "I tried to speak with Kirk, but he didn't. I don't think he actually check whether the release is tomorrow. No, sorry, the after tomorrow.",
            "I tried to speak with Kirk, but he didn't. I don't think he actually checked whether the release is the day after tomorrow."
        ),
        (
            "i tried to speak with kirk but he didn't i don't think he actually check whether the release is tomorrow no sorry the after tomorrow",
            "I tried to speak with Kirk, but he didn't. I don't think he actually checked whether the release is the day after tomorrow."
        ),
        ("The meeting is on Tuesday. Sorry, Wednesday.", "The meeting is on Wednesday."),
        ("Is the release tomorrow? No, it's the day after.", "Is the release tomorrow? No, it's the day after."),
        (
            "I finished the report. Sorry, I haven't had time to review yours yet.",
            "I finished the report. Sorry, I haven't had time to review yours yet."
        ),
        ("I don't want the blue one, I want the green one.", "I don't want the blue one, I want the green one."),
    ]

    @Test(.timeLimit(.minutes(10)), arguments: cases)
    func cleansAsMeant(said: String, meant: String) async throws {
        try await Self.loaded.value
        #expect(await Self.cleaner.activeDeepAdapter != nil, "Deep's adapter is bundled and fits the default model")
        let segment = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 0, rawText: said)
        let cleaned = await Self.cleaner.clean(segment, context: [], options: CleanupOptions(level: .deep))
        #expect(!cleaned.fellBack, "\(cleaned.fallbackReason ?? "")")
        #expect(cleaned.cleanedText == meant)
    }
}
