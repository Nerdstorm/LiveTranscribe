import Foundation
import Shared

/// Checks that cleanup kept the names the speaker said where they said them.
///
/// Which name comes where carries meaning that word counts cannot see. Given a whole message,
/// the model has moved the sign-off's name into the greeting: "Hi John thanks for the update …
/// cheers Sam" came back "Hi Sam, thanks for the update. … Cheers." It dropped one word and
/// reordered the rest, so the length, similarity and dropped-word limits all passed.
///
/// A name is a capitalised word that does not start a sentence, other than a function word
/// such as "I" or "OK". Speech-to-text capitalises the people, places, days and products it
/// hears, so these are what the text is about. A name is kept when the alignment matches it, or
/// when the word put in its place respells it ("Jon" → "John") or merges it with a neighbour
/// ("Nerd Storm" → "Nerdstorm"). A name said twice in a row may be said once.
struct SpokenNames: Sendable {
    /// Punctuation after which the next word starts a sentence, so its capital says nothing.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…", ":"]
    private static let hyphens: Set<Character> = ["-", "\u{2014}", "\u{2013}"]

    private let functionWords: Set<String>
    private let minRespellingSimilarity: Double

    init(policy: OutputGuard.Policy) {
        functionWords = Set(policy.functionWords.map(EditDistance.normalize))
        minRespellingSimilarity = policy.minRespellingSimilarity
    }

    /// Whether a name in `raw`, the text the model was given, is missing from its place in
    /// `alignment`. Words in `ignored` (the normalized placeholder tokens) are never names.
    func movesOrDropsName(in raw: String, alignment: WordAlignment, ignoring ignored: Set<String>) -> Bool {
        let words = alignment.raw
        let spoken = Set(words)
        var gaps: [Int: WordAlignment.Gap] = [:]
        for gap in alignment.gaps {
            for index in gap.deleted { gaps[index] = gap }
        }
        return nameIndices(in: raw, words: words, ignoring: ignored).contains { index in
            guard alignment.matches[index] == nil else { return false }
            let saidTwice = (index > 0 && words[index - 1] == words[index])
                || (index + 1 < words.count && words[index + 1] == words[index])
            guard !saidTwice else { return false }
            let standIns = gaps[index]?.inserted ?? []
            return !standIns.contains { respells(words[index], as: alignment.cleaned[$0], spoken: spoken) }
        }
    }

    /// Indices, among `words` (the normalized words of `raw`), of the names in `raw`. Empty if
    /// `words` are not the words of `raw`, so a mismatch can only let a name through.
    func nameIndices(in raw: String, words: [String], ignoring ignored: Set<String>) -> [Int] {
        var names: [Int] = []
        var index = 0
        for line in raw.split(whereSeparator: \.isNewline) {
            var startsSentence = true
            for token in line.split(whereSeparator: \.isWhitespace) {
                for part in token.split(whereSeparator: Self.hyphens.contains) {
                    let word = EditDistance.normalize(String(part))
                    if !word.isEmpty {
                        guard index < words.count, words[index] == word else { return [] }
                        let capitalised = part.first(where: \.isLetter)?.isUppercase ?? false
                        if capitalised, !startsSentence, !functionWords.contains(word), !ignored.contains(word) {
                            names.append(index)
                        }
                        index += 1
                    }
                    // A placeholder can stand for a line break or a list marker, which starts a
                    // new line.
                    startsSentence = ignored.contains(word)
                        || part.reversed().prefix { !$0.isLetter && !$0.isNumber }.contains(where: Self.sentenceEnders.contains)
                }
            }
        }
        return index == words.count ? names : []
    }

    // MARK: - Private

    /// Whether `word`, put where `name` was, is `name` respelled or merged with a neighbour. A
    /// different word the speaker said elsewhere is never a respelling: it moved there.
    private func respells(_ name: String, as word: String, spoken: Set<String>) -> Bool {
        guard !spoken.contains(word) else { return false }
        return EditDistance.normalizedSimilarity(name, word) >= minRespellingSimilarity
            || (word.count > name.count && word.contains(name))
    }
}
