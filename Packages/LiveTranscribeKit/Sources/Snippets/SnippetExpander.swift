import Foundation
import Shared

/// Finds spoken snippet triggers in a raw transcript and swaps them for placeholder tokens, so the
/// language model never sees (and never "fixes") a URL, an address or a signature.
///
/// Dictation passes it to ``PhraseProtector`` with the spoken commands, asks the model to keep
/// the tokens verbatim, and calls ``ProtectedText/restore(in:)`` on the model's output. A model
/// that drops or mangles a token is caught there instead of inserting half an expansion.
///
/// Matching:
/// - whole words only, after ``EditDistance/normalize(_:)``, so casing and punctuation do not
///   matter ("My calendar-link!" matches "my calendar link") but "link" never matches "linked";
/// - leftmost match first and, among matches starting at the same word, the longest, so
///   "my link to the calendar" wins over "my link";
/// - punctuation around the matched words that is not part of the trigger (a closing full stop,
///   an opening bracket) stays next to the placeholder: "Here's my calendar link." becomes
///   "Here's ⟦S1⟧.";
/// - a snippet that ``Snippet/validate(_:)`` would reject for its own content (a trigger with no
///   words, an empty expansion) or for repeating an earlier snippet's trigger is ignored.
public struct SnippetExpander: PhraseMatcher {
    /// Patterns keyed by their first word, longest first, so the first one that matches at a
    /// position is the longest.
    private let patternsByFirstWord: [String: [TriggerPattern]]

    /// Prepares the triggers once, so each dictation only pays for the matching itself. Snippets
    /// read from a hand-edited file may not have passed ``Snippet/validate(_:)``; the invalid ones
    /// are skipped here, by the same rules, rather than failing the whole dictation. The first of
    /// two snippets with the same trigger wins, as validation blames the later one.
    public init(snippets: [Snippet]) {
        var seenTriggers: Set<[String]> = []
        var patterns: [String: [TriggerPattern]] = [:]
        var ignored = 0
        for snippet in snippets {
            guard !snippet.expansion.isEmpty,
                  let pattern = TriggerPattern(snippet: snippet),
                  seenTriggers.insert(pattern.words).inserted
            else {
                ignored += 1
                continue
            }
            patterns[pattern.words[0], default: []].append(pattern)
        }
        // Ties need no order: two different triggers of the same length cannot both match at
        // the same position.
        self.patternsByFirstWord = patterns.mapValues { candidates in
            candidates.sorted { $0.words.count > $1.words.count }
        }
        if ignored > 0 {
            Log.snippets.notice("Ignoring \(ignored, privacy: .public) snippets with an empty trigger, an empty expansion or a repeated trigger")
        }
    }

    /// The longest trigger starting at each word, each a placeholder for its snippet's expansion.
    /// Overlapping matches are left for ``PhraseProtector`` to choose among.
    public func matches(in text: TokenizedText) -> [PhraseMatch] {
        guard !patternsByFirstWord.isEmpty else { return [] }
        var found: [PhraseMatch] = []
        for (position, word) in text.words.enumerated() where word.startsToken {
            guard let candidates = patternsByFirstWord[word.text],
                  let pattern = candidates.first(where: { Self.words(text.words, at: position, match: $0.words) })
            else { continue }
            let end = position + pattern.words.count
            found.append(PhraseMatch(
                words: position..<end,
                replacement: .placeholder(
                    trigger: pattern.snippet.trigger,
                    expansion: pattern.snippet.expansion,
                    role: .content
                ),
                keptLeading: String(pattern.keptLeading(of: text.token(ofWord: position))),
                keptTrailing: String(pattern.keptTrailing(of: text.token(ofWord: end - 1)))
            ))
        }
        return found
    }

    /// `text` with every trigger replaced by a placeholder token, numbered in order of
    /// appearance. Text without triggers comes back unchanged.
    public func protect(_ text: String) -> ProtectedText {
        PhraseProtector(matchers: [self]).protect(text)
    }

    /// `text` with every trigger replaced by its expansion directly, for text that does not go
    /// through the language model (cleanup level None, or a fallback).
    public func expand(_ text: String) -> String {
        protect(text).expanded
    }

    // MARK: - Private

    /// Whether `pattern` matches the words starting at `position` and ends at the end of a token.
    private static func words(_ words: [TokenizedText.Word], at position: Int, match pattern: [String]) -> Bool {
        let end = position + pattern.count
        guard end <= words.count, words[end - 1].endsToken else { return false }
        return zip(pattern, words[position..<end]).allSatisfy { $0 == $1.text }
    }
}
