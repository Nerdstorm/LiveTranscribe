import Foundation

/// Adds the space a typist would when dictated text lands straight after a word, so dictating
/// "world" after "Hello" gives "Hello world", not "Helloworld".
enum InsertionSpacing {
    /// Characters after which text follows without a space.
    private static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "`", "/", "@", "#", "-", "_", "<"]
    /// Characters that attach to the text before them.
    private static let closers: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "”", "’", "%", "…", ">"]

    /// `text` with a leading space when `preceding`, the character before the cursor, is part of
    /// a word. Unchanged when the character is unknown (paste targets) or the field is empty.
    static func adjusted(_ text: String, after preceding: Character?) -> String {
        guard let preceding, let first = text.first else { return text }
        if preceding.isWhitespace || preceding.isNewline || openers.contains(preceding) { return text }
        if first.isWhitespace || closers.contains(first) { return text }
        return " " + text
    }

    /// The character before `selection` in `value`, or `nil` at the start of the field.
    /// Accessibility ranges count UTF-16 code units.
    static func character(before selection: NSRange, in value: String) -> Character? {
        let string = value as NSString
        guard selection.location != NSNotFound, selection.location > 0, selection.location <= string.length else {
            return nil
        }
        let range = string.rangeOfComposedCharacterSequence(at: selection.location - 1)
        return string.substring(with: range).first
    }
}
