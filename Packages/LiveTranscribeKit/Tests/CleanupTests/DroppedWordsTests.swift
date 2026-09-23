@testable import Cleanup
import Shared
import Testing

@Suite("OutputGuard: dropped words")
struct DroppedWordsTests {
    private let outputGuard = OutputGuard()
    private let droppedWords = DroppedWords(policy: .default)
    private let medium = CleanupOptions(level: .medium)

    private func words(_ text: String) -> [String] {
        EditDistance.words(in: EditDistance.normalize(text))
    }

    @Test("Deleting a run of spoken words without a cue is rejected", arguments: [
        ("Yeah he said someone will come by on Monday, maybe Tuesday at the latest.",
         "Yeah, he said someone will come by on Tuesday at the latest.", 2),
        ("correction sunday morning i'm away on saturday", "Correction, I'm away on Saturday.", 2),
        ("we could meet at the cafe on the corner or at the office", "We could meet at the office.", 7),
    ])
    func rejectsADeletedRun(raw: String, cleaned: String, count: Int) {
        #expect(outputGuard.review(raw: raw, outcome: .completed(cleaned), options: medium) == .rejected(.droppedWords(count: count)))
    }

    @Test("Removing a negation is rejected", arguments: [
        ("i do not agree with that plan", "I do agree with that plan."),
        ("i can't make it on friday", "I can make it on Friday."),
        ("we never ship on a friday", "We ship on a Friday."),
    ])
    func rejectsALostNegation(raw: String, cleaned: String) {
        #expect(outputGuard.review(raw: raw, outcome: .completed(cleaned), options: medium) == .rejected(.lostNegation))
    }

    @Test("Ordinary corrections are still accepted", arguments: [
        ("so the the numbers look good", "So the numbers look good."),
        ("um i think its fine", "I think it's fine."),
        ("i really think we should go", "I think we should go."),
        ("i cannot make it", "I can't make it."),
        ("we won't ship it before the review on friday", "We will not ship it before the review on Friday."),
    ])
    func acceptsOrdinaryCorrections(raw: String, cleaned: String) {
        #expect(outputGuard.review(raw: raw, outcome: .completed(cleaned), options: medium) == .accepted(cleaned))
    }

    @Test func highMayDeleteWordsWhenRewordingButNotANegation() {
        let high = CleanupOptions(level: .high)
        let cleaned = "We could meet at the cafe or the office."
        #expect(outputGuard.review(raw: "we could meet at the cafe on the corner or at the office", outcome: .completed(cleaned), options: high)
            == .accepted(cleaned))
        #expect(outputGuard.review(raw: "i do not agree with that plan", outcome: .completed("I do agree with that plan."), options: high)
            == .rejected(.lostNegation))
    }

    @Test func aReplacementIsNotADeletion() {
        #expect(droppedWords.droppedRun(raw: words("we need twenty five chairs"), cleaned: words("We need 25 chairs.")) == nil)
        #expect(droppedWords.droppedRun(raw: words("email the nerd storm team"), cleaned: words("Email the Nerdstorm team.")) == nil)
    }

    @Test func gapsPairDeletionsWithWhatReplacedThem() {
        let gaps = DroppedWords.gaps(raw: ["a", "b", "c", "d", "e"], cleaned: ["a", "x", "d", "e", "f"])
        #expect(gaps.map(\.deleted) == [[1, 2], []])
        #expect(gaps.map(\.inserted) == [1, 1])
    }

    @Test func fallbackReasonsDoNotRepeatWhatWasSaid() {
        #expect(FallbackReason.droppedWords(count: 3).description == "dropped 3 spoken words")
        #expect(FallbackReason.lostNegation.description == "dropped a negation")
    }
}
