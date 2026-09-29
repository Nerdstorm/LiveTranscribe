use std::fmt;

use lt_shared::swift_string::{self as s, CharacterSet};
use lt_shared::{edit_distance, placeholder_token};

use crate::content_words::ContentWords;
use crate::dropped_words::DroppedWords;
use crate::self_correction::SelfCorrection;
use crate::spoken_names::SpokenNames;
use crate::word_alignment::WordAlignment;
use crate::words::{WordSet, normalized_words, starts_with};
use crate::{CleanupOptions, GuardPolicy};

/// How a cleanup generation ended.
#[derive(Clone, Debug, PartialEq)]
pub enum GenerationOutcome {
    Completed(String),
    TimedOut { seconds: f64 },
    Cancelled,
    Failed(String),
}

/// Why cleaned text was rejected in favour of the raw text.
#[derive(Clone, Debug, PartialEq)]
pub enum FallbackReason {
    EmptyOutput,
    ThinkingLeaked,
    Preamble(String),
    WordRatio(f64),
    LowSimilarity(f64),
    /// A correction cue was dropped, but the removed words were not a self-correction.
    InvalidSelfCorrection,
    /// A self-correction was resolved at a level that keeps every spoken word.
    SelfCorrectionNotAllowed,
    /// A placeholder (for a snippet, emoji, address, line break or list marker) was dropped,
    /// repeated or altered.
    PlaceholderChanged,
    /// A run of spoken words was deleted with nothing in its place, and no cue explains it.
    DroppedWords {
        count: usize,
    },
    /// A negation ("not", "never", "can't") was removed.
    LostNegation,
    /// A name the speaker said was dropped or moved, as when the sign-off's name ends up in the
    /// greeting.
    MovedOrDroppedName,
    /// Words that carry what was said ("milk", "Tuesday", "cancel") were deleted with nothing in
    /// their place.
    DroppedContent {
        count: usize,
    },
    TimedOut {
        seconds: f64,
    },
    Cancelled,
    GenerationFailed(String),
}

/// What the Mac app records as the reason, word for word.
impl fmt::Display for FallbackReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyOutput => write!(f, "empty output"),
            Self::ThinkingLeaked => write!(f, "thinking tags in output"),
            Self::Preamble(phrase) => write!(f, "preamble in output ({phrase})"),
            Self::WordRatio(ratio) => write!(f, "word-count ratio {ratio:.2} outside allowed range"),
            Self::LowSimilarity(similarity) => write!(f, "similarity {similarity:.2} below threshold"),
            Self::InvalidSelfCorrection => write!(f, "removed words that were not a self-correction"),
            Self::SelfCorrectionNotAllowed => {
                write!(f, "resolved a self-correction at a level that keeps every word")
            }
            Self::PlaceholderChanged => write!(f, "changed a placeholder"),
            Self::DroppedWords { count } => write!(f, "dropped {count} spoken words"),
            Self::LostNegation => write!(f, "dropped a negation"),
            Self::MovedOrDroppedName => write!(f, "dropped or moved a name"),
            Self::DroppedContent { count: 1 } => write!(f, "dropped a word that carries meaning"),
            Self::DroppedContent { count } => write!(f, "dropped {count} words that carry meaning"),
            Self::TimedOut { seconds } => write!(f, "timed out after {seconds:.1}s"),
            Self::Cancelled => write!(f, "cancelled"),
            Self::GenerationFailed(message) => write!(f, "generation failed: {message}"),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum GuardVerdict {
    Accepted(String),
    Rejected(FallbackReason),
}

/// Decides whether the language model's output can replace the raw transcript.
///
/// The model is asked only to correct, so output that is empty, chatty, much longer or shorter
/// than the level allows, or substantially different from the input is treated as a meaning change
/// and rejected. So is output that damaged a placeholder, since what it stands for could then not
/// be put back.
///
/// Output that drops a correction cue ("sorry", "I mean", …) is checked as a self-correction
/// instead of by the length and similarity limits: dropping a cue is acceptable only as part of
/// removing a spoken self-correction. This catches the model's most harmful mistake, keeping the
/// words the speaker took back and dropping their correction, which is often short enough to pass
/// the length and similarity limits. At a level that keeps every word (Light), dropping a cue is
/// always rejected.
///
/// Output that keeps every cue may not remove a negation and, unless the level allows rewording
/// (High), may not delete a run of spoken words outright. At every level, it must keep each name
/// where the speaker said it and may not delete a word that carries meaning with nothing in its
/// place: rewording replaces words, it does not leave them out.
#[derive(Clone, Debug)]
pub struct OutputGuard {
    policy: GuardPolicy,
    self_correction: SelfCorrection,
    dropped_words: DroppedWords,
    spoken_names: SpokenNames,
    content_words: ContentWords,
}

impl Default for OutputGuard {
    fn default() -> Self {
        Self::new(GuardPolicy::default())
    }
}

impl OutputGuard {
    pub fn new(policy: GuardPolicy) -> Self {
        Self {
            self_correction: SelfCorrection::new(&policy),
            dropped_words: DroppedWords::new(&policy),
            spoken_names: SpokenNames::new(&policy),
            content_words: ContentWords::new(&policy),
            policy,
        }
    }

