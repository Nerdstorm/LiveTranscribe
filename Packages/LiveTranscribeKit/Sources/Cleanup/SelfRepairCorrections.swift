import Foundation
import Shared

extension SelfRepair {
    /// The self-corrections Deep's check lets a repair resolve.
    ///
    /// A correction replaces the words it corrects with its phrase, and the cue goes. Deep reads
    /// two kinds:
    /// - Medium's: up to ``OutputGuard/Policy/maxRetractedWords`` words just before a run of cues,
    ///   taken out with the cues ("we need three, sorry, four"), in the cue's sentence; or at the
    ///   end of the one before, when the cues open the next: one phrase that doesn't start it ("I
    ///   left my charger in the garage. Actually, the lobby."), or more after a "scratch that"
    ///   ("I'll call the plumber tomorrow. Scratch that, I'll fix the tap myself.") or after cues
    ///   followed by "not" and exactly those words ("We'll need compasses. Sorry, not compasses.
    ///   Stoves.");
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
    /// Monday after next"). The cues may be followed by "not" and corrected words said again, which
    /// go with them ("room four, no, not four, five"; ``restates(_:_:)``).
    ///
    /// A correction must also keep its meaning: the word that says what it says instead, its
    /// phrase's key word (``keyWord(of:correcting:)``), stays, as itself or a word like it
    /// ("busses" → "buses"), and the corrected words it takes back are never written again
    /// (``takenBack(by:from:)``, ``stoodInFor(phrase:key:corrected:)``), so "the blue room, sorry,
    /// the green room" is "the green room", and neither "the blue room" nor "the blue green room".
    /// Nor does a phrase that says the corrected words again after a new word leave the word before
    /// them, which the new word takes back (``leavesTakenBack(_:corrected:phrase:)``); it corrects
    /// that word too ("The billing service goes live. Sorry, I mean the login service." → "The
    /// login service goes live."). Nor does a fact or a name leave the one of its sort just before
    /// the words it corrects ("three servers, sorry, four" corrects "three", never only "servers").
    /// Medium's take back no more than the corrected words said again ("the physio team, sorry,
    /// not physio, nursing" is never "the nursing"), and no less than a sentence that a phrase
    /// opening the way it did starts again ("Ship it to Prague, scratch that, hold it until
    /// September" is never "Ship it to hold it until September"). In text written with capitals and
    /// punctuation, one takes back its whole sentence so far only when its phrase shows it says all
    /// of it again ("Insurance for ferries, no wait, boats went up again." is never "Boats went up
    /// again."; ``takesBackTooMuch(before:corrected:phrase:)``).
    enum Corrections {
        /// Medium's corrections in the words said, by said index.
        struct Spans {
            /// For each start, the ends of the corrected words and cues that may be taken out from
            /// there.
            var ends: [Int: [Int]] = [:]
            /// For each phrase that follows, by where it starts, the words it may correct.
            var corrected: [Int: Set<String>] = [:]
            /// Of those, the ones its repair may re-use (none after "scratch that").
            var spare: [Int: Set<String>] = [:]
            /// For each phrase, by where it starts, the corrected words its key word takes back,
            /// which no repair may write again.
            var taken: [Int: Set<String>] = [:]
            /// Where the key words of the phrases are, which no repair may change.
            var keys: [Int] = []
        }

