@testable import Dictation
import Foundation
import Testing

@Suite("InsertionSpacing")
struct InsertionSpacingTests {
    @Test("A space is added after a word", arguments: [
        (Character("o"), "world", " world"),
        (Character("."), "Next sentence.", " Next sentence."),
        (Character(","), "and then", " and then"),
        (Character("7"), "items", " items"),
    ])
    func addsASpaceAfterAWord(preceding: Character, text: String, expected: String) {
        #expect(InsertionSpacing.adjusted(text, after: preceding) == expected)
    }

    @Test("No space where a typist would not add one", arguments: [
        (Character?.none, "Hello"),
        (Character(" "), "world"),
        (Character("\n"), "New line"),
        (Character("("), "aside"),
        (Character("“"), "quoted"),
        (Character("@"), "mention"),
        (Character("o"), ", and more"),
        (Character("o"), "."),
        (Character("o"), ""),
    ])
    func leavesTextAlone(preceding: Character?, text: String) {
        #expect(InsertionSpacing.adjusted(text, after: preceding) == text)
    }

    @Test func readsTheCharacterBeforeTheCursorInUTF16() {
        #expect(InsertionSpacing.character(before: NSRange(location: 5, length: 0), in: "Hello world") == "o")
        #expect(InsertionSpacing.character(before: NSRange(location: 0, length: 0), in: "Hello") == nil)
        #expect(InsertionSpacing.character(before: NSRange(location: 6, length: 0), in: "Hello") == nil)
        #expect(InsertionSpacing.character(before: NSRange(location: NSNotFound, length: 0), in: "Hello") == nil)
        // "Hi 👋" is 5 UTF-16 units; the emoji is a surrogate pair.
        #expect(InsertionSpacing.character(before: NSRange(location: 5, length: 0), in: "Hi 👋") == "👋")
    }
}
