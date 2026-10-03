import Foundation
import Shared

/// Finds meaning the cleanup output lost without dropping a correction cue: a run of spoken
/// words deleted with nothing in their place ("Monday, maybe Tuesday" → "Tuesday"), or a
/// negation removed ("I do not agree" → "I do agree"). Both can pass the length and similarity
/// limits, and both change what the speaker said.
///
/// Words are aligned exactly, so a respelling or a number written as digits ("twenty five" →
/// "25") counts as a replacement, not a deletion. Fillers, a word repeated straight after itself
/// and the start of a word broken off and said again in full (``WordFragments``) may always go.
struct DroppedWords: Sendable {
    private let fillers: Set<String>
    private let negations: Set<String>
    private let maxDroppedRun: Int

    init(policy: OutputGuard.Policy) {
        fillers = Set(policy.fillers.map(EditDistance.normalize))
        negations = Set(policy.negations.map(EditDistance.normalize))
        maxDroppedRun = policy.maxDroppedRun
    }

    /// The longest run of spoken words deleted without replacement, beyond the allowed run.
    /// `fragments` are the raw indices of the starts of words broken off (``WordFragments``).
    func droppedRun(in alignment: WordAlignment, fragments: Set<Int>) -> Int? {
        let longest = alignment.gaps
            .filter(\.inserted.isEmpty)
            .map { gap in gap.deleted.filter { !fragments.contains($0) && !isDroppable(at: $0, in: alignment.raw) }.count }
            .max() ?? 0
        return longest > maxDroppedRun ? longest : nil
    }

    /// Whether `cleaned` has fewer negations than `raw`.
    func losesNegation(raw: [String], cleaned: [String]) -> Bool {
        negationCount(in: cleaned) < negationCount(in: raw)
    }

    private func negationCount(in words: [String]) -> Int {
        words.filter { negations.contains($0) || $0.hasSuffix("n't") }.count
    }

    private func isDroppable(at index: Int, in words: [String]) -> Bool {
        fillers.contains(words[index])
            || (index + 1 < words.count && words[index + 1] == words[index])
            || (index > 0 && words[index - 1] == words[index])
    }
}
