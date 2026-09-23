import Foundation
import Shared

/// Rewrites known mishearings in a raw transcript to their canonical spelling, before cleanup.
///
/// This is the deterministic half of the vocabulary: a spoken variant the user listed is always
/// fixed, even at cleanup level None and even when the language model would have missed it.
///
/// Matching works on whole words ("git hub" never matches inside "git hubs"), ignores case, and
/// ignores the punctuation around a phrase, which stays where it was: "I work at nerd storm."
/// becomes "I work at Nerdstorm.". A phrase's words must be separated by spaces or hyphens only;
/// a comma or full stop between them means they were not said as one name. Where phrases
/// overlap, the leftmost wins, and at the same position the longest wins. A possessive "'s" on
/// the last word is kept ("git hub's" becomes "GitHub's").
///
/// A term with distinctive casing ("GitHub", "iPhone", "macOS", "Qwen3") is also re-cased where
/// it appears in other casing. Plain words ("Go", "Swift"), all-capital acronyms ("IT", "US")
/// and plain words next to a number ("Swift 6", "Go 2") never are, because that would corrupt
/// ordinary speech (see ``DistinctiveCasing``).
public struct VocabularyReplacer: Sendable {
    private let terms: [String]
    private let matcher: PhraseMatcher

    /// Entries are used in order: where two claim the same phrase, the first wins. Entries
    /// without a term are ignored.
    ///
    /// Each entry is sanitised first (see ``VocabularyEntry/sanitized()``), because entries read
    /// from a hand-edited file have not been through ``VocabularyStore/save(_:)``. Without that,
    /// a variant "go" on the term "Go" would re-case every "go", which the distinctive-casing
    /// rule exists to prevent.
    public init(entries: [VocabularyEntry]) {
        var terms: [String] = []
        var patterns: [PhrasePattern] = []
        for entry in entries.map({ $0.sanitized() }) {
            let term = entry.term
            guard !term.isEmpty else { continue }
            let termIndex = terms.count
            terms.append(term)
            var phrases = entry.spokenVariants
            if DistinctiveCasing.isDistinctive(term: term) {
                phrases.append(term)
            }
            patterns += phrases.map { PhrasePattern(keys: WordTokenizer.keys(of: $0), termIndex: termIndex) }
        }
        self.terms = terms
        self.matcher = PhraseMatcher(patterns: patterns)
    }

    /// `text` with every listed spoken variant replaced by its term. Text with nothing to
    /// replace is returned as it came in.
    public func apply(to text: String) -> String {
        guard !matcher.isEmpty else { return text }
        let words = WordTokenizer.words(in: text)
        var result = ""
        var copiedUpTo = text.startIndex
        var replacements = 0
        var index = 0
        while index < words.count {
            guard let match = matcher.longestMatch(at: index, in: words, of: text) else {
                index += 1
                continue
            }
            let term = terms[match.termIndex]
            if text[match.range] != term {
                result += text[copiedUpTo..<match.range.lowerBound]
                result += term
                copiedUpTo = match.range.upperBound
                replacements += 1
            }
            index += match.wordCount
        }
        guard replacements > 0 else { return text }
        result += text[copiedUpTo...]
        Log.vocabulary.debug("Replaced \(replacements, privacy: .public) vocabulary phrase(s)")
        return result
    }
}
