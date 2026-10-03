use std::collections::{BTreeSet, HashSet};
use std::sync::LazyLock;

use lt_shared::edit_distance;
use lt_shared::swift_string::{self as s};

use crate::GuardPolicy;
use crate::word_alignment::WordAlignment;
use crate::words::{WordSet, same};

mod word_lists;

use word_lists::NUMBER_WORDS;
pub use word_lists::STANDARD_FUNCTION_WORDS;

static NUMBER_WORD_SET: LazyLock<WordSet> = LazyLock::new(|| WordSet::new(NUMBER_WORDS));

/// Finds content the cleanup output deleted: the words that carry what was said (things, people,
/// actions, qualities, numbers, times), as opposed to the function words that hold a sentence
/// together ("the", "of", "is", "and") and the intensifiers a rewording may drop ("really",
/// "basically").
///
/// The dropped-words check catches a run of deleted words, but lets one word go at a time and is
/// off at High, where rewording needs room. This check applies at every level and catches a
/// single word: "We need milk, eggs, and bread." cleaned to "We need eggs and bread." loses the
/// milk.
///
/// Rewording may replace, reorder, respell and merge words, so a deleted content word still counts
/// as kept when:
/// - a word put in its place respells it or merges it with a neighbour ("nerd storm" →
///   "Nerdstorm"), or it is a number or unit and digits took its place ("twenty five dollars" →
///   "$25");
/// - the output has it, or a respelling of it, somewhere else: it moved ("tomorrow I'll send it"
///   → "I'll send it tomorrow");
/// - its gap in the alignment puts back at least as many words as it deletes content words: a
///   rewording ("I got the tickets" → "I have the tickets").
///
/// The start of a word broken off and said again in full ("rep" in "the rep report") is not
/// content: the word it starts carries it (`WordFragments`).
///
/// What is left was deleted with nothing in its place.
#[derive(Clone, Debug)]
pub(crate) struct ContentWords {
    function_words: WordSet,
    fillers: WordSet,
    min_respelling_similarity: f64,
}

impl ContentWords {
    pub(crate) fn new(policy: &GuardPolicy) -> Self {
        Self {
            function_words: WordSet::normalized(&policy.function_words),
            fillers: WordSet::normalized(&policy.fillers),
            min_respelling_similarity: policy.min_respelling_similarity,
        }
    }

    /// How many content words in `alignment`'s raw text were deleted with nothing in their place.
    /// Words in `ignored` (the normalised placeholder tokens, which are checked on their own) are
    /// neither content nor a replacement for it, and `fragments`, the raw indices of the starts of
    /// words broken off (`WordFragments`), are not content.
    pub(crate) fn dropped_count(
        &self,
        alignment: &WordAlignment,
        ignored: &WordSet,
        fragments: &HashSet<usize>,
    ) -> usize {
        let (raw, cleaned) = (&alignment.raw, &alignment.cleaned);
        let spoken = WordSet::new(raw);
        // Output words the alignment left unmatched and nothing has claimed yet, in order.
        let mut unclaimed: BTreeSet<usize> = alignment
            .gaps
            .iter()
            .flat_map(|gap| gap.inserted.iter().copied())
            .filter(|&index| !ignored.contains(&cleaned[index]))
            .collect();
        let mut missing: Vec<Vec<usize>> = Vec::with_capacity(alignment.gaps.len());

        for gap in &alignment.gaps {
            let mut unaccounted = Vec::new();
            for index in gap
                .deleted
                .iter()
                .copied()
                .filter(|&index| !fragments.contains(&index) && self.is_content(index, raw, ignored))
            {
                let stands_in = |stand_in: usize| self.stands_in(&raw[index], &cleaned[stand_in], &spoken);
                // Merged words and the parts of a number share one stand-in ("twenty five" → "25").
                let stand_in = gap
                    .inserted
                    .iter()
                    .copied()
                    .find(|&candidate| unclaimed.contains(&candidate) && stands_in(candidate))
                    .or_else(|| gap.inserted.iter().copied().find(|&candidate| stands_in(candidate)));
                match stand_in {
                    Some(stand_in) => {
                        unclaimed.remove(&stand_in);
                    }
                    None => unaccounted.push(index),
                }
            }
            missing.push(unaccounted);
        }

        // A word the output has elsewhere moved. Exact matches claim first, so a respelling cannot
        // take the place of a word that is really there.
        for respelled in [false, true] {
            for indices in &mut missing {
                let mut still_missing = Vec::with_capacity(indices.len());
                for &index in indices.iter() {
                    let word = &raw[index];
                    let moved = unclaimed.iter().copied().find(|&candidate| {
                        same(&cleaned[candidate], word)
                            || (respelled
                                && edit_distance::normalized_similarity(word, &cleaned[candidate])
                                    >= self.min_respelling_similarity)
                    });
                    match moved {
                        Some(moved) => {
                            unclaimed.remove(&moved);
                        }
                        None => still_missing.push(index),
                    }
                }
                *indices = still_missing;
            }
        }

        // What the gap still puts back rewords as many of the rest.
        alignment
            .gaps
            .iter()
            .zip(&missing)
            .map(|(gap, unaccounted)| {
                let replacements = gap.inserted.iter().filter(|index| unclaimed.contains(index)).count();
                unaccounted.len().saturating_sub(replacements)
            })
            .sum()
    }

