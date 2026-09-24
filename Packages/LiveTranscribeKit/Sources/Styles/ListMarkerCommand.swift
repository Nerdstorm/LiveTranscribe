import Foundation
import Shared

/// Spoken list markers: "number one … number two …" (or "item", "step", with digits or words)
/// and "bullet point … bullet point …". Each marker goes behind a placeholder that becomes the
/// start of a list line, "1. " or "- ", which ``MarkedListLayout`` then lays out.
///
/// Numbered markers count only in a run that starts at one and goes up by one, with the same
/// word, at least two of them, so "we're number one" stays as said. Bullets need two markers
/// too. Every marker needs words after it. A marker is talked about, not said, after a
/// determiner ("the number one priority", "a bullet point"), after a form of "be" ("speed is
/// number one and cost is number two"), and, for bullets, after an ordinal ("the second bullet
/// point is wrong"). An "is" straight after a number belongs to the marker ("number one is ship
/// the release"), but not after a comma ("number one, is it ready?") or in a question ("number
/// one is it ready?").
///
/// Used only where lists are laid out: Medium and High, in fields that take several lines.
/// Elsewhere the model sees the words, and text that is not laid out gets them back.
public struct ListMarkerCommand: PhraseMatcher {
    static let numberedKeywords: Set<String> = ["number", "item", "step"]
    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
    ]
    static let bullet = ["bullet", "point"]
    /// Words after which "number one" is a predicate, not a list marker.
    static let copulas: Set<String> = ["is", "was", "are", "were", "be", "been", "being", "am", "isn't", "wasn't", "aren't", "weren't"]
    /// Words after a number that introduce its item: "number one is ship the release".
    static let itemCopulas: Set<String> = ["is", "was"]
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]
    /// Endings of contracted copulas: "we're", "I'm".
    static let copulaContractions = ["'re", "'m"]
    /// Words after which "bullet point" names a bullet on a slide or page.
    static let ordinals: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "last", "next", "previous", "final", "other",
    ]

    public init() {}

    public func matches(in text: TokenizedText) -> [PhraseMatch] {
        numberedMarkers(in: text) + bulletMarkers(in: text)
    }

    // MARK: - Private

    private struct Candidate {
        let words: Range<Int>
        let keyword: String
        let number: Int
    }

    private func numberedMarkers(in text: TokenizedText) -> [PhraseMatch] {
        var candidates: [Candidate] = []
        for position in text.words.indices.dropLast() where Self.numberedKeywords.contains(text.words[position].text) {
            let marker = position..<(position + 2)
            guard text.coversWholeTokens(marker),
                  !PhraseGrammar.endsClause(text.token(ofWord: position)),
                  !PhraseGrammar.followsDeterminer(position, in: text),
                  !Self.follows(position, in: text, oneOf: Self.copulas, orEndingIn: Self.copulaContractions),
                  let number = Self.number(text.words[position + 1].text)
            else { continue }
            let words = Self.includingItemCopula(marker, in: text)
            guard words.upperBound < text.words.count else { continue }
            candidates.append(Candidate(words: words, keyword: text.words[position].text, number: number))
        }

        var runs: [[Candidate]] = []
        for keyword in Self.numberedKeywords {
            var run: [Candidate] = []
            for candidate in candidates where candidate.keyword == keyword {
                if candidate.number == run.count + 1 {
                    run.append(candidate)
                } else if candidate.number == 1 {
                    runs.append(run)
                    run = [candidate]
                }
            }
            runs.append(run)
        }
        return runs.filter { $0.count >= 2 }.flatMap { run in
            run.map { marker(at: $0.words, text: "\($0.number). ", trigger: "\($0.keyword) \($0.number)", in: text) }
        }
    }

    private func bulletMarkers(in text: TokenizedText) -> [PhraseMatch] {
        let positions = text.words.indices.filter { position in
            PhraseGrammar.matches(Self.bullet, at: position, in: text)
                && position + Self.bullet.count < text.words.count
                && !PhraseGrammar.followsDeterminer(position, in: text)
                && !Self.follows(position, in: text, oneOf: Self.ordinals)
        }
        guard positions.count >= 2 else { return [] }
        return positions.map { marker(at: $0..<($0 + 2), text: "- ", trigger: "bullet point", in: text) }
    }

    /// A marker starts a new line, except at the start of the text.
    private func marker(at words: Range<Int>, text lineStart: String, trigger: String, in text: TokenizedText) -> PhraseMatch {
        PhraseMatch(
            words: words,
            replacement: .placeholder(
                trigger: trigger,
                expansion: (words.lowerBound == 0 ? "" : "\n") + lineStart,
                role: .structure
            ),
            keptTrailing: PhraseGrammar.trailingAfterClausePunctuation(text.token(ofWord: words.upperBound - 1))
        )
    }

    /// `marker` and the "is" after it, when that "is" introduces the item (see the type's rules).
    private static func includingItemCopula(_ marker: Range<Int>, in text: TokenizedText) -> Range<Int> {
        let next = marker.upperBound
        let withCopula = marker.lowerBound..<(next + 1)
        guard next < text.words.count,
              itemCopulas.contains(text.words[next].text),
              text.coversWholeTokens(withCopula),
              !PhraseGrammar.endsClause(text.token(ofWord: next - 1)),
              !asksQuestion(from: next, in: text)
        else { return marker }
        return withCopula
    }

    /// Whether the sentence from word `position` ends with a question mark.
    private static func asksQuestion(from position: Int, in text: TokenizedText) -> Bool {
        let tokens = text.tokens.indices[text.words[position].token...]
        let end = tokens.first { TokenEdges.trailing(of: text.token($0)).contains { sentenceEnders.contains($0) } }
        return end.map { TokenEdges.trailing(of: text.token($0)).contains("?") } ?? false
    }

    /// Whether the word before `position`, in the same clause, is one of `words` or ends with
    /// one of `endings`.
    private static func follows(
        _ position: Int,
        in text: TokenizedText,
        oneOf words: Set<String>,
        orEndingIn endings: [String] = []
    ) -> Bool {
        guard position > 0 else { return false }
        let previous = text.words[position - 1]
        guard previous.endsToken, !PhraseGrammar.endsClause(text.token(previous.token)) else { return false }
        return words.contains(previous.text) || endings.contains { previous.text.hasSuffix($0) }
    }

    private static func number(_ word: String) -> Int? {
        if let value = numberWords[word] { return value }
        guard word.count <= 2, let value = Int(word), value > 0 else { return nil }
        return value
    }
}
