import Foundation
import Shared

/// A phrase the user says ("my calendar link") and the text it stands for (a URL, an address,
/// a signature).
///
/// Snippets are expanded after the language model has run, never by it: the model only sees an
/// opaque placeholder, so it cannot "correct" a URL or an address into something else.
public struct Snippet: Codable, Sendable, Equatable, Identifiable {
    /// Stable across edits, so the settings screen can update or delete a snippet whose trigger
    /// the user is still typing.
    public var id: UUID
    /// What the user says. Matched as whole words, ignoring case and punctuation.
    public var trigger: String
    /// Inserted verbatim in place of the trigger, including newlines, URLs and emoji.
    public var expansion: String

    /// A new snippet gets a fresh id; pass one only to rebuild a snippet that already exists.
    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }

    /// The trigger's words as matching sees them: lowercased, punctuation removed, hyphens split
    /// (see ``EditDistance/normalize(_:)``). Two snippets with the same words would be ambiguous,
    /// so validation rejects them.
    public var triggerWords: [String] {
        EditDistance.words(in: EditDistance.normalize(trigger))
    }

    /// Checks that every snippet can be matched and expanded, and that no two share a trigger
    /// or an id.
    ///
    /// Throws the first problem found, in list order, so the settings screen can point at the
    /// snippet to fix. A whitespace-only expansion is allowed: "new paragraph" expanding to two
    /// newlines is a legitimate snippet. Ids must be unique because ``SnippetStore/upsert(_:)``
    /// and the settings list find a snippet by its id; only a hand-edited file can repeat one.
    public static func validate(_ snippets: [Snippet]) throws {
        var seenTriggers: Set<[String]> = []
        var seenIDs: Set<UUID> = []
        for snippet in snippets {
            let words = snippet.triggerWords
            guard !words.isEmpty else { throw SnippetError.emptyTrigger(id: snippet.id) }
            guard !snippet.expansion.isEmpty else { throw SnippetError.emptyExpansion(id: snippet.id) }
            guard seenIDs.insert(snippet.id).inserted else { throw SnippetError.duplicateID(id: snippet.id) }
            guard seenTriggers.insert(words).inserted else {
                throw SnippetError.duplicateTrigger(id: snippet.id, trigger: snippet.trigger)
            }
        }
    }
}

/// Why snippets could not be saved or loaded.
public enum SnippetError: LocalizedError, Equatable {
    /// The trigger has no words once punctuation is removed, so it could never be spoken.
    case emptyTrigger(id: UUID)
    /// There is no text to insert.
    case emptyExpansion(id: UUID)
    /// Another snippet earlier in the list has a trigger with the same words; `id` is the later one.
    case duplicateTrigger(id: UUID, trigger: String)
    /// Another snippet earlier in the list has the same id, which only a hand-edited file can cause.
    case duplicateID(id: UUID)
    /// The snippets file exists but could not be read, or a damaged file could not be set aside.
    case readFailed(String)
    /// The snippets file could not be written.
    case writeFailed(String)

    /// A sentence the settings screen can show as it is.
    public var errorDescription: String? {
        switch self {
        case .emptyTrigger:
            "A snippet needs a trigger phrase with at least one word."
        case .emptyExpansion:
            "A snippet needs text to insert."
        case .duplicateTrigger(_, let trigger):
            "Another snippet already uses the trigger \u{201C}\(trigger)\u{201D}."
        case .duplicateID:
            "Two snippets in the snippets file share an ID. Give one of them a new ID, or delete both and add them again."
        case .readFailed(let detail):
            "The snippets file could not be read: \(detail)"
        case .writeFailed(let detail):
            "The snippets could not be saved: \(detail)"
        }
    }
}