    pub fn policy(&self) -> &GuardPolicy {
        &self.policy
    }

    /// Whether `cleaned` has fewer correction cues than `raw`, so that [`Self::review`] judges it
    /// as a self-correction removal.
    pub fn drops_correction_cue(&self, raw: &str, cleaned: &str) -> bool {
        self.correction_cue_count(cleaned) < self.correction_cue_count(raw)
    }

    /// Occurrences of the policy's correction cues in `text`.
    pub fn correction_cue_count(&self, text: &str) -> usize {
        self.self_correction.cue_count(&normalized_words(text))
    }

    /// Whether `outcome` may replace `raw`, the text the model was given, under `options`.
    pub fn review(&self, raw: &str, outcome: &GenerationOutcome, options: &CleanupOptions) -> GuardVerdict {
        let output = match outcome {
            GenerationOutcome::Completed(text) => text,
            GenerationOutcome::TimedOut { seconds } => {
                return GuardVerdict::Rejected(FallbackReason::TimedOut { seconds: *seconds });
            }
            GenerationOutcome::Cancelled => return GuardVerdict::Rejected(FallbackReason::Cancelled),
            GenerationOutcome::Failed(message) => {
                return GuardVerdict::Rejected(FallbackReason::GenerationFailed(message.clone()));
            }
        };
        let reject = GuardVerdict::Rejected;

        let cleaned = s::trimming(output, CharacterSet::WhitespacesAndNewlines);
        if cleaned.is_empty() {
            return reject(FallbackReason::EmptyOutput);
        }

        let lowered = s::lowercased(cleaned);
        if s::contains_string(&lowered, "<think") || s::contains_string(&lowered, "</think>") {
            return reject(FallbackReason::ThinkingLeaked);
        }

        let raw_words = normalized_words(raw);
        // An opening the speaker said is not a preamble, however either side punctuates it.
        if let Some(phrase) = self
            .policy
            .preambles
            .iter()
            .find(|phrase| s::has_prefix(&lowered, phrase) && !starts_with(&raw_words, &normalized_words(phrase)))
        {
            return reject(FallbackReason::Preamble(phrase.clone()));
        }

        if self.policy.requires_intact_placeholders && !keeps_placeholders(&options.placeholders, raw, cleaned) {
            return reject(FallbackReason::PlaceholderChanged);
        }

        let cleaned_words = normalized_words(cleaned);
        if self.self_correction.drops_cue(&raw_words, &cleaned_words) {
            if !options.level.resolves_self_corrections() {
                return reject(FallbackReason::SelfCorrectionNotAllowed);
            }
            return if self.self_correction.is_correction(&raw_words, &cleaned_words) {
                GuardVerdict::Accepted(cleaned.to_owned())
            } else {
                reject(FallbackReason::InvalidSelfCorrection)
            };
        }
        let alignment = WordAlignment::new(raw_words, cleaned_words);
        if !options.level.allows_rewording()
            && let Some(count) = self.dropped_words.dropped_run(&alignment)
        {
            return reject(FallbackReason::DroppedWords { count });
        }
        if self.dropped_words.loses_negation(&alignment.raw, &alignment.cleaned) {
            return reject(FallbackReason::LostNegation);
        }
        let placeholder_words = WordSet::normalized(&options.placeholders);
        if self.policy.requires_names_in_place
            && self
                .spoken_names
                .moves_or_drops_name(raw, &alignment, &placeholder_words)
        {
            return reject(FallbackReason::MovedOrDroppedName);
        }
        let dropped_content = self.content_words.dropped_count(&alignment, &placeholder_words);
        if dropped_content > self.policy.max_dropped_content {
            return reject(FallbackReason::DroppedContent { count: dropped_content });
        }

        let raw_word_count = edit_distance::words(raw).len();
        if raw_word_count > 0 {
            let ratio = edit_distance::words(cleaned).len() as f64 / raw_word_count as f64;
            if !self.policy.word_ratio_bounds_for(options.level).contains(&ratio) {
                return reject(FallbackReason::WordRatio(ratio));
            }
        }

        let similarity = edit_distance::normalized_similarity(raw, cleaned);
        if similarity < self.policy.min_similarity {
            return reject(FallbackReason::LowSimilarity(similarity));
        }
        GuardVerdict::Accepted(cleaned.to_owned())
    }
}

/// Every expected placeholder comes back exactly once, and no other token appears or is left
/// half-changed. A placeholder retracted by a self-correction also fails: dropping it would
/// silently lose a snippet the speaker may have wanted.
pub(crate) fn keeps_placeholders(placeholders: &[String], raw: &str, cleaned: &str) -> bool {
    placeholders
        .iter()
        .all(|placeholder| placeholder_token::occurrences(placeholder, cleaned) == 1)
        && placeholder_token::opening_count(cleaned) == placeholder_token::opening_count(raw)
        && placeholder_token::closing_count(cleaned) == placeholder_token::closing_count(raw)
}

#[cfg(test)]
mod tests;