        /// Medium's corrections in `words`.
        static func spans(in words: [SaidWord], repair: SelfRepair, placeholders: Set<String>) -> Spans {
            var spans = Spans()
            // Every word each phrase may correct, by where it starts. Which of them a repair took
            // back isn't known, so its key word and the words that takes back are found among them
            // all.
            var takenBack: [Int: Set<Int>] = [:]
            // Capitals show names only in text speech-to-text wrote with them: a capital a name may
            // have, and no sentence started in lower case. A vocabulary term or a weekday in text
            // written without capitals ("alice knows, sorry, tara will lead the review on Monday")
            // isn't one.
            let cased = words.contains(where: \.mayBeName) && !words.contains { $0.startsSentence && $0.isLowerCase }
            for (cueStart, runEnds) in cueRuns(in: words, repair: repair) {
                // Speech-to-text ends a sentence where the speaker paused, so a cue that opens one
                // may take back the end of the one before ("I left my charger in the garage.
                // Actually, the lobby."): one phrase, after a word that stays, for a phrase that
                // starts like it and not with a subject. "Sorry, I haven't had time" after "I
                // finished the report.", "Actually, it's quite fast" after "It works." and
                // "Actually, we shipped it early" after "We shipped version two." start a new
                // thought; "Sorry, four" after "three servers for the launch." and "No, three"
                // after "Bring two chairs." take back only the number
                // (``once(_:repair:placeholders:)``). Saying the corrected words again ("compasses.
                // Sorry, not compasses. Stoves and water.") or "scratch that" takes back more.
                let retractsStatement = repair.retractsStatement(words[cueStart...])
                let crosses = cueStart > 0 && words[cueStart - 1].endsSentence
                let sentenceStart = crosses ? (words[..<(cueStart - 1)].lastIndex(where: \.endsSentence) ?? -1) + 1 : 0
                // A lone "No" after a question answers it ("Is it on Tuesday? No, not Tuesday,
                // Thursday."), as ``once(_:repair:placeholders:)`` reads it.
                let answers = crosses && words[cueStart - 1].endsQuestion && words[cueStart].word == "no"
                // The sentence the corrected words end, and its first word that carries meaning, if
                // the cues can take back from there.
                let first = (words[..<max(cueStart - 1, 0)].lastIndex(where: \.endsSentence) ?? -1) + 1
                let opening = words[first..<cueStart].firstIndex(where: repair.carriesMeaning)
                    .flatMap { $0 + repair.retractionLimit >= cueStart ? $0 : nil }
                // Cues speech-to-text set off with punctuation, in text it wrote with capitals.
                let setOff = cased && cueStart > 0 && words[cueStart - 1].pausesAfter
                for start in max(0, cueStart - repair.retractionLimit)..<cueStart {
                    let corrected = words[start..<cueStart]
                    guard !corrected.dropLast().contains(where: \.endsSentence),
                          corrected.contains(where: { !repair.isCue($0.word) }),
                          !corrected.contains(where: { placeholders.contains($0.word) })
                    else { continue }
                    let isContent = { (word: SaidWord) in
                        !repair.isFunctionWord(word.word) && !repair.isFiller(word.word) && !repair.isCue(word.word)
                    }
                    let endsSentenceBefore = words[sentenceStart..<start].contains(where: isContent)
                        && corrected.dropFirst().allSatisfy(isContent)
                    let saysMoreThanAFact = corrected.contains { isContent($0) && repair.factKind($0) == nil }
                    func standsIn(from end: Int) -> Bool {
                        guard endsSentenceBefore, end < words.count, isContent(words[end]) == isContent(words[start]),
                              !subjects.contains(words[end].word)
                        else { return false }
                        let first = words[end...].prefix(SelfRepair.correctionPhraseWords).first(where: isContent)
                        return !(saysMoreThanAFact && first.map { repair.factKind($0) != nil } == true)
                    }
                    // A phrase starts after the whole run of cues, and after the corrected words
                    // said again, which are all it takes back: "the physio team, sorry, not
                    // physio, nursing" corrects "physio", and is never "the nursing".
                    for runEnd in runEnds where !(answers && runEnd - cueStart == 1) {
                        for (end, restated) in phraseStarts(after: runEnd, in: words, repair: repair)
                        where (end == words.count || !repair.isCue(words[end].word))
                            && restated.map({ repair.restates(words[$0], corrected) && repair.restates(corrected, words[$0]) }) ?? true
                            && (!crosses || retractsStatement || restated != nil || standsIn(from: end)) {
                            let length = min(Alignment.phraseLength(from: end, in: words), SelfRepair.correctionPhraseWords)
                            let phrase = words[end..<(end + length)]
                            // A phrase that opens the way its sentence did starts it again, and
                            // takes back from there: "Ship it to Prague, scratch that, hold it
                            // until September" is never "Ship it to hold it until September".
                            if let opening, start > opening, repair.restarts(words[opening..<cueStart], phrase: phrase) {
                                continue
                            }
                            guard !repair.leavesTakenBack(words, corrected: start..<cueStart, phrase: phrase) else { continue }
                            if !retractsStatement {
                                guard repair.phrase(phrase, takesBackFactsIn: corrected, placeholders: placeholders) else {
                                    continue
                                }
                                spans.spare[end, default: []].formUnion(corrected.map(\.word))
                            }
                            // A reading that takes back too much is turned down, but its words count
                            // among those the phrase may correct all the same: leaving them out
                            // would let a repair add them to the phrase as new words, and turning a
                            // reading down must never let another through.
                            takenBack[end, default: []].formUnion(start..<cueStart)
                            spans.corrected[end, default: []].formUnion(corrected.map(\.word))
                            if setOff, !retractsStatement, restated.map({ repair.restates(corrected, words[$0]) }) != true,
                               repair.takesBackTooMuch(before: words[first..<start], corrected: corrected, phrase: phrase) {
                                continue
                            }
                            spans.ends[start, default: []].append(end)
                        }
                    }
                }
            }
            for (end, indices) in takenBack {
                let length = min(Alignment.phraseLength(from: end, in: words), SelfRepair.correctionPhraseWords)
                let phrase = words[end..<(end + length)]
                let corrected = indices.sorted().map { words[$0] }[...]
                if let key = repair.keyWord(of: phrase, correcting: corrected) {
                    spans.keys.append(end + key)
                    spans.taken[end] = repair.stoodInFor(phrase: phrase, key: key, corrected: corrected)
                }
            }
            return spans
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

        /// `words` without each correction that opens a later sentence, from its cue to the end of
        /// that sentence: the text an answer would be that dropped the correction and kept what it
        /// corrects as said ("Meet me at the Old Town Hall. Actually no, the Town Hall." → "Meet me
        /// at the Old Town Hall."), which no repair gives.
        static func dropped(from words: [SaidWord], repair: SelfRepair) -> [[SaidWord]] {
            cueRuns(in: words, repair: repair).keys.sorted().compactMap { cueStart in
                guard cueStart > 0, words[cueStart - 1].endsSentence else { return nil }
                let sentenceEnd = words[cueStart...].firstIndex(where: \.endsSentence).map { $0 + 1 } ?? words.count
                return Array(words[..<cueStart] + words[sentenceEnd...])
            }
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
                for runEnd in runEnds where !(answers && runEnd - cueStart == 1) {
                    for (end, restated) in phraseStarts(after: runEnd, in: words, repair: repair)
                    where end < words.count && !repair.isCue(words[end].word) {
                        let longest = Alignment.phraseLength(from: end, in: words)
                        guard longest > 0 else { continue }
                        // Saying the corrected words again makes even a weak cue a correction.
                        let weak = restated == nil && end - cueStart == 1 && weakCues.contains(words[cueStart].word)
                        for length in 1...min(longest, SelfRepair.correctionPhraseWords) {
                            let phrase = end..<(end + length)
                            for start in sentenceStart..<cueStart {
                                for count in 1...min(repair.retractionLimit, cueStart - start) {
                                    let corrected = start..<(start + count)
                                    // Within a sentence, a phrase that stays where it is was Medium's.
                                    guard crosses || corrected.upperBound < cueStart,
                                          !words[corrected].contains(where: { $0.opensPhrase > 0 }),
                                          restated.map({ repair.restates(words[$0], words[corrected]) }) ?? true,
                                          repair.relates(words[start], to: words[phrase], weak: weak)
                                            || (count == 1 && !weak && repair.replaces(words[start], with: words[phrase]))
                                            || repair.takesBackFirst(words[corrected], phrase: words[phrase]),
                                          repair.relates(words[corrected.upperBound - 1], to: words[phrase], weak: weak)
                                            || (count == 1 && !weak && repair.replaces(words[start], with: words[phrase])),
                                          repair.phrase(words[phrase], takesBackFactsIn: words[corrected], placeholders: placeholders),
                                          !repair.leavesTakenBack(words, corrected: corrected, phrase: words[phrase])
                                    else { continue }
                                    results.append(rewrite(words, correcting: corrected, cues: cueStart..<end, phrase: phrase))
                                }
                            }
                        }
                    }
                }
            }
            return results
        }

