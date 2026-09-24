import Styles
import Testing

@Suite("ListFormatter")
struct ListFormatterTests {
    private let formatter = ListFormatter()

    @Test func formatsAnEnumerationWithALeadIn() {
        #expect(formatter.formatted("We need three things: first, milk; second, eggs; and third, bread.")
            == "We need three things:\n1. Milk\n2. Eggs\n3. Bread")
    }

    @Test func addsAColonToALeadInThatHasNone() {
        #expect(formatter.formatted("For the launch, first we update the docs, second we tag the release.")
            == "For the launch:\n1. We update the docs\n2. We tag the release")
    }

    /// Ordinals must start clauses; unpunctuated text (a cleanup fallback) is left alone rather
    /// than guessed at.
    @Test func needsPunctuationToFindClauses() {
        #expect(formatter.formatted("for the launch first we update the docs second we tag the release") == nil)
    }

    @Test func keepsTextAfterTheListOnItsOwnLine() {
        #expect(formatter.formatted("First, we fix the login bug. Second, we ship the release. Then we celebrate.")
            == "1. We fix the login bug.\n2. We ship the release.\nThen we celebrate.")
    }

    @Test func finallyClosesTheList() {
        #expect(formatter.formatted("Firstly, speed. Secondly, cost. And finally, quality.")
            == "1. Speed\n2. Cost\n3. Quality")
    }

    @Test func firstOfAllIsOneMarker() {
        #expect(formatter.formatted("First of all, thanks for coming. Second, the agenda.")
            == "1. Thanks for coming\n2. The agenda")
    }

    @Test("Leaves text that is not an enumeration", arguments: [
        "The first and second floors are closed.",
        "First, let me say thanks.",
        "First, the budget. Third, the timeline.",
        "At first we thought the second build was broken.",
        "",
    ])
    func leavesOtherText(text: String) {
        #expect(formatter.formatted(text) == nil)
    }

    @Test func keepsQuestionMarks() {
        #expect(formatter.formatted("First, who owns it? Second, when is it due?")
            == "1. Who owns it?\n2. When is it due?")
    }
}
