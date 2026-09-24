import Foundation

/// The words the speaker said lined up with the words cleanup returned: a longest common
/// subsequence of the two, and the gaps between its matched words.
///
/// The output guard's checks for lost meaning share one alignment per review. Both arrays are
/// normalized words.
struct WordAlignment: Sendable {
    /// What lies between two consecutive matched words: the raw indices with no counterpart, and
    /// the cleaned indices that stand in their place.
    struct Gap: Sendable, Equatable {
        let deleted: [Int]
        let inserted: [Int]
    }

    let raw: [String]
    let cleaned: [String]
    /// For each raw index, the cleaned index it is matched to; `nil` when it is in a gap.
    let matches: [Int?]
    let gaps: [Gap]

    init(raw: [String], cleaned: [String]) {
        self.raw = raw
        self.cleaned = cleaned
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

        var matches = [Int?](repeating: nil, count: n)
        var gaps: [Gap] = []
        var deleted: [Int] = []
        var inserted: [Int] = []
        func closeGap() {
            if !deleted.isEmpty || !inserted.isEmpty { gaps.append(Gap(deleted: deleted, inserted: inserted)) }
            deleted = []
            inserted = []
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, raw[i] == cleaned[j] {
                closeGap()
                matches[i] = j
                i += 1
                j += 1
            } else if j == m || (i < n && lengths[i + 1][j] >= lengths[i][j + 1]) {
                deleted.append(i)
                i += 1
            } else {
                inserted.append(j)
                j += 1
            }
        }
        closeGap()
        self.matches = matches
        self.gaps = gaps
    }
}
