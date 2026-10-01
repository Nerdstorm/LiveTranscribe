import Foundation
import Shared
import Styles

/// Runs one cleanup: applies the level's deterministic rules, builds the prompt, generates under
/// a deadline, and applies the output guard.
///
/// Model-agnostic: the generation itself is passed in, so the policy (levels, timeout,
/// cancellation, fallback) is unit-testable without loading a model.
///
/// The text the model sees is the raw transcript with fillers removed from Medium up. When
/// the guard rejects the output, that text is the result: fillers stay removed, so a fallback
/// differs from a success only in what the model would have corrected.
///
/// High runs in two passes when the text has a correction cue ("sorry", "no", "I mean"): the
/// Medium prompt resolves the self-correction, as the adapter was trained to, then the High
/// prompt rewords the result. Both share the one deadline. If the rewording is rejected or there
/// is no time left for it, the resolved text is used; that is a success at Medium's standard,
/// not a fallback.
///
/// Deep runs as ``DeepCleanup`` says: its own prompt, with or without the adapter, thinking or
/// not, after Medium's pass or on its own, under a longer deadline. When its repair is turned
/// down, Medium's result is used, from the pass before it or one run in the time left: a success
/// at Medium's standard, not a fallback.
public struct CleanupExecutor: Sendable {
    public let contextLimit: Int
    public let timeoutSeconds: Double
    public let outputGuard: OutputGuard
    public let prompts: PromptBuilder
    public let deep: DeepCleanup

    public init(
        contextLimit: Int,
        timeoutSeconds: Double,
        outputGuard: OutputGuard = OutputGuard(),
        prompts: PromptBuilder = PromptBuilder(adapted: false),
        deep: DeepCleanup = .shipped
    ) {
        self.contextLimit = contextLimit
        self.timeoutSeconds = timeoutSeconds
        self.outputGuard = outputGuard
        self.prompts = prompts
        self.deep = deep
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
        if options.level.repairsAcrossSentences {
            verdict = await repairing(input, context: context, options: options, started: started, generate: generate)
        } else if options.level.allowsRewording, outputGuard.correctionCueCount(in: input) > 0 {
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

    /// What `level` does without the model: fillers removed from Medium up, otherwise the
    /// text unchanged. It is what the model is given, what a fallback returns, and what
    /// dictation inserts when the cleanup model is turned off, so all three agree.
    public static func deterministicCleanup(of text: String, level: CleanupLevel) -> String {
        level.removesFillers ? FillerRemover().removingFillers(from: text) : text
    }

    // MARK: - Private

    /// Deep: its own pass, under Deep's deadline. With ``DeepCleanup/Passes/afterMedium`` and a
    /// correction cue in the text, Medium's pass resolves what it can first; if Deep's pass is then
    /// rejected or out of time, Medium's result is kept, a success at Medium's standard. Otherwise,
    /// when Deep's answer is turned down, Medium's pass runs in the time left
    /// (``DeepCleanup/fallsBackToMedium``).
    private func repairing(
        _ input: String,
        context: [String],
        options: CleanupOptions,
        started: ContinuousClock.Instant,
        generate: @escaping @Sendable (CleanupRequest) async throws -> String
    ) async -> GuardVerdict {
        let seconds = deep.deadline(given: timeoutSeconds)
        var text = input
        var resolved: GuardVerdict?
        var resolving = options
        resolving.level = .medium
        let resolvesFirst = deep.passes == .afterMedium && outputGuard.correctionCueCount(in: input) > 0
        if resolvesFirst {
            let first = await pass(input, context: context, options: resolving, seconds: seconds, generate: generate)
            if case .accepted(let resolvedText) = first {
                text = resolvedText
                resolved = first
            }
        }
        let remaining = seconds - Double(started.duration(to: .now).wholeMilliseconds) / 1_000
        guard remaining > 0, !Task.isCancelled else {
            return resolved ?? .rejected(Task.isCancelled ? .cancelled : .timedOut(seconds: seconds))
        }
        let repaired = await pass(text, context: context, options: options, seconds: remaining, generate: generate)
        guard case .rejected(let reason) = repaired else { return repaired }
        if let resolved {
            Log.cleanup.notice("Deep repair rejected, keeping Medium's result: \(reason.description, privacy: .public)")
            return resolved
        }
        guard deep.fallsBackToMedium, !resolvesFirst, reason.rejectsAnAnswer else { return repaired }
        let left = seconds - Double(started.duration(to: .now).wholeMilliseconds) / 1_000
        guard left > 0, !Task.isCancelled else { return repaired }
        let fallback = await pass(input, context: context, options: resolving, seconds: left, generate: generate)
        guard case .accepted = fallback else { return repaired }
        Log.cleanup.notice("Deep repair rejected, showing Medium's cleanup: \(reason.description, privacy: .public)")
        return fallback
    }

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
        let request = self.request(for: aliases.aliased(input), context: context, options: modelOptions)
        let signposter = Log.cleanupSignposter
        let interval = signposter.beginInterval("LLM", id: signposter.makeSignpostID())
        let outcome: GenerationOutcome
        do {
            let text = try await withDeadline(seconds: seconds) {
                try await generate(request)
            }
            if Task.isCancelled {
                outcome = .cancelled
            } else if request.thinks {
                guard case .answer(let answer) = ThinkingOutput(text) else {
                    signposter.endInterval("LLM", interval)
                    return .rejected(.thinkingUnfinished)
                }
                outcome = .completed(aliases.restored(answer))
            } else {
                outcome = .completed(aliases.restored(text))
            }
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

    /// The request the first pass sends for `input`, and `target` as the model writes it: the
    /// placeholders in both as the words the model sees (``PlaceholderAliases``), as in `run`, so
    /// a model trained on the pair is trained on what it will be asked.
    public func trainingPair(
        input: String,
        target: String,
        context: [String],
        options: CleanupOptions
    ) -> (request: CleanupRequest, target: String) {
        let aliases = PlaceholderAliases(tokens: options.placeholders, text: input)
        var modelOptions = options
        modelOptions.placeholders = aliases.aliases
        return (request(for: aliases.aliased(input), context: context, options: modelOptions), aliases.aliased(target))
    }

    /// What the model is asked for `text` under `options`. The adapter is on where the level
    /// resolves self-corrections, as it was trained to, and at Deep as ``deep`` says; only Deep
    /// thinks. Training builds its prompts here too, so they are the app's.
    public func request(for text: String, context: [String], options: CleanupOptions) -> CleanupRequest {
        let repairs = options.level.repairsAcrossSentences
        return Prompt.request(
            for: text,
            context: context,
            contextLimit: contextLimit,
            template: prompts.template(for: options),
            adapter: repairs ? deep.adapter : (options.level.resolvesSelfCorrections ? .medium : .off),
            thinkingTokens: repairs && deep.thinking ? deep.thinkingTokens : nil
        )
    }
}
