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

    @Test func anIsAfterTheNumberBelongsToTheMarker() {
        let protected = protector.protect("Number one is ship the release, number two is fix the build.")
        #expect(protected.text == "⟦S1⟧ ship the release, ⟦S2⟧ fix the build.")
        #expect(protected.placeholders.map(\.spoken) == ["Number one is", "number two is"], "unlaid text gets these back")
    }

    @Test("An \"is\" that asks stays in its item", arguments: [
        "Number one, is it ready? Number two, is it tested?",
        "Number one is it ready? Number two is it tested?",
    ])
    func anIsThatAsksStays(text: String) {
        #expect(protector.protect(text).text == "⟦S1⟧ is it ready? ⟦S2⟧ is it tested?")
    }

    @Test func laterNumbersMayBeSaidBare() {
        let protected = protector.protect(
            "A few things. Number one, the registration form can be shortened. Two, the Google sign-in failed. Three, the emails were late."
        )
        #expect(protected.text
            == "A few things. ⟦S1⟧ the registration form can be shortened. ⟦S2⟧ the Google sign-in failed. ⟦S3⟧ the emails were late.")
        #expect(protected.placeholders.map(\.expansion) == ["\n1. ", "\n2. ", "\n3. "])
        #expect(protected.placeholders.map(\.spoken) == ["Number one,", "Two,", "Three,"], "unlaid text gets these back")
    }

    @Test("A bare number continues a run that said its first number", arguments: [
        ("Step one, open the app. Two, tap save. Three, close it.", ["1. ", "\n2. ", "\n3. "]),
        ("Item one: apples. Two: pears.", ["1. ", "\n2. "]),
        ("Number one is speed. Two is cost.", ["1. ", "\n2. "]),
        ("Number 1, speed. 2, cost. 3, price.", ["1. ", "\n2. ", "\n3. "]),
        ("Number one, speed. Number two, cost. Three, price.", ["1. ", "\n2. ", "\n3. "]),
        ("Number one speed. Two. cost.", ["1. ", "\n2. "]),
    ])
    func bareNumbersContinueARun(text: String, expansions: [String]) {
        #expect(protector.protect(text).placeholders.map(\.expansion) == expansions)
    }

    @Test("A bare number alone, out of order or not starting a clause is not a marker", arguments: [
        "Number one, speed. Two people came. Three, cost.",
        "Number one, speed. Three, cost.",
        "Number one, speed. We have two, cost and speed.",
        "Number one, speed and two, cost.",
        "Number one, speed. Two is it ready?",
        "Two, cost. Three, speed.",
        "Number one, speed. Two",
        "One, speed. Two, cost.",
        "Choose from number one, two, three or four.",
        "Number one, two, three, go!",
        "Number one, two. Three, four.",
    ])
    func bareNumbersThatAreNotMarkers(text: String) {
        let protected = protector.protect(text)
        #expect(protected.placeholders.isEmpty)
        #expect(protected.text == text, "the speaker's words are all still there")
    }

    @Test func aBareNumberContinuesTheRunOfTheNearestKeyword() {
        let protected = protector.protect("Item one, apples. Number one, speed. Two, cost.")
        #expect(protected.placeholders.map(\.spoken) == ["Number one,", "Two,"])
        #expect(protected.text.hasPrefix("Item one, apples. ⟦S1⟧"), "an item run of one is not a list")
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
