import Foundation
import Shared

/// Checks that cleanup output which dropped a correction cue removed only spoken self-corrections.
///
/// A self-correction is the retracted words, a cue and the correction: "fuel efficiency in *cars,
/// sorry,* buses". Cleanup may drop the retracted words and the cue, and the correction stays.
/// Output that drops a cue in any other way lost something the speaker meant: "we need three,
/// sorry, four" cleaned to "we need three" keeps the retracted value, and "sorry I'm late" cleaned
/// to "I'm late" drops an apology. ``OutputGuard`` rejects both.
///
/// The cue may be followed by "not" and the retracted words said again, which go with it: "room
/// *four, no, not four,* five". The "not" goes only then, so a contrast keeps it: "Thursday, not
/// Friday".
struct SelfCorrection: Sendable {
    /// The word that, after a cue, says the retracted words again: "sorry, not Tuesday".
    static let restatingWord = "not"

    private let cues: [[String]]
    private let fillers: Set<String>
    private let functionWords: Set<String>
    private let maxRetractedWords: Int
    private let minRespellingSimilarity: Double

    init(policy: OutputGuard.Policy) {
        cues = policy.correctionCues
            .map { EditDistance.words(in: EditDistance.normalize($0)) }
            .filter { !$0.isEmpty }
        fillers = Set(policy.fillers.map(EditDistance.normalize))
        functionWords = Set(policy.functionWords.map(EditDistance.normalize))
        maxRetractedWords = policy.maxRetractedWords
        minRespellingSimilarity = policy.minRespellingSimilarity
    }

    /// Whether `cleaned` has fewer correction cues than `raw`. Both are normalized words.
    func dropsCue(raw: [String], cleaned: [String]) -> Bool {
        cueCount(in: cleaned) < cueCount(in: raw)
    }

    /// Whether `cleaned` can be made from `raw` by keeping words in order and deleting:
    /// - a self-correction: up to `maxRetractedWords` retracted words followed by a cue, or by
    ///   several cues in a row ("high street, wait, no, the shopping centre"), and by "not" and
    ///   the retracted words said again, if the speaker said them ("tuesday, sorry, not tuesday");
    /// - a filler word;
    /// - a word repeated straight after itself.
    ///
    /// A kept word may be respelled ("busses" → "buses"), but a word the speaker said must be
    /// matched where they said it. Otherwise "Tuesday, sorry, Thursday" cleaned to "Tuesday"
    /// would pass as a respelling of "Thursday". Both arrays are normalized words.
    func isCorrection(raw: [String], cleaned: [String]) -> Bool {
        let spoken = Set(raw)
        let spans = correctionSpans(in: raw)

        // matches[i][j]: raw[i...] can become cleaned[j...].
        var matches = Array(repeating: Array(repeating: false, count: cleaned.count + 1), count: raw.count + 1)
        matches[raw.count][cleaned.count] = true
        for i in stride(from: raw.count, through: 0, by: -1) {
            for j in stride(from: cleaned.count, through: 0, by: -1) where !(i == raw.count && j == cleaned.count) {
                if i < raw.count, j < cleaned.count, matches[i + 1][j + 1],
                   keeps(raw[i], as: cleaned[j], spoken: spoken) {
                    matches[i][j] = true
                } else if i < raw.count, matches[i + 1][j], isDroppable(at: i, in: raw) {
                    matches[i][j] = true
                } else if let ends = spans[i], ends.contains(where: { matches[$0][j] }) {
                    matches[i][j] = true
                }
            }
        }
        return matches[0][0]
    }

    func cueCount(in words: [String]) -> Int {
        cues.reduce(0) { count, cue in count + occurrences(of: cue, in: words).count }
    }

    /// Start indices of each occurrence of `cue` in `words`.
    private func occurrences(of cue: [String], in words: [String]) -> [Int] {
        guard words.count >= cue.count else { return [] }
        return (0...(words.count - cue.count)).filter { words[$0..<($0 + cue.count)].elementsEqual(cue) }
    }

    /// For each start index, the end indices (exclusive) of the self-corrections that can be
    /// deleted from there: at least one retracted word, then one or more cues back to back, then
    /// perhaps "not" and the retracted words said again.
    private func correctionSpans(in words: [String]) -> [Int: [Int]] {
        var cueEnds: [Int: [Int]] = [:]
        for cue in cues {
            for cueStart in occurrences(of: cue, in: words) {
                cueEnds[cueStart, default: []].append(cueStart + cue.count)
            }
        }
        // Where a run of back-to-back cues starting at `start` can end.
        func runEnds(from start: Int) -> [Int] {
            (cueEnds[start] ?? []).flatMap { end in [end] + runEnds(from: end) }
        }

        var spans: [Int: [Int]] = [:]
        for cueStart in cueEnds.keys {
            let ends = runEnds(from: cueStart)
            for start in max(0, cueStart - maxRetractedWords)..<cueStart {
                spans[start, default: []].append(contentsOf: ends)
                for end in ends {
                    spans[start, default: []].append(contentsOf: restatedEnds(after: end, retracting: words[start..<cueStart], in: words))
                }
            }
        }
        return spans
    }

    /// Where a self-correction whose cues end at `end` ends instead when "not" follows them and
    /// then the `retracted` words said again ("room four, no, not four, five"), however many of
    /// them the speaker repeats.
    private func restatedEnds(after end: Int, retracting retracted: ArraySlice<String>, in words: [String]) -> [Int] {
        guard end < words.count, words[end] == Self.restatingWord else { return [] }
        let first = end + 1
        return (0..<max(0, min(maxRetractedWords, words.count - first))).compactMap { offset in
            let restated = first..<(first + offset + 1)
            return restates(words[restated], retracted) ? restated.upperBound : nil
        }
    }

    /// Whether `restated` says again some of the `retracted` words: its words that carry meaning,
    /// at least one, are a run of theirs ("not the kitchen" for "kitchen", "not marketing" for
    /// "marketing team").
    private func restates(_ restated: ArraySlice<String>, _ retracted: ArraySlice<String>) -> Bool {
        let isContent = { (word: String) in !functionWords.contains(word) && !fillers.contains(word) }
        let said = restated.filter(isContent), taken = retracted.filter(isContent)
        guard !said.isEmpty, said.count <= taken.count else { return false }
        return (0...(taken.count - said.count)).contains { taken[$0..<($0 + said.count)].elementsEqual(said) }
    }

    private func keeps(_ rawWord: String, as cleanedWord: String, spoken: Set<String>) -> Bool {
        if rawWord == cleanedWord { return true }
        return !spoken.contains(cleanedWord)
            && EditDistance.normalizedSimilarity(rawWord, cleanedWord) >= minRespellingSimilarity
    }

    private func isDroppable(at index: Int, in words: [String]) -> Bool {
        fillers.contains(words[index]) || (index + 1 < words.count && words[index + 1] == words[index])
    }
}
