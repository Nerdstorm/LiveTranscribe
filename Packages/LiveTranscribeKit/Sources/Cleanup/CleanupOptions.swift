import Shared

/// What one cleanup request may do, beyond the model's fixed instructions.
///
/// Chosen per request rather than per model load, so the level, vocabulary and snippets apply to
/// the next dictation or Start without reloading anything.
public struct CleanupOptions: Sendable, Equatable {
    public var level: CleanupLevel
    /// Canonical spellings the model should use (the user's vocabulary), most relevant first.
    /// The caller caps the list: every term costs prompt tokens and latency.
    public var vocabulary: [String]
    /// Placeholder tokens (`⟦S1⟧`, …) in the text, standing for snippets, emoji, addresses, line
    /// breaks and list markers, which must come back unchanged, once each, for the output to be
    /// accepted.
    public var placeholders: [String]
    /// The model may break the text across lines: the field takes several, and the speaker didn't
    /// lay the text out. Only Deep lays text out itself (emails, letters and lists); spoken line
    /// breaks and list markers come back as placeholders, which the layout rules lay out.
    public var multiline: Bool
    /// The text is the body of a letter or email, whose greeting and sign-off the app lays out
    /// itself (``LetterFrame``), so Deep writes neither.
    public var letterBody: Bool

    public init(
        level: CleanupLevel,
        vocabulary: [String] = [],
        placeholders: [String] = [],
        multiline: Bool = false,
        letterBody: Bool = false
    ) {
        self.level = level
        self.vocabulary = vocabulary
        self.placeholders = placeholders
        self.multiline = multiline
        self.letterBody = letterBody
    }
}