    /// A word that carries content: not a function word, filler, placeholder or lone letter, and
    /// not a word said twice in a row, which a correction may reduce to once.
    fn is_content(&self, index: usize, words: &[String], ignored: &WordSet) -> bool {
        let word = &words[index];
        if self.function_words.contains(word) || self.fillers.contains(word) || ignored.contains(word) {
            return false;
        }
        if s::character_count(word) <= 1 && !s::characters(word).all(s::is_number) {
            return false;
        }
        !(index > 0 && same(&words[index - 1], word)) && !(index + 1 < words.len() && same(&words[index + 1], word))
    }

    /// Whether `word`, put where `spoken_word` was, stands for it: a respelling, a merge with a
    /// neighbour ("nerd storm" → "nerdstorm"), or digits for a number word ("twenty five" → "25")
    /// and number words for digits. A different word the speaker said elsewhere is never a
    /// respelling: it moved there.
    fn stands_in(&self, spoken_word: &str, word: &str, spoken: &WordSet) -> bool {
        if has_digit(spoken_word) {
            return has_digit(word) || NUMBER_WORD_SET.contains(word);
        }
        if NUMBER_WORD_SET.contains(spoken_word) && has_digit(word) {
            return true;
        }
        if spoken.contains(word) {
            return false;
        }
        edit_distance::normalized_similarity(spoken_word, word) >= self.min_respelling_similarity
            || (s::character_count(word) > s::character_count(spoken_word) && s::contains_string(word, spoken_word))
    }
}

fn has_digit(word: &str) -> bool {
    s::any_character(word, s::is_number)
}

#[cfg(test)]
mod tests {
    use lt_shared::CleanupLevel;

    use super::*;
    use crate::words::normalized_words;
    use crate::{CleanupOptions, FallbackReason, GenerationOutcome, GuardVerdict, OutputGuard};

    fn review(raw: &str, cleaned: &str, level: CleanupLevel, placeholders: &[&str]) -> GuardVerdict {
        let options = CleanupOptions {
            placeholders: placeholders.iter().map(|&token| token.to_owned()).collect(),
            ..CleanupOptions::new(level)
        };
        OutputGuard::default().review(raw, &GenerationOutcome::Completed(cleaned.to_owned()), &options)
    }

    fn dropped(raw: &str, cleaned: &str) -> usize {
        ContentWords::new(&GuardPolicy::default()).dropped_count(
            &WordAlignment::new(normalized_words(raw), normalized_words(cleaned)),
            &WordSet::default(),
            &HashSet::new(),
        )
    }

