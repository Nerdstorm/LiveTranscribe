import Foundation

/// Text a phrase is replaced with directly, in the text the language model sees: punctuation
/// the speaker dictated ("question mark" → "?"), which the model may still adjust.
public struct InlineText: Sendable, Equatable {
    public let text: String
    /// Attaches to the text before it: the space before is removed ("ready?", not "ready ?").
    public let joinsPrevious: Bool
    /// Attaches to the text after it: the space after is removed ("(page", not "( page").
    public let joinsNext: Bool
    /// Punctuation just before it gives way to it ("ready," then a spoken question mark becomes
    /// "ready?"). Speech-to-text often punctuates the word before a dictated mark.
    public let replacesPrecedingPunctuation: Bool
    /// The next word starts a sentence.
    public let capitalizesNext: Bool

    public init(
        _ text: String,
        joinsPrevious: Bool = false,
        joinsNext: Bool = false,
        replacesPrecedingPunctuation: Bool = false,
        capitalizesNext: Bool = false
    ) {
        self.text = text
        self.joinsPrevious = joinsPrevious
        self.joinsNext = joinsNext
        self.replacesPrecedingPunctuation = replacesPrecedingPunctuation
        self.capitalizesNext = capitalizesNext
    }
}

/// A spoken phrase found in a transcript, and what it stands for.
public struct PhraseMatch: Sendable, Equatable {
    public enum Replacement: Sendable, Equatable {
        /// Hidden behind a placeholder token until cleanup is done (see ``Placeholder``).
        case placeholder(trigger: String, expansion: String, role: Placeholder.Role)
        /// Written into the text straight away.
        case inline(InlineText)
    }

    /// The matched words, as indices into ``TokenizedText/words``. The first must start a token
    /// and the last must end one, so only whole tokens are replaced.
    public let words: Range<Int>
    public let replacement: Replacement
    /// The part of the first token's leading punctuation that stays in the text: an opening
    /// bracket before a snippet trigger, say. Must be a prefix of that punctuation.
    public let keptLeading: String
    /// The part of the last token's trailing punctuation that stays in the text: a full stop
    /// after an emoji, say. Must be a suffix of that punctuation.
    public let keptTrailing: String

    public init(words: Range<Int>, replacement: Replacement, keptLeading: String = "", keptTrailing: String = "") {
        self.words = words
        self.replacement = replacement
        self.keptLeading = keptLeading
        self.keptTrailing = keptTrailing
    }
}

/// Finds one kind of spoken phrase in a transcript: snippet triggers, emoji names, dictated
/// punctuation, line breaks, list markers.
///
/// A new kind of phrase is a new matcher passed to ``PhraseProtector``; nothing else changes.
public protocol PhraseMatcher: Sendable {
    /// Every match in `text`. Matches may overlap one another and other matchers' matches;
    /// ``PhraseProtector`` chooses among them.
    func matches(in text: TokenizedText) -> [PhraseMatch]
}

/// Replaces the spoken phrases that matchers find in a transcript: placeholders for text the
/// language model must not see or change, inline text for dictated punctuation.
///
/// Where matches overlap, the leftmost wins, then the longest, then the one from the matcher
/// listed first. Listing the user's snippets first lets a snippet replace a built-in command
/// with the same words.
public struct PhraseProtector: Sendable {
    private let matchers: [any PhraseMatcher]

    public init(matchers: [any PhraseMatcher]) {
        self.matchers = matchers
    }

    /// `text` with every chosen phrase replaced, placeholders numbered in order of appearance.
    /// Text without phrases comes back unchanged.
    public func protect(_ text: String) -> ProtectedText {
        guard !matchers.isEmpty else { return ProtectedText(unchanged: text) }
        let tokenized = TokenizedText(text)
        guard !tokenized.words.isEmpty else { return ProtectedText(unchanged: text) }

        let chosen = choose(from: candidates(in: tokenized))
        guard !chosen.isEmpty else { return ProtectedText(unchanged: text) }

        var builder = SegmentBuilder()
        var cursor = text.startIndex
        for match in chosen {
            let firstToken = tokenized.tokens[tokenized.words[match.words.lowerBound].token]
            let lastToken = tokenized.tokens[tokenized.words[match.words.upperBound - 1].token]
            builder.appendLiteral(text[cursor..<firstToken.lowerBound])
            builder.appendLiteral(match.keptLeading)
            switch match.replacement {
            case .placeholder(let trigger, let expansion, let role):
                let span = text[firstToken.lowerBound..<lastToken.upperBound]
                let spoken = span.dropFirst(match.keptLeading.count).dropLast(match.keptTrailing.count)
                builder.appendPlaceholder(trigger: trigger, spoken: String(spoken), expansion: expansion, role: role)
            case .inline(let inline):
                builder.appendInline(inline)
            }
            builder.appendLiteral(match.keptTrailing)
            cursor = lastToken.upperBound
        }
        builder.appendLiteral(text[cursor...])

        let protected = builder.build()
        Log.dictation.debug(
            "Replaced \(chosen.count, privacy: .public) spoken phrases, \(protected.placeholders.count, privacy: .public) behind placeholders"
        )
        return protected
    }

