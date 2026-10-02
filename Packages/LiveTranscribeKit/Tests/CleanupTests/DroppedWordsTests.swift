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

    @Test func highMayDeleteARunOfFunctionWordsButNotANegation() {
        let raw = "the demo of the new release for the sales team was really very good"
        let cleaned = "The demo of the new release for the sales team was good."
        #expect(outputGuard.review(raw: raw, outcome: .completed(cleaned), options: medium) == .rejected(.droppedWords(count: 2)))
        #expect(outputGuard.review(raw: raw, outcome: .completed(cleaned), options: CleanupOptions(level: .high)) == .accepted(cleaned))
        #expect(outputGuard.review(raw: "i do not agree with that plan", outcome: .completed("I do agree with that plan."), options: CleanupOptions(level: .high))
            == .rejected(.lostNegation))
    }

    @Test func aReplacementIsNotADeletion() {
        #expect(droppedWords.droppedRun(in: WordAlignment(raw: words("we need twenty five chairs"), cleaned: words("We need 25 chairs.")), fragments: []) == nil)
        #expect(droppedWords.droppedRun(in: WordAlignment(raw: words("email the nerd storm team"), cleaned: words("Email the Nerdstorm team.")), fragments: []) == nil)
    }

    @Test("The start of a word broken off and said again in full may go", arguments: [
        ("She wants few ex expenses paid back.", "She wants few expenses paid back."),
        ("We should con consider the budget first.", "We should consider the budget first."),
        ("can you send the rep report by friday", "Can you send the report by Friday?"),
    ])
    func acceptsADroppedWordFragment(raw: String, cleaned: String) {
        #expect(outputGuard.review(raw: raw, outcome: .completed(cleaned), options: medium) == .accepted(cleaned))
    }

    @Test("A word that only starts the next by chance stays", arguments: [
        ("there is not nothing left", "There is nothing left.", FallbackReason.lostNegation),
        ("bring ten tennis balls", "Bring tennis balls.", .droppedContent(count: 1)),
        // "for" is no fragment of "forty", so the run is two words long.
        ("we could stay for forty minutes", "We could forty minutes.", .droppedWords(count: 2)),
        ("We met the new rep. Reports are due on Monday.", "We met the new. Reports are due on Monday.", .droppedContent(count: 1)),
        ("can you send the rap report by friday", "Can you send the report by Friday?", .droppedContent(count: 1)),
    ])
    func keepsAWordThatIsNoFragment(raw: String, cleaned: String, reason: FallbackReason) {
        #expect(outputGuard.review(raw: raw, outcome: .completed(cleaned), options: medium) == .rejected(reason))
    }

    @Test func fallbackReasonsDoNotRepeatWhatWasSaid() {
        #expect(FallbackReason.droppedWords(count: 3).description == "dropped 3 spoken words")
        #expect(FallbackReason.lostNegation.description == "dropped a negation")
    }
}