        /// `words` with `phrase` put in place of `corrected`, and `cues` taken out. The phrase ends
        /// a sentence when it replaced words that did. A phrase an earlier correction opened ends
        /// where its words stop following each other, as when this one takes a cue out of it
        /// ("email no one").
        private static func rewrite(_ said: [SaidWord], correcting corrected: Range<Int>, cues: Range<Int>, phrase: Range<Int>) -> [SaidWord] {
            var words = said
            for segment in [0..<corrected.lowerBound, phrase, corrected.upperBound..<cues.lowerBound, phrase.upperBound..<words.count] {
                for index in segment where words[index].opensPhrase > 0 {
                    words[index].opensPhrase = min(words[index].opensPhrase, segment.upperBound - index)
                }
            }
            var moved = Array(words[phrase])
            moved[0].opensPhrase = moved.count
            moved[0].spare = words[corrected].map(\.word)
            let lastCorrected = words[corrected.upperBound - 1]
            moved[moved.count - 1].endsSentence = lastCorrected.endsSentence
            moved[moved.count - 1].endsQuestion = lastCorrected.endsQuestion
            return Array(words[..<corrected.lowerBound]) + moved + words[corrected.upperBound..<cues.lowerBound] + words[phrase.upperBound...]
        }

        /// Where a correction's phrase can start after a run of cues that ends at `end`: there, or,
        /// when "not" follows the cues, after the corrected words said again ("Tuesday, sorry, not
        /// Tuesday, Thursday"), with the range of the words said again, which must be among the
        /// corrected words (``SelfRepair/restates(_:_:)``). Those words may end their sentence,
        /// since speech-to-text ends one where the speaker paused ("not Sunday. Thursday."), and
        /// the phrase then starts the next.
        private static func phraseStarts(after end: Int, in words: [SaidWord], repair: SelfRepair) -> [(start: Int, restated: Range<Int>?)] {
            var starts: [(start: Int, restated: Range<Int>?)] = [(end, nil)]
            guard end < words.count, words[end].word == SelfCorrection.restatingWord else { return starts }
            for last in (end + 1)..<min(end + 1 + repair.retractionLimit, words.count) {
                starts.append((last + 1, (end + 1)..<(last + 1)))
                if words[last].endsSentence { break }
            }
            return starts
        }

