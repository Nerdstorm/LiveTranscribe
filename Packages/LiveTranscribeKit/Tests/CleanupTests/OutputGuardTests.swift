import Cleanup
import Shared
import Testing

@Suite("OutputGuard")
struct OutputGuardTests {
    private let outputGuard = OutputGuard()

    private func review(raw: String, outcome: GenerationOutcome, level: CleanupLevel = .medium, placeholders: [String] = []) -> GuardVerdict {
        outputGuard.review(raw: raw, outcome: outcome, options: CleanupOptions(level: level, placeholders: placeholders))
    }

    private func words(_ count: Int) -> String {
        Array(repeating: "word", count: count).joined(separator: " ")
    }

    @Test func acceptsACorrection() {
        let verdict = review(
            raw: "i think we should meet on tuesday maybe at three",
            outcome: .completed("I think we should meet on Tuesday, maybe at three.")
        )
        #expect(verdict == .accepted("I think we should meet on Tuesday, maybe at three."))
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(review(raw: "hello there", outcome: .completed("\n  Hello there.  \n")) == .accepted("Hello there."))
    }

    @Test("Empty or blank output falls back", arguments: ["", "   ", "\n\n"])
    func rejectsEmptyOutput(output: String) {
        #expect(review(raw: "hello there", outcome: .completed(output)) == .rejected(.emptyOutput))
    }

    @Test func rejectsLeakedThinking() {
        let verdict = review(raw: "hello there", outcome: .completed("<think>\nuser said hi\n</think>\nHello there."))
        #expect(verdict == .rejected(.thinkingLeaked))
        #expect(review(raw: "hello there", outcome: .completed("Hello there.</think>")) == .rejected(.thinkingLeaked))
    }

    @Test func rejectsPreamble() {
        let verdict = review(
            raw: "the report is due friday",
            outcome: .completed("Here is the corrected text: The report is due Friday.")
        )
        #expect(verdict == .rejected(.preamble("here is")))
    }

    @Test func allowsAnOpeningThatWasActuallySpoken() {
        let verdict = review(raw: "sure, i can do that", outcome: .completed("Sure, I can do that."))
        #expect(verdict == .accepted("Sure, I can do that."))
    }

    @Test("A spoken opening is kept however it is punctuated", arguments: [
        ("sure so i was at a small startup for three years", "Sure. So I was at a small startup for three years."),
        ("Of course we can ship it on Friday.", "Of course, we can ship it on Friday."),
        ("certainly not before the review", "Certainly not before the review."),
        ("Here's the plan for the launch", "Here's the plan for the launch."),
    ])
    func allowsASpokenOpeningWithDifferentPunctuation(raw: String, cleaned: String) {
        #expect(review(raw: raw, outcome: .completed(cleaned)) == .accepted(cleaned))
    }

    @Test func stillRejectsAPreambleAddedAfterASpokenOpening() {
        let cleaned = "Sure, here's the corrected text: Sure thing."
        #expect(review(raw: "sure thing", outcome: .completed(cleaned)) != .accepted(cleaned))
    }

    /// The default policy without the similarity check, which on its own rejects most large
    /// changes in length, so the word-ratio bounds can be tested at their edges.
    private let ratioOnlyGuard: OutputGuard = {
        var policy = OutputGuard.Policy.default
        policy.minSimilarity = 0
        return OutputGuard(policy: policy)
    }()

    @Test("Each level accepts output at its word-ratio bounds and rejects it just outside",
          arguments: [CleanupLevel.light, .medium, .high])
    func wordRatioBoundsFollowTheLevel(level: CleanupLevel) {
        let options = CleanupOptions(level: level)
        let low = Int((level.wordRatioBounds.lowerBound * 100).rounded())
        let high = Int((level.wordRatioBounds.upperBound * 100).rounded())
        for accepted in [low, high] {
            #expect(ratioOnlyGuard.review(raw: words(100), outcome: .completed(words(accepted)), options: options) == .accepted(words(accepted)))
        }
        for rejected in [low - 1, high + 1] {
            let verdict = ratioOnlyGuard.review(raw: words(100), outcome: .completed(words(rejected)), options: options)
            guard case .rejected(.wordRatio(let ratio)) = verdict else {
                Issue.record("expected a word-ratio rejection at \(rejected) words for \(level), got \(verdict)")
                continue
            }
            #expect(abs(ratio - Double(rejected) / 100) < 1e-9)
        }
    }

