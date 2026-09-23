import Cleanup
import Foundation
import MLXSupport
import Shared
import Testing

/// Prints the cleanup model's output for hard cases (context echo, homophones, disfluencies,
/// self-corrections). A development aid for prompt changes: run with LT_PROMPT_PROBE=1
/// (TEST_RUNNER_LT_PROMPT_PROBE=1 with xcodebuild). It downloads and loads the cleanup model.
@Suite(
    "Prompt probe",
    .tags(.models),
    .enabled(if: ProcessInfo.processInfo.environment["LT_PROMPT_PROBE"] == "1", "set LT_PROMPT_PROBE=1"),
    .serialized
)
struct PromptProbeTests {
    static let cases: [(context: [String], raw: String)] = [
        (["I think we should probably meet on Tuesday."], "Maybe around three o'clock, if that works for you."),
        (["The quarterly report is due next Friday."], "please send me your numbers by wednesday so i can review them before the call"),
        (["So the main issue is that the build keeps failing on the release branch."], "I'm not totally sure why, but I suspect the cash."),
        ([], "i think we should probably meet on tuesday"),
        (["We shipped the new version yesterday.", "Um, there were a couple of bugs."], "so like we need to hot fix the the login page"),
        ([], "their going to announce it tomorrow i think"),
        (["Let's review the plan."], "the the main risk is the data migration which we haven't tested yet"),
        (["Can you check the logs?"], "yeah i can do that after lunch"),
        (["The deploy failed twice this morning."], "I'm not sure, maybe we could try rolling back."),
        (["First we load the data.", "Then we clean it up.", "Then we train the model."], "and finally we evaluate it on the test set"),
    ]

    /// Spoken self-corrections, which should keep only the correction, and look-alike phrases
    /// that correct nothing and must be kept.
    static let selfCorrectionCases: [(context: [String], raw: String, expected: String)] = [
        ([], "I want to talk about fuel efficiency in cars sorry busses", "I want to talk about fuel efficiency in buses."),
        ([], "let's meet on tuesday no wait wednesday at ten", "Let's meet on Wednesday at ten."),
        ([], "send it to john i mean jane before friday", "Send it to Jane before Friday."),
        ([], "we need three sorry four more servers for the launch", "We need four more servers for the launch."),
        (["The build is failing again."], "it's the login service or rather the auth service that times out", "It's the auth service that times out."),
        ([], "the meeting is at two pm actually make that three pm", "The meeting is at three p.m."),
        ([], "open the settings sorry the preferences window", "Open the preferences window."),
        ([], "sorry i'm late the traffic was terrible", "Sorry I'm late, the traffic was terrible."),
        ([], "i mean it this time we really need to ship", "I mean it this time, we really need to ship."),
        ([], "no i don't think that's right", "No, I don't think that's right."),
        ([], "actually that works for me", "Actually, that works for me."),
        ([], "was it the cars or the buses that had better fuel efficiency", "Was it the cars or the buses that had better fuel efficiency?"),
        ([], "sorry to interrupt but can i ask a question", "Sorry to interrupt, but can I ask a question?"),
        ([], "i said tuesday not wednesday", "I said Tuesday, not Wednesday."),
    ]

    /// Asks for self-corrections to be resolved. Measured on Qwen3-1.7B and Qwen3-4B, it resolved
    /// at most 2 of 7, often kept the retracted words instead, and dropped hedges ("I think") or
    /// meaning-bearing words ("I mean it" → "I mean,") elsewhere.
    static let selfCorrectionSystem = """
        Correct transcription errors, punctuation, casing and grammar in the TEXT.
        Preserve meaning, tone, hedging and filler intent exactly.
        Do not add, summarise or rephrase content.
        Remove only words the speaker takes back when correcting themselves, and keep the correction.
        If the text is already correct, return it unchanged.
        Output only the corrected text.
        """

    static let selfCorrectionExamples: [PromptTemplate.Example] = [
        .init(text: "the invoice goes to mark sorry sarah in accounts", cleaned: "The invoice goes to Sarah in accounts."),
        .init(text: "we shipped it in march no wait april", cleaned: "We shipped it in April."),
        .init(text: "can you open the terminal i mean the browser", cleaned: "Can you open the browser?"),
        .init(text: "we need about ten or rather twelve people for this", cleaned: "We need about twelve people for this."),
        .init(text: "sorry i missed your call earlier", cleaned: "Sorry I missed your call earlier."),
        .init(text: "i mean we could just try it", cleaned: "I mean, we could just try it."),
    ]

    /// Prompts compared by ``compareSelfCorrectionPrompts()``. Add candidate templates here to
    /// measure them against production.
    static let variants: [(name: String, template: PromptTemplate)] = [
        ("production", Prompt.cleanup),
        ("self-correction rule", PromptTemplate(system: selfCorrectionSystem, examples: [])),
        ("self-correction rule + 6 examples", PromptTemplate(system: selfCorrectionSystem, examples: selfCorrectionExamples)),
    ]

