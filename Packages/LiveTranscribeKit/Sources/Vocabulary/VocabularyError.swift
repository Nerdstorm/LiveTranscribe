import Foundation

/// Why the vocabulary could not be saved or read. Descriptions are written for the Settings
/// window, which shows them next to the entry the user is editing.
public enum VocabularyError: LocalizedError, Equatable {
    /// An entry has no word or name (only whitespace or punctuation).
    case emptyTerm
    /// The term is already in the vocabulary, possibly in different casing.
    case duplicateTerm(String)
    /// Two entries claim the same spoken phrase, as a variant or as their term, so the replacer
    /// could not tell which spelling was meant.
    case conflictingVariant(variant: String, firstTerm: String, secondTerm: String)
    /// The file exists but could not be read (for example, a permissions problem).
    case readFailed(String)
    /// The file could not be written; the previous vocabulary is still in place.
    case writeFailed(String)
    /// The file is damaged and could not be moved aside, so it is left alone rather than being
    /// overwritten.
    case backupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTerm:
            "Every vocabulary entry needs a word or name."
        case .duplicateTerm(let term):
            "\u{201C}\(term)\u{201D} is already in your vocabulary."
        case .conflictingVariant(let variant, let firstTerm, let secondTerm):
            "\u{201C}\(variant)\u{201D} can\u{2019}t stand for both \u{201C}\(firstTerm)\u{201D} and \u{201C}\(secondTerm)\u{201D}."
        case .readFailed(let detail):
            "Your vocabulary could not be read: \(detail)"
        case .writeFailed(let detail):
            "Your vocabulary could not be saved: \(detail)"
        case .backupFailed(let detail):
            "Your vocabulary file is damaged and could not be set aside: \(detail)"
        }
    }
}
