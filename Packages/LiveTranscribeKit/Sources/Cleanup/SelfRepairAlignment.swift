import Foundation
import Shared

extension SelfRepair {
    /// The search behind ``SelfRepair/accepts(raw:cleaned:placeholders:)``: whether some sequence
    /// of a repair's edits turns the words said into the words written.
    ///
    /// Positions are pairs of said and written word indices, visited in order. At each, the
    /// search also knows whether it is inside a correction phrase, how much of that phrase is
    /// left, how many repairs it still allows, and whether a word of it has been written; that
    /// state fits in a bit set, so the search takes time proportional to the two lengths
    /// multiplied. A phrase follows a cue within a
    /// sentence, or opens where a correction from a later sentence was put (``Corrections``). Once
    /// a word of a phrase has been written, the words it corrected may be written too ("three
    /// servers, sorry, four" → "four servers"; "next week, sorry, the after next" → "the week
    /// after next"), until the word after the phrase is read; never before, which would keep what
    /// was taken back and drop only the cue. The words its key word takes back are never written
    /// again, and the key word itself is changed only into a word like it
    /// (``SelfRepair/keyWord(of:correcting:)``).
    struct Alignment {
        let repair: SelfRepair
        let said: [SaidWord]
        let written: [WrittenWord]
        let placeholders: Set<String>
        /// Every word of the dictation as said, before any correction was applied.
        private let spoken: Set<String>
        /// For each said index, where the self-corrections that may be taken out from it end.
        private let spans: [Int: [Int]]
        /// For each said index, the corrected words a repair may write there: in the correction
        /// phrase that covers it, or just after, before the next said word is read.
        private let spare: [Set<String>]
        /// For each said index, the words corrected by the phrase that covers it, which a repair
        /// may not add there as new words.
        private let corrected: [Set<String>]
        /// For each said index, the corrected words the key word of the phrase that covers it
        /// takes back, which a repair may not write there either.
        private let taken: [Set<String>]
        /// Whether each said word is the key word of a correction phrase, which a repair may not
        /// change.
        private let key: [Bool]
        /// The words of the cues said, whose forms a repair may not add ("make that" → "made that").
        private let cueWords: Set<String>
        /// The said indices of the starts of words broken off and said again in full
        /// (``WordFragments``).
        private let fragments: Set<Int>

        private static let phrase = SelfRepair.correctionPhraseWords
        private static let repairs = SelfRepair.maxRepairWords

        init(repair: SelfRepair, said: [SaidWord], written: [WrittenWord], placeholders: Set<String>, spoken: Set<String>) {
            self.repair = repair
            self.said = said
            self.written = written
            self.placeholders = placeholders
            self.spoken = spoken
            let corrections = Corrections.spans(in: said, repair: repair, placeholders: placeholders)
            spans = corrections.ends
            var spare = Array(repeating: Set<String>(), count: said.count + 1)
            var corrected = Array(repeating: Set<String>(), count: said.count + 1)
            func cover(from start: Int, length: Int, with words: Set<String>) {
                for index in start...min(start + length, said.count) { spare[index].formUnion(words) }
            }
            for (start, words) in corrections.spare {
                cover(from: start, length: min(Self.phraseLength(from: start, in: said), Self.phrase), with: words)
            }
            for (start, words) in corrections.corrected {
                for index in start...min(start + min(Self.phraseLength(from: start, in: said), Self.phrase), said.count) {
                    corrected[index].formUnion(words)
                }
            }
            var taken = Array(repeating: Set<String>(), count: said.count + 1)
            for (start, words) in corrections.taken {
                for index in start...min(start + min(Self.phraseLength(from: start, in: said), Self.phrase), said.count) {
                    taken[index].formUnion(words)
                }
            }
            var keys = corrections.keys
            for (start, word) in said.enumerated() where word.opensPhrase > 0 {
                cover(from: start, length: word.opensPhrase, with: Set(word.spare))
                for index in start...min(start + word.opensPhrase, said.count) { corrected[index].formUnion(word.spare) }
                let phrase = said[start..<min(start + word.opensPhrase, said.count)]
                let spareWords = word.spare.map { SaidWord(word: $0, endsSentence: false, endsQuestion: false, isName: false) }[...]
                if let keyIndex = repair.keyWord(of: phrase, correcting: spareWords) {
                    keys.append(start + keyIndex)
                    let words = repair.takenBack(by: phrase, from: spareWords)
                    for index in start...min(start + word.opensPhrase, said.count) { taken[index].formUnion(words) }
                }
            }
            // The key word said again in a row is the key word too: either copy may be the one kept.
            var key = Array(repeating: false, count: said.count)
            for index in keys {
                var end = index
                while end + 1 < said.count, said[end + 1].word == said[index].word { end += 1 }
                for position in index...end { key[position] = true }
            }
            self.spare = spare
            self.corrected = corrected
            self.taken = taken
            self.key = key
            cueWords = Set(said.filter(\.isCue).map(\.word))
            fragments = repair.fragments.indices(in: said)
        }