    /// Cleanup models to compare: LT_PROMPT_PROBE_MODELS (comma-separated Hugging Face ids),
    /// or the app's default.
    static var models: [String] {
        let configured = (ProcessInfo.processInfo.environment["LT_PROMPT_PROBE_MODELS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return configured.isEmpty ? [AppSettings.defaults.llmModel] : configured
    }

    /// Accepts any non-empty answer, so the probe sees what the model actually wrote.
    static let permissiveGuard = OutputGuard(policy: .init(
        minWordRatio: 0,
        maxWordRatio: .infinity,
        minSimilarity: 0,
        preambles: [],
        correctionCues: [],
        fillers: [],
        maxRetractedWords: 0,
        minRespellingSimilarity: 1
    ))

    @Test(.timeLimit(.minutes(10)))
    func printCleanupOutputs() async throws {
        let cleaner = try await Self.loadCleaner()
        var fallbacks = 0
        for (index, probe) in Self.cases.enumerated() {
            let cleaned = await Self.clean(probe.raw, context: probe.context, with: cleaner)
            if cleaned.fellBack { fallbacks += 1 }
            print("PROBE \(index) [\(cleaned.latencyMs) ms] \(cleaned.fellBack ? "FALLBACK(\(cleaned.fallbackReason ?? ""))" : "OK")")
            print("PROBE   raw:     \(probe.raw)")
            print("PROBE   cleaned: \(cleaned.cleanedText)")
        }
        print("PROBE fallbacks: \(fallbacks)/\(Self.cases.count)")
    }

    /// For each model and variant: the model's unguarded answer to every case, what the
    /// production guard makes of it, whether the text finally shown matches the expected text,
    /// and cleanup latency. Run in Release for representative latency.
    @Test(.timeLimit(.minutes(30)))
    func compareSelfCorrectionPrompts() async throws {
        let productionGuard = OutputGuard()
        for model in Self.models {
            for variant in Self.variants {
                let label = "\(model) | \(variant.name)"
                let cleaner = try await Self.loadCleaner(model: model, template: variant.template, outputGuard: Self.permissiveGuard)
                var latencies: [Int] = []
                var failed = 0
                var shownCorrectly = 0
                for probe in Self.selfCorrectionCases {
                    let cleaned = await Self.clean(probe.raw, context: probe.context, with: cleaner)
                    latencies.append(cleaned.latencyMs)
                    if cleaned.fellBack { failed += 1 }
                    let verdict = productionGuard.review(raw: probe.raw, outcome: .completed(cleaned.cleanedText))
                    let shown: String
                    switch verdict {
                    case .accepted(let text): shown = text
                    case .rejected: shown = probe.raw
                    }
                    let correct = EditDistance.normalize(shown) == EditDistance.normalize(probe.expected)
                    if correct { shownCorrectly += 1 }
                    print("VARIANT \(label) \(correct ? "✓" : "✗") \(Self.describe(verdict)) | \(cleaned.cleanedText)")
                }
                var rejected = 0
                for probe in Self.cases {
                    let cleaned = await Self.clean(probe.raw, context: probe.context, with: cleaner)
                    latencies.append(cleaned.latencyMs)
                    if cleaned.fellBack { failed += 1 }
                    let verdict = productionGuard.review(raw: probe.raw, outcome: .completed(cleaned.cleanedText))
                    if case .rejected = verdict { rejected += 1 }
                    print("VARIANT \(label) general \(Self.describe(verdict)) | \(cleaned.cleanedText)")
                }
                latencies.sort()
                print("""
                    VARIANT \(label) SUMMARY self-corrections shown correctly \(shownCorrectly)/\(Self.selfCorrectionCases.count), \
                    general cases rejected \(rejected)/\(Self.cases.count), timed out or failed \(failed), \
                    latency p50 \(Self.percentile(latencies, 0.5)) ms p95 \(Self.percentile(latencies, 0.95)) ms
                    """)
            }
        }
    }

    private static func loadCleaner(
        model: String = AppSettings.defaults.llmModel,
        template: PromptTemplate = Prompt.cleanup,
        outputGuard: OutputGuard = OutputGuard()
    ) async throws -> MLXCleaner {
        var settings = AppSettings.defaults
        settings.llmModel = model
        MLXRuntime.configure(gpuCacheLimitMB: settings.gpuCacheLimitMB)
        let cleaner = MLXCleaner(configuration: .init(settings: settings, template: template), outputGuard: outputGuard)
        try await cleaner.load { _ in }
        return cleaner
    }

    /// Nearest-rank percentile of sorted values.
    private static func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    private static func clean(_ raw: String, context: [String], with cleaner: MLXCleaner) async -> CleanedSegment {
        let segment = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: raw)
        return await cleaner.clean(segment, context: context)
    }

    private static func describe(_ verdict: GuardVerdict) -> String {
        switch verdict {
        case .accepted: "accepted"
        case .rejected(let reason): "REJECTED(\(reason))"
        }
    }
}
