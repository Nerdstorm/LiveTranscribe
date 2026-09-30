import Foundation
import Shared

extension SelfRepair {
    /// The self-corrections Deep's check lets a repair resolve.
    ///
    /// A correction replaces the words it corrects with its phrase, and the cue goes. Deep reads
    /// two kinds:
    /// - Medium's: up to ``OutputGuard/Policy/maxRetractedWords`` words just before a run of cues,
    ///   taken out with the cues ("we need three, sorry, four"), in the cue's sentence; or, after a
    ///   "scratch that" that opens a sentence, at the end of the one before ("I'll call the plumber
    ///   tomorrow. Scratch that, I'll fix the tap myself.");
    /// - one whose phrase goes back in place of what it corrects, with the words in between kept:
    ///   in an earlier sentence ("The demo is on Tuesday at noon. Sorry, Wednesday." → "The demo
    ///   is on Wednesday at noon.") or earlier in the same one ("three servers at noon, sorry,
    ///   four" → "four servers at noon"). Its corrected words must start and end with a word the
    ///   phrase is about (``relates(_:to:weak:)``), and its phrase must be short.
    ///
    /// Either way, the phrase must take back every fact in the corrected words with one of the
    /// same kind (``phrase(_:takesBackFactsIn:placeholders:)``), so a correction can't also drop
    /// "not" or "at noon", except after "scratch that", which takes back what was said whole; and
    /// inside the phrase, a repair may re-use only the words it corrects ("the Monday after" → "the
    /// Monday after next").
    enum Corrections {
        /// Medium's corrections: for each start, the ends of the corrected words and cues that may
        /// be taken out from there; and for each phrase that follows, the words it may correct and,
        /// of those, the ones its repair may re-use (none after "scratch that").
        static func spans(
            in words: [SaidWord],
            repair: SelfRepair,
            placeholders: Set<String>
        ) -> (ends: [Int: [Int]], corrected: [Int: Set<String>], spare: [Int: Set<String>]) {
            var ends: [Int: [Int]] = [:]
            var correctedWords: [Int: Set<String>] = [:]
            var spare: [Int: Set<String>] = [:]
            for (cueStart, runEnds) in cueRuns(in: words, repair: repair) {
                // Other corrections of an earlier sentence must be about the same thing, which
                // only a phrase that goes back is checked for (``once(_:repair:placeholders:)``).
                let retractsStatement = repair.retractsStatement(words[cueStart...])
                let crosses = cueStart > 0 && words[cueStart - 1].endsSentence
                guard !crosses || retractsStatement else { continue }
                for start in max(0, cueStart - repair.retractionLimit)..<cueStart {
                    let corrected = words[start..<cueStart]
                    guard !corrected.dropLast().contains(where: \.endsSentence),
                          corrected.contains(where: { !repair.isCue($0.word) }),
                          !corrected.contains(where: { placeholders.contains($0.word) })
                    else { continue }
                    // A phrase starts after the whole run of cues.
                    for end in runEnds where end == words.count || !repair.isCue(words[end].word) {
                        let length = min(Alignment.phraseLength(from: end, in: words), SelfRepair.correctionPhraseWords)
                        if !retractsStatement {
                            guard repair.phrase(words[end..<(end + length)], takesBackFactsIn: corrected, placeholders: placeholders) else {
                                continue
                            }
                            spare[end, default: []].formUnion(corrected.map(\.word))
                        }
                        ends[start, default: []].append(end)
                        correctedWords[end, default: []].formUnion(corrected.map(\.word))
                    }
                }
            }
            return (ends, correctedWords, spare)
        }

        /// The words said with the corrections whose phrase goes back applied, in every way they
        /// may be: first one, then, in each result, one more, up to ``maxApplied``. In each result,
        /// a moved phrase opens a correction phrase (``SaidWord/opensPhrase``) that may re-use the
        /// words it corrected (``SaidWord/spare``).
        static func applied(to words: [SaidWord], repair: SelfRepair, placeholders: Set<String>) -> [[SaidWord]] {
            var results: [[SaidWord]] = []
            var frontier = [words]
            for _ in 0..<maxApplied {
                var next: [[SaidWord]] = []
                for said in frontier {
                    for rewritten in once(said, repair: repair, placeholders: placeholders)
                    where results.count < maxRewrites && !results.contains(rewritten) {
                        results.append(rewritten)
                        next.append(rewritten)
                    }
                }
                frontier = next
            }
            return results
        }

        /// How many corrections whose phrase goes back one dictation may have resolved.
        static let maxApplied = 2
        /// How many ways of applying them are checked, which bounds the search.
        static let maxRewrites = 256