        func reachesEnd() -> Bool {
            let n = said.count, m = written.count
            var reached = [UInt64](repeating: 0, count: (n + 1) * (m + 1))
            func at(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
            reached[0] = 1
            for i in 0...n {
                for j in 0...m {
                    // Opening a phrase moves to another state at the same position, so states are
                    // visited until none is new.
                    var visited: UInt64 = 0
                    while true {
                        let pending = reached[at(i, j)] & ~visited
                        guard pending != 0 else { break }
                        for state in 0...Self.lastState where pending & (1 << state) != 0 {
                            visited |= 1 << state
                            for (di, dj, next) in steps(from: i, j, state: state) {
                                reached[at(i + di, j + dj)] |= 1 << next
                            }
                        }
                    }
                }
            }
            return reached[at(n, m)] != 0
        }

        // MARK: - Steps

        /// Every edit that can be made at said index `i` and written index `j`: how many words of
        /// each it takes, and the state after it.
        private func steps(from i: Int, _ j: Int, state: Int) -> [(Int, Int, Int)] {
            let n = said.count, m = written.count
            var steps: [(Int, Int, Int)] = []
            if i < n, state == 0, said[i].opensPhrase > 0 {
                steps.append((0, 0, Self.encode(left: min(said[i].opensPhrase, Self.phrase), repairs: Self.repairs, begun: false)))
            }
            if i < n, j < m, keeps(said[i], as: written[j]) {
                steps.append((1, 1, consuming(1, from: i, in: state, writing: true)))
            }
            if i < n, isDroppable(i, before: j) {
                steps.append((1, 0, consuming(1, from: i, in: state, writing: false)))
            }
            for end in spans[i] ?? [] {
                steps.append((end - i, 0, opening(at: end)))
            }
            if j < m, isInsertable(written[j]) {
                steps.append((0, 1, state))
            }
            if state != 0, j < m {
                let (left, repairsLeft, begun) = Self.decode(state)
                let new = isRepair(written[j]) && !corrected[i].contains(written[j].word)
                if begun, spare[i].contains(written[j].word), !taken[i].contains(written[j].word),
                   !placeholders.contains(written[j].word) {
                    steps.append((0, 1, state))
                } else if left > 0, repairsLeft > 0, new {
                    steps.append((0, 1, Self.encode(left: left, repairs: repairsLeft - 1, begun: begun)))
                }
                if left > 0, repairsLeft > 0, i < n, mayStandIn(written[j].word, at: i), isReplaceable(said[i]), new {
                    let after = consuming(1, from: i, in: Self.encode(left: left, repairs: repairsLeft - 1, begun: begun), writing: true)
                    steps.append((1, 1, after))
                }
            }
            if i + 1 < n, j < m, merges(said[i], said[i + 1], into: written[j]) {
                steps.append((2, 1, consuming(2, from: i, in: state, writing: true)))
            }
            if i < n, j + 1 < m, splits(said[i], into: written[j], written[j + 1]) {
                steps.append((1, 2, consuming(1, from: i, in: state, writing: true)))
            }
            steps += numberSteps(from: i, j, state: state)
            if let step = acronymStep(from: i, j, state: state) { steps.append(step) }
            return steps
        }

        /// Letters spelled out and written as one word, in order ("p r" → "PR", "A P I" → "API"):
        /// two to ``maxAcronymLetters`` said words of one letter each. Speech-to-text gives them
        /// capitals, as it does names, so a spelled letter is kept as a letter either way.
        private func acronymStep(from i: Int, _ j: Int, state: Int) -> (Int, Int, Int)? {
            guard j < written.count else { return nil }
            let letters = written[j].word
            let count = letters.count
            guard (2...Self.maxAcronymLetters).contains(count), i + count <= said.count,
                  letters.allSatisfy(\.isLetter) else { return nil }
            let run = said[i..<(i + count)]
            guard run.allSatisfy({ $0.word.count == 1 && !$0.isCue }), !run.dropLast().contains(where: \.endsSentence),
                  run.map(\.word).joined() == letters else { return nil }
            return (count, 1, consuming(count, from: i, in: state, writing: true))
        }

        /// Most letters spelled out that may be written as one word.
        static let maxAcronymLetters = 6

        /// A number said in words and written in digits, or the other way round ("twenty five" →
        /// "25", "2:30" → "two thirty"), with the same value.
        private func numberSteps(from i: Int, _ j: Int, state: Int) -> [(Int, Int, Int)] {
            let n = said.count, m = written.count
            guard i < n, j < m else { return [] }
            var steps: [(Int, Int, Int)] = []
            let writtenValue = WordForms.value(of: [written[j].word][...])
            if writtenValue != nil {
                var k = 0
                while i + k < n, k < 5, WordForms.isNumberWord(said[i + k].word) {
                    k += 1
                    if k > 1, WordForms.value(of: said[i..<(i + k)].map(\.word)[...]) == writtenValue {
                        steps.append((k, 1, consuming(k, from: i, in: state, writing: true)))
                    }
                }
            }
            if let saidValue = WordForms.value(of: [said[i].word][...]) {
                var l = 0
                while j + l < m, l < 5, WordForms.isNumberWord(written[j + l].word) {
                    l += 1
                    if l > 1, WordForms.value(of: written[j..<(j + l)].map(\.word)[...]) == saidValue {
                        steps.append((1, l, consuming(1, from: i, in: state, writing: true)))
                    }
                }
            }
            return steps
        }

        // MARK: - Edits

        /// Whether `writtenWord` keeps `saidWord`: the same word or another form of it, a word
        /// speech-to-text confuses with it ("weather", "whether"), or a respelling; a protected word
        /// only as itself, as another way of writing its number, or, for a negated verb, in another
        /// form that keeps its negation ("don't" → "doesn't"); a cue only as itself. A respelling is
        /// never a filler, nor a name the speaker didn't say: a word written with a capital where no
        /// sentence starts is a name, which keeps only itself or takes its possessive ("uma" is not
        /// "Una", "jura" not "Jira", "Kirk" not "Kurt"), and one that starts a sentence may be, so
        /// only another form is written there ("uma hasn't" is not "Una hasn't"). Where a list item
        /// starts, the capital is the layout's, so a word said within a sentence is respelled there
        /// as anywhere else. A capital a word had as said shows only that speech-to-text took it for
        /// a name, which a misheard word often isn't: "can you Madge it" may be "can you merge it",
        /// and "First, Madge the PR" "1. Merge the PR".
        func keeps(_ saidWord: SaidWord, as writtenWord: WrittenWord) -> Bool {
            let said = saidWord.word, word = writtenWord.word
            if said == word { return true }
            if saidWord.isCue || repair.isFiller(word) { return false }
            if repair.isProtected(said, placeholders: placeholders) || repair.isProtected(word, placeholders: placeholders) {
                if let value = WordForms.value(of: [said][...]), value == WordForms.value(of: [word][...]) { return true }
                return Self.isNegatedVerb(said) && Self.isNegatedVerb(word) && WordForms.areForms(said, word)
            }
            let pronoun = word == "i" || word.hasPrefix("i'")
            let laidOut = writtenWord.startsListItem && !saidWord.startsSentence
            let mayBeName = writtenWord.isCapitalised && !pronoun && !laidOut
            if mayBeName, !writtenWord.startsSentence {
                return !spoken.contains(word) && Self.possessives(of: said).contains(word)
            }
            if WordForms.areForms(said, word) { return true }
            return !mayBeName && !repair.isCue(word) && !spoken.contains(word)
                && EditDistance.normalizedSimilarity(said, word) >= repair.respellingSimilarity
        }

        private static func possessives(of name: String) -> Set<String> {
            [name + "'s", name.hasSuffix("s") ? name + "'" : name + "s'"]
        }

        /// A filler, a word said twice in a row, a word that only holds the grammar together, the
        /// start of a word broken off and said again in full ("con" in "con consider"), a unit whose
        /// number is now written with its symbol ("dollars" in "twenty five dollars" → "$25"), or a
        /// word said to mark the list item that is written next.
        private func isDroppable(_ i: Int, before j: Int) -> Bool {
            let word = said[i].word
            if repair.isFiller(word) { return true }
            if (i + 1 < said.count && said[i + 1].word == word) || (i > 0 && said[i - 1].word == word) { return true }
            if j < written.count, written[j].startsListItem, isListMarker(at: i) { return true }
            if WordForms.unitWords.contains(word), i > 0, WordForms.isNumber(said[i - 1].word) { return true }
            if said[i].isCue { return false }
            guard !repair.isProtected(word, placeholders: placeholders), !said[i].isName, !said[i].isCue else { return false }
            return WordForms.droppable.contains(word) || fragments.contains(i)
        }

        private func isListMarker(at i: Int) -> Bool {
            let word = said[i].word
            if WordForms.listMarkers.contains(word) { return true }
            return WordForms.isNumberWord(word) && i > 0 && said[i - 1].word == "number"
        }

        private func isInsertable(_ word: WrittenWord) -> Bool {
            WordForms.insertable.contains(word.word)
        }

        /// A word a repair may add or put in place of another inside a correction phrase: not a
        /// protected word, a name, a cue or a filler.
        private func isRepair(_ word: WrittenWord) -> Bool {
            // A capital shows a name, except at the start of a sentence, where only a word that
            // holds the grammar together is surely not one.
            let mayBeName = word.isCapitalised && (!word.startsSentence || !repair.isFunctionWord(word.word))
            return !repair.isProtected(word.word, placeholders: placeholders) && !mayBeName
                && !repair.isCue(word.word) && !repair.isFiller(word.word)
                && !cueWords.contains { $0 == word.word || WordForms.areForms($0, word.word) }
        }

        /// Whether a repair may put `word` in place of said word `i`: any word, unless that is a
        /// correction's key word, which only a word like it may stand in for.
        private func mayStandIn(_ word: String, at i: Int) -> Bool {
            !key[i] || EditDistance.normalizedSimilarity(said[i].word, word) >= Self.minKeyWordSimilarity
        }

        /// How alike a correction's key word and a word a repair puts in its place must be: a
        /// garbled key word may be read as meant ("busses" → "buses"), never as another word
        /// ("busses" → "trains").
        static let minKeyWordSimilarity = 0.5

        private func isReplaceable(_ word: SaidWord) -> Bool {
            !repair.isProtected(word.word, placeholders: placeholders) && !word.isName && !word.isCue
        }

        /// Two words said as one written: a contraction, the two run together, or a respelling of
        /// both; never across the end of a sentence ("plan A. I think" is not "plan AI think").
        private func merges(_ first: SaidWord, _ second: SaidWord, into written: WrittenWord) -> Bool {
            guard !first.isCue, !second.isCue, !first.isName, !second.isName, !first.endsSentence else { return false }
            let (a, b, word) = (first.word, second.word, written.word)
            if WordForms.expansions(of: word).contains([a, b]) || a + b == word { return true }
            let protected = [a, b, word].contains { repair.isProtected($0, placeholders: placeholders) }
            return !protected && !spoken.contains(word) && EditDistance.normalizedSimilarity(a + b, word) >= 0.8
        }

        private func splits(_ said: SaidWord, into first: WrittenWord, _ second: WrittenWord) -> Bool {
            guard !said.isCue, !said.isName else { return false }
            return WordForms.expansions(of: said.word).contains([first.word, second.word]) || first.word + second.word == said.word
        }

        private static func isNegatedVerb(_ word: String) -> Bool {
            word.hasSuffix("n't") || word == "cannot"
        }

        // MARK: - Correction phrases

        /// The state after taking `count` said words from `i`, `writing` something for them or
        /// dropping them: a correction phrase is read once its sentence ends or its words run
        /// out, and left with the next said word.
        private func consuming(_ count: Int, from i: Int, in state: Int, writing: Bool) -> Int {
            guard state != 0 else { return 0 }
            let (left, repairs, begun) = Self.decode(state)
            guard left >= count else { return 0 }
            let endsSentence = said[i..<min(i + count, said.count)].contains(where: \.endsSentence)
            return Self.encode(left: endsSentence ? 0 : left - count, repairs: repairs, begun: begun || writing)
        }

        /// The state at the start of the correction phrase that begins at said index `start`.
        private func opening(at start: Int) -> Int {
            let length = Self.phraseLength(from: start, in: said)
            return length == 0 ? 0 : Self.encode(left: min(length, Self.phrase), repairs: Self.repairs, begun: false)
        }

        /// State 0 is outside any correction phrase; the others are inside one, with `left` of its
        /// words still to read (0 once it has been read), `repairs` still allowed, and whether a
        /// word of it has been written (`begun`).
        private static func encode(left: Int, repairs: Int, begun: Bool) -> Int {
            1 + (left * (Self.repairs + 1) + repairs) * 2 + (begun ? 1 : 0)
        }

        private static func decode(_ state: Int) -> (left: Int, repairs: Int, begun: Bool) {
            let value = state - 1
            return (value / 2 / (repairs + 1), value / 2 % (repairs + 1), value % 2 == 1)
        }

        /// The highest state, which the bit sets must hold.
        private static let lastState: Int = {
            let last = encode(left: phrase, repairs: repairs, begun: true)
            precondition(last < UInt64.bitWidth, "the search's states must fit its bit sets")
            return last
        }()

        /// Words from `start` to the end of its sentence, inclusive.
        static func phraseLength(from start: Int, in words: [SaidWord]) -> Int {
            guard start < words.count else { return 0 }
            let end = words[start...].firstIndex(where: \.endsSentence) ?? (words.count - 1)
            return end - start + 1
        }
    }
}