    #[test]
    fn a_content_word_deleted_outright_is_rejected_at_every_level() {
        for level in [CleanupLevel::Light, CleanupLevel::Medium, CleanupLevel::High] {
            assert_eq!(
                review("we need milk, eggs, and bread.", "We need eggs and bread.", level, &[]),
                GuardVerdict::Rejected(FallbackReason::DroppedContent { count: 1 }),
                "{level:?}"
            );
        }
    }

    #[test]
    fn rewording_at_high_may_not_leave_content_out() {
        for (raw, cleaned, count) in [
            (
                "we could meet at the cafe on the corner or at the office",
                "We could meet at the cafe or the office.",
                1,
            ),
            (
                "i need to cancel the order before friday",
                "I need the order before Friday.",
                1,
            ),
            (
                "Shopping list bullet point milk bullet point eggs bullet point bread.",
                "Shopping list bullet point: milk, eggs, bread.",
                4,
            ),
            ("thanks ⟦S1⟧ see you tomorrow", "Thanks ⟦S1⟧, see you.", 1),
        ] {
            let placeholders: &[&str] = if raw.contains("⟦S1⟧") { &["⟦S1⟧"] } else { &[] };
            assert_eq!(
                review(raw, cleaned, CleanupLevel::High, placeholders),
                GuardVerdict::Rejected(FallbackReason::DroppedContent { count }),
                "{raw}"
            );
        }
    }

    #[test]
    fn rewording_may_replace_reorder_respell_merge_and_rewrite_numbers() {
        for (raw, cleaned) in [
            ("i got the tickets for friday", "I have the tickets for Friday."),
            (
                "tomorrow i will send it to the team",
                "I will send it to the team tomorrow.",
            ),
            ("the meating is at noon", "The meeting is at noon."),
            ("email the nerd storm team", "Email the Nerdstorm team."),
            ("we need twenty five chairs", "We need 25 chairs."),
            ("it costs twenty five dollars", "It costs $25."),
            ("we need 25 chairs", "We need twenty-five chairs."),
            ("honestly the demo was really good", "The demo was good."),
        ] {
            assert_eq!(dropped(raw, cleaned), 0, "{raw}");
        }
    }

    #[test]
    fn high_accepts_rewording_that_keeps_the_content() {
        let raw = "please send the final slides to the whole team tomorrow and i got the room booked for friday";
        let cleaned = "Tomorrow, please send the final slides to the whole team. I have the room booked for Friday.";
        assert_eq!(
            review(raw, cleaned, CleanupLevel::High, &[]),
            GuardVerdict::Accepted(cleaned.to_owned())
        );
        assert_eq!(
            review(
                "send ⟦S1⟧ to the team",
                "Send ⟦S1⟧ to the team.",
                CleanupLevel::High,
                &["⟦S1⟧"]
            ),
            GuardVerdict::Accepted("Send ⟦S1⟧ to the team.".to_owned())
        );
    }

    #[test]
    fn a_word_moved_over_a_cue_is_not_a_correction() {
        assert_eq!(
            review(
                "tell yasmin or rather victor",
                "Tell Victor, or rather.",
                CleanupLevel::Medium,
                &[]
            ),
            GuardVerdict::Rejected(FallbackReason::DroppedContent { count: 1 })
        );
    }

    #[test]
    fn a_word_said_twice_in_a_row_may_be_said_once() {
        assert_eq!(
            review(
                "we need milk milk and bread",
                "We need milk and bread.",
                CleanupLevel::Medium,
                &[]
            ),
            GuardVerdict::Accepted("We need milk and bread.".to_owned())
        );
    }

    #[test]
    fn a_word_moved_into_another_words_place_does_not_replace_it() {
        assert_eq!(
            dropped(
                "hi john thanks for the update cheers sam",
                "Hi Sam, thanks for the update. Cheers."
            ),
            1
        );
    }

    #[test]
    fn fallback_reasons_count_words_in_plain_words() {
        assert_eq!(
            FallbackReason::DroppedContent { count: 1 }.to_string(),
            "dropped a word that carries meaning"
        );
        assert_eq!(
            FallbackReason::DroppedContent { count: 3 }.to_string(),
            "dropped 3 words that carry meaning"
        );
    }
}
