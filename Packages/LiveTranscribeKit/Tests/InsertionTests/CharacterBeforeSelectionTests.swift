import Foundation
import Insertion
import Testing

/// The character before the caret decides whether dictated text needs a leading space. It is read
/// on every dictation, so it must never copy the whole field.
@Suite("AccessibilityElement.characterBeforeSelection")
struct CharacterBeforeSelectionTests {
    @Test("Reads the whole character before the caret", arguments: [
        ("Hello", "o"),
        ("Hello ", " "),
        ("Line\n", "\n"),
        // A surrogate pair.
        ("Hi 👋", "👋"),
        // A letter and a combining acute accent: two code points, one character.
        ("Cafe\u{0301}", "e\u{0301}"),
        // A family: four emoji joined by zero-width joiners, 11 UTF-16 units.
        ("Us 👨‍👩‍👧‍👦", "👨‍👩‍👧‍👦"),
        // A flag: two regional indicators.
        ("From 🇦🇺", "🇦🇺"),
        // 21 UTF-16 units, so the window of 16 starts on the second half of the third emoji's
        // surrogate pair; the character at the caret is still read whole.
        ("👋👋👋👋👋👋👋👋👋a👋", "👋"),
    ] as [(String, Character)])
    func readsTheCharacterBeforeTheCaret(value: String, expected: Character) {
        let field = FakeElement(value: value)
        #expect(field.characterBeforeSelection() == expected)
        #expect(field.valueReads == 0)
    }

    @Test func readsTheCharacterBeforeASelection() {
        // "world" selected: dictation replaces it, so the space before it is what counts.
        let field = FakeElement(value: "Hello world", selection: NSRange(location: 6, length: 5))
        #expect(field.characterBeforeSelection() == " ")
    }

    @Test func nothingPrecedesTheStartOfTheField() {
        let field = FakeElement(value: "Hello", selection: NSRange(location: 0, length: 0))
        #expect(field.characterBeforeSelection() == nil)
        #expect(field.stringForRangeRequests.isEmpty, "no text is asked for")
    }

    @Test func readsOnlyAFewUnitsEndingAtTheCaretOfALargeField() throws {
        let document = String(repeating: "All work and no play. ", count: 50_000)
        let field = FakeElement(value: document + "Done", selection: NSRange(location: document.utf16.count + 2, length: 0))

        #expect(field.characterBeforeSelection() == "o")

        let request = try #require(field.stringForRangeRequests.first)
        #expect(field.stringForRangeRequests.count == 1)
        #expect(NSMaxRange(request) == document.utf16.count + 2)
        #expect(request.length <= 16)
        #expect(field.valueReads == 0, "the document is never copied")
    }

    /// Longer than the lookback: cut to its tail, which is still not whitespace, so spacing still
    /// treats it as part of a word.
    @Test func aCharacterLongerThanTheLookbackIsNotTakenForWhitespace() throws {
        let zalgo = "a" + String(repeating: "\u{0301}", count: 40)
        let field = FakeElement(value: "word " + zalgo)

        let character = try #require(field.characterBeforeSelection())

        #expect(!character.isWhitespace)
        #expect(field.valueReads == 0)
    }

    @Test func isUnknownWhenTheAppDoesNotProvideTextForARange() {
        let field = FakeElement(value: "Hello", providesStringForRange: false)
        #expect(field.characterBeforeSelection() == nil)
        #expect(field.valueReads == 0, "no fallback to copying the whole value")
    }

    @Test func isUnknownWhenTheSelectionIsUnreadable() {
        let field = FakeElement(value: "Hello")
        field.clearSelection()
        #expect(field.characterBeforeSelection() == nil)
        #expect(field.stringForRangeRequests.isEmpty)
    }

    @Test func isUnknownForASelectionAtNotFound() {
        let field = FakeElement(value: "Hello", selection: NSRange(location: NSNotFound, length: 0))
        #expect(field.characterBeforeSelection() == nil)
        #expect(field.stringForRangeRequests.isEmpty)
    }

    @Test func isUnknownWhenTheCaretIsPastTheEndOfTheValue() {
        // Some apps report a stale selection; the app answers the range with an error.
        let field = FakeElement(value: "Hi", selection: NSRange(location: 40, length: 0))
        #expect(field.characterBeforeSelection() == nil)
    }
}
