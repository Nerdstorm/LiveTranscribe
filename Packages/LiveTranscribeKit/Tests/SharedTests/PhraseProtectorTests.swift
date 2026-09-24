import Shared
import Testing

/// Fixed phrases, for testing how ``PhraseProtector`` chooses and applies matches.
private struct FixedPhrases: PhraseMatcher {
    struct Phrase: Sendable {
        let words: [String]
        let replacement: PhraseMatch.Replacement
        /// Keep the last token's trailing punctuation next to the replacement.
        var keepsTrailing = true
    }

    let phrases: [Phrase]

    func matches(in text: TokenizedText) -> [PhraseMatch] {
        var found: [PhraseMatch] = []
        for start in text.words.indices {
            for phrase in phrases {
                let range = start..<(start + phrase.words.count)
                guard range.upperBound <= text.words.count,
                      text.words(in: range) == phrase.words,
                      text.coversWholeTokens(range)
                else { continue }
                let trailing = TokenEdges.trailing(of: text.token(ofWord: range.upperBound - 1))
                found.append(PhraseMatch(
                    words: range,
                    replacement: phrase.replacement,
                    keptTrailing: phrase.keepsTrailing ? String(trailing) : ""
                ))
            }
        }
        return found
    }
}

/// Returns fixed matches whatever the text, to test the protector's own checks.
private struct Scripted: PhraseMatcher {
    let result: [PhraseMatch]
    func matches(in text: TokenizedText) -> [PhraseMatch] { result }
}

@Suite("PhraseProtector")
struct PhraseProtectorTests {
    private static func content(_ expansion: String, trigger: String = "") -> PhraseMatch.Replacement {
        .placeholder(trigger: trigger, expansion: expansion, role: .content)
    }

    private static let questionMark = FixedPhrases.Phrase(
        words: ["question", "mark"],
        replacement: .inline(InlineText("?", joinsPrevious: true, replacesPrecedingPunctuation: true, capitalizesNext: true)),
        keepsTrailing: false
    )
    private static let newLine = FixedPhrases.Phrase(
        words: ["new", "line"],
        replacement: .placeholder(trigger: "new line", expansion: "\n", role: .lineBreak),
        keepsTrailing: false
    )
    private static let fire = FixedPhrases.Phrase(words: ["emoji", "fire"], replacement: content("🔥", trigger: "emoji fire"))

    @Test func leftmostThenLongestThenFirstMatcherWins() {
        let first = FixedPhrases(phrases: [
            .init(words: ["alpha", "beta"], replacement: Self.content("AB")),
            .init(words: ["beta", "gamma", "delta"], replacement: Self.content("BGD")),
        ])
        let second = FixedPhrases(phrases: [
            .init(words: ["alpha", "beta"], replacement: Self.content("other")),
            .init(words: ["gamma"], replacement: Self.content("G")),
            .init(words: ["gamma", "delta"], replacement: Self.content("GD")),
        ])
        let protected = PhraseProtector(matchers: [first, second]).protect("alpha beta gamma delta")
        #expect(protected.text == "⟦S1⟧ ⟦S2⟧")
        #expect(protected.placeholders.map(\.expansion) == ["AB", "GD"])
    }

    @Test func dictatedPunctuationReplacesPunctuationBeforeItAndCapitalisesTheNextWord() {
        let protector = PhraseProtector(matchers: [FixedPhrases(phrases: [Self.questionMark])])
        let protected = protector.protect("is it ready, question mark. yes it is")
        #expect(protected.text == "is it ready? Yes it is")
        #expect(protected.placeholders.isEmpty)
        #expect(protected.expanded == protected.text)
    }

    @Test func openingAndClosingMarksAttachToTheWordsTheyEnclose() {
        let quotes = FixedPhrases(phrases: [
            .init(words: ["open", "quote"], replacement: .inline(InlineText("\"", joinsNext: true))),
            .init(words: ["close", "quote"], replacement: .inline(InlineText("\"", joinsPrevious: true))),
        ])
        let protected = PhraseProtector(matchers: [quotes]).protect("he said open quote hi there close quote and left")
        #expect(protected.text == "he said \"hi there\" and left")
    }

