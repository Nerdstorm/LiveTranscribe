import Cleanup
import Foundation
import Shared
import Snippets
import SpokenCommands
import Styles
import Vocabulary

/// One transcript made ready for cleanup, and the steps that turn the cleaned text into the text
/// to insert.
///
/// Snippet triggers, spoken commands (emoji, punctuation, line breaks, addresses) and, where
/// lists are laid out, spoken list markers are replaced before vocabulary and the model run (see
/// ``PhraseProtector``); the user's snippets come first, so a snippet wins over a command with
/// the same words. Afterwards the placeholders come back in two steps: line breaks and list
/// markers first, so the layout rules see lines, then snippets, emoji and addresses, so no rule
/// can change them.
struct PreparedDictation {
    /// The transcript with phrases replaced and vocabulary applied: what cleanup starts from.
    let text: String
    /// Lists and letters are laid out: at Medium and High, in fields that take several lines.
    let laysOut: Bool
    private let protected: ProtectedText
    private let layout: Layout

    init(transcript: String, configuration: DictationProcessor.Configuration, layout: Layout = Layout()) {
        laysOut = configuration.level.formatsLayout && configuration.multiline
        var matchers: [any PhraseMatcher] = [SnippetExpander(snippets: configuration.snippets)]
        matchers += SpokenCommands.matchers(multiline: configuration.multiline)
        if laysOut {
            matchers.append(ListMarkerCommand())
        }
        protected = PhraseProtector(matchers: matchers).protect(transcript)
        text = VocabularyReplacer(entries: configuration.vocabulary).apply(to: protected.text)
        self.layout = layout
    }

    /// The placeholder tokens in `text`, which cleanup must keep.
    var placeholders: [String] {
        protected.tokens
    }

    /// The text before cleanup, which Undo AI edit puts back: phrases replaced and line breaks
    /// in place, but list markers as they were said and nothing laid out.
    var uncleaned: String {
        let asSaid: (Placeholder) -> String = { $0.role == .structure ? $0.spoken : $0.expansion }
        if let restored = protected.restore(in: text, resolving: asSaid) {
            return tidied(restored)
        }
        // Vocabulary replacement skips placeholders, so this means a bug there.
        Log.dictation.error("Placeholders did not survive vocabulary replacement; using the text without vocabulary")
        return tidied(protected.expanded(asSaid))
    }

    /// The structure in `text` that must be laid out before the model runs, such as a letter's
    /// greeting and sign-off; `nil` when there is none or nothing is laid out. Found after the
    /// level's filler removal, so "Um, dear Sam" still starts with its greeting.
    func frame(level: CleanupLevel) -> TextFrame? {
        guard laysOut else { return nil }
        return layout.frame(in: CleanupExecutor.deterministicCleanup(of: text, level: level))
    }

    /// `cleaned`, cleanup's output with every placeholder in it, as the text to insert; `nil` when
    /// a placeholder did not survive.
    func finished(_ cleaned: String) -> String? {
        let breaks: (Placeholder) -> String? = { $0.role == .content ? nil : $0.expansion }
        guard let lines = protected.restore(in: withoutAddedCommasAroundEmoji(cleaned), resolving: breaks) else {
            return nil
        }
        let tidy = tidied(lines)
        let arranged = laysOut ? layout.arrange(tidy) : tidy
        return protected.restore(in: arranged, roles: [.content])
    }

    // MARK: - Private

    /// `cleaned` without the commas the model put next to an emoji's placeholder and the speaker
    /// did not say. The model sees the placeholder as a word and punctuates it like a name:
    /// "Great job, S1, see you tomorrow."
    private func withoutAddedCommasAroundEmoji(_ cleaned: String) -> String {
        var result = cleaned
        for placeholder in protected.placeholders where placeholder.role == .content && Self.isEmoji(placeholder.expansion) {
            guard let said = text.range(of: placeholder.token) else { continue }
            let saidCommaBefore = text[..<said.lowerBound].last { !$0.isWhitespace } == ","
            let saidCommaAfter = text[said.upperBound...].first { !$0.isWhitespace } == ","
            if !saidCommaAfter, let token = result.range(of: placeholder.token),
               let after = result[token.upperBound...].firstIndex(where: { !$0.isWhitespace }), result[after] == "," {
                result.remove(at: after)
            }
            if !saidCommaBefore, let token = result.range(of: placeholder.token),
               let before = result[..<token.lowerBound].lastIndex(where: { !$0.isWhitespace }), result[before] == "," {
                result.remove(at: before)
            }
        }
        return result
    }

    /// Whether `text` is emoji and spaces only, such as an emoji command's expansion.
    private static func isEmoji(_ text: String) -> Bool {
        let glyphs = text.filter { !$0.isWhitespace }
        return !glyphs.isEmpty && glyphs.allSatisfy { character in
            guard let first = character.unicodeScalars.first else { return false }
            return first.properties.isEmojiPresentation
                || (first.properties.isEmoji && (first.value > 0xFF || character.unicodeScalars.contains("\u{FE0F}")))
        }
    }

    /// Line breaks and list markers leave stray spaces and punctuation around them.
    private func tidied(_ text: String) -> String {
        protected.hasLayoutPlaceholders ? SpokenCommands.tidyLineBreaks(text) : text
    }
}
