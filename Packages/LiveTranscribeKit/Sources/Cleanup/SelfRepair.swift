import Foundation
import Shared

/// Checks Deep's output: that it can be made from the text the model was given by the edits a
/// repair may make, and by no others.
///
/// Deep reads the whole dictation, so it may resolve a correction that reaches back into an
/// earlier sentence, read a garbled correction phrase as meant, fix grammar and misheard words, and
/// lay the text out. The limits the other levels use (length, similarity, a dropped cue checked by
/// ``SelfCorrection``) would reject much of that, and widening them would let through what they
/// guard against. Instead the output is lined up with what was said, word by word, and every
/// difference must be one of these edits:
/// - a word kept, respelled, or put in another form of itself ("check" → "checked", "is" → "are",
///   "their" → "there"); two words merged or one split ("do not" → "don't", "twenty five" → "25").
///   A name is kept as said, and no word is respelled into one;
/// - a filler, a repeated word, or a word that only holds the grammar together dropped or added
///   ("I going" → "I am going");
/// - a self-correction resolved (``Corrections``): as at Medium, up to
///   ``OutputGuard/Policy/maxRetractedWords`` words and the cue after them taken out; from a later
///   sentence, a short correction phrase about the same thing (a word they share, or both a
///   number, a day, a month or a name) put in place of what it corrects, with the rest of the
///   earlier sentence kept. One may not answer a question: "Is it tomorrow? No, the day after."
///   keeps its "No". A cue's words are taken out only with the correction they make, and never
///   changed ("make that" is not "made that"). Nor may a correction that opens a later sentence
///   be dropped whole, leaving what it corrects as said;
/// - inside a correction phrase, up to ``maxRepairWords`` new words or changed words, and the words
///   it corrects, which is how a garbled phrase is read as meant ("tomorrow. No, sorry, the after
///   tomorrow" → "the day after tomorrow");
/// - a list's numbers or bullets put in place of the words said to mark its items.
///
/// The layout is checked too (``OutputGuard``): a bulleted list has at least ``minBulletedItems``
/// items, since two things said in a sentence stay in it, and no line holds only placeholders, as
/// when an emoji is moved below the sentence it ended.
///
/// Names, numbers, negations and words of time are kept as said everywhere else: none may be
/// added, dropped or changed, and no other new word may appear, so the model can't add a claim
/// ("he didn't" → "he didn't answer") or turn "after" into "before".
struct SelfRepair: Sendable {
    /// Longest correction phrase after a cue, and the stretch in which a garbled one may be repaired.
    static let correctionPhraseWords = 6
    /// Most words a repair may add to or change in one correction phrase.
    static let maxRepairWords = 2
    /// Fewest items in a bulleted list the model makes: two things said in a sentence ("the invoice
    /// and the agreement") stay in it. A numbered list may have two, as when they were counted.
    static let minBulletedItems = 3

    private let cues: [[String]]
    private let cueWords: Set<String>
    private let fillers: Set<String>
    private let negations: Set<String>
    private let functionWords: Set<String>
    private let maxRetractedWords: Int
    private let minRespellingSimilarity: Double

    init(policy: OutputGuard.Policy) {
        // "Or rather" is one cue at Deep: its "or" goes with it.
        cues = (policy.correctionCues + ["or rather"])
            .map { EditDistance.words(in: EditDistance.normalize($0)) }
            .filter { !$0.isEmpty }
        cueWords = Set(policy.correctionCues.map { EditDistance.words(in: EditDistance.normalize($0)) }.filter { $0.count == 1 }.map { $0[0] })
        fillers = Set(policy.fillers.map(EditDistance.normalize))
        negations = Set(policy.negations.map(EditDistance.normalize))
        functionWords = Set(policy.functionWords.map(EditDistance.normalize))
        maxRetractedWords = policy.maxRetractedWords
        minRespellingSimilarity = policy.minRespellingSimilarity
    }

    /// Whether `cleaned` can be made from `raw` by a repair's edits. `placeholders` are the
    /// normalized placeholder tokens, which must come through as they are.
    func accepts(raw: String, cleaned: String, placeholders: Set<String>) -> Bool {
        var said = Self.saidWords(in: raw, functionWords: functionWords, placeholders: placeholders)
        markCues(in: &said)
        let written = Self.writtenWords(in: cleaned)
        guard !said.isEmpty else { return written.isEmpty }
        let spoken = Set(said.map(\.word))
        func aligns(_ candidate: [SaidWord]) -> Bool {
            Alignment(repair: self, said: candidate, written: written, placeholders: placeholders, spoken: spoken).reachesEnd()
        }
        // Re-using the words it corrects, a repaired phrase could come out as those words.
        guard !Corrections.dropped(from: said, repair: self).contains(where: aligns) else { return false }
        return ([said] + Corrections.applied(to: said, repair: self, placeholders: placeholders)).contains(where: aligns)
    }

