use lt_shared::edit_distance;

use crate::GuardPolicy;
use crate::words::{WordSet, normalized_words, same};

/// Checks that cleanup output which dropped a correction cue removed only spoken self-corrections.
///
/// A self-correction is the retracted words, a cue and the correction: "fuel efficiency in *cars,
/// sorry,* buses". Cleanup may drop the retracted words and the cue, and the correction stays.
/// Output that drops a cue in any other way lost something the speaker meant: "we need three,
/// sorry, four" cleaned to "we need three" keeps the retracted value, and "sorry I'm late" cleaned
/// to "I'm late" drops an apology. The output guard rejects both.
#[derive(Clone, Debug)]
pub(crate) struct SelfCorrection {
    cues: Vec<Vec<String>>,
    fillers: WordSet,
    max_retracted_words: usize,
    min_respelling_similarity: f64,
}

impl SelfCorrection {
    pub(crate) fn new(policy: &GuardPolicy) -> Self {
        Self {
            cues: policy
                .correction_cues
                .iter()
                .map(|cue| normalized_words(cue))
                .filter(|cue| !cue.is_empty())
                .collect(),
            fillers: WordSet::normalized(&policy.fillers),
            max_retracted_words: policy.max_retracted_words,
            min_respelling_similarity: policy.min_respelling_similarity,
        }
    }

    /// Whether `cleaned` has fewer correction cues than `raw`. Both are normalised words.
    pub(crate) fn drops_cue(&self, raw: &[String], cleaned: &[String]) -> bool {
        self.cue_count(cleaned) < self.cue_count(raw)
    }

    /// Whether `cleaned` can be made from `raw` by keeping words in order and deleting:
    /// - a self-correction: up to `max_retracted_words` retracted words followed by a cue, or by
    ///   several cues in a row ("high street, wait, no, the shopping centre");
    /// - a filler word;
    /// - a word repeated straight after itself.
    ///
    /// A kept word may be respelled ("busses" → "buses"), but a word the speaker said must be
    /// matched where they said it. Otherwise "Tuesday, sorry, Thursday" cleaned to "Tuesday" would
    /// pass as a respelling of "Thursday". Both lists are normalised words.
    pub(crate) fn is_correction(&self, raw: &[String], cleaned: &[String]) -> bool {
        let spoken = WordSet::new(raw);
        let spans = self.correction_spans(raw);
        let (n, m) = (raw.len(), cleaned.len());

        // matches[i * (m + 1) + j]: raw[i...] can become cleaned[j...].
        let at = |i: usize, j: usize| i * (m + 1) + j;
        let mut matches = vec![false; (n + 1) * (m + 1)];
        matches[at(n, m)] = true;
        for i in (0..=n).rev() {
            for j in (0..=m).rev() {
                if i == n && j == m {
                    continue;
                }
                matches[at(i, j)] =
                    (i < n && j < m && matches[at(i + 1, j + 1)] && self.keeps(&raw[i], &cleaned[j], &spoken))
                        || (i < n && matches[at(i + 1, j)] && self.is_droppable(i, raw))
                        || spans[i].iter().any(|&end| matches[at(end, j)]);
            }
        }
        matches[at(0, 0)]
    }

    pub(crate) fn cue_count(&self, words: &[String]) -> usize {
        self.cues.iter().map(|cue| occurrences(cue, words).len()).sum()
    }

    /// For each start index, the end indices (exclusive) of the self-corrections that can be
    /// deleted from there: at least one retracted word, then one or more cues back to back.
    fn correction_spans(&self, words: &[String]) -> Vec<Vec<usize>> {
        let mut cue_ends = vec![Vec::new(); words.len() + 1];
        for cue in &self.cues {
            for cue_start in occurrences(cue, words) {
                cue_ends[cue_start].push(cue_start + cue.len());
            }
        }
        // Where a run of back-to-back cues starting at `start` can end.
        fn run_ends(cue_ends: &[Vec<usize>], start: usize) -> Vec<usize> {
            cue_ends[start]
                .iter()
                .flat_map(|&end| std::iter::once(end).chain(run_ends(cue_ends, end)))
                .collect()
        }

        let mut spans = vec![Vec::new(); words.len() + 1];
        for cue_start in 0..cue_ends.len() {
            if cue_ends[cue_start].is_empty() {
                continue;
            }
            let ends = run_ends(&cue_ends, cue_start);
            for span in &mut spans[cue_start.saturating_sub(self.max_retracted_words)..cue_start] {
                span.extend_from_slice(&ends);
            }
        }
        spans
    }

    fn keeps(&self, raw_word: &str, cleaned_word: &str, spoken: &WordSet) -> bool {
        same(raw_word, cleaned_word)
            || (!spoken.contains(cleaned_word)
                && edit_distance::normalized_similarity(raw_word, cleaned_word) >= self.min_respelling_similarity)
    }

    fn is_droppable(&self, index: usize, words: &[String]) -> bool {
        self.fillers.contains(&words[index]) || (index + 1 < words.len() && same(&words[index + 1], &words[index]))
    }
}

