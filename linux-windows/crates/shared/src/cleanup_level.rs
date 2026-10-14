/// How much the cleanup step may change what was said.
///
/// Dictation applies the user's snippets, vocabulary and spoken commands at every level, before
/// the level is looked at. The levels are in order: each does what the one before it does, and
/// more.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum CleanupLevel {
    /// No cleanup: the language model is not used.
    None,
    /// Punctuation, casing, grammar and misheard words fixed, fillers removed, spoken
    /// self-corrections resolved, light rewording for clarity, spoken lists and letters laid out
    /// where the text field allows lines, and spoken numbers written in digits. The default.
    Standard,
    /// Standard, plus repairs that need the whole dictation: a correction applied to an earlier
    /// sentence ("Tuesday. Sorry, Wednesday."), a garbled correction phrase read as meant, grammar
    /// and misheard words fixed from what the rest says, and emails and lists laid out where the
    /// field allows lines. It does not reword as Standard does: every change must be one of those
    /// repairs ([`Self::repairs_across_sentences`]). Slower.
    Deep,
}

impl CleanupLevel {
    /// Every level, from the least change to the most, as menus and settings list them.
    pub const ALL: [Self; 3] = [Self::None, Self::Standard, Self::Deep];

    /// The name settings and the golden cases store the level under.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Standard => "standard",
            Self::Deep => "deep",
        }
    }

    /// The level a stored name names, including the earlier levels Light, Medium and High, which
    /// are Standard now.
    pub fn from_stored(name: &str) -> Option<Self> {
        match name {
            "light" | "medium" | "high" => Some(Self::Standard),
            _ => Self::ALL.into_iter().find(|level| level.as_str() == name),
        }
    }

    /// The name menus and settings show.
    pub fn display_name(self) -> &'static str {
        match self {
            Self::None => "None",
            Self::Standard => "Standard",
            Self::Deep => "Deep",
        }
    }

    /// One line for menus and pickers, as the Mac app says it.
    pub fn summary(self) -> &'static str {
        match self {
            Self::None => "No cleanup, but dictation still applies your snippets, vocabulary and spoken commands",
            Self::Standard => {
                "Fixes punctuation and misheard words, removes fillers, resolves self-corrections, lays out lists and rewords lightly"
            }
            Self::Deep => {
                "Fixes grammar, misheard words and corrections across sentences, and lays out emails and lists. Slower"
            }
        }
    }

    pub fn uses_language_model(self) -> bool {
        self != Self::None
    }

    /// Fillers ("um", "uh") are removed before the language model sees the text: at Standard and
    /// Deep.
    pub fn removes_fillers(self) -> bool {
        self >= Self::Standard
    }

    /// The model is asked to keep only the correction when the speaker corrects themselves: at
    /// Standard and Deep.
    pub fn resolves_self_corrections(self) -> bool {
        self >= Self::Standard
    }

    /// Spoken lists become numbered or bulleted lines, and a letter's greeting and sign-off go on
    /// lines of their own, in multi-line fields: at Standard and Deep.
    pub fn formats_layout(self) -> bool {
        self >= Self::Standard
    }

    /// Spoken numbers are written in digits after cleanup ("twenty one chairs" → "21 chairs"), in
    /// every field: at Standard and Deep, the levels that lay out lists.
    pub fn writes_numbers(self) -> bool {
        self >= Self::Standard
    }

    /// The model may reword for grammar and clarity, not only correct: Standard only. Deep fixes
    /// grammar without rewording.
    pub fn allows_rewording(self) -> bool {
        self == Self::Standard
    }

    /// Deep's own prompt, passes and output check: a correction may reach back into an earlier
    /// sentence and a garbled correction phrase may be read as meant, while everything outside
    /// what was corrected keeps its names, numbers, dates, negations and claims.
    pub fn repairs_across_sentences(self) -> bool {
        self == Self::Deep
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
    fn standard_and_deep_remove_fillers_resolve_corrections_lay_out_text_and_write_numbers() {
        for level in CleanupLevel::ALL {
            let expected = level != CleanupLevel::None;
            assert_eq!(level.removes_fillers(), expected);
            assert_eq!(level.resolves_self_corrections(), expected);
            assert_eq!(level.formats_layout(), expected);
            assert_eq!(level.writes_numbers(), expected);
        }
        let only = |predicate: fn(CleanupLevel) -> bool| -> Vec<CleanupLevel> {
            CleanupLevel::ALL
                .into_iter()
                .filter(|&level| predicate(level))
                .collect()
        };
        assert_eq!(only(CleanupLevel::allows_rewording), [CleanupLevel::Standard]);
        assert_eq!(only(CleanupLevel::repairs_across_sentences), [CleanupLevel::Deep]);
    }

    #[test]
    fn levels_are_ordered_from_least_to_most_change() {
        let mut sorted = CleanupLevel::ALL;
        sorted.sort();
        assert_eq!(sorted, CleanupLevel::ALL);
        assert!(CleanupLevel::Deep > CleanupLevel::Standard && CleanupLevel::None < CleanupLevel::Standard);
    }

    #[test]
    fn names_are_the_mac_apps() {
        assert_eq!(
            CleanupLevel::ALL.map(CleanupLevel::as_str),
            ["none", "standard", "deep"]
        );
        assert_eq!(CleanupLevel::Deep.display_name(), "Deep");
        assert!(CleanupLevel::Deep.summary().ends_with("Slower"));
    }

    /// Light, Medium and High became Standard; a stored name of them reads as Standard.
    #[test]
    fn the_earlier_levels_read_as_standard() {
        for name in ["light", "medium", "high"] {
            assert_eq!(CleanupLevel::from_stored(name), Some(CleanupLevel::Standard), "{name}");
        }
        for level in CleanupLevel::ALL {
            assert_eq!(CleanupLevel::from_stored(level.as_str()), Some(level));
        }
        assert_eq!(CleanupLevel::from_stored("extreme"), None);
        assert_eq!(CleanupLevel::from_stored("Medium"), None);
    }
}