    /// Marks every word of every correction cue in `words`.
    private func markCues(in words: inout [SaidWord]) {
        let texts = words.map(\.word)
        for cue in cues where texts.count >= cue.count {
            for start in 0...(texts.count - cue.count) where texts[start..<(start + cue.count)].elementsEqual(cue) {
                for index in start..<(start + cue.count) { words[index].isCue = true }
            }
        }
    }

    // MARK: - Words

    /// A word as said, with what its punctuation and capital say about it.
    struct SaidWord: Equatable {
        let word: String
        var endsSentence: Bool
        var endsQuestion: Bool
        let isName: Bool
        /// Capitalised where no sentence starts, as a name or the month "May" is.
        var isCapitalised = false
        /// A name, or a capitalised word that starts a sentence and could be one ("Chloe will …").
        var mayBeName = false
        /// Where a correction from a later sentence was put in place of what it corrects, how many
        /// words its phrase has, starting here; 0 elsewhere (see ``Corrections``).
        var opensPhrase = 0
        /// The words that correction corrected, which a repair of its phrase may re-use.
        var spare: [String] = []
        /// Part of a correction cue ("scratch that", "no"), which only a correction may take out.
        var isCue = false
    }

    /// A word as written, with what its capital and line say about it.
    struct WrittenWord: Equatable {
        let word: String
        let original: String
        let isCapitalised: Bool
        let startsSentence: Bool
        /// The first word of a list item whose number or bullet was taken off.
        let startsListItem: Bool
    }

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]
    private static let hyphens: Set<Character> = ["-", "\u{2014}", "\u{2013}"]

    /// The words of `text` as ``EditDistance/words(in:)`` finds them after normalizing, each with
    /// whether it ends a sentence (or a line) or a question, and whether it is a name: capitalised
    /// where no sentence starts, and not a function word (as ``SpokenNames`` decides).
    static func saidWords(in text: String, functionWords: Set<String>, placeholders: Set<String>) -> [SaidWord] {
        var words: [SaidWord] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var startsSentence = true
            let lineStart = words.count
            for token in line.split(whereSeparator: \.isWhitespace) {
                for part in token.split(whereSeparator: hyphens.contains) {
                    let trailing = part.reversed().prefix { !$0.isLetter && !$0.isNumber }
                    let ends = trailing.contains(where: sentenceEnders.contains)
                    let asks = trailing.contains("?")
                    let normalized = EditDistance.words(in: EditDistance.normalize(String(part)))
                    if normalized.isEmpty {
                        if ends, let last = words.indices.last, last >= lineStart {
                            words[last] = SaidWord(
                                word: words[last].word, endsSentence: true, endsQuestion: asks,
                                isName: words[last].isName, isCapitalised: words[last].isCapitalised,
                                mayBeName: words[last].mayBeName
                            )
                        }
                    }
                    for (offset, word) in normalized.enumerated() {
                        let isLastOfPart = offset == normalized.count - 1
                        let upper = offset == 0 && (part.first(where: \.isLetter)?.isUppercase ?? false)
                        let couldBeName = upper && !functionWords.contains(word) && !placeholders.contains(word)
                        words.append(SaidWord(
                            word: word,
                            endsSentence: isLastOfPart && ends,
                            endsQuestion: isLastOfPart && asks,
                            isName: couldBeName && !startsSentence,
                            isCapitalised: upper && !startsSentence,
                            mayBeName: couldBeName
                        ))
                    }
                    if !normalized.isEmpty { startsSentence = ends }
                }
            }
            if let last = words.indices.last, last >= lineStart, !words[last].endsSentence {
                words[last] = SaidWord(
                    word: words[last].word, endsSentence: true, endsQuestion: false,
                    isName: words[last].isName, isCapitalised: words[last].isCapitalised, mayBeName: words[last].mayBeName
                )
            }
        }
        return words
    }

    /// The words of `text`, with the numbers and bullets that start its list items taken off.
    static func writtenWords(in text: String) -> [WrittenWord] {
        var words: [WrittenWord] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let (item, isListItem) = withoutListMarker(line)
            var startsSentence = true
            var firstOfLine = true
            for token in item.split(whereSeparator: \.isWhitespace) {
                for part in token.split(whereSeparator: hyphens.contains) {
                    let normalized = EditDistance.words(in: EditDistance.normalize(String(part)))
                    for (offset, word) in normalized.enumerated() {
                        words.append(WrittenWord(
                            word: word,
                            original: String(part),
                            isCapitalised: offset == 0 && (part.first(where: \.isLetter)?.isUppercase ?? false),
                            startsSentence: startsSentence,
                            startsListItem: isListItem && firstOfLine
                        ))
                        firstOfLine = false
                    }
                    if !normalized.isEmpty {
                        startsSentence = part.reversed().prefix { !$0.isLetter && !$0.isNumber }.contains(where: sentenceEnders.contains)
                            || part.hasSuffix(":")
                    }
                }
            }
        }
        return words
    }

    /// `line` without a leading bullet ("-", "•", "*") or item number ("1.", "2)"), and whether it
    /// had one.
    static func withoutListMarker(_ line: Substring) -> (Substring, Bool) {
        let trimmed = line.drop(while: \.isWhitespace)
        if isBulleted(line) {
            return (trimmed.dropFirst(), true)
        }
        let digits = trimmed.prefix(while: \.isNumber)
        let afterDigits = trimmed.dropFirst(digits.count)
        if (1...3).contains(digits.count), let mark = afterDigits.first, mark == "." || mark == ")",
           afterDigits.dropFirst().first?.isWhitespace == true {
            return (afterDigits.dropFirst(), true)
        }
        return (line, false)
    }

    private static let bullets: Set<Character> = ["-", "*", "•", "‣", "◦", "▪", "–", "—", "·"]

    /// Whether `line` starts with a bullet and a space.
    private static func isBulleted(_ line: Substring) -> Bool {
        let trimmed = line.drop(while: \.isWhitespace)
        guard let first = trimmed.first else { return false }
        return bullets.contains(first) && trimmed.dropFirst().first?.isWhitespace == true
    }

    /// How many items each bulleted list in `text` has: a list is a run of lines that start with
    /// a bullet, which a blank line or any other line ends.
    static func bulletedListLengths(in text: String) -> [Int] {
        var lengths: [Int] = []
        var run = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if isBulleted(line) {
                run += 1
            } else if run > 0 {
                lengths.append(run)
                run = 0
            }
        }
        if run > 0 { lengths.append(run) }
        return lengths
    }

    /// How many lines of `text` hold placeholders and nothing else, list markers and punctuation
    /// aside. `placeholders` are normalized, as the words are.
    static func placeholderLineCount(in text: String, placeholders: Set<String>) -> Int {
        guard !placeholders.isEmpty else { return 0 }
        return text.split(whereSeparator: \.isNewline).filter { line in
            let words = EditDistance.words(in: EditDistance.normalize(String(withoutListMarker(line).0)))
            return !words.isEmpty && words.allSatisfy(placeholders.contains)
        }.count
    }

    // MARK: - Word classes

    /// A word no repair may add, drop or change outside a correction: a negation, a number or a
    /// word of time, or a placeholder.
    func isProtected(_ word: String, placeholders: Set<String>) -> Bool {
        negations.contains(word) || word.hasSuffix("n't") || word == "cannot" || WordForms.isNumber(word)
            || WordForms.unitWords.contains(word) || WordForms.timeWords.contains(word) || placeholders.contains(word)
    }

    func isFiller(_ word: String) -> Bool { fillers.contains(word) }
    func isNegation(_ word: String) -> Bool { negations.contains(word) || word.hasSuffix("n't") || word == "cannot" }
    /// A one-word correction cue ("sorry", "no", "actually").
    func isCue(_ word: String) -> Bool { cueWords.contains(word) }
    /// Cues that take back everything before them ("scratch that"), not one thing for another, so
    /// what they retract need not be replaced fact for fact.
    func retractsStatement(_ words: ArraySlice<SaidWord>) -> Bool {
        words.prefix(2).map(\.word) == ["scratch", "that"]
    }
    func isFunctionWord(_ word: String) -> Bool { functionWords.contains(word) }
    var respellingSimilarity: Double { minRespellingSimilarity }
    var retractionLimit: Int { maxRetractedWords }
    var correctionCues: [[String]] { cues }
}
