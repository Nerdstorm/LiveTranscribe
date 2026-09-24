import Styles
import Testing

@Suite("ListStyle")
struct ListStyleTests {
    private let style = ListStyle()

    @Test("Ends the line before a list with a colon", arguments: [
        ("Tasks for the week.", "Tasks for the week:"),
        ("Tasks for the week", "Tasks for the week:"),
        ("For the launch,", "For the launch:"),
        ("We need:", "We need:"),
        ("What do we need?", "What do we need?"),
        ("Great news!", "Great news!"),
    ])
    func endsTheLeadInWithAColon(line: String, expected: String) {
        #expect(style.leadIn(line) == expected)
    }

    @Test func aBlankLineIsNoLeadIn() {
        #expect(style.leadIn("  ") == nil)
        #expect(style.leadIn(".") == nil)
    }

    @Test func itemsThatAreSentencesKeepTheirFullStops() {
        #expect(style.items(["we have to work on the launch.", "need to fix the Android build."])
            == ["We have to work on the launch.", "Need to fix the Android build."])
    }

    @Test func shortItemsLoseTheirFullStops() {
        #expect(style.items(["milk,", "eggs;", "bread."]) == ["Milk", "Eggs", "Bread"])
        #expect(style.items(["we fix the login bug.", "ship it."]) == ["We fix the login bug", "Ship it"])
    }

    @Test func questionAndExclamationMarksStay() {
        #expect(style.items(["who owns it?", "ship it!"]) == ["Who owns it?", "Ship it!"])
    }

    @Test func leadingPunctuationGoes() {
        #expect(style.items([", milk", ": eggs"]) == ["Milk", "Eggs"])
    }

    @Test func aSentenceCanBeShorterWhenConfigured() {
        #expect(ListStyle(minimumSentenceWords: 2).items(["ship it.", "fix it."]) == ["Ship it.", "Fix it."])
    }

    @Test func namesWrittenWithCapitalsStayAsWritten() {
        #expect(style.items(["iPhone app", "eBay listing"]) == ["iPhone app", "eBay listing"])
    }
}
