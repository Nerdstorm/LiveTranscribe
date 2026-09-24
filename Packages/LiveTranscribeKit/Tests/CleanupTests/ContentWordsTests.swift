@testable import Cleanup
import Shared
import Testing

@Suite("OutputGuard: content words")
struct ContentWordsTests {
    private let outputGuard = OutputGuard()

    private func review(_ raw: String, _ cleaned: String, level: CleanupLevel, placeholders: [String] = []) -> GuardVerdict {
        outputGuard.review(raw: raw, outcome: .completed(cleaned), options: CleanupOptions(level: level, placeholders: placeholders))
    }

    private func words(_ text: String) -> [String] {
        EditDistance.words(in: EditDistance.normalize(text))
    }

    @Test("A content word deleted outright is rejected at every level", arguments: [CleanupLevel.light, .medium, .high])
    func rejectsAContentWordDeletedOutright(level: CleanupLevel) {
        #expect(review("we need milk, eggs, and bread.", "We need eggs and bread.", level: level) == .rejected(.droppedContent(count: 1)))
    }

    @Test("Rewording at High may not leave content out", arguments: [
        ("we could meet at the cafe on the corner or at the office", "We could meet at the cafe or the office.", 1),
        ("i need to cancel the order before friday", "I need the order before Friday.", 1),
        ("Shopping list bullet point milk bullet point eggs bullet point bread.", "Shopping list bullet point: milk, eggs, bread.", 4),
        ("thanks ⟦S1⟧ see you tomorrow", "Thanks ⟦S1⟧, see you.", 1),
    ])
    func highRejectsContentLeftOut(raw: String, cleaned: String, count: Int) {
        let placeholders = raw.contains("⟦S1⟧") ? ["⟦S1⟧"] : []
        #expect(review(raw, cleaned, level: .high, placeholders: placeholders) == .rejected(.droppedContent(count: count)))
    }

    @Test("Rewording may replace, reorder, respell, merge and rewrite numbers", arguments: [
        ("i got the tickets for friday", "I have the tickets for Friday."),
        ("tomorrow i will send it to the team", "I will send it to the team tomorrow."),
        ("the meating is at noon", "The meeting is at noon."),
        ("email the nerd storm team", "Email the Nerdstorm team."),
        ("we need twenty five chairs", "We need 25 chairs."),
        ("it costs twenty five dollars", "It costs $25."),
        ("we need 25 chairs", "We need twenty-five chairs."),
        ("honestly the demo was really good", "The demo was good."),
    ])
    func acceptsRewording(raw: String, cleaned: String) {
        let contentWords = ContentWords(policy: .default)
        #expect(contentWords.droppedCount(in: WordAlignment(raw: words(raw), cleaned: words(cleaned)), ignoring: []) == 0)
    }

    @Test func highAcceptsRewordingThatKeepsTheContent() {
        let raw = "please send the final slides to the whole team tomorrow and i got the room booked for friday"
        let cleaned = "Tomorrow, please send the final slides to the whole team. I have the room booked for Friday."
        #expect(review(raw, cleaned, level: .high) == .accepted(cleaned))
        let placeholders = ["⟦S1⟧"]
        #expect(review("send ⟦S1⟧ to the team", "Send ⟦S1⟧ to the team.", level: .high, placeholders: placeholders) == .accepted("Send ⟦S1⟧ to the team."))
    }

    @Test func aWordMovedOverACueIsNotACorrection() {
        #expect(review("tell yasmin or rather victor", "Tell Victor, or rather.", level: .medium) == .rejected(.droppedContent(count: 1)))
    }

    @Test func aWordSaidTwiceInARowMayBeSaidOnce() {
        #expect(review("we need milk milk and bread", "We need milk and bread.", level: .medium) == .accepted("We need milk and bread."))
    }

    @Test func aWordMovedIntoAnotherWordsPlaceDoesNotReplaceIt() {
        let contentWords = ContentWords(policy: .default)
        let alignment = WordAlignment(
            raw: words("hi john thanks for the update cheers sam"),
            cleaned: words("Hi Sam, thanks for the update. Cheers.")
        )
        #expect(contentWords.droppedCount(in: alignment, ignoring: []) == 1)
    }

    @Test func fallbackReasonsCountWordsInPlainWords() {
        #expect(FallbackReason.droppedContent(count: 1).description == "dropped a word that carries meaning")
        #expect(FallbackReason.droppedContent(count: 3).description == "dropped 3 words that carry meaning")
    }
}