    // MARK: - Private

    private struct Candidate {
        let match: PhraseMatch
        let priority: Int
    }

    private func candidates(in text: TokenizedText) -> [Candidate] {
        var candidates: [Candidate] = []
        var invalid = 0
        for (priority, matcher) in matchers.enumerated() {
            for match in matcher.matches(in: text) {
                if Self.isValid(match, in: text) {
                    candidates.append(Candidate(match: match, priority: priority))
                } else {
                    invalid += 1
                }
            }
        }
        if invalid > 0 {
            Log.dictation.error("Ignored \(invalid, privacy: .public) phrase matches that did not cover whole tokens")
        }
        return candidates
    }

    /// Leftmost, then longest, then earliest matcher; no two chosen matches share a word.
    private func choose(from candidates: [Candidate]) -> [PhraseMatch] {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.match.words.lowerBound != rhs.match.words.lowerBound {
                return lhs.match.words.lowerBound < rhs.match.words.lowerBound
            }
            if lhs.match.words.count != rhs.match.words.count {
                return lhs.match.words.count > rhs.match.words.count
            }
            return lhs.priority < rhs.priority
        }
        var chosen: [PhraseMatch] = []
        var nextFreeWord = 0
        for candidate in ordered where candidate.match.words.lowerBound >= nextFreeWord {
            chosen.append(candidate.match)
            nextFreeWord = candidate.match.words.upperBound
        }
        return chosen
    }

    /// Covers whole tokens, and keeps only punctuation those tokens have.
    private static func isValid(_ match: PhraseMatch, in text: TokenizedText) -> Bool {
        guard text.coversWholeTokens(match.words) else { return false }
        let leading = TokenEdges.leading(of: text.token(ofWord: match.words.lowerBound))
        let trailing = TokenEdges.trailing(of: text.token(ofWord: match.words.upperBound - 1))
        return leading.hasPrefix(match.keptLeading) && trailing.hasSuffix(match.keptTrailing)
    }
}

/// Assembles a ``ProtectedText`` piece by piece, applying inline text's spacing and casing to
/// the text around it.
private struct SegmentBuilder {
    private static let precedingPunctuation: Set<Character> = [",", ";", ":", ".", "!", "?"]

    private var segments: [ProtectedText.Segment] = []
    private var placeholders: [Placeholder] = []
    /// The previous inline text joins the next text: drop the whitespace before it.
    private var joinsNext = false
    /// The previous inline text ended a sentence: capitalise the next word.
    private var capitalizesNext = false
    /// The text so far ends with inline text, whose punctuation a following mark adds to rather
    /// than replaces ("?!").
    private var endsWithInline = false

    mutating func appendLiteral(_ literal: some StringProtocol) {
        var text = String(literal)
        if joinsNext {
            text = String(text.drop(while: \.isWhitespace))
            if !text.isEmpty { joinsNext = false }
        }
        if capitalizesNext, text.contains(where: { !$0.isWhitespace }) {
            text = SentenceCase.capitalizingFirstWord(text)
            capitalizesNext = false
        }
        if text.contains(where: { !$0.isWhitespace }) { endsWithInline = false }
        append(text)
    }

    mutating func appendPlaceholder(trigger: String, spoken: String, expansion: String, role: Placeholder.Role) {
        joinsNext = false
        capitalizesNext = false
        endsWithInline = false
        let placeholder = Placeholder(
            token: PlaceholderToken.make(index: placeholders.count + 1),
            trigger: trigger,
            spoken: spoken,
            expansion: expansion,
            role: role
        )
        segments.append(.placeholder(placeholders.count))
        placeholders.append(placeholder)
    }

    mutating func appendInline(_ inline: InlineText) {
        if inline.joinsPrevious {
            trimTail(punctuation: inline.replacesPrecedingPunctuation && !endsWithInline)
        }
        append(inline.text)
        joinsNext = inline.joinsNext
        capitalizesNext = inline.capitalizesNext
        endsWithInline = !inline.text.isEmpty
    }

    func build() -> ProtectedText {
        ProtectedText(segments: segments, placeholders: placeholders)
    }

    private mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        if case .literal(let previous) = segments.last {
            segments[segments.count - 1] = .literal(previous + text)
        } else {
            segments.append(.literal(text))
        }
    }

    /// Removes the whitespace, and optionally the punctuation, at the end of the text so far.
    /// Stops at a placeholder: its expansion is not known here.
    private mutating func trimTail(punctuation: Bool) {
        guard case .literal(var tail) = segments.last else { return }
        while let last = tail.last, last.isWhitespace || (punctuation && Self.precedingPunctuation.contains(last)) {
            tail.removeLast()
        }
        segments.removeLast()
        append(tail)
    }
}
