import Foundation
import Snippets
import Testing

/// A small, fast, seedable generator (Steele, Lea and Flood's SplitMix64), so every run of the
/// property test sees the same cases and a failure can be replayed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random snippet sets and transcripts: protect, let a simulated model change the casing and
/// punctuation of everything except the tokens, restore, and check every expansion arrived
/// verbatim, once per spoken trigger.
@Suite("Snippet round trip property")
struct SnippetPropertyTests {
    private static let iterations = 200
    private static let seed: UInt64 = 0x5EED_0F_5A1B_B175

    /// Trigger words and filler words never overlap, so the expected occurrences are exactly
    /// the triggers the generator inserted.
    private static let triggerVocabulary = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf"]
    private static let fillerVocabulary = ["the", "quick", "brown", "fox", "jumps", "over", "a", "lazy", "dog", "today"]
    /// Awkward expansion content: URLs, newlines, emoji, and text that looks like a token.
    private static let expansionPieces = [
        "https://example.com/a_b?c=d&e=f#g", "line one\nline two", "⟦S2⟧", "⟦S1⟧", "[S1]", "\u{1F642}",
        "Best,\n\u{2014} Alex", "  spaced  ", "{\"json\": true}", "$1.50", "\\n", "⟦", "⟧",
    ]

    @Test func expansionsSurviveAModelThatOnlyTouchesOtherWords() throws {
        var rng = SplitMix64(seed: Self.seed)
        for iteration in 0..<Self.iterations {
            let snippets = Self.randomSnippets(using: &rng)
            let (text, inserted) = Self.randomTranscript(triggers: snippets, using: &rng)
            let expander = SnippetExpander(snippets: snippets)
            let protected = expander.protect(text)
            let context = Comment(rawValue: "iteration \(iteration): \(text.debugDescription)")

            #expect(protected.placeholders.map(\.expansion) == inserted.map { snippets[$0].expansion }, context)
            // Every spoken trigger was taken, and the fallback path agrees with a model that
            // changed nothing.
            #expect(expander.protect(protected.text).placeholders.isEmpty, context)
            #expect(protected.restore(in: protected.text) == protected.expanded, context)
            #expect(expander.expand(text) == protected.expanded, context)

            let modelOutput = Self.simulateModel(on: protected.text, using: &rng)
            let restored = try #require(protected.restore(in: modelOutput), context)

            var remainder = restored
            for (index, snippet) in snippets.enumerated() {
                let expected = inserted.filter { $0 == index }.count
                #expect(restored.components(separatedBy: snippet.expansion).count - 1 == expected, context)
                remainder = remainder.replacingOccurrences(of: snippet.expansion, with: "")
            }
            #expect(!remainder.contains("⟦") && !remainder.contains("⟧"), context)
        }
    }

    /// The other half of the contract: when the model drops, repeats or alters any one token, the
    /// flow must learn that from `restore` and fall back.
    @Test func aModelThatDamagesAnyOneTokenIsCaught() {
        var rng = SplitMix64(seed: Self.seed ^ 0xDA3A_6E)
        for iteration in 0..<Self.iterations {
            let snippets = Self.randomSnippets(using: &rng)
            let (text, _) = Self.randomTranscript(triggers: snippets, using: &rng)
            let protected = SnippetExpander(snippets: snippets).protect(text)
            let modelOutput = Self.simulateModel(on: protected.text, using: &rng)
            let token = protected.tokens.randomElement(using: &rng)!
            let damaged = modelOutput.replacingOccurrences(of: token, with: Self.damage(token, using: &rng))
            let context = Comment(rawValue: "iteration \(iteration): \(damaged.debugDescription)")

            #expect(protected.restore(in: damaged) == nil, context)
        }
    }

    // MARK: - Generators

