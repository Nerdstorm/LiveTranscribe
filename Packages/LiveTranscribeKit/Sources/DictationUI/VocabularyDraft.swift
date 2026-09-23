import Foundation
import Shared
import Vocabulary

/// The vocabulary entry being added or edited in the sheet: its fields as typed.
///
/// Spoken variants are typed one per line rather than comma-separated, so a variant can hold any
/// text a transcript might, commas included, and a long list stays readable.
struct VocabularyDraft: Identifiable, Equatable {
    /// The entry's id. A new draft gets a fresh one, so saving it adds an entry; an edit keeps the
    /// entry's, so saving it replaces that entry in place.
    let id: UUID
    var term: String
    /// The spoken variants, one per line.
    var variantsText: String
    /// Whether saving adds an entry rather than changing one.
    let isNew: Bool

    /// An empty draft for a new entry.
    init() {
        id = UUID()
        term = ""
        variantsText = ""
        isNew = true
    }

    /// A draft that edits `entry`.
    init(editing entry: VocabularyEntry) {
        id = entry.id
        term = entry.term
        variantsText = entry.spokenVariants.joined(separator: "\n")
        isNew = false
    }

    /// The variants typed, one per line, without surrounding spaces or blank lines.
    var spokenVariants: [String] {
        variantsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The entry saving would store, before the store tidies it (see
    /// ``VocabularyEntry/sanitized()``).
    var entry: VocabularyEntry {
        VocabularyEntry(id: id, term: term.trimmingCharacters(in: .whitespacesAndNewlines), spokenVariants: spokenVariants)
    }
}

/// The sentence under the vocabulary explanation about how many terms cleanup is given.
enum VocabularyPromptLimitNote {
    /// The limit dictation actually uses for a stored `vocabularyPromptLimit`: the stored value
    /// clamped exactly as ``DictationSettings/sanitized()`` clamps it, so the screen never quotes
    /// a number the pipeline doesn't use.
    static func effectiveLimit(stored: Int) -> Int {
        var settings = AppSettings.defaults.dictation
        settings.vocabularyPromptLimit = stored
        return settings.sanitized().vocabularyPromptLimit
    }

    /// The sentence for a stored `vocabularyPromptLimit`.
    static func text(storedLimit: Int) -> String {
        switch effectiveLimit(stored: storedLimit) {
        case 0:
            "Cleanup isn\u{2019}t given any terms, but spoken variants are still replaced."
        case 1:
            "With each dictation, cleanup is given the one most relevant term."
        case let limit:
            "With each dictation, cleanup is given up to \(limit) of the most relevant terms."
        }
    }
}
