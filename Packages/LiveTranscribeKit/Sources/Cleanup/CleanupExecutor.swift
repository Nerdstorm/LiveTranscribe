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
public struct CleanupExecutor: Sendable {
    public let contextLimit: Int
    public let timeoutSeconds: Double
    public let outputGuard: OutputGuard
    public let prompts: PromptBuilder
    private let fillerRemover = FillerRemover()

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
        let input = options.level.removesFillers ? fillerRemover.removingFillers(from: segment.rawText) : segment.rawText
        guard !EditDistance.words(in: input).isEmpty else {
            return CleanedSegment(segment: segment, cleanedText: input, fellBack: false, fallbackReason: nil, latencyMs: 0)
        }

        let request = Prompt.request(
            for: input,
            context: context,
            contextLimit: contextLimit,
            template: prompts.template(for: options)
        )
        let signposter = Log.cleanupSignposter
        let interval = signposter.beginInterval("LLM", id: signposter.makeSignpostID())
        let outcome: GenerationOutcome
        do {
            let text = try await withDeadline(seconds: timeoutSeconds) {
                try await generate(request)
            }
            outcome = Task.isCancelled ? .cancelled : .completed(text)
        } catch let deadline as DeadlineExceeded {
            outcome = .timedOut(seconds: deadline.seconds)
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        signposter.endInterval("LLM", interval)

        let latencyMs = started.duration(to: .now).wholeMilliseconds
        switch outputGuard.review(raw: input, outcome: outcome, options: options) {
        case .accepted(let cleaned):
            return CleanedSegment(segment: segment, cleanedText: cleaned, fellBack: false, fallbackReason: nil, latencyMs: latencyMs)
        case .rejected(let reason):
            Log.cleanup.notice("Cleanup fell back to the uncorrected text: \(reason.description, privacy: .public)")
            return CleanedSegment(segment: segment, cleanedText: input, fellBack: true, fallbackReason: reason.description, latencyMs: latencyMs)
        }
    }
}
