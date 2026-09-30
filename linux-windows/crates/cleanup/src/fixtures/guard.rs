//! guard.jsonl: the output guard's verdict at every level, in a field that takes one line, and
//! Deep's in one that takes several too, with the parts it judges by, Deep's repair included, on
//! each raw text and what the model made of it.

mod repair;

use std::collections::{BTreeMap, BTreeSet};

use lt_shared::swift_string::{self as s, CharacterSet};
use lt_shared::{CleanupLevel, edit_distance};
use serde::Deserialize;

use super::{Exact, assert_no_differences, exact, level, number, read_lines};
use crate::content_words::ContentWords;
use crate::dropped_words::DroppedWords;
use crate::output_guard::keeps_placeholders;
use crate::self_correction::SelfCorrection;
use crate::spoken_names::SpokenNames;
use crate::word_alignment::WordAlignment;
use crate::words::{WordSet, normalized_words};
use crate::{CleanupOptions, FallbackReason, GenerationOutcome, GuardPolicy, GuardVerdict, OutputGuard};
use repair::{RepairJson, repair_differences};

/// Every fallback reason the guard gives, as the fixtures name them; the guard's cases must cover
/// them all. (Unfinished thinking is the executor's, and its fixture covers it.)
const REASONS: [&str; 17] = [
    "emptyOutput",
    "thinkingLeaked",
    "preamble",
    "wordRatio",
    "lowSimilarity",
    "invalidSelfCorrection",
    "selfCorrectionNotAllowed",
    "placeholderChanged",
    "droppedWords",
    "lostNegation",
    "movedOrDroppedName",
    "droppedContent",
    "timedOut",
    "cancelled",
    "generationFailed",
    "invalidRepair",
    "layoutNotAllowed",
];

// MARK: - Verdicts

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct GuardLine {
    raw: String,
    outcome: OutcomeJson,
    placeholders: Vec<String>,
    policy: Option<PolicyJson>,
    verdicts: BTreeMap<String, VerdictJson>,
    /// Deep's verdict in a field that takes several lines; the other levels don't read the field.
    deep_multiline: VerdictJson,
    parts: Option<PartsJson>,
    repair: Option<RepairJson>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OutcomeJson {
    completed: Option<String>,
    timed_out: Option<String>,
    #[serde(default)]
    cancelled: bool,
    failed: Option<String>,
}

impl OutcomeJson {
    fn outcome(&self) -> GenerationOutcome {
        match self {
            Self {
                completed: Some(text), ..
            } => GenerationOutcome::Completed(text.clone()),
            Self {
                timed_out: Some(seconds),
                ..
            } => GenerationOutcome::TimedOut {
                seconds: number(seconds),
            },
            Self { cancelled: true, .. } => GenerationOutcome::Cancelled,
            Self {
                failed: Some(message), ..
            } => GenerationOutcome::Failed(message.clone()),
            _ => panic!("no outcome in {self:?}"),
        }
    }
}

/// Changes to the default policy. A word-ratio table replaces the default one.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PolicyJson {
    word_ratio_bounds: Option<BTreeMap<String, [String; 2]>>,
    min_similarity: Option<String>,
    preambles: Option<Vec<String>>,
    correction_cues: Option<Vec<String>>,
    fillers: Option<Vec<String>>,
    negations: Option<Vec<String>>,
    function_words: Option<Vec<String>>,
    max_dropped_run: Option<usize>,
    max_dropped_content: Option<usize>,
    max_retracted_words: Option<usize>,
    min_respelling_similarity: Option<String>,
    requires_intact_placeholders: Option<bool>,
    requires_names_in_place: Option<bool>,
}