/// Start indices of each occurrence of `cue` in `words`.
fn occurrences(cue: &[String], words: &[String]) -> Vec<usize> {
    if words.len() < cue.len() {
        return Vec::new();
    }
    (0..=words.len() - cue.len())
        .filter(|&start| {
            words[start..start + cue.len()]
                .iter()
                .zip(cue)
                .all(|(word, cue_word)| same(word, cue_word))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use lt_shared::CleanupLevel;

    use crate::{CleanupOptions, FallbackReason, GenerationOutcome, GuardVerdict, OutputGuard};

    fn review(raw: &str, cleaned: &str) -> GuardVerdict {
        OutputGuard::default().review(
            raw,
            &GenerationOutcome::Completed(cleaned.to_owned()),
            &CleanupOptions::new(CleanupLevel::Medium),
        )
    }

    fn accepted(cleaned: &str) -> GuardVerdict {
        GuardVerdict::Accepted(cleaned.to_owned())
    }

    const INVALID: GuardVerdict = GuardVerdict::Rejected(FallbackReason::InvalidSelfCorrection);

    #[test]
    fn keeping_only_the_correction_is_accepted() {
        for (raw, cleaned) in [
            (
                "I want to talk about fuel efficiency in cars sorry busses",
                "I want to talk about fuel efficiency in buses.",
            ),
            (
                "let's meet on tuesday no wait wednesday at ten",
                "Let's meet on Wednesday at ten.",
            ),
            (
                "send it to john i mean jane before friday",
                "Send it to Jane before Friday.",
            ),
            (
                "we need three sorry four more servers for the launch",
                "We need four more servers for the launch.",
            ),
            (
                "it's the login service or rather the auth service that times out",
                "It's the auth service that times out.",
            ),
            (
                "the meeting is at two pm actually make that three pm",
                "The meeting is at three p.m.",
            ),
            (
                "open the settings sorry the preferences window",
                "Open the preferences window.",
            ),
            (
                "we should deploy on monday scratch that let's wait until tuesday",
                "Let's wait until Tuesday.",
            ),
        ] {
            assert_eq!(review(raw, cleaned), accepted(cleaned), "{raw}");
        }
    }

    #[test]
    fn accepts_a_self_correction_alongside_other_fixes() {
        let cleaned = "So we need to fix the login page.";
        assert_eq!(
            review("so um we need to fix the the signup sorry login page", cleaned),
            accepted(cleaned)
        );
    }

    #[test]
    fn keeping_the_retracted_words_instead_of_the_correction_is_rejected() {
        for (raw, cleaned) in [
            (
                "we need three sorry four more servers for the launch",
                "We need three more servers for the launch.",
            ),
            ("let's meet on tuesday sorry thursday", "Let's meet on Tuesday."),
            ("send it to john i mean jane", "Send it to John."),
        ] {
            assert_eq!(review(raw, cleaned), INVALID, "{raw}");
        }
    }

    #[test]
    fn a_cue_with_nothing_before_it_to_retract_must_stay() {
        for (raw, cleaned) in [
            (
                "sorry i'm late the traffic was terrible",
                "I'm late, the traffic was terrible.",
            ),
            (
                "i mean it this time we really need to ship",
                "It this time, we really need to ship.",
            ),
            ("no i don't think that's right", "I don't think that's right."),
            ("actually that works for me", "That works for me."),
        ] {
            assert_eq!(review(raw, cleaned), INVALID, "{raw}");
        }
    }

    #[test]
    fn accepts_a_full_retraction_ending_in_back_to_back_cues() {
        let cleaned = "I returned the jacket to the shop in the shopping centre.";
        let raw = "i returned the jacket to the shop on high street wait no to the shop in the shopping centre";
        assert_eq!(review(raw, cleaned), accepted(cleaned));
    }

    #[test]
    fn back_to_back_cues_still_limit_the_retracted_words() {
        let raw = "i returned the jacket to the big shop on high street wait no to the shop in the centre";
        assert_eq!(review(raw, "I returned the jacket to the shop in the centre."), INVALID);
    }

    #[test]
    fn rejects_retracting_more_than_the_limit() {
        assert_eq!(
            review("I want to talk about fuel efficiency in cars sorry busses", "Buses."),
            INVALID
        );
    }

    #[test]
    fn rejects_adding_words_while_dropping_a_cue() {
        assert_eq!(
            review("send it to john i mean jane", "Send it to Jane in accounts."),
            INVALID
        );
    }

    #[test]
    fn rejects_replacing_the_correction_with_an_unrelated_word() {
        assert_eq!(
            review("fuel efficiency in cars sorry busses", "Fuel efficiency in trains."),
            INVALID
        );
    }

    #[test]
    fn kept_cues_use_the_usual_limits() {
        let cleaned = "Sorry to interrupt, but can I ask a question?";
        assert_eq!(
            review("sorry to interrupt but can i ask a question", cleaned),
            accepted(cleaned)
        );
        // Keeping the cue means no self-correction was resolved, so the deleted words count.
        assert_eq!(
            review("sorry to interrupt but can i ask a question", "Sorry, a question?"),
            GuardVerdict::Rejected(FallbackReason::DroppedWords { count: 6 })
        );
    }

    #[test]
    fn counts_cues_including_multi_word_ones() {
        let guard = OutputGuard::default();
        assert_eq!(
            guard.correction_cue_count("Send it to John, I mean Jane, no wait, Jill."),
            3
        );
        assert_eq!(guard.correction_cue_count("The build is green."), 0);
    }

    #[test]
    fn drops_correction_cue_compares_cue_counts() {
        let guard = OutputGuard::default();
        assert!(guard.drops_correction_cue("cars sorry buses", "Buses."));
        assert!(!guard.drops_correction_cue("sorry I'm late", "Sorry, I'm late."));
    }

    #[test]
    fn invalid_self_correction_is_readable() {
        assert_eq!(
            FallbackReason::InvalidSelfCorrection.to_string(),
            "removed words that were not a self-correction"
        );
    }
}
