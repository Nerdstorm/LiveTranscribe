@testable import Cleanup
import Shared
import Testing

@Suite("OutputGuard: names")
struct SpokenNamesTests {
    private let outputGuard = OutputGuard()
    private let spokenNames = SpokenNames(policy: .default)
    private static let letter = "Hi John thanks for the update I will review it tomorrow cheers Sam."

    private func review(_ raw: String, _ cleaned: String, level: CleanupLevel = .medium) -> GuardVerdict {
        outputGuard.review(raw: raw, outcome: .completed(cleaned), options: CleanupOptions(level: level))
    }

    private func names(in raw: String, ignoring ignored: Set<String> = []) -> [Int] {
        spokenNames.nameIndices(in: raw, words: EditDistance.words(in: EditDistance.normalize(raw)), ignoring: ignored)
    }

    @Test("The sign-off's name moved into the greeting is rejected at every level", arguments: [CleanupLevel.light, .medium, .high])
    func rejectsTheSignOffsNameInTheGreeting(level: CleanupLevel) {
        let cleaned = "Hi Sam, thanks for the update. I will review it tomorrow. Cheers."
        #expect(review(Self.letter, cleaned, level: level) == .rejected(.movedOrDroppedName))
    }

    @Test("Names swapped, moved or dropped are rejected", arguments: [
        (letter, "Hi Sam, thanks for the update. I will review it tomorrow. Cheers, John."),
        (letter, "Hi John and Sam, thanks for the update. I will review it tomorrow. Cheers."),
        ("Send the report to Priya, Daniel and Ana", "Send the report to Priya and Ana."),
        ("Tell Yasmin, or rather, Victor.", "Tell Victor, or rather."),
    ])
    func rejectsANameOutOfPlace(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.movedOrDroppedName))
    }

    @Test("Names kept, respelled, merged or said once instead of twice are accepted", arguments: [
        (letter, "Hi John, thanks for the update. I will review it tomorrow. Cheers, Sam."),
        ("Hi Jon see you on Friday", "Hi John, see you on Friday."),
        ("Email the Nerd Storm team", "Email the Nerdstorm team."),
        ("Hi John John thanks for coming", "Hi John, thanks for coming."),
    ])
    func acceptsNamesInPlace(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test func namesAreCapitalisedWordsThatDoNotStartASentence() {
        #expect(names(in: Self.letter) == [1, 12])
        #expect(names(in: "Thanks, Sam. Talk soon. OK then, I will call.") == [1])
        #expect(names(in: "Meet at the Café near Jean-Luc's flat") == [3, 5, 6])
        #expect(names(in: "Things to do today: Call the bank") == [])
        #expect(names(in: "Hi Sam\nThanks for coming") == [1])
    }

    @Test func aWordAfterAPlaceholderIsNotAName() {
        #expect(names(in: "Hi ⟦S1⟧ Thanks for coming, Sam", ignoring: ["s1"]) == [5])
    }

    @Test func wordsThatAreNotTheTextsFindNoNames() {
        #expect(spokenNames.nameIndices(in: "Hi John", words: ["hi"], ignoring: []) == [])
    }

    @Test func fallbackReasonSaysWhatHappened() {
        #expect(FallbackReason.movedOrDroppedName.description == "dropped or moved a name")
    }
}
