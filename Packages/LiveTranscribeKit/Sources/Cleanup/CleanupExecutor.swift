import Foundation
import Shared
import Styles

/// Runs one cleanup: applies the level's deterministic rules, builds the prompt, generates under
/// a deadline, and applies the output guard.
///
/// Model-agnostic: the generation itself is passed in, so the policy (levels, timeout,
/// cancellation, fallback) is unit-testable without loading a model.
///
/// The text the model sees is the raw transcript with fillers removed at Medium and High. When
/// the guard rejects the output, that text is the result: fillers stay removed, so a fallback
/// differs from a success only in what the model would have corrected.
///
/// High runs in two passes when the text has a correction cue ("sorry", "no", "I mean"): the
/// Medium prompt resolves the self-correction, as the adapter was trained to, then the High
/// prompt rewords the result. Both share the one deadline. If the rewording is rejected or there
/// is no time left for it, the resolved text is used; that is a success at Medium's standard,
/// not a fallback.
public struct CleanupExecutor: Sendable {
    public let contextLimit: Int
    public let timeoutSeconds: Double
    public let outputGuard: OutputGuard
    public let prompts: PromptBuilder

    public init(
        contextLimit: Int,
        timeoutSeconds: Double,
        outputGuard: OutputGuard = OutputGuard(),
        prompts: PromptBuilder = PromptBuilder(adapted: false)
    ) {
        self.contextLimit = contextLimit
        self.timeoutSeconds = timeoutSeconds
        self.outputGuard = outputGuard
        self.prompts = prompts
    }

    public func run(
        _ segment: Segment,
        context: [String],
        options: CleanupOptions,
        generate: @escaping @Sendable (CleanupRequest) async throws -> String
    ) async -> CleanedSegment {
        let started = ContinuousClock.now
        guard options.level.usesLanguageModel else {
            return CleanedSegment(segment: segment, cleanedText: segment.rawText, fellBack: false, fallbackReason: nil, latencyMs: 0)
        }
        let input = Self.deterministicCleanup(of: segment.rawText, level: options.level)
        guard !EditDistance.words(in: input).isEmpty else {
            return CleanedSegment(segment: segment, cleanedText: input, fellBack: false, fallbackReason: nil, latencyMs: 0)
        }
        // Text the model would damage gets the level's deterministic rules only, as when the
        // model is off (``CleanupScripts``).
        guard CleanupScripts.modelCanRewrite(input) else {
            Log.cleanup.info("Cleanup skipped the model: the text is in a script it can't write")
            return CleanedSegment(segment: segment, cleanedText: input, fellBack: false, fallbackReason: nil, latencyMs: 0)
        }

        let verdict: GuardVerdict
        if options.level.allowsRewording, outputGuard.correctionCueCount(in: input) > 0 {
            verdict = await resolvingThenRewording(input, context: context, options: options, started: started, generate: generate)
        } else {
            verdict = await pass(input, context: context, options: options, seconds: timeoutSeconds, generate: generate)
        }

        let latencyMs = started.duration(to: .now).wholeMilliseconds
        switch verdict {
        case .accepted(let cleaned):
            return CleanedSegment(segment: segment, cleanedText: cleaned, fellBack: false, fallbackReason: nil, latencyMs: latencyMs)
        case .rejected(let reason):
            Log.cleanup.notice("Cleanup fell back to the uncorrected text: \(reason.description, privacy: .public)")
            return CleanedSegment(segment: segment, cleanedText: input, fellBack: true, fallbackReason: reason.description, latencyMs: latencyMs)
        }
    }

    /// What `level` does without the model: fillers removed at Medium and High, otherwise the
    /// text unchanged. It is what the model is given, what a fallback returns, and what
    /// dictation inserts when the cleanup model is turned off, so all three agree.
    public static func deterministicCleanup(of text: String, level: CleanupLevel) -> String {
        level.removesFillers ? FillerRemover().removingFillers(from: text) : text
    }

    // MARK: - Private

    /// High with a self-correction: Medium resolves it, then High rewords what is left in the
    /// time remaining. A rejected rewording keeps the resolved text.
    private func resolvingThenRewording(
        _ input: String,
        context: [String],
        options: CleanupOptions,
        started: ContinuousClock.Instant,
        generate: @escaping @Sendable (CleanupRequest) async throws -> String
    ) async -> GuardVerdict {
        var resolving = options
        resolving.level = .medium
        let first = await pass(input, context: context, options: resolving, seconds: timeoutSeconds, generate: generate)
        guard case .accepted(let resolved) = first else { return first }

        let remaining = timeoutSeconds - Double(started.duration(to: .now).wholeMilliseconds) / 1_000
        guard remaining > 0, !Task.isCancelled else {
            Log.cleanup.notice("No time left to reword; keeping the resolved self-correction")
            return first
        }
        let second = await pass(resolved, context: context, options: options, seconds: remaining, generate: generate)
        if case .rejected(let reason) = second {
            Log.cleanup.notice(
                "Rewording rejected, keeping the resolved self-correction: \(reason.description, privacy: .public)"
            )
            return first
        }
        return second
    }

    /// One generation of `input` under `options`, within `seconds`, reviewed by the guard. The
    /// model sees the placeholders as words (see ``PlaceholderAliases``); the guard sees tokens.
    private func pass(
        _ input: String,
        context: [String],
        options: CleanupOptions,
        seconds: Double,
        generate: @escaping @Sendable (CleanupRequest) async throws -> String
    ) async -> GuardVerdict {
        let aliases = PlaceholderAliases(tokens: options.placeholders, text: input)
        var modelOptions = options
        modelOptions.placeholders = aliases.aliases
        let request = Prompt.request(
            for: aliases.aliased(input),
            context: context,
            contextLimit: contextLimit,
            template: prompts.template(for: modelOptions)
        )
        let signposter = Log.cleanupSignposter
        let interval = signposter.beginInterval("LLM", id: signposter.makeSignpostID())
        let outcome: GenerationOutcome
        do {
            let text = try await withDeadline(seconds: seconds) {
                try await generate(request)
            }
            outcome = Task.isCancelled ? .cancelled : .completed(aliases.restored(text))
        } catch let deadline as DeadlineExceeded {
            outcome = .timedOut(seconds: deadline.seconds)
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        signposter.endInterval("LLM", interval)
        return outputGuard.review(raw: input, outcome: outcome, options: options)
    }
}
