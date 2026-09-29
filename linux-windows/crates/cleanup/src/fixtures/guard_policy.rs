//! guard-policy.json: the output guard's default policy, word lists included, and each level's
//! own word-ratio bounds.

use std::collections::BTreeMap;
use std::ops::RangeInclusive;

use lt_shared::CleanupLevel;
use serde::Deserialize;

use super::{Exact, exact, read_lines};
use crate::GuardPolicy;

fn exact_bounds(bounds: &[String; 2]) -> (Exact, Exact) {
    (exact(&bounds[0]), exact(&bounds[1]))
}

fn bounds_of(range: &RangeInclusive<f64>) -> (Exact, Exact) {
    (Exact(*range.start()), Exact(*range.end()))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DefaultPolicyJson {
    word_ratio_bounds: BTreeMap<String, [String; 2]>,
    level_word_ratio_bounds: BTreeMap<String, [String; 2]>,
    min_similarity: String,
    preambles: Vec<String>,
    correction_cues: Vec<String>,
    fillers: Vec<String>,
    negations: Vec<String>,
    function_words: Vec<String>,
    max_dropped_run: usize,
    max_dropped_content: usize,
    max_retracted_words: usize,
    min_respelling_similarity: String,
    requires_intact_placeholders: bool,
    requires_names_in_place: bool,
}

#[test]
fn the_default_policy_matches_the_mac_apps() {
    let [recorded]: [DefaultPolicyJson; 1] = read_lines("guard-policy.json")
        .try_into()
        .unwrap_or_else(|lines: Vec<_>| panic!("guard-policy.json has one line, not {}", lines.len()));
    let policy = GuardPolicy::default();

    let table: BTreeMap<&str, (Exact, Exact)> = policy
        .word_ratio_bounds
        .iter()
        .map(|(level, range)| (level.as_str(), bounds_of(range)))
        .collect();
    let recorded_table: BTreeMap<&str, (Exact, Exact)> = recorded
        .word_ratio_bounds
        .iter()
        .map(|(level, bounds)| (level.as_str(), exact_bounds(bounds)))
        .collect();
    assert_eq!(table, recorded_table, "word-ratio bounds");
    for level in CleanupLevel::ALL {
        let bounds = recorded
            .level_word_ratio_bounds
            .get(level.as_str())
            .unwrap_or_else(|| panic!("no bounds recorded for {level:?}"));
        assert_eq!(
            bounds_of(&level.word_ratio_bounds()),
            exact_bounds(bounds),
            "{level:?}'s own bounds"
        );
    }
    assert_eq!(
        Exact(policy.min_similarity),
        exact(&recorded.min_similarity),
        "minimum similarity"
    );
    assert_eq!(policy.preambles, recorded.preambles, "preambles");
    assert_eq!(policy.correction_cues, recorded.correction_cues, "correction cues");
    assert_eq!(policy.fillers, recorded.fillers, "fillers");
    assert_eq!(policy.negations, recorded.negations, "negations");
    assert_eq!(policy.function_words, recorded.function_words, "function words");
    assert_eq!(policy.max_dropped_run, recorded.max_dropped_run, "longest dropped run");
    assert_eq!(
        policy.max_dropped_content, recorded.max_dropped_content,
        "most dropped content"
    );
    assert_eq!(
        policy.max_retracted_words, recorded.max_retracted_words,
        "most retracted words"
    );
    assert_eq!(
        Exact(policy.min_respelling_similarity),
        exact(&recorded.min_respelling_similarity),
        "minimum respelling similarity"
    );
    assert_eq!(
        policy.requires_intact_placeholders,
        recorded.requires_intact_placeholders
    );
    assert_eq!(policy.requires_names_in_place, recorded.requires_names_in_place);
}
