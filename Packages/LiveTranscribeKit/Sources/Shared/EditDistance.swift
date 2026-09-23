import Foundation

/// Levenshtein distance and the metrics built on it.
///
/// Used by the cleanup output guard (character similarity) and by the bench (word error rate).
public enum EditDistance {
    /// Minimum number of insertions, deletions and substitutions turning `source` into `target`.
    public static func levenshtein<Element: Equatable>(_ source: [Element], _ target: [Element]) -> Int {
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }

        var previous = Array(0...target.count)
        var current = [Int](repeating: 0, count: target.count + 1)
        for (i, sourceElement) in source.enumerated() {
            current[0] = i + 1
            for (j, targetElement) in target.enumerated() {
                let substitution = previous[j] + (sourceElement == targetElement ? 0 : 1)
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[target.count]
    }

    /// Character-level Levenshtein distance.
    public static func levenshtein(_ source: String, _ target: String) -> Int {
        levenshtein(Array(source), Array(target))
    }

    /// Similarity in 0...1 of two strings after ``normalize(_:)``: `1 - distance / longerLength`.
    ///
    /// Casing and punctuation are ignored, so the score reflects changes to the words themselves.
    public static func normalizedSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(normalize(lhs))
        let b = Array(normalize(rhs))
        let longer = max(a.count, b.count)
        guard longer > 0 else { return 1 }
        return 1 - Double(levenshtein(a, b)) / Double(longer)
    }

    /// Word error rate of `hypothesis` against `reference`, after ``normalize(_:)``.
    ///
    /// An empty reference scores 0 when the hypothesis is also empty, otherwise 1.
    public static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let referenceWords = words(in: normalize(reference))
        let hypothesisWords = words(in: normalize(hypothesis))
        guard !referenceWords.isEmpty else { return hypothesisWords.isEmpty ? 0 : 1 }
        return Double(levenshtein(referenceWords, hypothesisWords)) / Double(referenceWords.count)
    }

    /// Whitespace-separated words, ignoring empty runs.
    public static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Lowercases, turns hyphens into spaces, removes punctuation except in-word apostrophes,
    /// and collapses whitespace.
    public static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").unicodeScalars {
            if scalar == "-" || scalar == "\u{2014}" || scalar == "\u{2013}" {
                scalars.append(" ")
            } else if scalar == "'" || !CharacterSet.punctuationCharacters.union(.symbols).contains(scalar) {
                scalars.append(scalar)
            }
        }
        let collapsed = words(in: String(scalars))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
        return collapsed.joined(separator: " ")
    }
}