    @Test func placeholdersRecordTheirRoleAndTheWordsAsSpoken() {
        let protector = PhraseProtector(matchers: [FixedPhrases(phrases: [Self.fire, Self.newLine])])
        let protected = protector.protect("Hi Emoji fire. New line, bye")
        #expect(protected.text == "Hi ⟦S1⟧. ⟦S2⟧ bye")
        #expect(protected.placeholders.map(\.role) == [.content, .lineBreak])
        #expect(protected.placeholders.map(\.trigger) == ["emoji fire", "new line"])
        #expect(protected.placeholders.map(\.spoken) == ["Emoji fire", "New line,"])
        #expect(protected.hasLayoutPlaceholders)
        #expect(protected.expanded { $0.role == .content ? $0.expansion : $0.spoken } == "Hi 🔥. New line, bye")
    }

    @Test func restoresLineBreaksBeforeContent() throws {
        let protected = PhraseProtector(matchers: [FixedPhrases(phrases: [Self.fire, Self.newLine])]).protect("hi emoji fire new line bye")
        #expect(protected.text == "hi ⟦S1⟧ ⟦S2⟧ bye")
        let broken = try #require(protected.restore(in: "Hi ⟦S1⟧. ⟦S2⟧ Bye.", roles: [.lineBreak]))
        #expect(broken == "Hi ⟦S1⟧. \n Bye.")
        #expect(protected.restore(in: broken, roles: [.content]) == "Hi 🔥. \n Bye.")
    }

    @Test("A step checks the tokens it replaces fully and the others for repeats", arguments: [
        ("Hi ⟦S1⟧. Bye.", false),
        ("Hi. ⟦S2⟧ Bye.", true),
        ("Hi ⟦S1⟧ ⟦S1⟧ ⟦S2⟧", false),
        ("Hi ⟦S1⟧ ⟦S2⟧ ⟦S3⟧", false),
        ("Hi ⟦S1⟧ ⟦S2 bye", false),
    ])
    func stepValidation(output: String, restores: Bool) {
        let protected = PhraseProtector(matchers: [FixedPhrases(phrases: [Self.fire, Self.newLine])]).protect("hi emoji fire new line bye")
        #expect((protected.restore(in: output, roles: [.lineBreak]) != nil) == restores)
    }

    @Test func ignoresMatchesThatSplitATokenOrKeepPunctuationTheTokenLacks() {
        let text = "use my calendar-link now"
        let splitsAToken = PhraseMatch(words: 3..<4, replacement: Self.content("X"))
        let inventsPunctuation = PhraseMatch(words: 4..<5, replacement: Self.content("Y"), keptTrailing: "!")
        let outOfRange = PhraseMatch(words: 4..<9, replacement: Self.content("Z"))
        let protected = PhraseProtector(matchers: [Scripted(result: [splitsAToken, inventsPunctuation, outOfRange])]).protect(text)
        #expect(protected.text == text)
        #expect(protected.placeholders.isEmpty)
    }

    @Test func textWithoutMatchesComesBackUnchanged() {
        let protector = PhraseProtector(matchers: [FixedPhrases(phrases: [Self.fire])])
        for text in ["", "   ", "nothing to see here", "  two  spaces\nand a newline\t"] {
            let protected = protector.protect(text)
            #expect(protected.text == text)
            #expect(protected.expanded == text)
            #expect(!protected.hasLayoutPlaceholders)
        }
    }
}

@Suite("TokenizedText")
struct TokenizedTextTests {
    @Test func splitsTokensAndTheirNormalisedWords() {
        let text = TokenizedText("Use my calendar-link \u{2014} now!")
        #expect(text.tokens.count == 5)
        #expect(text.words.map(\.text) == ["use", "my", "calendar", "link", "now"])
        #expect(text.token(ofWord: 3) == "calendar-link")
        #expect(text.words[2].startsToken && !text.words[2].endsToken)
        #expect(text.coversWholeTokens(2..<4))
        #expect(!text.coversWholeTokens(2..<3))
        #expect(!text.coversWholeTokens(3..<4))
        #expect(!text.coversWholeTokens(4..<6))
        #expect(TokenEdges.trailing(of: text.token(ofWord: 4)) == "!")
    }
}
