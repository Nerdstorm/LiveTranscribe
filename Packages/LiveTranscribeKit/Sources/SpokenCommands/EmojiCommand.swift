import Foundation
import Shared

/// An emoji said by name: "hi emoji fireworks" → "Hi 🎆", "thanks heart emoji" → "Thanks ❤️".
///
/// The keyword "emoji" comes before the name or after it. Before is tried first, so in "happy
/// birthday emoji cake" the cake is the emoji, not the birthday; the name after the keyword is
/// then read as the longest run of up to ``maxNameWords`` words that names an emoji, so "emoji
/// party popper see you" finds the party popper. A name never runs across a comma or a full
/// stop. "emoji" with no name next to it stays a word.
///
/// Speech about emoji stays as said: nothing is replaced after a determiner ("an emoji party",
/// "the fire emoji"), and a name before the keyword is not taken when a pronoun or auxiliary
/// comes before it, which makes it a verb ("I love emoji", "we'd like emoji").
///
/// The emoji goes behind a placeholder, so the model neither drops it nor rewrites its name.
public struct EmojiCommand: PhraseMatcher {
    static let keyword = "emoji"

    private let names: EmojiNames
    private let maxNameWords: Int

    /// - Parameter maxNameWords: The longest name tried, in words ("face with tears of joy" is 5).
    public init(names: EmojiNames = .standard, maxNameWords: Int = 6) {
        self.names = names
        self.maxNameWords = maxNameWords
    }

    public func matches(in text: TokenizedText) -> [PhraseMatch] {
        var found: [PhraseMatch] = []
        // A name may not reuse words an earlier match took: "emoji heart emoji" is one heart.
        var firstFreeWord = 0
        for keyword in text.words.indices where isKeyword(at: keyword, in: text) {
            guard keyword >= firstFreeWord else { continue }
            if let match = nameAfter(keyword, in: text) ?? nameBefore(keyword, notBefore: firstFreeWord, in: text) {
                found.append(match)
                firstFreeWord = match.words.upperBound
            }
        }
        return found
    }

    // MARK: - Private

    private func isKeyword(at index: Int, in text: TokenizedText) -> Bool {
        let word = text.words[index]
        return word.text == Self.keyword && word.startsToken && word.endsToken
    }

    /// "emoji fireworks": the longest name right after the keyword.
    private func nameAfter(_ keyword: Int, in text: TokenizedText) -> PhraseMatch? {
        let keywordToken = text.token(ofWord: keyword)
        guard !CommandGrammar.endsClause(keywordToken), !CommandGrammar.followsDeterminer(keyword, in: text) else {
            return nil
        }
        let longest = min(maxNameWords, text.words.count - keyword - 1)
        guard longest > 0 else { return nil }
        for count in stride(from: longest, through: 1, by: -1) {
            let name = (keyword + 1)..<(keyword + 1 + count)
            guard text.coversWholeTokens(name), CommandGrammar.runsOn(name, in: text),
                  let emoji = names.emoji(for: text.words(in: name))
            else { continue }
            return PhraseMatch(
                words: keyword..<name.upperBound,
                replacement: .placeholder(trigger: trigger(text.words(in: name)), expansion: emoji, role: .content),
                keptLeading: String(TokenEdges.leading(of: keywordToken)),
                keptTrailing: String(TokenEdges.trailing(of: text.token(ofWord: name.upperBound - 1)))
            )
        }
        return nil
    }

    /// "heart emoji": the longest name right before the keyword.
    private func nameBefore(_ keyword: Int, notBefore firstFreeWord: Int, in text: TokenizedText) -> PhraseMatch? {
        let longest = min(maxNameWords, keyword - firstFreeWord)
        guard longest > 0 else { return nil }
        for count in stride(from: longest, through: 1, by: -1) {
            let name = (keyword - count)..<keyword
            guard text.coversWholeTokens(name),
                  !CommandGrammar.endsClause(text.token(ofWord: keyword - 1)),
                  CommandGrammar.runsOn(name, in: text),
                  !CommandGrammar.followsDeterminer(name.lowerBound, in: text),
                  !Self.followsSubject(name.lowerBound, in: text),
                  let emoji = names.emoji(for: text.words(in: name))
            else { continue }
            return PhraseMatch(
                words: name.lowerBound..<(keyword + 1),
                replacement: .placeholder(trigger: trigger(text.words(in: name)), expansion: emoji, role: .content),
                keptLeading: String(TokenEdges.leading(of: text.token(ofWord: name.lowerBound))),
                keptTrailing: String(TokenEdges.trailing(of: text.token(ofWord: keyword)))
            )
        }
        return nil
    }

