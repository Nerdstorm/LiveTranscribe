import Styles
import Testing

@Suite("FillerRemover")
struct FillerRemoverTests {
    private let remover = FillerRemover()

    @Test("Removes standalone fillers", arguments: [
        ("so um we need to uh ship it", "so we need to ship it"),
        ("So, um, we need to ship it.", "So, we need to ship it."),
        ("Um, I think it's fine.", "I think it's fine."),
        ("Uh, so the build is green.", "So the build is green."),
        ("That's it, um.", "That's it."),
        ("Well... hmm... maybe Friday?", "Well... maybe Friday?"),
        ("um um uh okay", "okay"),
        ("It works. Erm, mostly.", "It works. Mostly."),
    ])
    func removesFillers(input: String, expected: String) {
        #expect(remover.removingFillers(from: input) == expected)
    }

    @Test("Leaves words that only contain a filler", arguments: [
        "Bring an umbrella.",
        "Uh-oh, the build failed.",
        "The error is in the header.",
        "I like it, you know.",
    ])
    func keepsOtherWords(input: String) {
        #expect(remover.removingFillers(from: input) == input)
    }

    @Test func aTranscriptOfOnlyFillersBecomesEmpty() {
        #expect(remover.removingFillers(from: "Um... uh.").isEmpty)
    }

    @Test func usesTheGivenFillers() {
        #expect(FillerRemover(fillers: ["like"]).removingFillers(from: "it was like fine") == "it was fine")
    }
}
