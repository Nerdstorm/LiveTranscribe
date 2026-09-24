import Styles
import Testing

@Suite("MarkedListLayout")
struct MarkedListLayoutTests {
    private let layout = MarkedListLayout()

    /// A list dictated as "Number 1, … Number two, …", once its markers start lines.
    @Test func laysOutANumberedListWithItsLeadIn() {
        let lines = [
            "List of to-do tasks for Acme.",
            "1. we have to work on the launch of the new app.",
            "2. need to fix the Android build for the beta.",
        ]
        #expect(layout.arrange(lines) == [
            "List of to-do tasks for Acme:",
            "1. We have to work on the launch of the new app.",
            "2. Need to fix the Android build for the beta.",
        ])
    }

    @Test func laysOutBullets() {
        #expect(layout.arrange(["Groceries.", "- milk,", "- eggs."]) == ["Groceries:", "- Milk", "- Eggs"])
    }

    @Test func startsANewParagraphAfterTheLastItem() {
        #expect(layout.arrange(["My goals:", "1. ship the release.", "2. fix the login bug. Then we celebrate."])
            == ["My goals:", "1. Ship the release", "2. Fix the login bug", "", "Then we celebrate."])
    }

    @Test func aListRightAfterAnotherHasNoLeadIn() {
        #expect(layout.arrange(["1. a", "2. b", "- c", "- d"]) == ["1. A", "2. B", "- C", "- D"])
    }

    @Test func leavesLinesThatAreNotAList() {
        #expect(layout.arrange(["Just a sentence.", "Another line."]) == nil)
    }
}

@Suite("OrdinalListLayout")
struct OrdinalListLayoutTests {
    private let layout = OrdinalListLayout()

    @Test func laysOutAnEnumerationWithinALine() {
        #expect(layout.arrange(["Hello.", "We need three things: first, milk; second, eggs; and third, bread."])
            == ["Hello.", "We need three things:", "1. Milk", "2. Eggs", "3. Bread"])
    }

    @Test func laysOutAListNumberedWithCardinals() {
        #expect(layout.arrange(["Two things. One is the build, two is the docs. Thanks for checking."])
            == ["Two things:", "1. The build", "2. The docs", "", "Thanks for checking."])
    }

    @Test func leavesListLinesAlone() {
        #expect(layout.arrange(["1. First, check it. Second, ship it."]) == nil)
    }
}

@Suite("Layout")
struct LayoutTests {
    @Test func arrangesEachParagraph() {
        let text = "Plan for today.\n1. write the tests\n2. ship it\n\nWe need two things: first, milk; second, eggs."
        #expect(Layout().arrange(text)
            == "Plan for today:\n1. Write the tests\n2. Ship it\n\nWe need two things:\n1. Milk\n2. Eggs")
    }

    @Test func leavesProseAsItIs() {
        let text = "Hi John,\n\nThe build is green.\n\nCheers,\nSam"
        #expect(Layout().arrange(text) == text)
    }

    @Test func findsTheFirstFrameThatFits() {
        #expect(Layout().frame(in: "Hi John thanks for the update cheers Sam.")?.opening == "Hi John,\n\n")
        #expect(Layout().frame(in: "Thanks for the update.") == nil)
        #expect(Layout(frames: []).frame(in: "Hi John thanks for the update cheers Sam.") == nil)
    }

    @Test func assemblesTheFrameAroundTheCleanedBody() {
        let frame = TextFrame(opening: "Hi John,\n\n", body: "thanks", closing: "\n\nCheers,\nSam")
        #expect(frame.assembled(body: " thanks for the update. \n")
            == "Hi John,\n\nThanks for the update.\n\nCheers,\nSam")
    }
}
