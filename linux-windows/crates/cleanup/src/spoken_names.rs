use lt_shared::edit_distance;
use lt_shared::swift_string::{self as s};

use crate::GuardPolicy;
use crate::word_alignment::WordAlignment;
use crate::words::{WordSet, same};

/// Punctuation after which the next word starts a sentence, so its capital says nothing.
const SENTENCE_ENDERS: [&str; 5] = [".", "!", "?", "…", ":"];
const HYPHENS: [&str; 3] = ["-", "\u{2014}", "\u{2013}"];

/// Checks that cleanup kept the names the speaker said where they said them.
///
/// Which name comes where carries meaning that word counts cannot see. Given a whole message, the
/// model has moved the sign-off's name into the greeting: "Hi John thanks for the update … cheers
/// Sam" came back "Hi Sam, thanks for the update. … Cheers." It dropped one word and reordered the
/// rest, so the length, similarity and dropped-word limits all passed.
///
/// A name is a capitalised word that does not start a sentence, other than a function word such
/// as "I" or "OK". Speech-to-text capitalises the people, places, days and products it hears, so
/// these are what the text is about. A name is kept when the alignment matches it, or when the
/// word put in its place respells it ("Jon" → "John") or merges it with a neighbour ("Nerd Storm"
/// → "Nerdstorm"). A name said twice in a row may be said once.
#[derive(Clone, Debug)]
pub(crate) struct SpokenNames {
    function_words: WordSet,
    min_respelling_similarity: f64,
}

impl SpokenNames {
    pub(crate) fn new(policy: &GuardPolicy) -> Self {
        Self {
            function_words: WordSet::normalized(&policy.function_words),
            min_respelling_similarity: policy.min_respelling_similarity,
        }
    }

    /// Whether a name in `raw`, the text the model was given, is missing from its place in
    /// `alignment`. Words in `ignored` (the normalised placeholder tokens) are never names.
    pub(crate) fn moves_or_drops_name(&self, raw: &str, alignment: &WordAlignment, ignored: &WordSet) -> bool {
        let words = &alignment.raw;
        let spoken = WordSet::new(words);
        let mut gap_of = vec![None; words.len()];
        for (gap_index, gap) in alignment.gaps.iter().enumerate() {
            for &index in &gap.deleted {
                gap_of[index] = Some(gap_index);
            }
        }
        self.name_indices(raw, words, ignored).into_iter().any(|index| {
            if alignment.matches[index].is_some() {
                return false;
            }
            let said_twice = (index > 0 && same(&words[index - 1], &words[index]))
                || (index + 1 < words.len() && same(&words[index + 1], &words[index]));
            if said_twice {
                return false;
            }
            let stand_ins = gap_of[index].map_or(&[][..], |gap| alignment.gaps[gap].inserted.as_slice());
            !stand_ins
                .iter()
                .any(|&stand_in| self.respells(&words[index], &alignment.cleaned[stand_in], &spoken))
        })
    }

    /// Indices, among `words` (the normalised words of `raw`), of the names in `raw`. Empty if
    /// `words` are not the words of `raw`, so a mismatch can only let a name through.
    pub(crate) fn name_indices(&self, raw: &str, words: &[String], ignored: &WordSet) -> Vec<usize> {
        let mut names = Vec::new();
        let mut index = 0;
        for line in s::split_where(raw, usize::MAX, true, s::is_newline) {
            let mut starts_sentence = true;
            for token in s::split_whitespace(line) {
                for part in s::split_where(token, usize::MAX, true, |character| s::is_one_of(character, &HYPHENS)) {
                    let word = edit_distance::normalize(part);
                    if !word.is_empty() {
                        if index >= words.len() || !same(&words[index], &word) {
                            return Vec::new();
                        }
                        let capitalised = s::characters(part)
                            .find(|&c| s::is_letter(c))
                            .is_some_and(s::is_uppercase);
                        if capitalised
                            && !starts_sentence
                            && !self.function_words.contains(&word)
                            && !ignored.contains(&word)
                        {
                            names.push(index);
                        }
                        index += 1;
                    }
                    // A placeholder can stand for a line break or a list marker, which starts a
                    // new line.
                    starts_sentence = ignored.contains(&word)
                        || s::characters(part)
                            .rev()
                            .take_while(|&c| !s::is_letter(c) && !s::is_number(c))
                            .any(|c| s::is_one_of(c, &SENTENCE_ENDERS));
                }
            }
        }
        if index == words.len() { names } else { Vec::new() }
    }