impl PolicyJson {
    fn applied(&self) -> GuardPolicy {
        let mut policy = GuardPolicy::default();
        if let Some(table) = &self.word_ratio_bounds {
            policy.word_ratio_bounds = table
                .iter()
                .map(|(name, [lower, upper])| (level(name), number(lower)..=number(upper)))
                .collect();
        }
        let replace = |target: &mut Vec<String>, value: &Option<Vec<String>>| {
            if let Some(value) = value {
                target.clone_from(value);
            }
        };
        replace(&mut policy.preambles, &self.preambles);
        replace(&mut policy.correction_cues, &self.correction_cues);
        replace(&mut policy.fillers, &self.fillers);
        replace(&mut policy.negations, &self.negations);
        replace(&mut policy.function_words, &self.function_words);
        if let Some(value) = &self.min_similarity {
            policy.min_similarity = number(value);
        }
        if let Some(value) = &self.min_respelling_similarity {
            policy.min_respelling_similarity = number(value);
        }
        policy.max_dropped_run = self.max_dropped_run.unwrap_or(policy.max_dropped_run);
        policy.max_dropped_content = self.max_dropped_content.unwrap_or(policy.max_dropped_content);
        policy.max_retracted_words = self.max_retracted_words.unwrap_or(policy.max_retracted_words);
        policy.requires_intact_placeholders = self
            .requires_intact_placeholders
            .unwrap_or(policy.requires_intact_placeholders);
        policy.requires_names_in_place = self.requires_names_in_place.unwrap_or(policy.requires_names_in_place);
        policy
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct VerdictJson {
    accepted: Option<String>,
    rejected: Option<ReasonJson>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ReasonJson {
    reason: String,
    text: Option<String>,
    count: Option<usize>,
    number: Option<String>,
    description: String,
}

/// A verdict in the form the fixtures record it, with numbers compared exactly.
#[derive(Debug, PartialEq, Eq)]
enum Judged {
    Accepted(String),
    Rejected {
        reason: String,
        text: Option<String>,
        count: Option<usize>,
        number: Option<Exact>,
        description: String,
    },
}

impl VerdictJson {
    fn judged(&self) -> Judged {
        match self {
            Self {
                accepted: Some(text),
                rejected: None,
            } => Judged::Accepted(text.clone()),
            Self {
                accepted: None,
                rejected: Some(reason),
            } => Judged::Rejected {
                reason: reason.reason.clone(),
                text: reason.text.clone(),
                count: reason.count,
                number: reason.number.as_deref().map(exact),
                description: reason.description.clone(),
            },
            _ => panic!("a verdict is accepted or rejected: {self:?}"),
        }
    }
}

fn judged(verdict: &GuardVerdict) -> Judged {
    let reason = match verdict {
        GuardVerdict::Accepted(text) => return Judged::Accepted(text.clone()),
        GuardVerdict::Rejected(reason) => reason,
    };
    let (name, text, count, number) = match reason {
        FallbackReason::EmptyOutput => ("emptyOutput", None, None, None),
        FallbackReason::ThinkingLeaked => ("thinkingLeaked", None, None, None),
        FallbackReason::Preamble(phrase) => ("preamble", Some(phrase.clone()), None, None),
        FallbackReason::WordRatio(ratio) => ("wordRatio", None, None, Some(Exact(*ratio))),
        FallbackReason::LowSimilarity(similarity) => ("lowSimilarity", None, None, Some(Exact(*similarity))),
        FallbackReason::InvalidSelfCorrection => ("invalidSelfCorrection", None, None, None),
        FallbackReason::SelfCorrectionNotAllowed => ("selfCorrectionNotAllowed", None, None, None),
        FallbackReason::PlaceholderChanged => ("placeholderChanged", None, None, None),
        FallbackReason::DroppedWords { count } => ("droppedWords", None, Some(*count), None),
        FallbackReason::LostNegation => ("lostNegation", None, None, None),
        FallbackReason::MovedOrDroppedName => ("movedOrDroppedName", None, None, None),
        FallbackReason::DroppedContent { count } => ("droppedContent", None, Some(*count), None),
        FallbackReason::TimedOut { seconds } => ("timedOut", None, None, Some(Exact(*seconds))),
        FallbackReason::Cancelled => ("cancelled", None, None, None),
        FallbackReason::GenerationFailed(message) => ("generationFailed", Some(message.clone()), None, None),
        FallbackReason::ThinkingUnfinished => ("thinkingUnfinished", None, None, None),
        FallbackReason::InvalidRepair => ("invalidRepair", None, None, None),
        FallbackReason::LayoutNotAllowed => ("layoutNotAllowed", None, None, None),
    };
    Judged::Rejected {
        reason: name.to_owned(),
        text,
        count,
        number,
        description: reason.to_string(),
    }
}

// MARK: - Parts

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PartsJson {
    raw_words: Vec<String>,
    cleaned_words: Vec<String>,
    raw_cues: usize,
    cleaned_cues: usize,
    is_correction: bool,
    keeps_placeholders: bool,
    matches: Vec<Option<usize>>,
    gaps: Vec<GapJson>,
    dropped_run: Option<usize>,
    loses_negation: bool,
    names: Vec<usize>,
    moves_or_drops_name: bool,
    dropped_content: usize,
    similarity: String,
    word_ratio: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct GapJson {
    deleted: Vec<usize>,
    inserted: Vec<usize>,
}

/// What the guard judges a completed generation by.
#[derive(Debug)]
struct Parts {
    raw_words: Vec<String>,
    cleaned_words: Vec<String>,
    raw_cues: usize,
    cleaned_cues: usize,
    is_correction: bool,
    keeps_placeholders: bool,
    matches: Vec<Option<usize>>,
    /// Deleted and inserted indices.
    gaps: Vec<(Vec<usize>, Vec<usize>)>,
    dropped_run: Option<usize>,
    loses_negation: bool,
    names: Vec<usize>,
    moves_or_drops_name: bool,
    dropped_content: usize,
    similarity: Exact,
    word_ratio: Option<Exact>,
}

impl From<&PartsJson> for Parts {
    fn from(recorded: &PartsJson) -> Self {
        Self {
            raw_words: recorded.raw_words.clone(),
            cleaned_words: recorded.cleaned_words.clone(),
            raw_cues: recorded.raw_cues,
            cleaned_cues: recorded.cleaned_cues,
            is_correction: recorded.is_correction,
            keeps_placeholders: recorded.keeps_placeholders,
            matches: recorded.matches.clone(),
            gaps: recorded
                .gaps
                .iter()
                .map(|gap| (gap.deleted.clone(), gap.inserted.clone()))
                .collect(),
            dropped_run: recorded.dropped_run,
            loses_negation: recorded.loses_negation,
            names: recorded.names.clone(),
            moves_or_drops_name: recorded.moves_or_drops_name,
            dropped_content: recorded.dropped_content,
            similarity: exact(&recorded.similarity),
            word_ratio: recorded.word_ratio.as_deref().map(exact),
        }
    }
}

impl Parts {
    /// The parts that differ from `expected`'s, each with both values.
    fn differences(&self, expected: &Self) -> Vec<String> {
        let mut differences = Vec::new();
        macro_rules! compare {
            ($($field:ident),*) => {$(
                if self.$field != expected.$field {
                    differences.push(format!(
                        "{}: Mac app {:?}, this port {:?}",
                        stringify!($field),
                        expected.$field,
                        self.$field
                    ));
                }
            )*};
        }
        compare!(
            raw_words,
            cleaned_words,
            raw_cues,
            cleaned_cues,
            is_correction,
            keeps_placeholders,
            matches,
            gaps,
            dropped_run,
            loses_negation,
            names,
            moves_or_drops_name,
            dropped_content,
            similarity,
            word_ratio
        );
        differences
    }
}

// MARK: - The fixture

/// The parts of `output` for `raw`, as the guard computes them under `policy`.
fn parts(raw: &str, output: &str, placeholders: &[String], policy: &GuardPolicy) -> Parts {
    let cleaned = s::trimming(output, CharacterSet::WhitespacesAndNewlines);
    let raw_words = normalized_words(raw);
    let cleaned_words = normalized_words(cleaned);
    let self_correction = SelfCorrection::new(policy);
    let dropped_words = DroppedWords::new(policy);
    let spoken_names = SpokenNames::new(policy);
    let alignment = WordAlignment::new(raw_words.clone(), cleaned_words.clone());
    let ignored = WordSet::normalized(placeholders);
    let raw_word_count = edit_distance::words(raw).len();
    Parts {
        raw_cues: self_correction.cue_count(&raw_words),
        cleaned_cues: self_correction.cue_count(&cleaned_words),
        is_correction: self_correction.is_correction(&raw_words, &cleaned_words),
        keeps_placeholders: keeps_placeholders(placeholders, raw, cleaned),
        matches: alignment.matches.clone(),
        gaps: alignment
            .gaps
            .iter()
            .map(|gap| (gap.deleted.clone(), gap.inserted.clone()))
            .collect(),
        dropped_run: dropped_words.dropped_run(&alignment),
        loses_negation: dropped_words.loses_negation(&raw_words, &cleaned_words),
        names: spoken_names.name_indices(raw, &raw_words, &ignored),
        moves_or_drops_name: spoken_names.moves_or_drops_name(raw, &alignment, &ignored),
        dropped_content: ContentWords::new(policy).dropped_count(&alignment, &ignored),
        similarity: Exact(edit_distance::normalized_similarity(raw, cleaned)),
        word_ratio: (raw_word_count > 0)
            .then(|| Exact(edit_distance::words(cleaned).len() as f64 / raw_word_count as f64)),
        raw_words,
        cleaned_words,
    }
}

#[test]
fn the_guard_verdicts_match_the_mac_apps() {
    let lines: Vec<GuardLine> = read_lines("guard.jsonl");
    assert!(lines.len() > 300, "guard.jsonl was read");

    let mut differences = Vec::new();
    let mut reasons = BTreeSet::new();
    for (number, line) in lines.iter().enumerate() {
        let policy = line
            .policy
            .as_ref()
            .map_or_else(GuardPolicy::default, PolicyJson::applied);
        let output_guard = OutputGuard::new(policy.clone());
        let outcome = line.outcome.outcome();
        let case = format!(
            "line {}: {:?} → {:?}, placeholders {:?}, policy {:?}",
            number + 1,
            line.raw,
            outcome,
            line.placeholders,
            line.policy
        );
        for level in CleanupLevel::ALL {
            let one_line = line
                .verdicts
                .get(level.as_str())
                .unwrap_or_else(|| panic!("{case}: no verdict at {level:?}"));
            let multiline = if level.repairs_across_sentences() {
                &line.deep_multiline
            } else {
                one_line
            };
            for (in_multiline_field, expected) in [(false, one_line), (true, multiline)] {
                let expected = expected.judged();
                if let Judged::Rejected { reason, .. } = &expected {
                    reasons.insert(reason.clone());
                }
                let options = CleanupOptions {
                    level,
                    vocabulary: Vec::new(),
                    placeholders: line.placeholders.clone(),
                    multiline: in_multiline_field,
                };
                let actual = judged(&output_guard.review(&line.raw, &outcome, &options));
                if actual != expected {
                    differences.push(format!(
                        "{case}\n  at {level:?} (multiline: {in_multiline_field}), Mac app: {expected:?}\n  this port: {actual:?}"
                    ));
                }
            }
        }
        match (&line.parts, &outcome) {
            (Some(recorded), GenerationOutcome::Completed(output)) => {
                let expected = Parts::from(recorded);
                let actual = parts(&line.raw, output, &line.placeholders, &policy);
                let differing = actual.differences(&expected);
                if !differing.is_empty() {
                    differences.push(format!("{case}\n  {}", differing.join("\n  ")));
                }
            }
            (None, GenerationOutcome::Completed(_)) => panic!("{case}: no parts for a completed generation"),
            _ => {}
        }
        match (&line.repair, &outcome) {
            (Some(recorded), GenerationOutcome::Completed(output)) => {
                let differing = repair_differences(&line.raw, output, &line.placeholders, &policy, recorded);
                if !differing.is_empty() {
                    differences.push(format!("{case}\n  Deep's repair, {}", differing.join("\n  ")));
                }
            }
            (None, GenerationOutcome::Completed(_)) => {
                panic!("{case}: no repair for a completed generation")
            }
            (Some(_), _) => panic!("{case}: a repair for a generation that didn't complete"),
            _ => {}
        }
    }
    assert_no_differences("guard.jsonl", &differences);
    let missing: Vec<&str> = REASONS
        .into_iter()
        .filter(|reason| !reasons.contains(*reason))
        .collect();
    assert!(
        missing.is_empty(),
        "guard.jsonl covers every fallback reason; missing {missing:?}"
    );
}