    private func trigger(_ name: [String]) -> String {
        ([Self.keyword] + name).joined(separator: " ")
    }

    /// Words after which the next word is a verb: "I love emoji" is about emoji, "thanks, love
    /// emoji" is not written that way.
    private static let subjects: Set<String> = [
        "i", "you", "we", "they", "he", "she", "it", "who", "people",
        "i'm", "you're", "we're", "they're", "he's", "she's", "it's",
        "i've", "you've", "we've", "they've", "i'd", "you'd", "we'd", "they'd", "i'll", "you'll", "we'll", "they'll",
        "do", "does", "did", "don't", "doesn't", "didn't", "will", "would", "can", "could", "should", "might",
        "must", "won't", "wouldn't", "can't", "couldn't", "shouldn't", "to", "not", "never", "really", "also", "just",
    ]

    private static func followsSubject(_ position: Int, in text: TokenizedText) -> Bool {
        guard position > 0 else { return false }
        let previous = text.words[position - 1]
        return previous.endsToken && !CommandGrammar.endsClause(text.token(previous.token)) && subjects.contains(previous.text)
    }
}

/// Emoji by spoken name: a table of the names people say ("thumbs up", "heart", "smiley"),
/// then any emoji's Unicode name ("rocket", "fireworks", "face with tears of joy"), then either
/// of those in the singular ("hearts").
public struct EmojiNames: Sendable {
    /// The built-in names; see ``EmojiNames/commonNames``.
    public static let standard = EmojiNames(aliases: commonNames)

    private let aliases: [String: String]
    private let usesUnicodeNames: Bool

    /// - Parameters:
    ///   - aliases: Emoji by name, in the lowercase words ``EditDistance/normalize(_:)`` gives.
    ///   - usesUnicodeNames: Also accept any emoji's Unicode character name.
    public init(aliases: [String: String], usesUnicodeNames: Bool = true) {
        self.aliases = aliases
        self.usesUnicodeNames = usesUnicodeNames
    }

    /// The emoji named by `words`, lowercase and without punctuation; `nil` if they name none.
    public func emoji(for words: [String]) -> String? {
        guard !words.isEmpty else { return nil }
        if let emoji = lookUp(words.joined(separator: " ")) { return emoji }
        guard let last = words.last, last.count > 3, last.hasSuffix("s"), !last.hasSuffix("ss") else { return nil }
        return lookUp((words.dropLast() + [String(last.dropLast())]).joined(separator: " "))
    }

    private func lookUp(_ name: String) -> String? {
        if let emoji = aliases[name] { return emoji }
        return usesUnicodeNames ? Self.emoji(unicodeName: name) : nil
    }

    /// The emoji whose Unicode character name is `name`, with emoji presentation forced for one
    /// that is text by default (☀ becomes ☀️). `nil` for anything but a single emoji character.
    static func emoji(unicodeName name: String) -> String? {
        guard name.unicodeScalars.allSatisfy({ ($0.isASCII && $0.properties.isAlphabetic) || $0 == " " || ("0"..."9").contains($0) })
        else { return nil }
        let query = "\\N{\(name.uppercased())}"
        guard let character = query.applyingTransform(.toUnicodeName, reverse: true),
              character != query,
              character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else { return nil }
        if scalar.properties.isEmojiPresentation { return character }
        // Digits, # and * are emoji only as keycaps; below U+00FF nothing else is an emoji.
        if scalar.properties.isEmoji, scalar.value > 0xFF { return character + "\u{FE0F}" }
        return nil
    }
}