    /// One to five snippets with distinct triggers of one to three words. Each expansion starts
    /// with a unique `«n»` marker, so occurrences can be counted without one expansion being
    /// mistaken for part of another.
    private static func randomSnippets(using rng: inout SplitMix64) -> [Snippet] {
        var triggers: [[String]] = []
        let count = Int.random(in: 1...5, using: &rng)
        while triggers.count < count {
            let words = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                triggerVocabulary.randomElement(using: &rng)!
            }
            if !triggers.contains(words) { triggers.append(words) }
        }
        return triggers.enumerated().map { index, words in
            let pieces = (0..<Int.random(in: 1...3, using: &rng)).map { _ in expansionPieces.randomElement(using: &rng)! }
            return Snippet(trigger: words.joined(separator: " "), expansion: "\u{00AB}\(index)\u{00BB}" + pieces.joined(separator: " "))
        }
    }

    /// Filler runs with trigger occurrences between them, spoken with random casing, commas,
    /// hyphens, brackets and closing punctuation. Returns the text and the snippet index of each
    /// inserted occurrence, in order.
    private static func randomTranscript(triggers snippets: [Snippet], using rng: inout SplitMix64) -> (String, [Int]) {
        var tokens: [String] = []
        var inserted: [Int] = []
        for _ in 0..<Int.random(in: 1...6, using: &rng) {
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                tokens.append(recased(fillerVocabulary.randomElement(using: &rng)!, using: &rng))
            }
            guard Bool.random(using: &rng) || inserted.isEmpty else { continue }
            let index = Int.random(in: 0..<snippets.count, using: &rng)
            inserted.append(index)
            tokens.append(contentsOf: spoken(snippets[index].triggerWords, using: &rng))
        }
        tokens.append(fillerVocabulary.randomElement(using: &rng)!)

        var text = ""
        for (position, token) in tokens.enumerated() {
            if position > 0 { text += [" ", " ", " ", "  ", "\n"].randomElement(using: &rng)! }
            text += token
        }
        return (text, inserted)
    }

    /// Trigger words as speech-to-text might punctuate them.
    private static func spoken(_ words: [String], using rng: inout SplitMix64) -> [String] {
        var tokens: [String] = []
        for word in words.map({ recased($0, using: &rng) }) {
            if let last = tokens.last, Int.random(in: 0..<5, using: &rng) == 0 {
                tokens[tokens.count - 1] = last + "-" + word
            } else if let last = tokens.last, Int.random(in: 0..<5, using: &rng) == 0 {
                tokens[tokens.count - 1] = last + ","
                tokens.append(word)
            } else {
                tokens.append(word)
            }
        }
        if Int.random(in: 0..<4, using: &rng) == 0 {
            tokens[0] = "(" + tokens[0]
            tokens[tokens.count - 1] += ")"
        }
        tokens[tokens.count - 1] += ["", "", ".", ",", "!", "?", "...", ";"].randomElement(using: &rng)!
        return tokens
    }

    /// A model that recases words and swaps their punctuation, but keeps every token and never
    /// changes the characters of one.
    private static func simulateModel(on text: String, using rng: inout SplitMix64) -> String {
        let rewritten = text.split(whereSeparator: \.isWhitespace).map { piece -> String in
            let token = String(piece)
            if token.contains("⟦"), let close = token.lastIndex(of: "⟧") {
                // Keep the token and anything before it; replace the punctuation after it.
                return token[...close] + ["", ".", ",", "!", ":"].randomElement(using: &rng)!
            }
            let bare = token.trimmingCharacters(in: .punctuationCharacters)
            return recased(bare, using: &rng) + ["", "", ",", ".", ";", "?"].randomElement(using: &rng)!
        }
        var output = ""
        for (position, token) in rewritten.enumerated() {
            if position > 0 { output += Int.random(in: 0..<8, using: &rng) == 0 ? "\n" : " " }
            output += token
        }
        return output
    }

    /// What a model might do to a token it was told to keep: drop it, repeat it, or rewrite it.
    private static func damage(_ token: String, using rng: inout SplitMix64) -> String {
        let damaged = [
            "",
            token + " " + token,
            token.replacingOccurrences(of: "S", with: "S "),
            token.replacingOccurrences(of: "⟦", with: "[").replacingOccurrences(of: "⟧", with: "]"),
            token.lowercased(),
            String(token.dropFirst()),
            String(token.dropLast()),
            token.replacingOccurrences(of: "S", with: "S0"),
        ]
        return damaged.randomElement(using: &rng)!
    }

    private static func recased(_ word: String, using rng: inout SplitMix64) -> String {
        switch Int.random(in: 0..<4, using: &rng) {
        case 0: word.uppercased()
        case 1: word.prefix(1).uppercased() + word.dropFirst()
        default: word.lowercased()
        }
    }
}
