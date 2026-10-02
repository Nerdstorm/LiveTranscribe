@testable import Cleanup
import Testing

@Suite("OutputGuard: word fragments")
struct WordFragmentsTests {
    private let fragments = WordFragments(policy: .default)

    @Test("The start of a word broken off and said again in full is a fragment", arguments: [
        ("She wants few ex expenses paid back.", 3),
        ("We should con consider the budget first.", 2),
        ("can you send the rep report by friday", 4),
        ("We should con- consider the budget first.", 2),
        ("Con consider the budget first.", 0),
    ])
    func findsAFragment(text: String, index: Int) {
        #expect(fragments.indices(in: text, placeholders: []) == [index])
    }

    @Test("A word that starts the next by chance, or across a sentence, is not one", arguments: [
        // Function words.
        "wait for forty minutes",
        "move it to tomorrow",
        "so soon",
        "the theory",
        "an another",
        // A negation, a number, a unit and a word of time.
        "there is not nothing left",
        "bring ten tennis balls",
        "a cent centrally",
        "the week weekend",
        // Across the end of a sentence.
        "We met the new rep. Reports are due on Monday.",
        // Not the start of the next word, or only one letter short of it.
        "can you send the rap report by friday",
        "check the plan plans",
        // A name.
        "Ask Ed Edwards about it.",
    ])
    func findsNone(text: String) {
        #expect(fragments.indices(in: text, placeholders: []).isEmpty)
    }
}