        /// Where each run of cues can end, by where it starts; a cue misheard as another word
        /// (``cueSoundAlikes``) may end it. The ends of a run follow the order of the policy's cues,
        /// which decides which rewrites ``maxRewrites`` keeps.
        private static func cueRuns(in words: [SaidWord], repair: SelfRepair) -> [Int: [Int]] {
            let texts = words.map(\.word)
            var cueEnds: [Int: [Int]] = [:]
            for cue in repair.correctionCues where texts.count >= cue.count {
                for start in 0...(texts.count - cue.count) where texts[start..<(start + cue.count)].elementsEqual(cue) {
                    let end = start + cue.count
                    cueEnds[start, default: []].append(end)
                    // A cue speech-to-text misheard, just after one it didn't, goes with it ("the
                    // monitor, wait, node, the router").
                    if end < texts.count, cueSoundAlikes.contains(texts[end]) {
                        cueEnds[start, default: []].append(end + 1)
                    }
                }
            }
            func runEnds(from start: Int) -> [Int] {
                (cueEnds[start] ?? []).flatMap { end in [end] + runEnds(from: end) }
            }
            return cueEnds.keys.reduce(into: [:]) { runs, start in runs[start] = runEnds(from: start) }
        }

        /// Cue words that as often start a new point as correct the last one.
        static let weakCues: Set<String> = ["no", "wait", "actually", "rather"]
        /// Words speech-to-text writes for a cue ("know" for "no", "weight" for "wait", "made" for
        /// "make"), which say nothing a correction says instead.
        static let cueSoundAlikes: Set<String> = ["know", "now", "note", "node", "weight", "weigh", "way", "made", "maid"]
        /// Words that start a new clause, which a correction of the sentence before doesn't.
        static let subjects: Set<String> = [
            "i", "we", "you", "he", "she", "it", "they", "i'm", "i'll", "i've", "i'd", "we're", "we'll", "we've", "we'd",
            "you're", "you'll", "you've", "he's", "he'll", "she's", "she'll", "it's", "it'll", "they're", "they'll",
            "they've", "there's", "that's", "let's",
        ]
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

