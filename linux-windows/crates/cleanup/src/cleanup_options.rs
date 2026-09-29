use lt_shared::CleanupLevel;

/// What one cleanup request may do, beyond the model's fixed instructions.
///
/// Chosen per request rather than per model load, so the level, vocabulary and snippets apply to
/// the next dictation without reloading anything.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CleanupOptions {
    pub level: CleanupLevel,
    /// Canonical spellings the model should use (the user's vocabulary), most relevant first.
    /// The caller caps the list: every term costs prompt tokens and latency.
    pub vocabulary: Vec<String>,
    /// Placeholder tokens (`⟦S1⟧`, …) in the text, standing for snippets, emoji, addresses, line
    /// breaks and list markers, which must come back unchanged, once each, for the output to be
    /// accepted.
    pub placeholders: Vec<String>,
}

impl CleanupOptions {
    /// The options for `level`, with no vocabulary and no placeholders.
    pub fn new(level: CleanupLevel) -> Self {
        Self {
            level,
            vocabulary: Vec::new(),
            placeholders: Vec::new(),
        }
    }
}