    @Test func aPolicyCanOverrideALevelsBounds() {
        var policy = OutputGuard.Policy.default
        policy.minSimilarity = 0
        policy.wordRatioBounds[.light] = 0.9...1.1
        let verdict = OutputGuard(policy: policy).review(raw: words(100), outcome: .completed(words(85)), options: CleanupOptions(level: .light))
        #expect(verdict == .rejected(.wordRatio(0.85)))
        #expect(policy.wordRatioBounds(for: .medium) == CleanupLevel.medium.wordRatioBounds)
    }

    @Test func lowSimilarityFallsBack() {
        let verdict = review(
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
        #expect(review(raw: "hello", outcome: .timedOut(seconds: 3)) == .rejected(.timedOut(seconds: 3)))
    }

    @Test func cancellationFallsBack() {
        #expect(review(raw: "hello", outcome: .cancelled) == .rejected(.cancelled))
    }

    @Test func generationErrorFallsBack() {
        #expect(review(raw: "hello", outcome: .failed("GPU error")) == .rejected(.generationFailed("GPU error")))
    }

    @Test func fallbackReasonsAreReadable() {
        #expect(FallbackReason.timedOut(seconds: 3).description == "timed out after 3.0s")
        #expect(FallbackReason.wordRatio(1.31).description == "word-count ratio 1.31 outside allowed range")
        #expect(FallbackReason.selfCorrectionNotAllowed.description == "resolved a self-correction at a level that keeps every word")
        #expect(FallbackReason.placeholderChanged.description == "changed a placeholder")
    }

    // MARK: - Levels

    @Test func lightRejectsAResolvedSelfCorrectionThatMediumAccepts() {
        let raw = "we should meet on tuesday sorry wednesday"
        let cleaned = "We should meet on Wednesday."
        #expect(review(raw: raw, outcome: .completed(cleaned), level: .light) == .rejected(.selfCorrectionNotAllowed))
        #expect(review(raw: raw, outcome: .completed(cleaned), level: .medium) == .accepted(cleaned))
        #expect(review(raw: raw, outcome: .completed(cleaned), level: .high) == .accepted(cleaned))
    }

    @Test func lightAcceptsASelfCorrectionKeptAsSpoken() {
        let cleaned = "We should meet on Tuesday, sorry, Wednesday."
        #expect(review(raw: "we should meet on tuesday sorry wednesday", outcome: .completed(cleaned), level: .light) == .accepted(cleaned))
    }

    // MARK: - Placeholders

    @Test func acceptsPlaceholdersThatComeBackIntact() {
        let cleaned = "Here's ⟦S1⟧, and the deck is at ⟦S2⟧."
        let verdict = review(
            raw: "here's ⟦S1⟧ and the deck is at ⟦S2⟧",
            outcome: .completed(cleaned),
            placeholders: ["⟦S1⟧", "⟦S2⟧"]
        )
        #expect(verdict == .accepted(cleaned))
    }

    @Test("Rejects a dropped, repeated, altered or invented placeholder", arguments: [
        "Here's the link, and the deck is at ⟦S2⟧.",
        "Here's ⟦S1⟧ ⟦S1⟧, and the deck is at ⟦S2⟧.",
        "Here's ⟦S 1⟧, and the deck is at ⟦S2⟧.",
        "Here's [S1], and the deck is at ⟦S2⟧.",
        "Here's ⟦S1⟧, and the deck is at ⟦S2⟧ and ⟦S3⟧.",
        "Here's ⟦S1, and the deck is at ⟦S2⟧.",
    ])
    func rejectsADamagedPlaceholder(cleaned: String) {
        let verdict = review(
            raw: "here's ⟦S1⟧ and the deck is at ⟦S2⟧",
            outcome: .completed(cleaned),
            placeholders: ["⟦S1⟧", "⟦S2⟧"]
        )
        #expect(verdict == .rejected(.placeholderChanged))
    }

    @Test func rejectsAPlaceholderRetractedByASelfCorrection() {
        let verdict = review(
            raw: "send them ⟦S1⟧ sorry ⟦S2⟧",
            outcome: .completed("Send them ⟦S2⟧."),
            placeholders: ["⟦S1⟧", "⟦S2⟧"]
        )
        #expect(verdict == .rejected(.placeholderChanged))
    }

    @Test func rejectsATokenInOutputWhenNoneWasGiven() {
        #expect(review(raw: "see you soon", outcome: .completed("See you ⟦S1⟧ soon.")) == .rejected(.placeholderChanged))
    }
}
