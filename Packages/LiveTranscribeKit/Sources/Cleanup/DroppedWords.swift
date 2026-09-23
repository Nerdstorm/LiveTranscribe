import Foundation
import Shared

/// Finds meaning the cleanup output lost without dropping a correction cue: a run of spoken
/// words deleted with nothing in their place ("Monday, maybe Tuesday" → "Tuesday"), or a
/// negation removed ("I do not agree" → "I do agree"). Both can pass the length and similarity
/// limits, and both change what the speaker said.
///
/// Words are aligned exactly, so a respelling or a number written as digits ("twenty five" →
/// "25") counts as a replacement, not a deletion. Fillers and a word repeated straight after
/// itself may always go.
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
    /// `raw` and `cleaned` are normalized words.
    func droppedRun(raw: [String], cleaned: [String]) -> Int? {
        let longest = Self.gaps(raw: raw, cleaned: cleaned)
            .filter { $0.inserted == 0 }
            .map { gap in gap.deleted.filter { !isDroppable(at: $0, in: raw) }.count }
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

    /// Between consecutive matched words of a longest-common-subsequence alignment: the raw
    /// indices with no counterpart, and how many cleaned words stand in their place.
    static func gaps(raw: [String], cleaned: [String]) -> [(deleted: [Int], inserted: Int)] {
        let n = raw.count, m = cleaned.count
        // lengths[i][j]: LCS length of raw[i...] and cleaned[j...].
        var lengths = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i][j] = raw[i] == cleaned[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var gaps: [(deleted: [Int], inserted: Int)] = []
        var deleted: [Int] = []
        var inserted = 0
        func closeGap() {
            if !deleted.isEmpty || inserted > 0 { gaps.append((deleted, inserted)) }
            deleted = []
            inserted = 0
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, raw[i] == cleaned[j] {
                closeGap()
                i += 1
                j += 1
            } else if j == m || (i < n && lengths[i + 1][j] >= lengths[i][j + 1]) {
                deleted.append(i)
                i += 1
            } else {
                inserted += 1
                j += 1
            }
        }
        closeGap()
        return gaps
    }
}
