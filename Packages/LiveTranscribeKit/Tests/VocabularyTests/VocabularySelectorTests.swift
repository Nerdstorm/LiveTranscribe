import Foundation
import Shared
import Testing
import Vocabulary

@Suite("VocabularySelector")
struct VocabularySelectorTests {
    private func makeSelector(_ entries: [VocabularyEntry], threshold: Double = 0.8) -> VocabularySelector {
        VocabularySelector(entries: entries, similarityThreshold: threshold)
    }

    @Test func termsThatOccurComeFirstInTheOrderTheyOccur() {
        let selector = makeSelector([
            VocabularyEntry(term: "Alpha"),
            VocabularyEntry(term: "Nerdstorm", spokenVariants: ["nerd storm"]),
            VocabularyEntry(term: "GitHub", spokenVariants: ["git hub"]),
            VocabularyEntry(term: "Zeta"),
        ])
        #expect(selector.relevantTerms(for: "push to git hub, then tell nerd storm", limit: 10)
            == ["GitHub", "Nerdstorm", "Alpha", "Zeta"])
    }

    @Test func aTermOccursInAnyCasing() {
        let selector = makeSelector([VocabularyEntry(term: "Alpha"), VocabularyEntry(term: "Swift")])
        #expect(selector.relevantTerms(for: "A SWIFT reply.", limit: 10) == ["Swift", "Alpha"])
    }

    @Test func similarTermsFollowMostSimilarFirst() {
        let selector = makeSelector([
            VocabularyEntry(term: "Postgres"),
            VocabularyEntry(term: "Kafka"),
            VocabularyEntry(term: "Kubernetes"),
        ], threshold: 0.75)
        // "kubernetis" is 0.9 similar to "Kubernetes", "kafca" 0.8 to "Kafka".
        #expect(selector.relevantTerms(for: "we run kubernetis and kafca", limit: 10)
            == ["Kubernetes", "Kafka", "Postgres"])
    }

    /// A name misheard as two words is only similar as a pair: "nerd storm" to "Nerdstorm".
    @Test func adjacentWordPairsCountAsCandidates() {
        let selector = makeSelector([VocabularyEntry(term: "Alpha"), VocabularyEntry(term: "Nerdstorm")], threshold: 0.85)
        #expect(selector.relevantTerms(for: "we met at nerd storm", limit: 10) == ["Nerdstorm", "Alpha"])
    }

    @Test func variantsCountForSimilarity() {
        let selector = makeSelector([VocabularyEntry(term: "Alpha"), VocabularyEntry(term: "Siobhan", spokenVariants: ["shivon"])])
        #expect(selector.relevantTerms(for: "ask shivan", limit: 10) == ["Siobhan", "Alpha"])
    }

    /// The threshold is compared with `EditDistance.normalizedSimilarity`, inclusive.
    @Test func theThresholdIsInclusive() {
        let entries = [VocabularyEntry(term: "Alpha"), VocabularyEntry(term: "Kafka")]
        let similarity = EditDistance.normalizedSimilarity("Kafka", "kafca")
        #expect(makeSelector(entries, threshold: similarity).relevantTerms(for: "kafca", limit: 10) == ["Kafka", "Alpha"])
        #expect(makeSelector(entries, threshold: similarity + 0.01).relevantTerms(for: "kafca", limit: 10) == ["Alpha", "Kafka"])
    }

    @Test("Equally similar terms keep the stored order", arguments: [
        (["Bert", "Bart"], ["Bert", "Bart"]),
        (["Bart", "Bert"], ["Bart", "Bert"]),
    ])
    func tiesKeepStoredOrder(terms: [String], expected: [String]) {
        let selector = makeSelector(terms.map { VocabularyEntry(term: $0) }, threshold: 0.7)
        #expect(selector.relevantTerms(for: "bort", limit: 10) == expected)
    }

    @Test func theRestFollowsInStoredOrderUpToTheLimit() {
        let entries = (0..<60).map { VocabularyEntry(term: String(format: "Term%02d", $0)) }
        let selector = makeSelector(entries, threshold: 0.9)
        let terms = selector.relevantTerms(for: "about term59", limit: 50)
        #expect(terms.count == 50)
        #expect(terms == ["Term59"] + (0..<49).map { String(format: "Term%02d", $0) })
    }

    @Test func termsThatOccurFillASmallLimitFirst() {
        let selector = makeSelector([
            VocabularyEntry(term: "Alpha"),
            VocabularyEntry(term: "Kafka"),
            VocabularyEntry(term: "GitHub"),
        ])
        #expect(selector.relevantTerms(for: "github and kafca", limit: 1) == ["GitHub"])
        #expect(selector.relevantTerms(for: "github and kafca", limit: 2) == ["GitHub", "Kafka"])
    }

    @Test("A limit below one selects nothing", arguments: [0, -1])
    func nonPositiveLimit(limit: Int) {
        #expect(makeSelector([VocabularyEntry(term: "GitHub")]).relevantTerms(for: "github", limit: limit).isEmpty)
    }

    @Test func noEntriesSelectNothing() {
        #expect(makeSelector([]).relevantTerms(for: "anything", limit: 50).isEmpty)
    }

    @Test func aTermIsListedOnceHoweverOftenItMatches() {
        let selector = makeSelector([VocabularyEntry(term: "GitHub", spokenVariants: ["git hub"])])
        #expect(selector.relevantTerms(for: "github and git hub and gitub", limit: 10) == ["GitHub"])
    }

    @Test func entriesWithTheSameTermAreMerged() {
        let selector = makeSelector([
            VocabularyEntry(term: "GitHub", spokenVariants: ["git hub"]),
            VocabularyEntry(term: "github", spokenVariants: ["gid hub"]),
            VocabularyEntry(term: "Alpha"),
        ])
        #expect(selector.relevantTerms(for: "on gid hub", limit: 10) == ["GitHub", "Alpha"])
    }

    /// A snippet placeholder is not speech: "⟦S1⟧" must not make the term "S1" look said,
    /// neither as a match nor as a similar word.
    @Test func placeholdersDoNotCountAsWords() {
        let selector = makeSelector([VocabularyEntry(term: "Alpha"), VocabularyEntry(term: "S1")])
        let text = "send \(PlaceholderToken.make(index: 1)) now"
        #expect(selector.relevantTerms(for: text, limit: 10) == ["Alpha", "S1"])
    }

    /// Punctuation between two words does not stop them forming a pair for similarity: the
    /// list only ranks terms for the prompt, so recall matters more than precision.
    @Test func similarityUsesWordsAcrossPunctuation() {
        let selector = makeSelector([VocabularyEntry(term: "Alpha"), VocabularyEntry(term: "Nerdstorm")], threshold: 0.85)
        #expect(selector.relevantTerms(for: "a nerd, storm", limit: 10) == ["Nerdstorm", "Alpha"])
    }

    /// Entries read from a hand-edited file have not been sanitised by the store.
    @Test func termsAreListedAsTheyWouldBeStored() {
        let selector = makeSelector([VocabularyEntry(term: "  Visual\n Studio   Code "), VocabularyEntry(term: "Alpha")])
        #expect(selector.relevantTerms(for: "", limit: 10) == ["Visual Studio Code", "Alpha"])
    }

    @Test func emptyTextListsTermsInStoredOrder() {
        let selector = makeSelector([VocabularyEntry(term: "Zeta"), VocabularyEntry(term: "Alpha")])
        #expect(selector.relevantTerms(for: "", limit: 10) == ["Zeta", "Alpha"])
    }
}
