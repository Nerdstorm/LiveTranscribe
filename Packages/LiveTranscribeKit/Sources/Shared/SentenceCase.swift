import Foundation

/// Capitalising the word that starts a sentence, a line or a list item.
public enum SentenceCase {
    /// Characters skipped to reach the first word: whitespace and opening quotes and brackets.
    private static let openers: Set<Character> = ["\"", "'", "(", "[", "{", "\u{201C}", "\u{2018}", "\u{00AB}"]

    /// `text` with the first letter of its first word uppercased.
    ///
    /// Whitespace and opening quotes or brackets before the word are skipped ("\"so" becomes
    /// "\"So"). A word that already has a capital ("iPhone", "eBay") stays as written, and so
    /// does text that starts with anything else, such as a digit or an emoji.
    public static func capitalizingFirstWord(_ text: some StringProtocol) -> String {
        guard let start = text.firstIndex(where: { !$0.isWhitespace && !openers.contains($0) }),
              text[start].isLowercase
        else { return String(text) }
        let word = text[start...].prefix { !$0.isWhitespace }
        guard !word.contains(where: \.isUppercase) else { return String(text) }
        return text[..<start] + text[start].uppercased() + text[text.index(after: start)...]
    }
}
