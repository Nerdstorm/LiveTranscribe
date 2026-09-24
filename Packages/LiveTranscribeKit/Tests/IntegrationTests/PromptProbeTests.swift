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

    /// The app's default level: fillers are removed before the model sees the text.
    static let options = CleanupOptions(level: .medium)

    /// Text as dictation sends it, with placeholders for emoji, addresses, line breaks, list
    /// markers and snippets, which the model must copy once each, unchanged.
    static let placeholderCases = [
        "Hi ⟦S1⟧.",
        "Thanks so much ⟦S1⟧.",
        "Great job ⟦S1⟧ see you tomorrow.",
        "See you soon ⟦S1⟧.",
        "Email me at ⟦S1⟧.",
        "The pricing is on ⟦S1⟧.",
        "Send it to ⟦S1⟧ please.",
        "First line ⟦S1⟧ second line.",
        "My goals for this week ⟦S1⟧ ship the release ⟦S2⟧ fix the login bug ⟦S3⟧ write the docs.",
        "⟦S1⟧ the build is green ⟦S2⟧",
        "um send ⟦S1⟧ to the team",
        "please call me on ⟦S1⟧ tomorrow",
        "I love it ⟦S1⟧ ⟦S2⟧",
        "thanks ⟦S1⟧ see you ⟦S2⟧",
        "the report is due friday ⟦S1⟧ and the invoice is attached",
        "good morning ⟦S1⟧ how are you",
        "happy birthday ⟦S1⟧ ⟦S2⟧ have a great day",
    ]

    /// Accepts any non-empty answer, so the probe sees what the model actually wrote.
    static let permissiveGuard = OutputGuard(policy: .init(
        wordRatioBounds: Dictionary(uniqueKeysWithValues: CleanupLevel.allCases.map { ($0, 0...Double.greatestFiniteMagnitude) }),
        minSimilarity: 0,
        preambles: [],
        correctionCues: [],
        fillers: [],
        negations: [],
        maxDroppedRun: .max,
        maxRetractedWords: 0,
        minRespellingSimilarity: 1,
        requiresIntactPlaceholders: false
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

    /// The model's answer to text with placeholders under the production prompt, which lists the
    /// tokens, and whether the production guard would keep it.
    @Test(.timeLimit(.minutes(10)))
    func printPlaceholderOutputs() async throws {
        let cleaner = try await Self.loadCleaner(template: nil, outputGuard: Self.permissiveGuard)
        let productionGuard = OutputGuard()
        var damaged = 0
        for raw in Self.placeholderCases {
            let tokens = raw.matches(of: /⟦S[0-9]+⟧/).map { String($0.output) }
            let options = CleanupOptions(level: .medium, placeholders: tokens)
            let segment = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: raw)
            let cleaned = await cleaner.clean(segment, context: [], options: options)
            let verdict = productionGuard.review(raw: raw, outcome: .completed(cleaned.cleanedText), options: options)
            if case .rejected(.placeholderChanged) = verdict { damaged += 1 }
            print("PLACEHOLDER \(Self.describe(verdict)) [\(cleaned.latencyMs) ms] \(raw) → \(cleaned.cleanedText)")
        }
        print("PLACEHOLDER damaged \(damaged)/\(Self.placeholderCases.count)")
    }

    /// Token formats compared by ``comparePlaceholderFormats()``: the text before and after the
    /// placeholder's number.
    static let placeholderFormats: [(opening: String, closing: String)] = [
        ("⟦S", "⟧"), ("S", ""), ("s", ""), ("#", ""), ("TOKEN", ""), ("ZQ", ""), ("S_", ""), ("@S", ""), ("{{S", "}}"),
    ]

    /// How often the model copies each token format exactly once, over ``placeholderCases``.
    @Test(.timeLimit(.minutes(30)))
    func comparePlaceholderFormats() async throws {
        let cleaner = try await Self.loadCleaner(template: nil, outputGuard: Self.permissiveGuard)
        for format in Self.placeholderFormats {
            var kept = 0
            var repunctuated = 0
            var total = 0
            for original in Self.placeholderCases {
                var raw = original
                var tokens: [String] = []
                for match in original.matches(of: /⟦S([0-9]+)⟧/) {
                    let token = format.opening + match.output.1 + format.closing
                    raw = raw.replacingOccurrences(of: String(match.output.0), with: token)
                    tokens.append(token)
                }
                let options = CleanupOptions(level: .medium, placeholders: tokens)
                let segment = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: raw)
                let cleaned = await cleaner.clean(segment, context: [], options: options).cleanedText
                let intact = tokens.filter { cleaned.components(separatedBy: $0).count == 2 }
                let punctuated = intact.filter { Self.punctuation(around: $0, in: cleaned) != Self.punctuation(around: $0, in: raw) }
                kept += intact.count
                repunctuated += punctuated.count
                total += tokens.count
                print("FORMAT \(format.opening)n\(format.closing) \(intact.count)/\(tokens.count) \(punctuated.count) | \(raw) → \(cleaned)")
            }
            print("FORMAT \(format.opening)n\(format.closing) SUMMARY kept \(kept)/\(total), punctuated \(repunctuated)")
        }
    }

    /// Emoji written into the text the model sees, in place of placeholders.
    static let emojiCases = [
        "Hi 🎆.", "Thanks so much ❤️.", "Great job 🎉 see you tomorrow.", "See you soon 🙂.",
        "I love it 😍 🔥", "thanks 👋 see you 👍", "good morning ☀️ how are you",
        "happy birthday 🎂 🎉 have a great day", "the report is due friday 😅 and the invoice is attached",
    ]

    /// Whether the model keeps emoji it can see, and the punctuation around them.
    @Test(.timeLimit(.minutes(10)))
    func printEmojiOutputs() async throws {
        let cleaner = try await Self.loadCleaner(template: nil, outputGuard: Self.permissiveGuard)
        var kept = 0
        var repunctuated = 0
        var total = 0
        for raw in Self.emojiCases {
            let emoji = raw.split(separator: " ").map(String.init).filter { $0.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value > 0x2000 && $0.properties.isEmoji } }
            let segment = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: raw)
            let cleaned = await cleaner.clean(segment, context: [], options: CleanupOptions(level: .medium)).cleanedText
            let intact = emoji.map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { cleaned.components(separatedBy: $0).count == 2 }
            let punctuated = intact.filter { Self.punctuation(around: $0, in: cleaned) != Self.punctuation(around: $0, in: raw) }
            kept += intact.count
            repunctuated += punctuated.count
            total += emoji.count
            print("EMOJI \(intact.count)/\(emoji.count) \(punctuated.count) | \(raw) → \(cleaned)")
        }
        print("EMOJI SUMMARY kept \(kept)/\(total), punctuated \(repunctuated)")
    }

    /// The punctuation next to `token` in `text`, ignoring spaces: what the model put around it.
    private static func punctuation(around token: String, in text: String) -> String {
        guard let range = text.range(of: token) else { return "" }
        let before = text[..<range.lowerBound].reversed().drop { $0 == " " }.prefix { $0.isPunctuation }
        let after = text[range.upperBound...].drop { $0 == " " }.prefix { $0.isPunctuation }
        return String(before.reversed()) + "|" + String(after)
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
                    let verdict = productionGuard.review(raw: probe.raw, outcome: .completed(cleaned.cleanedText), options: Self.options)
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
                    let verdict = productionGuard.review(raw: probe.raw, outcome: .completed(cleaned.cleanedText), options: Self.options)
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

    /// - Parameter template: One prompt for every request, or `nil` for the production prompts.
    private static func loadCleaner(
        model: String = AppSettings.defaults.llmModel,
        template: PromptTemplate? = Prompt.cleanup,
        outputGuard: OutputGuard = OutputGuard()
    ) async throws -> MLXCleaner {
        var settings = AppSettings.defaults
        settings.llmModel = model
        MLXRuntime.configure(gpuCacheLimitMB: settings.gpuCacheLimitMB)
        let cleaner = MLXCleaner(configuration: .init(settings: settings, promptOverride: template), outputGuard: outputGuard)
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
        return await cleaner.clean(segment, context: context, options: options)
    }

    private static func describe(_ verdict: GuardVerdict) -> String {
        switch verdict {
        case .accepted: "accepted"
        case .rejected(let reason): "REJECTED(\(reason))"
        }
    }
}
