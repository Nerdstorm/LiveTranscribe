import Foundation

/// Which canonical terms may be re-cased wherever they appear.
///
/// Re-casing "github" to "GitHub" is safe because nobody writes "github" meaning anything else.
/// Re-casing "go" to "Go" or "swift" to "Swift" would corrupt ordinary speech, so only terms
/// whose spelling cannot be an ordinary word qualify. The replacer runs at every cleanup level,
/// including None, so a wrong re-casing here is never corrected later.
enum DistinctiveCasing {
    /// A term qualifies when any of its words does (see ``isDistinctive(word:)``). A multi-word
    /// term is only ever re-cased as the whole phrase, never word by word.
    static func isDistinctive(term: String) -> Bool {
        WordTokenizer.words(in: term).contains { isDistinctive(word: term[$0.range]) }
    }

    /// A word qualifies when it mixes letters and digits ("Qwen3", "M4", "4K") or mixes cases
    /// with a capital after its first character ("GitHub", "iPhone", "macOS").
    ///
    /// Two kinds of word look distinctive but are not:
    /// - All-capital words ("NASA", "IT", "US"): many acronyms are also ordinary words ("it",
    ///   "us", "who", "arm").
    /// - Numbers on their own ("6", "2", "11"): they have no casing, so in "Swift 6" or "Go 2"
    ///   only the plain word would be re-cased, and "I'd go 2 more rounds" would become
    ///   "I'd Go 2 more rounds".
    static func isDistinctive(word: Substring) -> Bool {
        let hasLetter = word.contains(where: \.isLetter)
        if hasLetter, word.contains(where: \.isNumber) { return true }
        return word.contains(where: \.isLowercase) && word.dropFirst().contains(where: \.isUppercase)
    }
}
