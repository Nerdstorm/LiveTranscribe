import Cleanup
import Testing

@Suite("OutputGuard")
struct OutputGuardTests {
    private let outputGuard = OutputGuard()

    private func words(_ count: Int) -> String {
        Array(repeating: "word", count: count).joined(separator: " ")
    }

    @Test func acceptsACorrection() {
        let verdict = outputGuard.review(
            raw: "i think we should meet on tuesday maybe at three",
            outcome: .completed("I think we should meet on Tuesday, maybe at three.")
        )
        #expect(verdict == .accepted("I think we should meet on Tuesday, maybe at three."))
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(outputGuard.review(raw: "hello there", outcome: .completed("\n  Hello there.  \n")) == .accepted("Hello there."))
    }

    @Test("Empty or blank output falls back", arguments: ["", "   ", "\n\n"])
    func rejectsEmptyOutput(output: String) {
        #expect(outputGuard.review(raw: "hello there", outcome: .completed(output)) == .rejected(.emptyOutput))
    }

    @Test func rejectsLeakedThinking() {
        let verdict = outputGuard.review(raw: "hello there", outcome: .completed("<think>\nuser said hi\n</think>\nHello there."))
        #expect(verdict == .rejected(.thinkingLeaked))
        #expect(outputGuard.review(raw: "hello there", outcome: .completed("Hello there.</think>")) == .rejected(.thinkingLeaked))
    }

    @Test func rejectsPreamble() {
        let verdict = outputGuard.review(
            raw: "the report is due friday",
            outcome: .completed("Here is the corrected text: The report is due Friday.")
        )
        #expect(verdict == .rejected(.preamble("here is")))
    }

    @Test func allowsAnOpeningThatWasActuallySpoken() {
        let verdict = outputGuard.review(raw: "sure, i can do that", outcome: .completed("Sure, I can do that."))
        #expect(verdict == .accepted("Sure, I can do that."))
    }

    @Test("A spoken opening is kept however it is punctuated", arguments: [
        ("sure so i was at a small startup for three years", "Sure. So I was at a small startup for three years."),
        ("Of course we can ship it on Friday.", "Of course, we can ship it on Friday."),
        ("certainly not before the review", "Certainly not before the review."),
        ("Here's the plan for the launch", "Here's the plan for the launch."),
    ])
    func allowsASpokenOpeningWithDifferentPunctuation(raw: String, cleaned: String) {
        #expect(outputGuard.review(raw: raw, outcome: .completed(cleaned)) == .accepted(cleaned))
    }

    @Test func stillRejectsAPreambleAddedAfterASpokenOpening() {
        let cleaned = "Sure, here's the corrected text: Sure thing."
        #expect(outputGuard.review(raw: "sure thing", outcome: .completed(cleaned)) != .accepted(cleaned))
    }

    @Test func wordRatioBelowMinimumFallsBack() {
        let verdict = outputGuard.review(raw: words(100), outcome: .completed(words(69)))
        guard case .rejected(.wordRatio(let ratio)) = verdict else {
            Issue.record("expected a word-ratio rejection, got \(verdict)")
            return
        }
        #expect(abs(ratio - 0.69) < 1e-9)
    }

    @Test func wordRatioAtMinimumIsAccepted() {
        #expect(outputGuard.review(raw: words(100), outcome: .completed(words(70))) == .accepted(words(70)))
    }

    @Test func wordRatioAboveMaximumFallsBack() {
        let verdict = outputGuard.review(raw: words(100), outcome: .completed(words(131)))
        guard case .rejected(.wordRatio(let ratio)) = verdict else {
            Issue.record("expected a word-ratio rejection, got \(verdict)")
            return
        }
        #expect(abs(ratio - 1.31) < 1e-9)
    }

    @Test func wordRatioAtMaximumIsAccepted() {
        #expect(outputGuard.review(raw: words(100), outcome: .completed(words(130))) == .accepted(words(130)))
    }

    @Test func lowSimilarityFallsBack() {
        let verdict = outputGuard.review(
            raw: "the meeting is on tuesday afternoon",
            outcome: .completed("A banana smoothie needs frozen fruit.")
        )
        guard case .rejected(.lowSimilarity(let similarity)) = verdict else {
            Issue.record("expected a similarity rejection, got \(verdict)")
            return
        }
        #expect(similarity < 0.6)
    }

    @Test func timeoutFallsBack() {
        #expect(outputGuard.review(raw: "hello", outcome: .timedOut(seconds: 3)) == .rejected(.timedOut(seconds: 3)))
    }

    @Test func cancellationFallsBack() {
        #expect(outputGuard.review(raw: "hello", outcome: .cancelled) == .rejected(.cancelled))
    }

    @Test func generationErrorFallsBack() {
        #expect(outputGuard.review(raw: "hello", outcome: .failed("GPU error")) == .rejected(.generationFailed("GPU error")))
    }

    @Test func fallbackReasonsAreReadable() {
        #expect(FallbackReason.timedOut(seconds: 3).description == "timed out after 3.0s")
        #expect(FallbackReason.wordRatio(1.31).description == "word-count ratio 1.31 outside allowed range")
    }
}
