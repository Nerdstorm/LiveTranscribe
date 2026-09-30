use std::collections::HashMap;
use std::ops::RangeInclusive;

use lt_shared::CleanupLevel;
use lt_styles::STANDARD_FILLERS;

use crate::content_words::STANDARD_FUNCTION_WORDS;

/// What the output guard allows: its limits, and the words its checks look for.
#[derive(Clone, Debug, PartialEq)]
pub struct GuardPolicy {
    /// Allowed ratio of the output's word count to the input's, per level. A level missing from
    /// the table uses [`CleanupLevel::word_ratio_bounds`].
    pub word_ratio_bounds: HashMap<CleanupLevel, RangeInclusive<f64>>,
    /// Minimum [`lt_shared::edit_distance::normalized_similarity`] between raw and cleaned text.
    pub min_similarity: f64,
    /// Lowercased openings that signal the model is talking about the text, not returning it.
    pub preambles: Vec<String>,
    /// Phrases that introduce a spoken self-correction, as in "cars, sorry, buses".
    pub correction_cues: Vec<String>,
    /// Filler words that may be dropped along with a self-correction.
    pub fillers: Vec<String>,
    /// Words that negate what follows; removing one reverses the meaning.
    pub negations: Vec<String>,
    /// Words that hold a sentence together rather than carry what was said ("the", "of", "is"),
    /// which cleanup may drop or replace. Every other word is content.
    pub function_words: Vec<String>,
    /// Longest run of spoken words that output keeping every cue may delete outright.
    pub max_dropped_run: usize,
    /// Most content words that output keeping every cue may delete with nothing in their place.
    pub max_dropped_content: usize,
    /// Most words a self-correction may retract before its cue.
    pub max_retracted_words: usize,
    /// Minimum similarity for a word that was not spoken to count as a respelling of one that
    /// was, inside a self-correction.
    pub min_respelling_similarity: f64,
    /// Output must keep every placeholder intact. Always on in the app, where a damaged
    /// placeholder cannot be put back; a prompt probe turns it off to see what the model wrote.
    pub requires_intact_placeholders: bool,
    /// Output must keep every name the speaker said where they said it. Always on in the app; a
    /// prompt probe turns it off to see what the model wrote.
    pub requires_names_in_place: bool,
}

impl GuardPolicy {
    /// The bounds for `level`.
    pub fn word_ratio_bounds_for(&self, level: CleanupLevel) -> RangeInclusive<f64> {
        self.word_ratio_bounds
            .get(&level)
            .cloned()
            .unwrap_or_else(|| level.word_ratio_bounds())
    }
}

impl Default for GuardPolicy {
    fn default() -> Self {
        let strings = |values: &[&str]| values.iter().map(|&value| value.to_owned()).collect();
        Self {
            word_ratio_bounds: CleanupLevel::ALL
                .into_iter()
                .map(|level| (level, level.word_ratio_bounds()))
                .collect(),
            min_similarity: 0.6,
            preambles: strings(&[
                "here is",
                "here's",
                "here are",
                "sure,",
                "sure!",
                "sure.",
                "certainly",
                "of course",
                "corrected text",
                "the corrected",
                "corrected:",
                "correction:",
                "output:",
                "text:",
                "context:",
            ]),
            correction_cues: strings(&[
                "sorry",
                "i mean",
                "i meant",
                "no",
                "wait",
                "rather",
                "actually",
                "make that",
                "scratch that",
                "correction",
            ]),
            fillers: strings(&STANDARD_FILLERS),
            negations: strings(&[
                "not", "never", "no", "nothing", "nobody", "none", "neither", "nor", "nowhere", "cannot", "without",
            ]),
            function_words: strings(STANDARD_FUNCTION_WORDS),
            max_dropped_run: 1,
            max_dropped_content: 0,
            max_retracted_words: 6,
            min_respelling_similarity: 0.6,
            requires_intact_placeholders: true,
            requires_names_in_place: true,
        }
    }
}
