//! Deep's repair in guard.jsonl: the words said and written, the rewrites of what was said that
//! Deep's check tries in turn, and whether it accepts what was written. A difference shows where
//! the port first reads the text differently, which a verdict alone would not.

use lt_shared::swift_string::{self as s, CharacterSet};
use serde::Deserialize;

use crate::GuardPolicy;
use crate::self_repair::{SaidWord, SelfRepair, WrittenWord, written_words};
use crate::words::WordSet;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RepairJson {
    said: Vec<SaidWordJson>,
    written: Vec<WrittenWordJson>,
    rewrites: Vec<Vec<SaidWordJson>>,
    accepts: bool,
}

/// A word as said; the fixtures record only the flags that are set.
#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SaidWordJson {
    word: String,
    #[serde(default)]
    ends_sentence: bool,
    #[serde(default)]
    ends_question: bool,
    #[serde(default)]
    is_name: bool,
    #[serde(default)]
    is_capitalised: bool,
    #[serde(default)]
    may_be_name: bool,
    #[serde(default)]
    is_cue: bool,
    #[serde(default)]
    opens_phrase: usize,
    #[serde(default)]
    spare: Vec<String>,
}

impl From<&SaidWord> for SaidWordJson {
    fn from(said: &SaidWord) -> Self {
        Self {
            word: said.word.clone(),
            ends_sentence: said.ends_sentence,
            ends_question: said.ends_question,
            is_name: said.is_name,
            is_capitalised: said.is_capitalised,
            may_be_name: said.may_be_name,
            is_cue: said.is_cue,
            opens_phrase: said.opens_phrase,
            spare: said.spare.clone(),
        }
    }
}

/// A word as written; the fixtures record only the flags that are set.
#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WrittenWordJson {
    word: String,
    #[serde(default)]
    is_capitalised: bool,
    #[serde(default)]
    starts_sentence: bool,
    #[serde(default)]
    starts_list_item: bool,
}

impl From<&WrittenWord> for WrittenWordJson {
    fn from(written: &WrittenWord) -> Self {
        Self {
            word: written.word.clone(),
            is_capitalised: written.is_capitalised,
            starts_sentence: written.starts_sentence,
            starts_list_item: written.starts_list_item,
        }
    }
}

/// How Deep's check reads `output` for `raw`, and where it first differs from `recorded`: the
/// words said and written, then the rewrites in the order they are tried, then the verdict.
pub(super) fn repair_differences(
    raw: &str,
    output: &str,
    placeholders: &[String],
    policy: &GuardPolicy,
    recorded: &RepairJson,
) -> Vec<String> {
    let cleaned = s::trimming(output, CharacterSet::WhitespacesAndNewlines);
    let repair = SelfRepair::new(policy);
    let tokens = WordSet::normalized(placeholders);
    let said = repair.words_said(raw, &tokens);
    let mut differences = Vec::new();
    let said_json: Vec<SaidWordJson> = said.iter().map(SaidWordJson::from).collect();
    if said_json != recorded.said {
        differences.push(format!("said: Mac app {:?}, this port {said_json:?}", recorded.said));
    }
    let written: Vec<WrittenWordJson> = written_words(cleaned).iter().map(WrittenWordJson::from).collect();
    if written != recorded.written {
        differences.push(format!(
            "written: Mac app {:?}, this port {written:?}",
            recorded.written
        ));
    }
    let rewrites: Vec<Vec<SaidWordJson>> = repair
        .rewrites(&said, &tokens)
        .iter()
        .map(|words| words.iter().map(SaidWordJson::from).collect())
        .collect();
    if rewrites != recorded.rewrites {
        let first = rewrites
            .iter()
            .zip(&recorded.rewrites)
            .position(|(made, expected)| made != expected)
            .unwrap_or(rewrites.len().min(recorded.rewrites.len()));
        differences.push(format!(
            "rewrites: the Mac app tried {}, this port {}; first differing, number {}: Mac app {:?}, this port {:?}",
            recorded.rewrites.len(),
            rewrites.len(),
            first + 1,
            recorded.rewrites.get(first),
            rewrites.get(first)
        ));
    }
    let accepts = repair.accepts(raw, cleaned, &tokens);
    if accepts != recorded.accepts {
        differences.push(format!("accepts: Mac app {}, this port {accepts}", recorded.accepts));
    }
    differences
}
