use std::collections::HashSet;

use lt_shared::swift_string::{self as s};

use crate::GuardPolicy;
use crate::word_alignment::WordAlignment;
use crate::words::{WordSet, same};

/// Finds meaning the cleanup output lost without dropping a correction cue: a run of spoken words
/// deleted with nothing in their place ("Monday, maybe Tuesday" → "Tuesday"), or a negation
/// removed ("I do not agree" → "I do agree"). Both can pass the length and similarity limits, and
/// both change what the speaker said.
///
/// Words are aligned exactly, so a respelling or a number written as digits ("twenty five" →
/// "25") counts as a replacement, not a deletion. Fillers, a word repeated straight after itself
/// and the start of a word broken off and said again in full (`WordFragments`) may always go.
#[derive(Clone, Debug)]
pub(crate) struct DroppedWords {
    fillers: WordSet,
    negations: WordSet,
    max_dropped_run: usize,
}

impl DroppedWords {
    pub(crate) fn new(policy: &GuardPolicy) -> Self {
        Self {
            fillers: WordSet::normalized(&policy.fillers),
            negations: WordSet::normalized(&policy.negations),
            max_dropped_run: policy.max_dropped_run,
        }
    }

    /// The longest run of spoken words deleted without replacement, beyond the allowed run.
    /// `fragments` are the raw indices of the starts of words broken off (`WordFragments`).
    pub(crate) fn dropped_run(&self, alignment: &WordAlignment, fragments: &HashSet<usize>) -> Option<usize> {
        let longest = alignment
            .gaps
            .iter()
            .filter(|gap| gap.inserted.is_empty())
            .map(|gap| {
                gap.deleted
                    .iter()
                    .filter(|&&index| !fragments.contains(&index) && !self.is_droppable(index, &alignment.raw))
                    .count()
            })
            .max()
            .unwrap_or(0);
        (longest > self.max_dropped_run).then_some(longest)
    }

    /// Whether `cleaned` has fewer negations than `raw`.
    pub(crate) fn loses_negation(&self, raw: &[String], cleaned: &[String]) -> bool {
        self.negation_count(cleaned) < self.negation_count(raw)
    }

    fn negation_count(&self, words: &[String]) -> usize {
        words
            .iter()
            .filter(|word| self.negations.contains(word) || s::has_suffix(word, "n't"))
            .count()
    }

    fn is_droppable(&self, index: usize, words: &[String]) -> bool {
        self.fillers.contains(&words[index])
            || (index + 1 < words.len() && same(&words[index + 1], &words[index]))
            || (index > 0 && same(&words[index - 1], &words[index]))
    }
}

#[cfg(test)]
mod tests {
    use lt_shared::CleanupLevel;

    use super::*;
    use crate::words::normalized_words;
    use crate::{CleanupOptions, FallbackReason, GenerationOutcome, GuardVerdict, OutputGuard};

    fn review(raw: &str, cleaned: &str, level: CleanupLevel) -> GuardVerdict {
        OutputGuard::default().review(
            raw,
            &GenerationOutcome::Completed(cleaned.to_owned()),
            &CleanupOptions::new(level),
        )
    }

    fn alignment(raw: &str, cleaned: &str) -> WordAlignment {
        WordAlignment::new(normalized_words(raw), normalized_words(cleaned))
    }

    #[test]
    fn deleting_a_run_of_spoken_words_without_a_cue_is_rejected() {
        for (raw, cleaned, count) in [
            (
                "Yeah he said someone will come by on Monday, maybe Tuesday at the latest.",
                "Yeah, he said someone will come by on Tuesday at the latest.",
                2,
            ),
            (
                "correction sunday morning i'm away on saturday",
                "Correction, I'm away on Saturday.",
                2,
            ),
            (
                "we could meet at the cafe on the corner or at the office",
                "We could meet at the office.",
                7,
            ),
        ] {
            assert_eq!(
                review(raw, cleaned, CleanupLevel::Medium),
                GuardVerdict::Rejected(FallbackReason::DroppedWords { count }),
                "{raw}"
            );
        }
    }

