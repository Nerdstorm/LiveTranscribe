import Foundation
import Shared

/// Spoken list markers: "number one … number two …" (or "item", "step", with digits or words)
/// and "bullet point … bullet point …". Each marker goes behind a placeholder that becomes the
/// start of a list line, "1. " or "- ", which ``MarkedListLayout`` then lays out.
///
/// Numbered markers count only in a run that starts at one and goes up by one, with the same
/// word, at least two of them, so "we're number one" stays as said. Bullets need two markers
/// too. A marker after a determiner is a noun ("the number one priority", "a bullet point").
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
            let words = position..<(position + 2)
            guard text.coversWholeTokens(words),
                  !PhraseGrammar.endsClause(text.token(ofWord: position)),
                  !PhraseGrammar.followsDeterminer(position, in: text),
                  let number = Self.number(text.words[position + 1].text)
            else { continue }
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
            PhraseGrammar.matches(Self.bullet, at: position, in: text) && !PhraseGrammar.followsDeterminer(position, in: text)
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

    private static func number(_ word: String) -> Int? {
        if let value = numberWords[word] { return value }
        guard word.count <= 2, let value = Int(word), value > 0 else { return nil }
        return value
    }
}