        /// Every way of applying one correction whose phrase goes back to `words`.
        private static func once(_ words: [SaidWord], repair: SelfRepair, placeholders: Set<String>) -> [[SaidWord]] {
            // A policy may let no words be taken back, as the prompt probe's does.
            guard repair.retractionLimit > 0 else { return [] }
            var results: [[SaidWord]] = []
            for (cueStart, runEnds) in cueRuns(in: words, repair: repair).sorted(by: { $0.key < $1.key }) {
                guard cueStart > 0, words[cueStart].opensPhrase == 0 else { continue }
                // A cue that opens a sentence corrects the one before, unless it answers it: a lone
                // "No" after a question does; "No, sorry, …" corrects it.
                let crosses = words[cueStart - 1].endsSentence
                let answers = crosses && words[cueStart - 1].endsQuestion && words[cueStart].word == "no"
                // The sentence corrected: the one before the cue's, or the cue's own up to the cue.
                let sentenceStart = (words[..<(cueStart - 1)].lastIndex(where: \.endsSentence) ?? -1) + 1
                for end in runEnds where !(answers && end - cueStart == 1) && end < words.count && !repair.isCue(words[end].word) {
                    let longest = Alignment.phraseLength(from: end, in: words)
                    guard longest > 0 else { continue }
                    let weak = end - cueStart == 1 && weakCues.contains(words[cueStart].word)
                    for length in 1...min(longest, SelfRepair.correctionPhraseWords) {
                        let phrase = end..<(end + length)
                        for start in sentenceStart..<cueStart {
                            for count in 1...min(repair.retractionLimit, cueStart - start) {
                                let corrected = start..<(start + count)
                                // Within a sentence, a phrase that stays where it is was Medium's.
                                guard crosses || corrected.upperBound < cueStart,
                                      !words[corrected].contains(where: { $0.opensPhrase > 0 }),
                                      repair.relates(words[start], to: words[phrase], weak: weak)
                                        || (count == 1 && !weak && repair.replaces(words[start], with: words[phrase])),
                                      repair.relates(words[corrected.upperBound - 1], to: words[phrase], weak: weak)
                                        || (count == 1 && !weak && repair.replaces(words[start], with: words[phrase])),
                                      repair.phrase(words[phrase], takesBackFactsIn: words[corrected], placeholders: placeholders)
                                else { continue }
                                results.append(rewrite(words, correcting: corrected, cues: cueStart..<end, phrase: phrase))
                            }
                        }
                    }
                }
            }
            return results
        }

        /// `words` with `phrase` put in place of `corrected`, and `cues` taken out. The phrase ends
        /// a sentence when it replaced words that did.
        private static func rewrite(_ words: [SaidWord], correcting corrected: Range<Int>, cues: Range<Int>, phrase: Range<Int>) -> [SaidWord] {
            var moved = Array(words[phrase])
            moved[0].opensPhrase = moved.count
            moved[0].spare = words[corrected].map(\.word)
            let lastCorrected = words[corrected.upperBound - 1]
            moved[moved.count - 1].endsSentence = lastCorrected.endsSentence
            moved[moved.count - 1].endsQuestion = lastCorrected.endsQuestion
            return Array(words[..<corrected.lowerBound]) + moved + words[corrected.upperBound..<cues.lowerBound] + words[phrase.upperBound...]
        }

        /// Where each run of cues can end, by where it starts.
        private static func cueRuns(in words: [SaidWord], repair: SelfRepair) -> [Int: [Int]] {
            let texts = words.map(\.word)
            var cueEnds: [Int: [Int]] = [:]
            for cue in repair.correctionCues where texts.count >= cue.count {
                for start in 0...(texts.count - cue.count) where texts[start..<(start + cue.count)].elementsEqual(cue) {
                    cueEnds[start, default: []].append(start + cue.count)
                }
            }
            func runEnds(from start: Int) -> [Int] {
                (cueEnds[start] ?? []).flatMap { end in [end] + runEnds(from: end) }
            }
            return cueEnds.keys.reduce(into: [:]) { runs, start in runs[start] = runEnds(from: start) }
        }

        /// Cue words that as often start a new point as correct the last one.
        static let weakCues: Set<String> = ["no", "wait", "actually", "rather"]
    }

    // MARK: - Facts

    /// Kinds of fact a correction takes back one for one.
    enum FactKind: Hashable {
        /// A number or when: "three", "2:30", "noon", "Tuesday", "May", "tomorrow", "next week".
        /// A run of them is one ("next Monday", "two thirty pm").
        case number
        case unit
        case negation
    }

