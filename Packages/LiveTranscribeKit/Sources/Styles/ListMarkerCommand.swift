import Foundation
import Shared

/// Spoken list markers: "number one … number two …" (or "item", "step", with digits or words)
/// and "bullet point … bullet point …". Each marker goes behind a placeholder that becomes the
/// start of a list line, "1. " or "- ", which ``MarkedListLayout`` then lays out.
///
/// Numbered markers count only in a run that starts at one and goes up by one, with the same
/// word ("number", "item" or "step"), at least two of them, so "we're number one" stays as said.
/// After "number one", the later numbers may be said bare or as ordinals, as people do: "Number
/// one, the form is too long. Two, the sign-in failed. Third, the emails were late." A bare
/// number counts only as a marker of a run already begun, with an item between it and the marker
/// before, starting its clause and followed by a comma, a colon, a full stop or "is" ("Two people
/// came" and "number one, two, three" stay as said). A list that starts with a bare number or an
/// ordinal is left to ``ListFormatter``, which reads "number two" after it. Bullets need two markers too. Every marker needs words after it. A marker is talked
/// about, not said, after a determiner ("the number one priority", "a bullet point"), after a form
/// of "be" ("speed is number one and cost is number two"), and, for bullets, after an ordinal
/// ("the second bullet point is wrong"). An "is" straight after a number belongs to the marker
/// ("number one is ship the release"), but not after a comma ("number one, is it ready?") or in a
/// question ("number one is it ready?").
///
/// Used only where lists are laid out: from Medium up, in fields that take several lines.
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
    /// Marks after a bare number that make it a list number: "Two, …", "Three: …", "Four. …".
    private static let bareEnders: Set<Character> = [",", ":", "."]
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
        /// The word said before the number; `nil` for a bare number ("Two, …").
        let keyword: String?
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

        let bare = bareNumbers(in: text)
        var taken = Set<Int>()
        var runs: [[Candidate]] = []
        for keyword in Self.numberedKeywords.sorted() {
            var run: [Candidate] = []
            func close() {
                guard run.count >= 2 else { return }
                runs.append(run)
                taken.formUnion(run.filter { $0.keyword == nil }.map(\.words.lowerBound))
            }
            let ordered = (candidates.filter { $0.keyword == keyword } + bare.filter { !taken.contains($0.words.lowerBound) })
                .sorted { $0.words.lowerBound < $1.words.lowerBound }
            /// A keyworded number continues its run. A bare one does when there is an item between
            /// it and the run's last marker, and no other keyword's marker.
            func continues(_ candidate: Candidate) -> Bool {
                if candidate.keyword != nil { return true }
                guard let last = run.last else { return false }
                return candidate.words.lowerBound > last.words.upperBound
                    && !candidates.contains {
                        $0.keyword != keyword && $0.words.lowerBound > last.words.lowerBound
                            && $0.words.lowerBound < candidate.words.lowerBound
                    }
            }
            for candidate in ordered {
                if candidate.number == run.count + 1, continues(candidate) {
                    run.append(candidate)
                } else if candidate.number == 1, candidate.keyword != nil {
                    close()
                    run = [candidate]
                }
            }
            close()
        }
        return runs.flatMap { run in
            run.map { candidate in
                let trigger = candidate.keyword.map { "\($0) \(candidate.number)" } ?? "\(candidate.number)"
                return marker(at: candidate.words, text: "\(candidate.number). ", trigger: trigger, in: text)
            }
        }
    }

    /// Numbers said without "number" before them: "Two, …", "Three: …", "Four. …", "Five is …",
    /// "Second, …". Each starts a clause, so "we have two, …" is not one, and has words after it.
    private func bareNumbers(in text: TokenizedText) -> [Candidate] {
        text.words.indices.dropFirst().compactMap { position in
            let word = text.words[position]
            guard let number = Self.number(word.text) ?? ListFormatter.ordinals[word.text],
                  text.coversWholeTokens(position..<(position + 1)),
                  Self.startsClause(position, in: text)
            else { return nil }
            let said = Self.includingItemCopula(position..<(position + 1), in: text)
            let marked = said.count > 1 || TokenEdges.trailing(of: text.token(word.token)).contains { Self.bareEnders.contains($0) }
            guard marked, said.upperBound < text.words.count else { return nil }
            return Candidate(words: said, keyword: nil, number: number)
        }
    }

    private static func startsClause(_ position: Int, in text: TokenizedText) -> Bool {
        let previous = text.words[position - 1]
        return previous.endsToken && PhraseGrammar.endsClause(text.token(previous.token))
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
