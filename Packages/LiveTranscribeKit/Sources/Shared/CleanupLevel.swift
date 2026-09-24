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
    /// Wednesday" → "Wednesday") and spoken lists and letters laid out where the text field
    /// allows lines.
    case medium
    /// Medium, plus light rewording for grammar and clarity.
    case high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .light: "Light"
        case .medium: "Medium"
        case .high: "High"
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
        }
    }

    public var usesLanguageModel: Bool { self != .none }

    /// Fillers ("um", "uh") are removed before the language model sees the text.
    public var removesFillers: Bool { self == .medium || self == .high }

    /// The model is asked to keep only the correction when the speaker corrects themselves.
    public var resolvesSelfCorrections: Bool { self == .medium || self == .high }

    /// Spoken lists ("first…, second…", "number one…") become numbered or bulleted lines, and a
    /// letter's greeting and sign-off go on lines of their own, in multi-line fields.
    public var formatsLayout: Bool { self == .medium || self == .high }

    /// The model may reword for grammar and clarity, not only correct.
    public var allowsRewording: Bool { self == .high }

    /// Allowed ratio of the cleaned text's word count to the input's. Rewording needs more room;
    /// Light must keep every word.
    public var wordRatioBounds: ClosedRange<Double> {
        switch self {
        case .none, .light: 0.8...1.2
        case .medium: 0.5...1.2
        case .high: 0.4...1.3
        }
    }
}
