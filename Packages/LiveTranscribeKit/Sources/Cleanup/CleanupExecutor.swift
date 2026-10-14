import Foundation
import Shared
import Styles

/// Runs one cleanup: applies the level's deterministic rules, builds the prompt, generates under
/// a deadline, and applies the output guard.
///
/// Model-agnostic: the generation itself is passed in, so the policy (levels, timeout,
/// cancellation, fallback) is unit-testable without loading a model.
///
/// The text the model sees is the raw transcript with fillers removed. When the guard rejects
/// the output, that text is the result: fillers stay removed, so a fallback differs from a
/// success only in what the model would have corrected.
///
/// Standard asks once, with its rewording pass, or twice when the text has a correction cue
/// ("sorry", "no", "I mean"): the correcting pass resolves the self-correction, as the adapter
/// was trained to, then the rewording pass rewords the result (``CleanupPass``). Both share the
/// one deadline. If the rewording is rejected or there is no time left for it, the resolved text
/// is used; that is a success, not a fallback.
///
/// Deep runs as ``DeepCleanup`` says: its own prompt, with or without the adapter, thinking or
/// not, after the correcting pass or on its own, under a longer deadline. When its repair is
/// turned down, the correcting pass's result is used if it ran first; otherwise Standard's
/// cleanup runs in the time left, and its result is used if it passes Deep's check as well.
/// Either is a success, not a fallback.
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

        let verdict = options.level.repairsAcrossSentences
            ? await repairing(input, context: context, options: options, started: started, generate: generate)
            : await standard(input, context: context, options: options, seconds: timeoutSeconds, generate: generate)

        let latencyMs = started.duration(to: .now).wholeMilliseconds
        switch verdict {
        case .accepted(let cleaned):
            return CleanedSegment(segment: segment, cleanedText: cleaned, fellBack: false, fallbackReason: nil, latencyMs: latencyMs)
        case .rejected(let reason):
            Log.cleanup.notice("Cleanup fell back to the uncorrected text: \(reason.description, privacy: .public)")
            return CleanedSegment(segment: segment, cleanedText: input, fellBack: true, fallbackReason: reason.description, latencyMs: latencyMs)
        }
    }

    /// What `level` does without the model: fillers removed at Standard and Deep, otherwise the
    /// text unchanged. It is what the model is given, what a fallback returns, and what
    /// dictation inserts when the cleanup model is turned off, so all three agree.
    public static func deterministicCleanup(of text: String, level: CleanupLevel) -> String {
        level.removesFillers ? FillerRemover().removingFillers(from: text) : text
    }

    // MARK: - Private

    /// Deep: its own pass, under Deep's deadline. With ``DeepCleanup/Passes/afterCorrecting`` and
    /// a correction cue in the text, Standard's correcting pass resolves what it can first; if
    /// Deep's pass is then rejected or out of time, that result is kept. Otherwise, when Deep's
    /// answer is turned down, Standard's cleanup runs in the time left
    /// (``DeepCleanup/fallsBackToStandard``), and its answer is shown only if Deep's check accepts
    /// it too: Standard's guard lets through some meaning changes that Deep's turns down, such as a
    /// correction that takes back more than it corrects. Otherwise Deep's reason is reported and
    /// what was said is shown.
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
        var standard = options
        standard.level = .standard
        standard.pass = .rewording
        var correcting = standard
        correcting.pass = .correcting
        let resolvesFirst = deep.passes == .afterCorrecting && outputGuard.correctionCueCount(in: input) > 0
        if resolvesFirst {
            let first = await pass(input, context: context, options: correcting, seconds: seconds, generate: generate)
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
            Log.cleanup.notice("Deep repair rejected, keeping the corrected text: \(reason.description, privacy: .public)")
            return resolved
        }
        guard deep.fallsBackToStandard, !resolvesFirst, reason.rejectsAnAnswer else { return repaired }
        let left = seconds - Double(started.duration(to: .now).wholeMilliseconds) / 1_000
        guard left > 0, !Task.isCancelled else { return repaired }
        let fallback = await self.standard(input, context: context, options: standard, seconds: left, generate: generate)
        guard case .accepted(let answer) = fallback else { return repaired }
        if case .rejected(let check) = outputGuard.review(raw: input, outcome: .completed(answer), options: options) {
            Log.cleanup.notice(
                "Deep repair rejected (\(reason.description, privacy: .public)), and Standard's cleanup fails Deep's check: \(check.description, privacy: .public)"
            )
            return repaired
        }
        Log.cleanup.notice("Deep repair rejected, showing Standard's cleanup: \(reason.description, privacy: .public)")
        return fallback
    }

    /// Standard, within `seconds`: one rewording pass, or, with a correction cue in the text, the
    /// correcting pass resolves it, then the rewording pass rewords what is left in the time
    /// remaining. A rejected rewording keeps the resolved text.
    private func standard(
        _ input: String,
        context: [String],
        options: CleanupOptions,
        seconds: Double,
        generate: @escaping @Sendable (CleanupRequest) async throws -> String
    ) async -> GuardVerdict {
        guard options.pass == .rewording, outputGuard.correctionCueCount(in: input) > 0 else {
            return await pass(input, context: context, options: options, seconds: seconds, generate: generate)
        }
        let started = ContinuousClock.now
        var correcting = options
        correcting.pass = .correcting
        let first = await pass(input, context: context, options: correcting, seconds: seconds, generate: generate)
        guard case .accepted(let resolved) = first else { return first }

        let remaining = seconds - Double(started.duration(to: .now).wholeMilliseconds) / 1_000
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

    /// What the model is asked for `text` under `options`. The self-correction adapter is on for
    /// Standard's passes, as it was trained to, and Deep's pass has the adapter ``deep`` says;
    /// only Deep thinks. Training builds its prompts here too, so they are the app's.
    public func request(for text: String, context: [String], options: CleanupOptions) -> CleanupRequest {
        let repairs = options.pass == .repairing
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
