import Foundation
import Shared

/// Runs one cleanup: builds the prompt, generates under a deadline, and applies the output guard.
///
/// Model-agnostic: the generation itself is passed in, so the policy (timeout, cancellation,
/// fallback) is unit-testable without loading a model.
public struct CleanupExecutor: Sendable {
    public let contextLimit: Int
    public let timeoutSeconds: Double
    public let outputGuard: OutputGuard
    public let template: PromptTemplate

    public init(
        contextLimit: Int,
        timeoutSeconds: Double,
        outputGuard: OutputGuard = OutputGuard(),
        template: PromptTemplate = Prompt.cleanup
    ) {
        self.contextLimit = contextLimit
        self.timeoutSeconds = timeoutSeconds
        self.outputGuard = outputGuard
        self.template = template
    }

    public func run(
        _ segment: Segment,
        context: [String],
        generate: @escaping @Sendable (CleanupRequest) async throws -> String
    ) async -> CleanedSegment {
        let started = ContinuousClock.now
        guard !EditDistance.words(in: segment.rawText).isEmpty else {
            return CleanedSegment(segment: segment, cleanedText: segment.rawText, fellBack: false, fallbackReason: nil, latencyMs: 0)
        }

        let request = Prompt.request(for: segment.rawText, context: context, contextLimit: contextLimit, template: template)
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
        switch outputGuard.review(raw: segment.rawText, outcome: outcome) {
        case .accepted(let cleaned):
            return CleanedSegment(segment: segment, cleanedText: cleaned, fellBack: false, fallbackReason: nil, latencyMs: latencyMs)
        case .rejected(let reason):
            Log.cleanup.notice("Cleanup fell back to raw text: \(reason.description, privacy: .public)")
            return .fallback(segment, reason: reason.description, latencyMs: latencyMs)
        }
    }
}
