import Foundation
import Snippets

/// The snippet being added or edited in the sheet: its fields as typed, not yet validated.
struct SnippetDraft: Identifiable, Equatable {
    /// The snippet's id. A new draft gets a fresh one, so saving it adds a snippet; an edit keeps
    /// the snippet's, so saving it replaces that snippet in place.
    let id: UUID
    var trigger: String
    var expansion: String
    /// Whether saving adds a snippet rather than changing one.
    let isNew: Bool

    /// An empty draft for a new snippet.
    init() {
        id = UUID()
        trigger = ""
        expansion = ""
        isNew = true
    }

    /// A draft that edits `snippet`.
    init(editing snippet: Snippet) {
        id = snippet.id
        trigger = snippet.trigger
        expansion = snippet.expansion
        isNew = false
    }

    /// The snippet saving would store: the trigger without surrounding spaces, and the expansion
    /// exactly as typed, since spaces and line breaks in it are inserted too.
    var snippet: Snippet {
        Snippet(id: id, trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines), expansion: expansion)
    }
}

/// A one-line preview of an expansion for the snippet list.
enum SnippetExpansionPreview {
    /// Stands for a line break, so a multi-line expansion still reads as one line.
    static let lineBreak = "\u{23CE}"
    /// Shown for an expansion that is only spaces or tabs, which would otherwise look empty.
    static let blank = "Spaces only"
    /// The longest preview built; the row truncates it further to fit. A layout limit only.
    static let maximumLength = 120

    /// `expansion` on one line: each line break shown as ``lineBreak``, runs of spaces and tabs
    /// collapsed to one space, and anything past ``maximumLength`` cut off with an ellipsis.
    static func text(for expansion: String) -> String {
        let lines = expansion.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let joined = lines
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: " \(lineBreak) ")
        let preview = joined.split(separator: " ").joined(separator: " ")
        guard !preview.isEmpty else { return blank }
        guard preview.count > maximumLength else { return preview }
        return String(preview.prefix(maximumLength)) + "\u{2026}"
    }
}
