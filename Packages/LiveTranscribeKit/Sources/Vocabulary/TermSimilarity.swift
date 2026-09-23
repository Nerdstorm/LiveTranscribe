import Foundation
import Shared

/// Finds the vocabulary terms a text nearly contains, scoring exactly as
/// ``EditDistance/normalizedSimilarity(_:_:)`` does, fast enough for a large vocabulary.
///
/// The obvious approach, a full edit distance between every term form and every word and word
/// pair of the text, took about 12 seconds (debug build) for a thousand terms against a
/// 300-word dictation, and grows with both. Three things make it cheap without changing any
/// score:
/// - Characters are coded as small integers once, so comparing two is an integer comparison
///   rather than a grapheme-cluster comparison.
/// - Units are grouped by length, and a length is skipped when the difference alone rules it
///   out: the edit distance is at least the difference in length.
/// - The edit distance is computed only within the band of the largest distance that still
///   reaches the threshold, and abandoned as soon as a whole row exceeds it.
struct TermSimilarity: Sendable {
    /// A code for every character in any form. Characters seen only in a text get codes past
    /// these, which match nothing, as they should.
    private let alphabet: [Character: Int]
    /// Per term: its distinct forms (spelling and variants, normalised), as character codes.
    private let formsByTerm: [[[Int]]]
    private let threshold: Double

    /// - Parameters:
    ///   - phrasesByTerm: Per term, its spelling followed by its spoken variants.
    ///   - threshold: The lowest similarity that counts as nearly said.
    init(phrasesByTerm: [[String]], threshold: Double) {
        var alphabet: [Character: Int] = [:]
        var formsByTerm: [[[Int]]] = []
        for phrases in phrasesByTerm {
            var seen: Set<String> = []
            var forms: [[Int]] = []
            for form in phrases.map(EditDistance.normalize) where !form.isEmpty && seen.insert(form).inserted {
                forms.append(Self.encode(form, with: &alphabet))
            }
            formsByTerm.append(forms)
        }
        self.alphabet = alphabet
        self.formsByTerm = formsByTerm
        self.threshold = threshold
    }

    /// Indices of the terms whose best similarity to a word or adjacent word pair of `text`
    /// reaches the threshold, most similar first and ties in term order. Terms for which
    /// `isExcluded` returns true are not scored.
    func similarTerms(to text: String, excluding isExcluded: (Int) -> Bool) -> [Int] {
        var alphabet = self.alphabet
        var unitsByLength: [Int: [[Int]]] = [:]
        for unit in Self.units(in: text) {
            let codes = Self.encode(unit, with: &alphabet)
            unitsByLength[codes.count, default: []].append(codes)
        }
        let unitLengths = unitsByLength.keys.sorted()
        guard let longestUnit = unitLengths.last else { return [] }
        let longestForm = formsByTerm.lazy.flatMap { $0 }.map(\.count).max() ?? 0
        let limits = (0...max(longestUnit, longestForm)).map(largestDistance(within:))

        var rows = BoundedEditDistance.Rows()
        var scored: [(index: Int, score: Double)] = []
        for (index, forms) in formsByTerm.enumerated() where !isExcluded(index) {
            var best = -Double.infinity
            search: for form in forms {
                for length in unitLengths {
                    let longer = max(form.count, length)
                    let limit = limits[longer]
                    let gap = abs(form.count - length)
                    // The gap is a lower bound on the distance, so this is the best score possible.
                    guard gap <= limit, Self.score(distance: gap, longer: longer) > best else { continue }
                    for unit in unitsByLength[length, default: []] {
                        guard let distance = BoundedEditDistance.distance(form, unit, limit: limit, rows: &rows) else { continue }
                        best = max(best, Self.score(distance: distance, longer: longer))
                        if distance == 0 { break search }
                    }
                }
            }
            if best >= threshold {
                scored.append((index, best))
            }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.index)
    }

    /// The largest edit distance between strings whose longer one has `longer` characters that
    /// still scores at least the threshold, or -1 when none does. Found with the same formula
    /// as the score, so the boundary is exactly where ``EditDistance`` puts it.
    private func largestDistance(within longer: Int) -> Int {
        var distance = longer
        while distance >= 0, !(Self.score(distance: distance, longer: longer) >= threshold) {
            distance -= 1
        }
        return distance
    }

    /// ``EditDistance/normalizedSimilarity(_:_:)``'s formula.
    private static func score(distance: Int, longer: Int) -> Double {
        1 - Double(distance) / Double(longer)
    }

    private static func encode(_ text: String, with alphabet: inout [Character: Int]) -> [Int] {
        text.map { character in
            if let code = alphabet[character] { return code }
            let code = alphabet.count
            alphabet[character] = code
            return code
        }
    }

    /// The text's normalised words and adjacent word pairs, without repeats: a name misheard
    /// as two words ("nerd storm" for "Nerdstorm") is only similar as a pair.
    ///
    /// Words come from ``WordTokenizer``, the definition the replacer and the selector's first
    /// ranking step use, so a snippet placeholder ("⟦S1⟧") never counts as something said.
    static func units(in text: String) -> [String] {
        let words = WordTokenizer.words(in: text)
            .flatMap { EditDistance.words(in: EditDistance.normalize($0.key)) }
        let pairs = zip(words, words.dropFirst()).map { "\($0) \($1)" }
        var seen: Set<String> = []
        return (words + pairs).filter { seen.insert($0).inserted }
    }
}

/// Levenshtein distance that gives up past a limit (Ukkonen's banded algorithm).
///
/// Only cells within `limit` of the diagonal can hold a distance of `limit` or less, so each
/// row computes at most `2 * limit + 1` cells, and a row whose cells all exceed the limit ends
/// the computation.
enum BoundedEditDistance {
    /// Two rows reused across calls, so a search over many pairs allocates only as they grow.
    struct Rows {
        var previous: [Int] = []
        var current: [Int] = []
    }

    /// The Levenshtein distance between `source` and `target` when it is at most `limit`;
    /// `nil` when it is larger.
    static func distance(_ source: [Int], _ target: [Int], limit: Int, rows: inout Rows) -> Int? {
        guard limit >= 0, abs(source.count - target.count) <= limit else { return nil }
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }

        let beyond = limit + 1
        let width = target.count + 1
        if rows.previous.count < width {
            rows.previous = Array(repeating: 0, count: width)
            rows.current = Array(repeating: 0, count: width)
        }
        for column in 0..<width {
            rows.previous[column] = min(column, beyond)
        }
        for row in 1...source.count {
            let low = max(1, row - limit)
            let high = min(target.count, row + limit)
            // The cell left of the band: column 0 on the early rows, out of reach otherwise.
            rows.current[low - 1] = low == 1 ? min(row, beyond) : beyond
            var rowMinimum = rows.current[low - 1]
            let sourceCode = source[row - 1]
            for column in low...high {
                let substitution = rows.previous[column - 1] + (sourceCode == target[column - 1] ? 0 : 1)
                let value = min(substitution, rows.previous[column] + 1, rows.current[column - 1] + 1, beyond)
                rows.current[column] = value
                rowMinimum = min(rowMinimum, value)
            }
            // The next row reads one column further right, which this row never computed.
            if high < target.count {
                rows.current[high + 1] = beyond
            }
            guard rowMinimum <= limit else { return nil }
            swap(&rows.previous, &rows.current)
        }
        let result = rows.previous[target.count]
        return result <= limit ? result : nil
    }
}
