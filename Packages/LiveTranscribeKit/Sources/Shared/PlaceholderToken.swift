import Foundation

/// The opaque tokens (`⟦S1⟧`, `⟦S2⟧`, …) that stand in for snippet text while a transcript goes
/// through the language model, so the model can neither see nor change the expansion.
///
/// Defined once here because two slices must agree on it: Snippets makes the tokens and
/// Cleanup's output guard checks that they came back intact.
public enum PlaceholderToken {
    public static let opening: Character = "⟦"
    public static let closing: Character = "⟧"

    /// The token for the `index`th placeholder in a text, counting from 1.
    public static func make(index: Int) -> String {
        "\(opening)S\(index)\(closing)"
    }

    /// Opening brackets in `text`: the number of tokens it holds, whole or damaged.
    public static func openingCount(in text: String) -> Int {
        text.reduce(0) { $1 == opening ? $0 + 1 : $0 }
    }

    /// Closing brackets in `text`.
    public static func closingCount(in text: String) -> Int {
        text.reduce(0) { $1 == closing ? $0 + 1 : $0 }
    }

    /// Occurrences of `token` in `text`.
    public static func occurrences(of token: String, in text: String) -> Int {
        guard !token.isEmpty else { return 0 }
        return text.components(separatedBy: token).count - 1
    }
}
