import Foundation

/// Adds the space a typist would when dictated text lands straight after a word, so dictating
/// "world" after "Hello" gives "Hello world", not "Helloworld".
enum InsertionSpacing {
    /// Characters after which text follows without a space.
    private static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "`", "/", "@", "#", "-", "_", "<"]
    /// Characters that attach to the text before them.
    private static let closers: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "”", "’", "%", "…", ">"]

    /// `text` with a leading space when `preceding`, the character before the cursor, is part of
    /// a word. Unchanged when the character is unknown (no focused element, or the app cannot
    /// provide the text before the caret) or the field is empty.
    static func adjusted(_ text: String, after preceding: Character?) -> String {
        guard let preceding, let first = text.first else { return text }
        if preceding.isWhitespace || preceding.isNewline || openers.contains(preceding) { return text }
        if first.isWhitespace || closers.contains(first) { return text }
        return " " + text
    }
}