    /// What fact `word` states, if any. "May" is the month when capitalised, or, with
    /// `mayIsMonth`, when it corrects a month ("the lease ends in april, no wait, may").
    func factKind(_ word: SaidWord, mayIsMonth: Bool = false) -> FactKind? {
        let text = word.word
        if isNegation(text) { return .negation }
        if WordForms.unitWords.contains(text) { return .unit }
        if text == "may" { return word.isCapitalised || mayIsMonth ? .number : nil }
        if WordForms.isNumber(text) || WordForms.partsOfDay.contains(text) || WordForms.timeWords.contains(text) { return .number }
        return nil
    }

    /// How many facts of each kind `words` has. A run of numbers is one, also across the words
    /// that join a number said in parts ("half past two", "ten to five", "two point five").
    private func facts(in words: ArraySlice<SaidWord>, mayIsMonth: Bool = false) -> [FactKind: Int] {
        var counts: [FactKind: Int] = [:]
        var previous: FactKind?
        let list = Array(words)
        for (index, word) in list.enumerated() {
            if previous == .number, Self.numberJoiners.contains(word.word), index + 1 < list.count,
               factKind(list[index + 1], mayIsMonth: mayIsMonth) == .number {
                continue
            }
            let kind = factKind(word, mayIsMonth: mayIsMonth)
            if let kind, !(kind == .number && previous == .number) {
                counts[kind, default: 0] += 1
            }
            previous = kind
        }
        return counts
    }

    private static let numberJoiners: Set<String> = ["past", "to", "and", "point"]

    private static func isMonth(_ word: SaidWord) -> Bool {
        WordForms.monthNames.contains(word.word) || (word.word == "may" && word.isCapitalised)
    }

    /// Whether `phrase` puts one thing in place of `word`, one for one: after a cue that only
    /// ever takes back, a phrase whose only content word is, like `word`, no fact
    /// ("paris, sorry, to madrid"; "the red one, sorry, blue"), which in lowercase text may be a
    /// name no capital shows.
    func replaces(_ word: SaidWord, with phrase: ArraySlice<SaidWord>) -> Bool {
        func isContent(_ text: String) -> Bool { !isFunctionWord(text) && !isFiller(text) && !isCue(text) }
        let content = phrase.filter { isContent($0.word) }
        guard isContent(word.word), factKind(word) == nil, content.count == 1, let other = content.first else { return false }
        return factKind(other) == nil
    }

    /// Whether `phrase` takes back every fact in `corrected` with one of its own kind: a number
    /// with a number, "Tuesday" with "Wednesday", "not" with a negation or the verb it negated
    /// ("I don't, sorry, I do"). A placeholder is never taken back.
    func phrase(_ phrase: ArraySlice<SaidWord>, takesBackFactsIn corrected: ArraySlice<SaidWord>, placeholders: Set<String>) -> Bool {
        guard !corrected.contains(where: { placeholders.contains($0.word) }) else { return false }
        let taken = facts(in: corrected)
        let given = facts(in: phrase, mayIsMonth: corrected.contains(where: Self.isMonth))
        let phraseWords = phrase.map(\.word)
        for (kind, count) in taken {
            var available = given[kind] ?? 0
            if kind == .negation {
                available += corrected.filter { isNegation($0.word) && Self.hasVerb(of: $0.word, in: phraseWords) }.count
            }
            guard count <= available else { return false }
        }
        return true
    }

    /// Whether `word` of a correction's corrected words is something its `phrase` is about: a fact
    /// of the same kind, a name for a name, or, after a cue that only ever takes back (not
    /// `weak`), the same word or a form of it.
    func relates(_ word: SaidWord, to phrase: ArraySlice<SaidWord>, weak: Bool) -> Bool {
        if let kind = factKind(word), kind != .negation,
           phrase.contains(where: { factKind($0, mayIsMonth: Self.isMonth(word)) == kind }) {
            return true
        }
        if word.mayBeName, phrase.contains(where: \.isName) { return true }
        guard !weak, !isFunctionWord(word.word), !isFiller(word.word), !isCue(word.word) else { return false }
        return phrase.contains { $0.word == word.word || WordForms.areForms($0.word, word.word) }
    }

    /// Whether `words` has the verb `negation` negated, in any form: "do" or "did" for "don't".
    private static func hasVerb(of negation: String, in words: [String]) -> Bool {
        guard let verb = WordForms.expansions(of: negation).first?.first else { return false }
        return words.contains { $0 == verb || WordForms.areForms($0, verb) }
    }
}
