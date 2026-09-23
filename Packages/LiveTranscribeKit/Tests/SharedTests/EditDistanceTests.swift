import Shared
import Testing

@Suite("EditDistance")
struct EditDistanceTests {
    @Test("Levenshtein on known character pairs", arguments: [
        ("kitten", "sitting", 3),
        ("flaw", "lawn", 2),
        ("", "abc", 3),
        ("abc", "", 3),
        ("same", "same", 0),
        ("", "", 0),
    ])
    func characterDistance(source: String, target: String, expected: Int) {
        #expect(EditDistance.levenshtein(source, target) == expected)
    }

    @Test func wordDistanceCountsWholeWords() {
        let reference = ["the", "cat", "sat", "on", "the", "mat"]
        let hypothesis = ["the", "cat", "sat", "on", "mat", "today"]
        #expect(EditDistance.levenshtein(reference, hypothesis) == 2)
    }

    @Test func werIsZeroForIdenticalText() {
        #expect(EditDistance.wordErrorRate(reference: "the cat sat", hypothesis: "the cat sat") == 0)
    }

    @Test func werIgnoresCasingAndPunctuation() {
        #expect(EditDistance.wordErrorRate(reference: "Hello, world! It's fine.", hypothesis: "hello world it's fine") == 0)
    }

    @Test func werCountsSubstitutionDeletionAndInsertion() {
        #expect(EditDistance.wordErrorRate(reference: "the cat sat", hypothesis: "the bat sat") == 1.0 / 3.0)
        #expect(EditDistance.wordErrorRate(reference: "the cat sat down", hypothesis: "the cat down") == 0.25)
        #expect(EditDistance.wordErrorRate(reference: "the cat", hypothesis: "the big cat") == 0.5)
    }

    @Test func werWithEmptyReference() {
        #expect(EditDistance.wordErrorRate(reference: "", hypothesis: "") == 0)
        #expect(EditDistance.wordErrorRate(reference: "  ", hypothesis: "noise") == 1)
    }

    @Test func similarityIgnoresCasingAndPunctuation() {
        #expect(EditDistance.normalizedSimilarity("i think we should go", "I think we should go.") == 1)
    }

    @Test func similarityOfUnrelatedTextIsLow() {
        #expect(EditDistance.normalizedSimilarity("the meeting is on tuesday", "banana smoothie recipe") < 0.4)
    }

    @Test func normalizeTreatsHyphensAsSpacesAndKeepsApostrophes() {
        #expect(EditDistance.normalize("Well-known, don\u{2019}t STOP!") == "well known don't stop")
    }
}
