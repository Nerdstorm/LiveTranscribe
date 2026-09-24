import Foundation
import Shared

/// A letter or email: a greeting at the start ("Dear Sir or Madam", "Hi John") and a sign-off
/// at the end ("Kind regards Jordan Lee"), laid out on lines of their own around the
/// body:
///
///     Dear Sir or Madam,
///
///     I am writing about my passport renewal.
///
///     Kind regards,
///     Jordan Lee
///
/// Both ends are found in the words before cleanup, and only the body goes to the model: given a
/// whole letter, the model moved the name in the sign-off into the greeting. A letter needs a
/// greeting and a sign-off, so "Hi John, can you send the report?" stays as it is, as a chat
/// message should. An everyday sign-off such as "Thanks", "Cheers" or "Best" ends a letter
/// before a name, or with no name when the body reads as a letter's: two sentences or more, or
/// a spoken list. So "Hi John, can you send the report? Thanks" stays a chat message, while an
/// email that lists a few points and ends "Thanks" is laid out.
///
/// The addressee is what follows the greeting up to its comma, or, when speech-to-text wrote
/// none, the capitalised names or a word such as "team" or "all" right after it. "Dear sir oh
/// madam", a common mishearing, becomes "Dear Sir or Madam".
public struct LetterFrame: FrameRule {
    /// A greeting with no addressee after it.
    private static let impersonalGreeting = ["to", "whom", "it", "may", "concern"]
    private static let greetings: [[String]] = [
        impersonalGreeting, ["good", "morning"], ["good", "afternoon"], ["good", "evening"],
        ["dear"], ["hi"], ["hello"], ["hey"], ["greetings"],
    ]
    /// Groups addressed by a common word, and how they are written.
    private static let groups: [String: String] = [
        "sir or madam": "Sir or Madam", "sir oh madam": "Sir or Madam", "sir slash madam": "Sir or Madam",
        "sir and madam": "Sir and Madam", "sir": "Sir", "madam": "Madam", "sirs": "Sirs",
        "hiring manager": "Hiring Manager", "hiring team": "Hiring Team",
        "all": "all", "team": "team", "everyone": "everyone", "everybody": "everybody", "folks": "folks",
        "guys": "guys", "there": "there", "both": "both", "you all": "you all", "all of you": "all of you",
        "colleagues": "colleagues", "friends": "friends",
    ]
    private static let longestGroup = groups.keys.map { $0.split(separator: " ").count }.max() ?? 1
    /// Capitalised words that start a body, never a name in a greeting.
    private static let notNames: Set<String> = [
        "i", "i'm", "i've", "i'll", "i'd", "we", "we're", "we've", "we'll", "thanks", "thank", "hope", "hoping",
        "just", "please", "can", "could", "would", "will", "here", "this", "the", "it", "it's", "is", "are",
        "how", "what", "when", "where", "why", "sorry", "good", "great", "so", "quick", "following", "further",
        "regarding", "as", "welcome", "congratulations", "congrats", "happy", "let", "let's", "my", "our",
        "your", "yes", "no", "ok", "okay", "hopefully", "unfortunately", "apologies", "attached", "today",
    ]
    /// Sign-offs that end a letter with or without a name after them.
    private static let signOffs: [[String]] = [
        ["kind", "regards"], ["best", "regards"], ["warm", "regards"], ["warmest", "regards"], ["kindest", "regards"],
        ["regards"], ["sincerely"], ["yours", "sincerely"], ["sincerely", "yours"], ["yours", "faithfully"],
        ["yours", "truly"], ["best", "wishes"], ["with", "best", "wishes"], ["all", "the", "best"],
        ["many", "thanks"], ["with", "thanks"], ["thanks", "and", "regards"], ["thanks", "in", "advance"],
        ["respectfully"], ["cordially"], ["with", "gratitude"],
    ]
    /// Sign-offs that are also everyday words, so they end a letter only before a name or after
    /// a body that reads as a letter's (see ``readsAsALetter(_:from:to:listMarkers:)``).
    private static let everydaySignOffs: [[String]] = [
        ["thanks"], ["thank", "you"], ["cheers"], ["best"], ["love"], ["take", "care"], ["talk", "soon"], ["speak", "soon"],
    ]
    /// Most words in a signature.
    private static let longestSignature = 4
    /// Fewest sentences in a body that an everyday sign-off with no name after it ends.
    private static let minimumLetterSentences = 2
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]

    public init() {}

    public func frame(in text: String, listMarkers: Set<String>) -> TextFrame? {
        let tokenized = TokenizedText(text)
        guard let firstWord = tokenized.words.first, firstWord.token == 0,
              let greeting = Self.greetings.first(where: { PhraseGrammar.matches($0, at: 0, in: tokenized) }),
              let salutation = salutation(after: greeting, in: tokenized),
              let signOff = signOff(after: salutation.bodyStart, in: tokenized, listMarkers: listMarkers),
              salutation.bodyStart < signOff.start
        else { return nil }

        let bodyRange = tokenized.tokens[salutation.bodyStart].lowerBound..<tokenized.tokens[signOff.start - 1].upperBound
        let body = text[bodyRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return TextFrame(opening: salutation.text + "\n\n", body: body, closing: "\n\n" + signOff.text)
    }

    // MARK: - Greeting

    /// The salutation line and the index of the first token of the body.
    private func salutation(after greeting: [String], in text: TokenizedText) -> (text: String, bodyStart: Int)? {
        let greetingEnd = text.words[greeting.count - 1].token
        let written = SentenceCase.capitalizingFirstWord(greeting.joined(separator: " "))
        let first = greetingEnd + 1
        guard first < text.tokens.count else { return nil }
        if greeting == Self.impersonalGreeting || PhraseGrammar.endsClause(text.token(greetingEnd)) {
            return (written + ",", first)
        }

        // Up to a comma or a placeholder in the next few tokens, if what comes before is an addressee.
        for index in first..<min(first + Self.longestGroup + 1, text.tokens.count) {
            let token = text.token(index)
            let isPlaceholder = token.contains(PlaceholderToken.opening)
            guard isPlaceholder || PhraseGrammar.endsClause(token) else { continue }
            let addressee = first..<(isPlaceholder ? index : index + 1)
            guard let name = self.addressee(addressee, in: text) else { break }
            let bodyStart = addressee.upperBound
            guard bodyStart < text.tokens.count else { return nil }
            return (name.isEmpty ? written + "," : "\(written) \(name),", bodyStart)
        }

        // No punctuation: a group word, else the capitalised names right after the greeting.
        for count in stride(from: Self.longestGroup, through: 1, by: -1) where first + count < text.tokens.count {
            if let name = addressee(first..<(first + count), in: text), Self.isGroup(first..<(first + count), in: text) {
                return ("\(written) \(name),", first + count)
            }
        }
        var end = first
        while end < min(first + 3, text.tokens.count - 1), Self.isName(text.token(end)) {
            end += 1
        }
        guard end > first, let name = addressee(first..<end, in: text) else { return nil }
        return ("\(written) \(name),", end)
    }

    /// How the addressee in `tokens` is written, "" for none; `nil` if those tokens are not an
    /// addressee.
    private func addressee(_ tokens: Range<Int>, in text: TokenizedText) -> String? {
        guard !tokens.isEmpty else { return "" }
        if let group = Self.groups[Self.words(of: tokens, in: text).joined(separator: " ")] { return group }
        guard tokens.allSatisfy({ Self.isName(text.token($0)) }) else { return nil }
        return tokens.map { SentenceCase.capitalizingFirstWord(Self.core(of: text.token($0))) }.joined(separator: " ")
    }

    private static func isGroup(_ tokens: Range<Int>, in text: TokenizedText) -> Bool {
        groups[words(of: tokens, in: text).joined(separator: " ")] != nil
    }

    /// A capitalised word that is not a common word starting a sentence.
    private static func isName(_ token: Substring) -> Bool {
        let core = core(of: token)
        guard let first = core.first, first.isUppercase, !token.contains(PlaceholderToken.opening) else { return false }
        return !notNames.contains(EditDistance.normalize(core))
    }

    // MARK: - Sign-off

    /// The sign-off and its signature, and the index of the sign-off's first token.
    private func signOff(
        after bodyStart: Int,
        in text: TokenizedText,
        listMarkers: Set<String>
    ) -> (text: String, start: Int)? {
        var best: (text: String, start: Int)?
        for (phrases, isEveryday) in [(Self.signOffs, false), (Self.everydaySignOffs, true)] {
            for phrase in phrases {
                for position in text.words.indices where PhraseGrammar.matches(phrase, at: position, in: text) {
                    let start = text.words[position].token
                    let end = text.words[position + phrase.count - 1].token
                    guard start > bodyStart, PhraseGrammar.runsOn(position..<(position + phrase.count), in: text),
                          let signature = signature(from: end + 1, in: text),
                          !isEveryday || !signature.isEmpty
                            || Self.readsAsALetter(text, from: bodyStart, to: start, listMarkers: listMarkers)
                    else { continue }
                    if let current = best, current.start <= start { continue }
                    let closing = SentenceCase.capitalizingFirstWord(phrase.joined(separator: " ")) + ","
                    best = (signature.isEmpty ? closing : closing + "\n" + signature, start)
                }
            }
        }
        return best
    }

    /// The name that runs from token `start` to the end of the text, "" when the sign-off ends
    /// the text; `nil` when what follows is not a name.
    private func signature(from start: Int, in text: TokenizedText) -> String? {
        let count = text.tokens.count - start
        guard count <= Self.longestSignature else { return nil }
        guard count > 0 else { return "" }
        var parts: [String] = []
        for index in start..<text.tokens.count {
            let token = text.token(index)
            let isLast = index == text.tokens.count - 1
            let isPlaceholder = token.contains(PlaceholderToken.opening)
            guard isPlaceholder || Self.core(of: token).first?.isUppercase == true else { return nil }
            let trailing = TokenEdges.trailing(of: token)
            if !isLast, !trailing.isEmpty, !Self.isInitial(token) { return nil }
            parts.append(isLast && !isPlaceholder ? String(token.dropLast(trailing.count)) : String(token))
        }
        return parts.joined(separator: " ")
    }

    /// Whether the body's tokens from `start` up to `end` read as a letter's rather than a chat
    /// message's: at least ``minimumLetterSentences`` sentences, or a spoken list, numbered in
    /// words ("first, …", "one is …") or with markers (two of `listMarkers`).
    private static func readsAsALetter(
        _ text: TokenizedText,
        from start: Int,
        to end: Int,
        listMarkers: Set<String>
    ) -> Bool {
        guard start < end else { return false }
        let tokens = (start..<end).map { String(text.token($0)) }
        let markers = tokens.filter { token in listMarkers.contains { token.contains($0) } }.count
        let sentences = tokens.filter { $0.last.map(sentenceEnders.contains) ?? false }.count
        return markers >= 2 || sentences >= minimumLetterSentences
            || ListFormatter().lines(for: tokens.joined(separator: " ")) != nil
    }

    /// "J." in "Sam J. Lee".
    private static func isInitial(_ token: Substring) -> Bool {
        token.count == 2 && token.first?.isUppercase == true && token.last == "."
    }

    // MARK: - Words

    private static func words(of tokens: Range<Int>, in text: TokenizedText) -> [String] {
        text.words.filter { tokens.contains($0.token) }.map(\.text)
    }

    /// The token without its leading and trailing punctuation.
    private static func core(of token: Substring) -> String {
        String(token.dropFirst(TokenEdges.leading(of: token).count).dropLast(TokenEdges.trailing(of: token).count))
    }
}