    /// Whether `word`, put where `name` was, is `name` respelled or merged with a neighbour. A
    /// different word the speaker said elsewhere is never a respelling: it moved there.
    fn respells(&self, name: &str, word: &str, spoken: &WordSet) -> bool {
        if spoken.contains(word) {
            return false;
        }
        edit_distance::normalized_similarity(name, word) >= self.min_respelling_similarity
            || (s::character_count(word) > s::character_count(name) && s::contains_string(word, name))
    }
}

#[cfg(test)]
mod tests {
    use lt_shared::CleanupLevel;

    use super::*;
    use crate::words::normalized_words;
    use crate::{CleanupOptions, FallbackReason, GenerationOutcome, GuardVerdict, OutputGuard};

    const LETTER: &str = "Hi John thanks for the update I will review it tomorrow cheers Sam.";

    fn review(raw: &str, cleaned: &str, level: CleanupLevel) -> GuardVerdict {
        OutputGuard::default().review(
            raw,
            &GenerationOutcome::Completed(cleaned.to_owned()),
            &CleanupOptions::new(level),
        )
    }

    fn names(raw: &str, ignored: &[&str]) -> Vec<usize> {
        SpokenNames::new(&GuardPolicy::default()).name_indices(raw, &normalized_words(raw), &WordSet::new(ignored))
    }

    const MOVED: GuardVerdict = GuardVerdict::Rejected(FallbackReason::MovedOrDroppedName);

    #[test]
    fn the_sign_offs_name_moved_into_the_greeting_is_rejected_at_every_level() {
        let cleaned = "Hi Sam, thanks for the update. I will review it tomorrow. Cheers.";
        for level in [CleanupLevel::Light, CleanupLevel::Medium, CleanupLevel::High] {
            assert_eq!(review(LETTER, cleaned, level), MOVED, "{level:?}");
        }
    }

    #[test]
    fn names_swapped_moved_or_dropped_are_rejected() {
        for (raw, cleaned) in [
            (
                LETTER,
                "Hi Sam, thanks for the update. I will review it tomorrow. Cheers, John.",
            ),
            (
                LETTER,
                "Hi John and Sam, thanks for the update. I will review it tomorrow. Cheers.",
            ),
            (
                "Send the report to Priya, Daniel and Ana",
                "Send the report to Priya and Ana.",
            ),
            ("Tell Yasmin, or rather, Victor.", "Tell Victor, or rather."),
        ] {
            assert_eq!(review(raw, cleaned, CleanupLevel::Medium), MOVED, "{cleaned}");
        }
    }

    #[test]
    fn names_kept_respelled_merged_or_said_once_instead_of_twice_are_accepted() {
        for (raw, cleaned) in [
            (
                LETTER,
                "Hi John, thanks for the update. I will review it tomorrow. Cheers, Sam.",
            ),
            ("Hi Jon see you on Friday", "Hi John, see you on Friday."),
            ("Email the Nerd Storm team", "Email the Nerdstorm team."),
            ("Hi John John thanks for coming", "Hi John, thanks for coming."),
        ] {
            assert_eq!(
                review(raw, cleaned, CleanupLevel::Medium),
                GuardVerdict::Accepted(cleaned.to_owned()),
                "{raw}"
            );
        }
    }

    #[test]
    fn names_are_capitalised_words_that_do_not_start_a_sentence() {
        assert_eq!(names(LETTER, &[]), [1, 12]);
        assert_eq!(names("Thanks, Sam. Talk soon. OK then, I will call.", &[]), [1]);
        assert_eq!(names("Meet at the Café near Jean-Luc's flat", &[]), [3, 5, 6]);
        assert!(names("Things to do today: Call the bank", &[]).is_empty());
        assert_eq!(names("Hi Sam\nThanks for coming", &[]), [1]);
    }

    #[test]
    fn a_word_after_a_placeholder_is_not_a_name() {
        assert_eq!(names("Hi ⟦S1⟧ Thanks for coming, Sam", &["s1"]), [5]);
    }

    #[test]
    fn words_that_are_not_the_texts_find_no_names() {
        let spoken_names = SpokenNames::new(&GuardPolicy::default());
        assert!(
            spoken_names
                .name_indices("Hi John", &["hi".to_owned()], &WordSet::default())
                .is_empty()
        );
    }

    #[test]
    fn fallback_reason_says_what_happened() {
        assert_eq!(
            FallbackReason::MovedOrDroppedName.to_string(),
            "dropped or moved a name"
        );
    }
}
