import Foundation
import Shared

/// Finds content the cleanup output deleted: the words that carry what was said (things, people,
/// actions, qualities, numbers, times), as opposed to the function words that hold a sentence
/// together ("the", "of", "is", "and") and the intensifiers a rewording may drop ("really",
/// "basically").
///
/// ``DroppedWords`` catches a run of deleted words, but lets one word go at a time and is off at
/// High, where rewording needs room. This check applies at every level and catches a single word:
/// "We need milk, eggs, and bread." cleaned to "We need eggs and bread." loses the milk.
///
/// Rewording may replace, reorder, respell and merge words, so a deleted content word still
/// counts as kept when:
/// - a word put in its place respells it or merges it with a neighbour ("nerd storm" →
///   "Nerdstorm"), or it is a number or unit and digits took its place ("twenty five dollars" →
///   "$25");
/// - the output has it, or a respelling of it, somewhere else: it moved ("tomorrow I'll send
///   it" → "I'll send it tomorrow");
/// - its gap in the alignment puts back at least as many words as it deletes content words: a
///   rewording ("I got the tickets" → "I have the tickets").
///
/// What is left was deleted with nothing in its place.
struct ContentWords: Sendable {
    /// Closed-class words: articles, pronouns, auxiliary verbs, prepositions, conjunctions and
    /// question words, plus intensifiers and discourse words that do not change what is said.
    /// Negations are left out; ``DroppedWords`` checks them on their own. So are hedges ("maybe",
    /// "kind of"), which the prompt asks the model to keep. Normalized with
    /// ``EditDistance/normalize(_:)``.
    static let standardFunctionWords = [
        // Articles, determiners and quantifiers
        "a", "an", "the", "this", "that", "these", "those", "some", "any", "each", "every", "either", "both", "all",
        "another", "other", "others", "such", "same", "own", "much", "many", "more", "most", "few", "fewer", "less",
        "least", "several", "enough", "lot", "lots", "whatever", "whichever",
        // Pronouns
        "i", "me", "my", "mine", "myself", "you", "your", "yours", "yourself", "yourselves", "he", "him", "his",
        "himself", "she", "her", "hers", "herself", "it", "its", "itself", "we", "us", "our", "ours", "ourselves",
        "they", "them", "their", "theirs", "themselves", "someone", "somebody", "something", "anyone", "anybody",
        "anything", "everyone", "everybody", "everything", "who", "whom", "whose", "which", "what", "whoever", "there",
        // A pronoun contracted with a verb
        "i'm", "i've", "i'll", "i'd", "you're", "you've", "you'll", "you'd", "he's", "he'll", "he'd", "she's",
        "she'll", "she'd", "it's", "it'll", "it'd", "we're", "we've", "we'll", "we'd", "they're", "they've",
        "they'll", "they'd", "that's", "that'll", "there's", "here's", "what's", "where's", "who's", "how's", "let's",
        // Auxiliary and modal verbs
        "be", "am", "is", "are", "was", "were", "been", "being", "have", "has", "had", "having", "do", "does", "did",
        "doing", "will", "would", "shall", "should", "can", "could", "may", "might", "must",
        // Prepositions and particles
        "about", "above", "across", "after", "against", "along", "among", "around", "as", "at", "before", "behind",
        "below", "beneath", "beside", "besides", "between", "beyond", "by", "down", "during", "except", "for",
        "from", "in", "inside", "into", "like", "near", "of", "off", "on", "onto", "out", "outside", "over", "per",
        "since", "through", "throughout", "till", "to", "toward", "towards", "under", "until", "up", "upon", "via",
        "with", "within",
        // Conjunctions and question words
        "and", "or", "but", "so", "because", "cause", "although", "though", "if", "unless", "whether", "while",
        "whereas", "once", "than", "then", "when", "whenever", "where", "wherever", "why", "how",
        // Intensifiers and discourse words
        "just", "really", "very", "quite", "pretty", "too", "also", "well", "oh", "ok", "okay", "yeah", "yes", "yep",
        "alright", "anyway", "anyways", "basically", "literally", "honestly", "seriously", "totally", "absolutely",
        "simply",
    ]

