import Foundation

/// How much the cleanup step may change what was said. Applies to dictation and to the live
/// transcript alike.
public enum CleanupLevel: String, CaseIterable, Codable, Sendable, Identifiable {
    /// No cleanup: the language model is not used. Dictation still applies the user's snippets,
    /// vocabulary and spoken commands, which run before this level is looked at; the live
    /// transcript applies none of them, so it shows what speech-to-text heard.
    case none
    /// Punctuation, casing and misheard words. Every spoken word stays, including fillers and
    /// self-corrections.
    case light
    /// Light, plus fillers removed, spoken self-corrections resolved ("Tuesday, no wait,
    /// Wednesday" → "Wednesday"), spoken lists and letters laid out where the text field
    /// allows lines, and spoken numbers written in digits.
    case medium
    /// Medium, plus light rewording for grammar and clarity.
    case high
    /// Medium, plus repairs that need the whole dictation: a correction applied to an earlier
    /// sentence ("Tuesday. Sorry, Wednesday."), a garbled correction phrase read as meant, grammar
    /// and misheard words fixed, and emails and lists laid out where the field allows lines. It
    /// does not reword as High does: every change must be one of those repairs
    /// (``repairsAcrossSentences``). Slower.
    case deep

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .light: "Light"
        case .medium: "Medium"
        case .high: "High"
        case .deep: "Deep"
        }
    }

    /// One line for pickers and menus, shown for dictation and the live transcript alike. None's
    /// line says that dictation still applies snippets, vocabulary and spoken commands: they run
    /// at every level, but only in dictation, so the live transcript at None shows what
    /// speech-to-text heard.
    public var summary: String {
        switch self {
        case .none: "No cleanup, but dictation still applies your snippets, vocabulary and spoken commands"
        case .light: "Punctuation, casing and misheard words"
        case .medium: "Also removes fillers, resolves self-corrections and lays out lists and letters"
        case .high: "Also rewords lightly for clarity"
        case .deep: "Fixes grammar, misheard words and corrections across sentences, and lays out emails and lists. Slower"
        }
    }

    public var usesLanguageModel: Bool { self != .none }

    /// Fillers ("um", "uh") are removed before the language model sees the text.
    public var removesFillers: Bool { self >= .medium }

    /// The model is asked to keep only the correction when the speaker corrects themselves.
    public var resolvesSelfCorrections: Bool { self >= .medium }

    /// Spoken lists ("first…, second…", "number one…") become numbered or bulleted lines, and a
    /// letter's greeting and sign-off go on lines of their own, in multi-line fields.
    public var formatsLayout: Bool { self >= .medium }

    /// Spoken numbers are written in digits after cleanup ("twenty one chairs" → "21 chairs"), in
    /// every field: from Medium up, the levels that lay out lists.
    public var writesNumbers: Bool { self >= .medium }

    /// The model may reword for grammar and clarity, not only correct: High only. Deep fixes
    /// grammar without rewording.
    public var allowsRewording: Bool { self == .high }

    /// Deep's own prompt, passes and output check: a correction may reach back into an earlier
    /// sentence and a garbled correction phrase may be read as meant, while everything outside what
    /// was corrected keeps its names, numbers, dates, negations and claims.
    public var repairsAcrossSentences: Bool { self == .deep }

    /// Allowed ratio of the cleaned text's word count to the input's. Rewording needs more room;
    /// Light must keep every word. Deep's own check replaces these limits (``repairsAcrossSentences``),
    /// so its bounds, High's, are not used.
    public var wordRatioBounds: ClosedRange<Double> {
        switch self {
        case .none, .light: 0.8...1.2
        case .medium: 0.5...1.2
        case .high, .deep: 0.4...1.3
        }
    }
}

extension CleanupLevel: Comparable {
    /// Declaration order: each level does what the one before it does, and more.
    public static func < (lhs: CleanupLevel, rhs: CleanupLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