    #[test]
    fn removing_a_negation_is_rejected() {
        for (raw, cleaned) in [
            ("i do not agree with that plan", "I do agree with that plan."),
            ("i can't make it on friday", "I can make it on Friday."),
            ("we never ship on a friday", "We ship on a Friday."),
        ] {
            assert_eq!(
                review(raw, cleaned, CleanupLevel::Medium),
                GuardVerdict::Rejected(FallbackReason::LostNegation),
                "{raw}"
            );
        }
    }

    #[test]
    fn ordinary_corrections_are_still_accepted() {
        for (raw, cleaned) in [
            ("so the the numbers look good", "So the numbers look good."),
            ("um i think its fine", "I think it's fine."),
            ("i really think we should go", "I think we should go."),
            ("i cannot make it", "I can't make it."),
            (
                "we won't ship it before the review on friday",
                "We will not ship it before the review on Friday.",
            ),
        ] {
            assert_eq!(
                review(raw, cleaned, CleanupLevel::Medium),
                GuardVerdict::Accepted(cleaned.to_owned()),
                "{raw}"
            );
        }
    }

    #[test]
    fn high_may_delete_a_run_of_function_words_but_not_a_negation() {
        let raw = "the demo of the new release for the sales team was really very good";
        let cleaned = "The demo of the new release for the sales team was good.";
        assert_eq!(
            review(raw, cleaned, CleanupLevel::Medium),
            GuardVerdict::Rejected(FallbackReason::DroppedWords { count: 2 })
        );
        assert_eq!(
            review(raw, cleaned, CleanupLevel::High),
            GuardVerdict::Accepted(cleaned.to_owned())
        );
        assert_eq!(
            review(
                "i do not agree with that plan",
                "I do agree with that plan.",
                CleanupLevel::High
            ),
            GuardVerdict::Rejected(FallbackReason::LostNegation)
        );
    }

    #[test]
    fn a_replacement_is_not_a_deletion() {
        let dropped_words = DroppedWords::new(&GuardPolicy::default());
        assert_eq!(
            dropped_words.dropped_run(
                &alignment("we need twenty five chairs", "We need 25 chairs."),
                &HashSet::new()
            ),
            None
        );
        assert_eq!(
            dropped_words.dropped_run(
                &alignment("email the nerd storm team", "Email the Nerdstorm team."),
                &HashSet::new()
            ),
            None
        );
    }

    #[test]
    fn the_start_of_a_word_broken_off_and_said_again_in_full_may_go() {
        for (raw, cleaned) in [
            (
                "She wants few ex expenses paid back.",
                "She wants few expenses paid back.",
            ),
            (
                "We should con consider the budget first.",
                "We should consider the budget first.",
            ),
            (
                "can you send the rep report by friday",
                "Can you send the report by Friday?",
            ),
        ] {
            assert_eq!(
                review(raw, cleaned, CleanupLevel::Medium),
                GuardVerdict::Accepted(cleaned.to_owned()),
                "{raw}"
            );
        }
    }

    #[test]
    fn a_word_that_only_starts_the_next_by_chance_stays() {
        for (raw, cleaned, reason) in [
            (
                "there is not nothing left",
                "There is nothing left.",
                FallbackReason::LostNegation,
            ),
            (
                "bring ten tennis balls",
                "Bring tennis balls.",
                FallbackReason::DroppedContent { count: 1 },
            ),
            // "for" is no fragment of "forty", so the run is two words long.
            (
                "we could stay for forty minutes",
                "We could forty minutes.",
                FallbackReason::DroppedWords { count: 2 },
            ),
            (
                "We met the new rep. Reports are due on Monday.",
                "We met the new. Reports are due on Monday.",
                FallbackReason::DroppedContent { count: 1 },
            ),
            (
                "can you send the rap report by friday",
                "Can you send the report by Friday?",
                FallbackReason::DroppedContent { count: 1 },
            ),
        ] {
            assert_eq!(
                review(raw, cleaned, CleanupLevel::Medium),
                GuardVerdict::Rejected(reason),
                "{raw}"
            );
        }
    }

    #[test]
    fn fallback_reasons_do_not_repeat_what_was_said() {
        assert_eq!(
            FallbackReason::DroppedWords { count: 3 }.to_string(),
            "dropped 3 spoken words"
        );
        assert_eq!(FallbackReason::LostNegation.to_string(), "dropped a negation");
    }
}
