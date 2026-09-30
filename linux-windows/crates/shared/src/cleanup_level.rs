use std::ops::RangeInclusive;

/// How much the cleanup step may change what was said.
///
/// Dictation applies the user's snippets, vocabulary and spoken commands at every level, before
/// the level is looked at. The levels are in order: each does what the one before it does, and
/// more.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
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
    /// Medium, plus repairs that need the whole dictation: a correction applied to an earlier
    /// sentence ("Tuesday. Sorry, Wednesday."), a garbled correction phrase read as meant, grammar
    /// and misheard words fixed, and emails and lists laid out where the field allows lines. It
    /// does not reword as High does: every change must be one of those repairs
    /// ([`Self::repairs_across_sentences`]). Slower.
    Deep,
}

impl CleanupLevel {
    /// Every level, from the least change to the most, as menus and settings list them.
    pub const ALL: [Self; 5] = [Self::None, Self::Light, Self::Medium, Self::High, Self::Deep];

    /// The name settings and the golden cases store the level under.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Light => "light",
            Self::Medium => "medium",
            Self::High => "high",
            Self::Deep => "deep",
        }
    }

    /// The name menus and settings show.
    pub fn display_name(self) -> &'static str {
        match self {
            Self::None => "None",
            Self::Light => "Light",
            Self::Medium => "Medium",
            Self::High => "High",
            Self::Deep => "Deep",
        }
    }

    /// One line for menus and pickers, as the Mac app says it.
    pub fn summary(self) -> &'static str {
        match self {
            Self::None => "No cleanup, but dictation still applies your snippets, vocabulary and spoken commands",
            Self::Light => "Punctuation, casing and misheard words",
            Self::Medium => "Also removes fillers, resolves self-corrections and lays out lists and letters",
            Self::High => "Also rewords lightly for clarity",
            Self::Deep => {
                "Fixes grammar, misheard words and corrections across sentences, and lays out emails and lists. Slower"
            }
        }
    }

    pub fn uses_language_model(self) -> bool {
        self != Self::None
    }

    /// Fillers ("um", "uh") are removed before the language model sees the text: from Medium up.
    pub fn removes_fillers(self) -> bool {
        self >= Self::Medium
    }

    /// The model is asked to keep only the correction when the speaker corrects themselves: from
    /// Medium up.
    pub fn resolves_self_corrections(self) -> bool {
        self >= Self::Medium
    }

    /// Spoken lists become numbered or bulleted lines, and a letter's greeting and sign-off go on
    /// lines of their own, in multi-line fields: from Medium up.
    pub fn formats_layout(self) -> bool {
        self >= Self::Medium
    }

    /// The model may reword for grammar and clarity, not only correct: High only. Deep fixes
    /// grammar without rewording.
    pub fn allows_rewording(self) -> bool {
        self == Self::High
    }

    /// Deep's own prompt, passes and output check: a correction may reach back into an earlier
    /// sentence and a garbled correction phrase may be read as meant, while everything outside
    /// what was corrected keeps its names, numbers, dates, negations and claims.
    pub fn repairs_across_sentences(self) -> bool {
        self == Self::Deep
    }

    /// Allowed ratio of the cleaned text's word count to the input's. Rewording needs more room;
    /// Light must keep every word. Deep's own check replaces these limits
    /// ([`Self::repairs_across_sentences`]), so its bounds, High's, are not used.
    pub fn word_ratio_bounds(self) -> RangeInclusive<f64> {
        match self {
            Self::None | Self::Light => 0.8..=1.2,
            Self::Medium => 0.5..=1.2,
            Self::High | Self::Deep => 0.4..=1.3,
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
    fn levels_from_medium_up_remove_fillers_resolve_corrections_and_lay_out_text() {
        for level in CleanupLevel::ALL {
            let expected = matches!(level, CleanupLevel::Medium | CleanupLevel::High | CleanupLevel::Deep);
            assert_eq!(level.removes_fillers(), expected);
            assert_eq!(level.resolves_self_corrections(), expected);
            assert_eq!(level.formats_layout(), expected);
        }
        let only = |predicate: fn(CleanupLevel) -> bool| -> Vec<CleanupLevel> {
            CleanupLevel::ALL
                .into_iter()
                .filter(|&level| predicate(level))
                .collect()
        };
        assert_eq!(only(CleanupLevel::allows_rewording), [CleanupLevel::High]);
        assert_eq!(only(CleanupLevel::repairs_across_sentences), [CleanupLevel::Deep]);
    }

    #[test]
    fn levels_are_ordered_from_least_to_most_change() {
        let mut sorted = CleanupLevel::ALL;
        sorted.sort();
        assert_eq!(sorted, CleanupLevel::ALL);
        assert!(CleanupLevel::Deep > CleanupLevel::High && CleanupLevel::Medium < CleanupLevel::High);
    }

    #[test]
    fn names_are_the_mac_apps() {
        assert_eq!(
            CleanupLevel::ALL.map(CleanupLevel::as_str),
            ["none", "light", "medium", "high", "deep"]
        );
        assert_eq!(CleanupLevel::Deep.display_name(), "Deep");
        assert!(CleanupLevel::Deep.summary().ends_with("Slower"));
    }

    #[test]
    fn word_ratio_bounds_widen_with_the_level() {
        assert_eq!(CleanupLevel::Light.word_ratio_bounds(), 0.8..=1.2);
        assert_eq!(CleanupLevel::Medium.word_ratio_bounds(), 0.5..=1.2);
        assert_eq!(CleanupLevel::High.word_ratio_bounds(), 0.4..=1.3);
        assert_eq!(CleanupLevel::Deep.word_ratio_bounds(), 0.4..=1.3);
    }
}