    /// Number words, and the units that are written as symbols next to digits. When digits take
    /// their place, the number was only rewritten.
    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
        "trillion", "dozen", "half", "quarter", "point",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh",
        "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth",
        "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth",
        "hundredth", "thousandth", "millionth",
        "o'clock", "am", "pm", "percent", "degree", "degrees", "dollar", "dollars", "cent", "cents", "buck", "bucks",
        "pound", "pounds", "pence", "euro", "euros", "yen", "rupee", "rupees",
    ]

    private let functionWords: Set<String>
    private let fillers: Set<String>
    private let minRespellingSimilarity: Double

    init(policy: OutputGuard.Policy) {
        functionWords = Set(policy.functionWords.map(EditDistance.normalize))
        fillers = Set(policy.fillers.map(EditDistance.normalize))
        minRespellingSimilarity = policy.minRespellingSimilarity
    }

    /// How many content words in `alignment`'s raw text were deleted with nothing in their place.
    /// Words in `ignored` (the normalized placeholder tokens, which are checked on their own) are
    /// neither content nor a replacement for it.
    func droppedCount(in alignment: WordAlignment, ignoring ignored: Set<String>) -> Int {
        let raw = alignment.raw, cleaned = alignment.cleaned
        let spoken = Set(raw)
        // Output words the alignment left unmatched and nothing has claimed yet.
        var unclaimed = Set(alignment.gaps.flatMap(\.inserted).filter { !ignored.contains(cleaned[$0]) })
        var missing: [[Int]] = []

        for gap in alignment.gaps {
            let content = gap.deleted.filter { isContent(at: $0, in: raw, ignoring: ignored) }
            var unaccounted: [Int] = []
            for index in content {
                let standsIn = { standIn in self.standsIn(for: raw[index], word: cleaned[standIn], spoken: spoken) }
                // Merged words and the parts of a number share one stand-in ("twenty five" → "25").
                if let standIn = gap.inserted.first(where: { unclaimed.contains($0) && standsIn($0) })
                    ?? gap.inserted.first(where: standsIn) {
                    unclaimed.remove(standIn)
                } else {
                    unaccounted.append(index)
                }
            }
            missing.append(unaccounted)
        }

        // A word the output has elsewhere moved. Exact matches claim first, so a respelling
        // cannot take the place of a word that is really there.
        for respelled in [false, true] {
            for (gapIndex, indices) in missing.enumerated() {
                missing[gapIndex] = indices.filter { index in
                    let word = raw[index]
                    let moved = unclaimed.sorted().first { candidate in
                        cleaned[candidate] == word
                            || (respelled && EditDistance.normalizedSimilarity(word, cleaned[candidate]) >= minRespellingSimilarity)
                    }
                    guard let moved else { return true }
                    unclaimed.remove(moved)
                    return false
                }
            }
        }

        // What the gap still puts back rewords as many of the rest.
        return zip(alignment.gaps, missing).reduce(0) { dropped, pair in
            let (gap, unaccounted) = pair
            let replacements = gap.inserted.filter(unclaimed.contains).count
            return dropped + max(0, unaccounted.count - replacements)
        }
    }

    // MARK: - Private

    /// A word that carries content: not a function word, filler, placeholder or lone letter, and
    /// not a word said twice in a row, which a correction may reduce to once.
    private func isContent(at index: Int, in words: [String], ignoring ignored: Set<String>) -> Bool {
        let word = words[index]
        guard !functionWords.contains(word), !fillers.contains(word), !ignored.contains(word) else { return false }
        guard word.count > 1 || word.allSatisfy(\.isNumber) else { return false }
        return !(index > 0 && words[index - 1] == word) && !(index + 1 < words.count && words[index + 1] == word)
    }

    /// Whether `word`, put where `spokenWord` was, stands for it: a respelling, a merge with a
    /// neighbour ("nerd storm" → "nerdstorm"), or digits for a number word ("twenty five" → "25")
    /// and number words for digits. A different word the speaker said elsewhere is never a
    /// respelling: it moved there.
    private func standsIn(for spokenWord: String, word: String, spoken: Set<String>) -> Bool {
        if Self.hasDigit(spokenWord) {
            return Self.hasDigit(word) || Self.numberWords.contains(word)
        }
        if Self.numberWords.contains(spokenWord), Self.hasDigit(word) {
            return true
        }
        guard !spoken.contains(word) else { return false }
        return EditDistance.normalizedSimilarity(spokenWord, word) >= minRespellingSimilarity
            || (word.count > spokenWord.count && word.contains(spokenWord))
    }

    private static func hasDigit(_ word: String) -> Bool {
        word.contains(where: \.isNumber)
    }
}
