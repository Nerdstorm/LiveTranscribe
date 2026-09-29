use std::ops::RangeInclusive;

/// How much the cleanup step may change what was said.
///
/// Dictation applies the user's snippets, vocabulary and spoken commands at every level, before
/// the level is looked at.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CleanupLevel {
    /// No cleanup: the language model is not used.
    None,
    /// Punctuation, casing and misheard words. Every spoken word stays, including fillers and
    /// self-corrections.
    Light,
    /// Light, plus fillers removed, spoken self-corrections resolved and spoken lists and letters
    /// laid out where the text field allows lines.
    Medium,
    /// Medium, plus light rewording for grammar and clarity.
    High,
}

impl CleanupLevel {
    pub const ALL: [Self; 4] = [Self::None, Self::Light, Self::Medium, Self::High];

    /// The name settings and the golden cases store the level under.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Light => "light",
            Self::Medium => "medium",
            Self::High => "high",
        }
    }

    /// The name menus and settings show.
    pub fn display_name(self) -> &'static str {
        match self {
            Self::None => "None",
            Self::Light => "Light",
            Self::Medium => "Medium",
            Self::High => "High",
        }
    }

    /// One line for menus and pickers, as the Mac app says it.
    pub fn summary(self) -> &'static str {
        match self {
            Self::None => "No cleanup, but dictation still applies your snippets, vocabulary and spoken commands",
            Self::Light => "Punctuation, casing and misheard words",
            Self::Medium => "Also removes fillers, resolves self-corrections and lays out lists and letters",
            Self::High => "Also rewords lightly for clarity",
        }
    }

    pub fn uses_language_model(self) -> bool {
        self != Self::None
    }

    /// Fillers ("um", "uh") are removed before the language model sees the text.
    pub fn removes_fillers(self) -> bool {
        matches!(self, Self::Medium | Self::High)
    }

    /// The model is asked to keep only the correction when the speaker corrects themselves.
    pub fn resolves_self_corrections(self) -> bool {
        matches!(self, Self::Medium | Self::High)
    }

    /// Spoken lists become numbered or bulleted lines, and a letter's greeting and sign-off go on
    /// lines of their own, in multi-line fields.
    pub fn formats_layout(self) -> bool {
        matches!(self, Self::Medium | Self::High)
    }

    /// The model may reword for grammar and clarity, not only correct.
    pub fn allows_rewording(self) -> bool {
        self == Self::High
    }

    /// Allowed ratio of the cleaned text's word count to the input's. Rewording needs more room;
    /// Light must keep every word.
    pub fn word_ratio_bounds(self) -> RangeInclusive<f64> {
        match self {
            Self::None | Self::Light => 0.8..=1.2,
            Self::Medium => 0.5..=1.2,
            Self::High => 0.4..=1.3,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_none_skips_the_language_model() {
        let skipping: Vec<_> = CleanupLevel::ALL
            .into_iter()
            .filter(|level| !level.uses_language_model())
            .collect();
        assert_eq!(skipping, [CleanupLevel::None]);
    }

    #[test]
    fn medium_and_high_remove_fillers_resolve_corrections_and_lay_out_text() {
        for level in CleanupLevel::ALL {
            let expected = matches!(level, CleanupLevel::Medium | CleanupLevel::High);
            assert_eq!(level.removes_fillers(), expected);
            assert_eq!(level.resolves_self_corrections(), expected);
            assert_eq!(level.formats_layout(), expected);
        }
        let rewording: Vec<_> = CleanupLevel::ALL
            .into_iter()
            .filter(|level| level.allows_rewording())
            .collect();
        assert_eq!(rewording, [CleanupLevel::High]);
    }

    #[test]
    fn word_ratio_bounds_widen_with_the_level() {
        assert_eq!(CleanupLevel::Light.word_ratio_bounds(), 0.8..=1.2);
        assert_eq!(CleanupLevel::Medium.word_ratio_bounds(), 0.5..=1.2);
        assert_eq!(CleanupLevel::High.word_ratio_bounds(), 0.4..=1.3);
    }
}
