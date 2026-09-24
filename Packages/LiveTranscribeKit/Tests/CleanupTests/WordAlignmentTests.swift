@testable import Cleanup
import Testing

@Suite("Word alignment")
struct WordAlignmentTests {
    @Test func gapsPairDeletionsWithWhatReplacedThem() {
        let alignment = WordAlignment(raw: ["a", "b", "c", "d", "e"], cleaned: ["a", "x", "d", "e", "f"])
        #expect(alignment.gaps == [.init(deleted: [1, 2], inserted: [1]), .init(deleted: [], inserted: [4])])
        #expect(alignment.matches == [0, nil, nil, 2, 3])
    }

    @Test func aMovedWordIsDeletedInOneGapAndInsertedInAnother() {
        let alignment = WordAlignment(raw: ["tomorrow", "i", "will", "send", "it"], cleaned: ["i", "will", "send", "it", "tomorrow"])
        #expect(alignment.gaps == [.init(deleted: [0], inserted: []), .init(deleted: [], inserted: [4])])
    }

    @Test func emptyTextHasNoGapsOrOnlyOne() {
        #expect(WordAlignment(raw: [], cleaned: []).gaps.isEmpty)
        #expect(WordAlignment(raw: ["a"], cleaned: []).gaps == [.init(deleted: [0], inserted: [])])
    }
}