    /// Whether `restated`, said after a cue and "not", says again some of the `corrected` words:
    /// its words that carry meaning, at least one, are a run of theirs ("not the kitchen" for
    /// "kitchen", "not marketing" for "marketing team"). Only then does the "not" go with the
    /// correction; any other keeps what it negates ("Thursday, not Friday").
    func restates(_ restated: ArraySlice<SaidWord>, _ corrected: ArraySlice<SaidWord>) -> Bool {
        let content = { (words: ArraySlice<SaidWord>) in words.map(\.word).filter { !isFunctionWord($0) && !isFiller($0) } }
        let said = content(restated), taken = content(corrected)
        guard !said.isEmpty, said.count <= taken.count else { return false }
        return (0...(taken.count - said.count)).contains { taken[$0..<($0 + said.count)].elementsEqual(said) }
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

    // MARK: - Meaning

    /// Whether a correction's `phrase` starts again the sentence whose words from its first that
    /// carries meaning up to the cues are `said`: the phrase's first word is that word ("Book the
    /// early flight. Scratch that. Book the afternoon one."); or carries meaning in its place, and
    /// its second is the word said next ("ship it" → "hold it"); or says nothing new before a
    /// second that is that word ("ship it" → "just ship it"). A word is said again as itself, or
    /// as another form of a word that carries meaning.
    func restarts(_ said: ArraySlice<SaidWord>, phrase: ArraySlice<SaidWord>) -> Bool {
        let opening = phrase.filter { !isFiller($0.word) }
        guard let lead = opening.first, let first = said.first else { return false }
        func saysAgain(_ said: SaidWord, _ word: SaidWord) -> Bool {
            said.word == word.word || (carriesMeaning(said) && WordForms.areForms(said.word, word.word))
        }
        if saysAgain(first, lead) { return true }
        guard opening.count > 1 else { return false }
        let next = opening[1]
        let leadsIn = !carriesMeaning(lead) || WordForms.droppable.contains(lead.word)
        return (carriesMeaning(lead) && said.dropFirst().first.map { saysAgain($0, next) } == true)
            || (leadsIn && saysAgain(first, next))
    }

    /// Whether a reading of a correction takes back its whole sentence so far with nothing to show
    /// that its `phrase` says all of it again: the `corrected` words hold two or more that carry
    /// meaning, none does in the words `before` them in their sentence, and the phrase neither
    /// opens like them (``opensAlike(_:phrase:)``) nor says one of them again. "Insurance for
    /// ferries, no wait, boats went up again." corrects "ferries", and is never "Boats went up
    /// again."; "My laptop battery, no wait, my phone is dead." is "My phone is dead.".
    ///
    /// Only for cues that text written with capitals and punctuation sets off: there a word
    /// without a capital is no name, so "Alice knows, sorry, Tara will lead the design review."
    /// opens a name for a name, a false start. In lower case "alice knows sorry tara will lead the
    /// design review" reads like the ferries, and nothing tells them apart.
    func takesBackTooMuch(before: ArraySlice<SaidWord>, corrected: ArraySlice<SaidWord>, phrase: ArraySlice<SaidWord>) -> Bool {
        !before.contains(where: carriesMeaning)
            && corrected.filter(carriesMeaning).count > 1
            && !corrected.contains { carriesMeaning($0) && Self.isSaid($0, in: phrase) }
            && !opensAlike(corrected, phrase: phrase)
    }

    /// Whether `phrase` opens like the `corrected` words, a word for a word: its first, or its
    /// second after its first, or after a first of theirs, that only leads in ("on Monday" →
    /// "Tuesday"; "the red car" → "a red bike"). Words are alike when they are the same word, forms
    /// of a word that carries meaning, both capitalised as a name may be, or facts of one kind.
    private func opensAlike(_ corrected: ArraySlice<SaidWord>, phrase: ArraySlice<SaidWord>) -> Bool {
        let opening = phrase.filter { !isFiller($0.word) }
        guard let lead = opening.first, let first = corrected.first else { return false }
        func alike(_ said: SaidWord, _ word: SaidWord) -> Bool {
            said.word == word.word
                || (carriesMeaning(said) && WordForms.areForms(said.word, word.word))
                || (said.mayBeName && word.mayBeName)
                || factKind(said).map { $0 != .negation && factKind(word, mayIsMonth: Self.isMonth(said)) == $0 } == true
        }
        func leadsIn(_ word: SaidWord) -> Bool { !carriesMeaning(word) || WordForms.droppable.contains(word.word) }
        let second = corrected.dropFirst().first
        if alike(first, lead) { return true }
        if opening.count > 1 {
            let next = opening[1]
            if second.map({ alike($0, next) }) == true || (leadsIn(lead) && alike(first, next)) { return true }
        }
        return leadsIn(first) && second.map { alike($0, lead) } == true
    }

    /// Whether `word` says something a correction can take back or say instead: it holds more than
    /// the grammar together, and isn't a filler, a cue, or a cue as speech-to-text misheard it
    /// ("know" for "no").
    private func carriesMeaning(_ word: SaidWord) -> Bool {
        !isFunctionWord(word.word) && !isFiller(word.word) && !isCue(word.word)
            && !Corrections.cueSoundAlikes.contains(word.word)
    }

    /// Whether `word` is likely a word that holds the grammar together, misheard ("thee" for "the",
    /// "theon" for "then"): no fact or name, and close to one.
    private func isMisheardFunctionWord(_ word: SaidWord) -> Bool {
        guard !word.mayBeName, factKind(word) == nil else { return false }
        let length = word.word.count
        return allFunctionWords.contains { functionWord in
            let other = functionWord.count
            // Words further apart in length can't be as alike.
            return Double(abs(length - other)) <= (1 - Self.minMisheardSimilarity) * Double(max(length, other))
                && EditDistance.normalizedSimilarity(word.word, functionWord) >= Self.minMisheardSimilarity
        }
    }

    /// How far into a correction's `phrase` its key word is: the first word that carries meaning
    /// and isn't among the `corrected` words or a misheard word that only holds the grammar
    /// together, which says what the correction says instead ("green" in "the blue room, sorry,
    /// the green room"). No repair may change it into another word, so an answer can't keep what
    /// was corrected and lose the correction.
    func keyWord(of phrase: ArraySlice<SaidWord>, correcting corrected: ArraySlice<SaidWord>) -> Int? {
        phrase.firstIndex { carriesMeaning($0) && !Self.isSaid($0, in: corrected) && !isMisheardFunctionWord($0) }
            .map { $0 - phrase.startIndex }
    }

    /// What sort of thing a word says, finer than ``FactKind``, for what a key word takes back.
    private enum Sort {
        case number, day, month
        /// Another word of time ("tomorrow", "noon", "week").
        case time
        case unit, negation
        /// A name, capitalised where no sentence starts.
        case name
        /// Any other word that carries meaning.
        case word
    }

    /// What sort of thing `word` says, which a key word takes back one of its own sort of.
    private func sort(of word: SaidWord, mayIsMonth: Bool = false) -> Sort {
        switch factKind(word, mayIsMonth: mayIsMonth) {
        case nil: word.isName ? .name : .word
        case .negation: .negation
        case .unit: .unit
        case .number where WordForms.isNumber(word.word): .number
        case .number where Self.days.contains(word.word): .day
        case .number where Self.isMonth(word) || word.word == "may": .month
        case .number: .time
        }
    }

    /// The `corrected` words a correction whose `phrase` goes back takes back, which no repair may
    /// write again once it has a key word: those that carry meaning and that the phrase doesn't say
    /// again ("Tuesday" for "Wednesday", "billing" for "the login service").
    func takenBack(by phrase: ArraySlice<SaidWord>, from corrected: ArraySlice<SaidWord>) -> Set<String> {
        Set(corrected.filter { carriesMeaning($0) && !Self.isSaid($0, in: phrase) }.map(\.word))
    }

    /// Of the words a phrase of Medium's corrections may correct (`corrected`, all of them, since
    /// which a repair took back isn't known), the ones the key word `key` words into the phrase
    /// stands in for, which no repair may write again: the one where the phrase puts it, found by a
    /// word the phrase says again after it ("blue" in "the blue room, sorry, the green room") or
    /// else before it ("Sam" in "send it to Sam, sorry, to Priya"); without one, for a fact, the
    /// corrected facts ("three" in "three servers, sorry, four"), and for a name, the one name
    /// corrected. Other corrected words may be written again ("I'm meeting divya at the station,
    /// actually nikhil" → "I'm meeting Nikhil at the station").
    func stoodInFor(phrase: ArraySlice<SaidWord>, key: Int, corrected: ArraySlice<SaidWord>) -> Set<String> {
        let mayIsMonth = corrected.contains(where: Self.isMonth)
        let keySort = sort(of: phrase[phrase.startIndex + key], mayIsMonth: mayIsMonth)
        func isTaken(_ word: SaidWord) -> Bool {
            carriesMeaning(word) && sort(of: word, mayIsMonth: mayIsMonth) == keySort && !Self.isSaid(word, in: phrase)
        }
        let after = ((key + 1)..<phrase.count).first {
            carriesMeaning(phrase[phrase.startIndex + $0]) && Self.isSaid(phrase[phrase.startIndex + $0], in: corrected)
        }
        let before = (0..<key).reversed().first { Self.isSaid(phrase[phrase.startIndex + $0], in: corrected) }
        guard let anchor = after ?? before else {
            switch keySort {
            case .name:
                let names = corrected.filter(isTaken)
                return names.count == 1 ? [names[0].word] : []
            case .word:
                return []
            default:
                return Set(corrected.filter { factKind($0, mayIsMonth: mayIsMonth) != nil && !Self.isSaid($0, in: phrase) }.map(\.word))
            }
        }
        // The corrected word as far from the anchor said again as the key word is in the phrase.
        guard let index = corrected.lastIndex(where: { $0.word == phrase[phrase.startIndex + anchor].word }),
              corrected.indices.contains(index + key - anchor), isTaken(corrected[index + key - anchor])
        else { return [] }
        return [corrected[index + key - anchor].word]
    }

    /// Whether a reading of a correction would keep the word its key word takes back, just before
    /// the `corrected` words of `words`: its `phrase` says each of them that carries meaning again,
    /// after the key word, so it corrects that word too ("the blue room, sorry, the green room"
    /// corrects "blue room", and is never "the blue green room"); or the key word is a fact or a
    /// name, none of the corrected words is one of its sort, and the word before them that carries
    /// meaning is ("three servers, sorry, four" corrects "three", and is never "three, four
    /// servers"; "Invite Sam to the launch. Sorry, Priya." corrects "Sam", and is never "Invite Sam
    /// and Priya to the launch.").
    func leavesTakenBack(_ words: [SaidWord], corrected: Range<Int>, phrase: ArraySlice<SaidWord>) -> Bool {
        corrected.lowerBound > 0 && !words[corrected.lowerBound - 1].endsSentence
            && (takesBackFirst(words[(corrected.lowerBound - 1)..<corrected.upperBound], phrase: phrase)
                || leavesItsSort(words, corrected: corrected, phrase: phrase))
    }

    /// Whether the key word of `phrase` is a fact or a name, none of the `corrected` words of
    /// `words` is of its sort, and the last word before them in their sentence that carries
    /// meaning is.
    private func leavesItsSort(_ words: [SaidWord], corrected: Range<Int>, phrase: ArraySlice<SaidWord>) -> Bool {
        let correctedWords = words[corrected]
        guard let before = words[..<corrected.lowerBound].reversed().prefix(while: { !$0.endsSentence }).first(where: carriesMeaning)
        else { return false }
        let mayIsMonth = correctedWords.contains(where: Self.isMonth)
        let beforeSort = sort(of: before, mayIsMonth: mayIsMonth)
        // The key word, the costliest to find, last.
        return beforeSort != .word && !Self.isSaid(before, in: phrase)
            && !correctedWords.contains { carriesMeaning($0) && sort(of: $0, mayIsMonth: mayIsMonth) == beforeSort }
            && keyWord(of: phrase, correcting: correctedWords)
                .map { sort(of: phrase[phrase.startIndex + $0], mayIsMonth: mayIsMonth) == beforeSort } == true
    }

    /// Whether the key word of `phrase` takes back the first of the `corrected` words, and the
    /// phrase says each of the others that carries meaning again after it: "the green room" for
    /// "blue room", "the login service" for "billing service".
    func takesBackFirst(_ corrected: ArraySlice<SaidWord>, phrase: ArraySlice<SaidWord>) -> Bool {
        guard let first = corrected.first, carriesMeaning(first), !Self.isSaid(first, in: phrase) else { return false }
        let rest = corrected.dropFirst()
        guard !rest.contains(where: { carriesMeaning($0) && !Self.isSaid($0, in: phrase) }),
              let saidAgain = phrase.firstIndex(where: { carriesMeaning($0) && Self.isSaid($0, in: rest) }),
              let key = keyWord(of: phrase, correcting: corrected)
        else { return false }
        return key < saidAgain - phrase.startIndex && sort(of: first) == sort(of: phrase[phrase.startIndex + key])
    }

    /// Whether `word` is among `words`, as itself or another form of it.
    private static func isSaid(_ word: SaidWord, in words: ArraySlice<SaidWord>) -> Bool {
        words.contains { $0.word == word.word || WordForms.areForms($0.word, word.word) }
    }

    /// How alike a word and one that only holds the grammar together must be for the word to be
    /// that one misheard ("thee" for "the", "theon" for "then").
    private static let minMisheardSimilarity = 0.75
    /// The days of the week, which a key word that is one takes back one of.
    private static let days: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
}
