import Foundation
import Shared

/// Picks which vocabulary terms to list in the cleanup prompt, most relevant first.
///
/// The prompt has room for a limited number of terms (the app passes 50): every extra term costs
/// prompt tokens and latency on a small model, and a long list dilutes the ones that matter. The
/// terms that matter most are those the speaker actually said, then those the transcript nearly
/// contains (a mishearing nobody listed as a variant, which the model can still fix), and only
/// then the rest, to fill the remaining room in the order the user added them.
public struct VocabularySelector: Sendable {
    private let terms: [String]
    private let matcher: PhraseMatcher
    private let similarity: TermSimilarity

    /// - Parameters:
    ///   - entries: The vocabulary in stored order, sanitised here as the replacer does (see
    ///     ``VocabularyEntry/sanitized()``) so the prompt lists the stored spelling. Entries
    ///     whose terms differ only in casing are merged under the first, so no term is listed
    ///     twice.
    ///   - similarityThreshold: The lowest ``EditDistance/normalizedSimilarity(_:_:)`` (0...1)
    ///     between a term or variant and a word or adjacent word pair of the text for the term to
    ///     count as nearly said. Lower values admit more distant mishearings, and cost more: the
    ///     search can skip less. In an optimised build, 1,000 terms against a 300-word
    ///     dictation take about 70 ms at 0.8 but about 0.9 s at 0.5 (see ``TermSimilarity``).
    public init(entries: [VocabularyEntry], similarityThreshold: Double) {
        var terms: [String] = []
        var phrasesByTerm: [[String]] = []
        var indexByLowercasedTerm: [String: Int] = [:]
        for entry in entries.map({ $0.sanitized() }) {
            let term = entry.term
            guard !term.isEmpty else { continue }
            let index: Int
            if let existing = indexByLowercasedTerm[term.lowercased()] {
                index = existing
            } else {
                index = terms.count
                indexByLowercasedTerm[term.lowercased()] = index
                terms.append(term)
                phrasesByTerm.append([term])
            }
            phrasesByTerm[index] += entry.spokenVariants
        }
        self.terms = terms
        self.matcher = PhraseMatcher(patterns: phrasesByTerm.enumerated().flatMap { index, phrases in
            phrases.map { PhrasePattern(keys: WordTokenizer.keys(of: $0), termIndex: index) }
        })
        self.similarity = TermSimilarity(phrasesByTerm: phrasesByTerm, threshold: similarityThreshold)
    }

    /// Up to `limit` canonical terms for a prompt about `text`, without duplicates:
    ///
    /// 1. terms whose spelling or a variant occurs in the text (whole words, any casing), in the
    ///    order they occur;
    /// 2. terms similar to a word or adjacent word pair of the text, most similar first;
    /// 3. every other term, in stored order.
    ///
    /// Ties keep the stored order, so the same text always yields the same list.
    public func relevantTerms(for text: String, limit: Int) -> [String] {
        guard limit > 0, !terms.isEmpty else { return [] }
        var selection = Selection(termCount: terms.count, limit: limit)

        let words = WordTokenizer.words(in: text)
        for start in words.indices {
            for match in matcher.allMatches(at: start, in: words, of: text) {
                selection.add(match.termIndex)
                if selection.isFull { return selection.terms(from: terms) }
            }
        }

        for index in similarity.similarTerms(to: text, excluding: selection.contains) {
            selection.add(index)
            if selection.isFull { return selection.terms(from: terms) }
        }

        for index in terms.indices {
            selection.add(index)
            if selection.isFull { break }
        }
        return selection.terms(from: terms)
    }
}

/// The terms chosen so far, in order, up to the limit.
private struct Selection {
    private var chosen: [Int] = []
    private var isChosen: [Bool]
    private let limit: Int

    init(termCount: Int, limit: Int) {
        self.isChosen = Array(repeating: false, count: termCount)
        self.limit = limit
    }

    var isFull: Bool { chosen.count >= limit }

    func contains(_ index: Int) -> Bool { isChosen[index] }

    mutating func add(_ index: Int) {
        guard !isChosen[index], !isFull else { return }
        isChosen[index] = true
        chosen.append(index)
    }

    func terms(from terms: [String]) -> [String] {
        chosen.map { terms[$0] }
    }
}
