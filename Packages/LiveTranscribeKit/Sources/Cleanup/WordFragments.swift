import Foundation
import Shared

/// Finds the start of a word the speaker broke off and then said in full, which speech-to-text
/// writes as a word of its own: "She wants few ex expenses", "we should con consider",
/// "send the rep report". Cleanup rightly drops it, so both checks let it go: Deep's
/// (``SelfRepair``) and the others' (``DroppedWords``, ``ContentWords``).
///
/// A said word is a fragment when the next word said in its sentence starts with it and has at
/// least ``minAddedLetters`` letters more ("rep" → "report"), whatever the capitals, and it is
/// all letters, at least ``minLetters`` of them. It must be written as a word broken off is
/// (``SelfRepair/SaidWord/mayBeBrokenOff``): on its own, with nothing after it but a hyphen or
/// dash ("con- consider"), so never part of a word ("re" in "re-read") or a word set off by a
/// comma or colon ("pen" in "pen, pencil and paper"), and not in capitals ("PR process").
///
/// It is never a word that starts a longer one by chance and says something of its own: a
/// function word ("for forty", "to tomorrow", "so soon", "the theory", "an another"), a negation
/// ("not nothing"), a number, a unit or a word of time; nor a name or a correction cue, nor a word
/// before a name ("Ed Edwards", however it starts its sentence), nor the last word of a sentence
/// ("Call the rep. Report it.").
///
/// What it can't tell apart is a word that carries meaning and happens to start the next one:
/// "car" in "the car carpet" is a fragment of "carpet", so an answer that drops it is accepted;
/// so is one that drops "add" from "add additional notes" or "new" from "the new newsletter".
/// Such pairs are rare in speech, and the model has no reason to drop the word.
struct WordFragments: Sendable {
    /// Fewest letters a fragment has: a single letter names something as often as it starts a
    /// word ("plan b because", "vitamin d deficiency").
    static let minLetters = 2
    /// Fewest letters the whole word has beyond its fragment, so that a word and its plural or
    /// another short form of it ("plan plans", "test tests") are never taken for one.
    static let minAddedLetters = 2

    private let functionWords: Set<String>
    private let negations: Set<String>

    init(policy: OutputGuard.Policy) {
        functionWords = Set(policy.functionWords.map(EditDistance.normalize))
        negations = Set(policy.negations.map(EditDistance.normalize))
    }

    /// The indices of the normalized words of `text` (``EditDistance/words(in:)`` after
    /// ``EditDistance/normalize(_:)``) that are fragments of the word after them, with its
    /// sentences and names read as ``SelfRepair/saidWords(in:functionWords:placeholders:)`` reads
    /// them. `placeholders` are the normalized placeholder tokens.
    func indices(in text: String, placeholders: Set<String>) -> Set<Int> {
        indices(in: SelfRepair.saidWords(in: text, functionWords: functionWords, placeholders: placeholders))
    }

    /// The indices of the words in `said` that are fragments of the word after them.
    func indices(in said: [SelfRepair.SaidWord]) -> Set<Int> {
        Set(said.indices.dropLast().filter { index in
            let word = said[index], next = said[index + 1]
            return word.mayBeBrokenOff && !word.endsSentence && !word.isName && !word.isCue && !next.isName
                && isFragment(word.word, of: next.word)
        })
    }

    /// Whether `word` is the start of `next`, broken off. Both are normalized words.
    func isFragment(_ word: String, of next: String) -> Bool {
        guard word.count >= Self.minLetters, word.allSatisfy(\.isLetter), next.count >= word.count + Self.minAddedLetters,
              next.hasPrefix(word) else { return false }
        return !functionWords.contains(word) && !negations.contains(word) && !WordForms.isNumber(word)
            && !WordForms.unitWords.contains(word) && !WordForms.timeWords.contains(word)
    }
}
