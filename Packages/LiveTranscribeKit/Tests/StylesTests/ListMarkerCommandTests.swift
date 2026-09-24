import Shared
import Styles
import Testing

@Suite("ListMarkerCommand")
struct ListMarkerCommandTests {
    private let protector = PhraseProtector(matchers: [ListMarkerCommand()])

    @Test func turnsSpokenNumbersIntoListLines() {
        let protected = protector.protect(
            "Tasks for Acme. Number 1, we have to work on the launch. Number two, need to fix the Android build."
        )
        #expect(protected.text
            == "Tasks for Acme. ⟦S1⟧ we have to work on the launch. ⟦S2⟧ need to fix the Android build.")
        #expect(protected.placeholders.map(\.expansion) == ["\n1. ", "\n2. "])
        #expect(protected.placeholders.map(\.spoken) == ["Number 1,", "Number two,"], "unlaid text gets these back")
        #expect(protected.placeholders.allSatisfy { $0.role == .structure })
    }

    @Test func aListAtTheStartNeedsNoLineBreak() {
        let protected = protector.protect("item one apples item two pears")
        #expect(protected.text == "⟦S1⟧ apples ⟦S2⟧ pears")
        #expect(protected.placeholders.map(\.expansion) == ["1. ", "\n2. "])
    }

    @Test func bulletPoints() {
        let protected = protector.protect("Groceries bullet point milk bullet point eggs")
        #expect(protected.text == "Groceries ⟦S1⟧ milk ⟦S2⟧ eggs")
        #expect(protected.placeholders.map(\.expansion) == ["\n- ", "\n- "])
    }

    @Test func aListAfterAColonIsStillAList() {
        let protected = protector.protect("My goals are: number one ship it, number two test it.")
        #expect(protected.placeholders.map(\.expansion) == ["\n1. ", "\n2. "])
    }

    @Test func aNewRunStartsAtOne() {
        let protected = protector.protect("step 1 mix step 2 bake then step one wash step two dry")
        #expect(protected.placeholders.map(\.expansion) == ["1. ", "\n2. ", "\n1. ", "\n2. "])
    }

    @Test("Leaves numbers and bullets that are not a list", arguments: [
        "we're number one",
        "the number one priority is speed and number two is cost",
        "number two and number three",
        "number one and item two",
        "a bullet point is enough",
        "one bullet point here",
        "we need number 1, and a bullet point",
        "speed is number one and cost is number two for us",
        "we're number one and they're number two in sales",
        "speed number one, cost number two",
        "the first bullet point is wrong and the second bullet point is fine",
        "list bullet point milk bullet point",
    ])
    func leavesOtherText(text: String) {
        #expect(protector.protect(text).placeholders.isEmpty)
    }
}
