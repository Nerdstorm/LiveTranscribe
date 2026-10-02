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

    @Test func startsANewParagraphAfterTheList() {
        #expect(formatter.formatted("First, we fix the login bug. Second, we ship the release. Then we celebrate.")
            == "1. We fix the login bug.\n2. We ship the release.\n\nThen we celebrate.")
    }

    @Test func finallyClosesTheList() {
        #expect(formatter.formatted("Firstly, speed. Secondly, cost. And finally, quality.")
            == "1. Speed\n2. Cost\n3. Quality")
    }

    @Test func firstOfAllIsOneMarker() {
        #expect(formatter.formatted("First of all, thanks for coming. Second, the agenda.")
            == "1. Thanks for coming\n2. The agenda")
    }

    @Test("Words that introduce an item belong to its ordinal", arguments: [
        ("I have a few to-do items. First is work on getting the weed killer. Second is go to the hardware store and buy the weed killer.",
         "I have a few to-do items:\n1. Work on getting the weed killer.\n2. Go to the hardware store and buy the weed killer."),
        ("First thing is milk. Second thing is eggs.", "1. Milk\n2. Eggs"),
        ("First one's milk, second one\u{2019}s eggs.", "1. Milk\n2. Eggs"),
        ("Firstly was the budget. Secondly was the timeline.", "1. The budget\n2. The timeline"),
    ])
    func introducingWordsBelongToTheOrdinal(text: String, list: String) {
        #expect(formatter.formatted(text) == list)
    }

    @Test("An \"is\" that asks stays in its item", arguments: [
        "First, is it ready? Second, is it tested?",
        "First is it ready? Second is it tested?",
    ])
    func anIsThatAsksStays(text: String) {
        #expect(formatter.formatted(text) == "1. Is it ready?\n2. Is it tested?")
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

    @Test("Cardinals number a list when \"is\", a comma, a colon or a full stop follows them", arguments: [
        ("one is XYZ, two is kyt", "1. XYZ\n2. Kyt"),
        (
            "There are a few things I need to talk to you about. One is the launch of the app. Two, the marketing plan.",
            "There are a few things I need to talk to you about:\n1. The launch of the app\n2. The marketing plan"
        ),
        ("Two options: one, fly on Monday; two, drive on Sunday.", "Two options:\n1. Fly on Monday\n2. Drive on Sunday"),
        ("One: the venue. Two: the invites. Three: the catering.", "1. The venue\n2. The invites\n3. The catering"),
        ("One. Book the venue. Two. Send the invites.", "1. Book the venue\n2. Send the invites"),
        ("1 is the budget, 2 is the timeline, and finally the team.", "1. The budget\n2. The timeline\n3. The team"),
    ])
    func cardinalsNumberAList(text: String, list: String) {
        #expect(formatter.formatted(text) == list)
    }

    @Test("Leaves cardinals that don't introduce items", arguments: [
        "One of them left early. Two stayed behind.",
        "Two people came and one left.",
        "One, two, three, go!",
        "We need one, two or three volunteers.",
        "I only need one.",
        "One is enough.",
    ])
    func leavesOtherCardinals(text: String) {
        #expect(formatter.formatted(text) == nil)
    }

    @Test("A list may switch between ordinals, cardinals and \"number\"", arguments: [
        ("First, book the venue. Two, send the invites.", "1. Book the venue\n2. Send the invites"),
        ("One is the budget. Second, the timeline.", "1. The budget\n2. The timeline"),
        ("One, book the venue. Number two, send the invites.", "1. Book the venue\n2. Send the invites"),
        ("Number one, book the venue. Two, send the invites.", "1. Book the venue\n2. Send the invites"),
        ("Number one, book the venue. Second, send the invites.", "1. Book the venue\n2. Send the invites"),
        ("First, book the venue. Number two is send the invites.", "1. Book the venue\n2. Send the invites"),
        (
            "First, book the venue. Second, send the invites. Three, order the food.",
            "1. Book the venue\n2. Send the invites\n3. Order the food"
        ),
        (
            "One, book the venue. Two, send the invites. Number three, order the food.",
            "1. Book the venue\n2. Send the invites\n3. Order the food"
        ),
        (
            "We need two things: one, the venue; and item two, the invites.",
            "We need two things:\n1. The venue\n2. The invites"
        ),
    ])
    func switchesMarkerStyles(text: String, list: String) {
        #expect(formatter.formatted(text) == list)
    }

    @Test("Numbers inside an item stay in it when the markers around them start sentences", arguments: [
        (
            "I have two questions. One, are we sure that when we fix one and two, then the build will pass? Number two, what does it cost?",
            "I have two questions:\n1. Are we sure that when we fix one and two, then the build will pass?\n2. What does it cost?"
        ),
        (
            "One, when we fix one, and two, then does it pass? Number two, what does it cost?",
            "1. When we fix one, and two, then does it pass?\n2. What does it cost?"
        ),
        (
            "One, if we do it, one, and two, then does it pass? Number two, what does it cost?",
            "1. If we do it, one, and two, then does it pass?\n2. What does it cost?"
        ),
        ("First, pick one, two, then ship. Second, test it.", "1. Pick one, two, then ship\n2. Test it"),
    ])
    func numbersInsideAnItemStayInIt(text: String, list: String) {
        #expect(formatter.formatted(text) == list)
    }

    @Test("Leaves markers of other styles that don't make a list", arguments: [
        "Number one, two, three, go!",
        "We're number one. Number two is Apple.",
        "Speed is number one, number two is cost.",
        "First, the budget. Number three, the timeline.",
        "One, speed. Two people came.",
        "Number two, the venue. Three, the invites.",
    ])
    func leavesOtherStyles(text: String) {
        #expect(formatter.formatted(text) == nil)
    }

    /// A one that isn't followed by two leaves the list to a later one.
    @Test func aOneBeforeTheSecondItemStartsTheListAgain() {
        #expect(formatter.formatted("One is enough, I thought. Then there were two issues. One is the build. Two, the docs.")
            == "One is enough, I thought. Then there were two issues:\n1. The build\n2. The docs")
    }

    @Test func keepsQuestionMarks() {
        #expect(formatter.formatted("First, who owns it? Second, when is it due?")
            == "1. Who owns it?\n2. When is it due?")
    }
}
