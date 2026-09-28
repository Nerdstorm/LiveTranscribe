use std::collections::HashMap;
use std::ops::Range;

use lt_shared::swift_string::{self as s};

use crate::word_tokenizer::{self, TextWord};

/// A phrase to look for, as word keys, and the canonical term it stands for.
#[derive(Clone, Debug)]
pub(crate) struct PhrasePattern {
    pub keys: Vec<String>,
    /// Index of the canonical term in the owner's term list.
    pub term_index: usize,
}

/// Where a pattern matched: the words it covers and the part of the text to replace.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Match {
    pub term_index: usize,
    pub word_count: usize,
    /// From the first word's first letter to the last word's last letter, excluding a possessive
    /// "'s", so surrounding punctuation stays where it was.
    pub range: Range<usize>,
}

#[derive(Clone, Debug)]
struct RankedPattern {
    pattern: PhrasePattern,
    order: usize,
}

/// Finds whole-word phrase matches in tokenised text: whole words only, case-insensitive,
/// punctuation around the phrase ignored, and nothing but spaces or hyphens between its words.
/// The last word may carry a possessive "'s".
#[derive(Clone, Debug, Default)]
pub(crate) struct PhraseMatcher {
    /// Patterns indexed by their first word, each list ordered longest first and then in the
    /// order given, so the first match found at a position is the one to prefer.
    patterns_by_first_key: HashMap<String, Vec<RankedPattern>>,
}

impl PhraseMatcher {
    /// Patterns without words (a variant of punctuation only) are ignored.
    pub fn new(patterns: Vec<PhrasePattern>) -> Self {
        let mut by_first_key: HashMap<String, Vec<RankedPattern>> = HashMap::new();
        for (order, pattern) in patterns.into_iter().enumerate() {
            let Some(first) = pattern.keys.first() else { continue };
            by_first_key
                .entry(s::canonical_key(first).into_owned())
                .or_default()
                .push(RankedPattern { pattern, order });
        }
        for ranked in by_first_key.values_mut() {
            ranked.sort_by(precedes);
        }
        Self {
            patterns_by_first_key: by_first_key,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.patterns_by_first_key.is_empty()
    }

    /// The longest match starting at word `start`; among equally long ones, the earliest given.
    pub fn longest_match(&self, start: usize, words: &[TextWord], text: &str) -> Option<Match> {
        self.candidates(&words[start])
            .into_iter()
            .find_map(|candidate| matching(&candidate.pattern, start, words, text))
    }

    fn candidates(&self, word: &TextWord) -> Vec<&RankedPattern> {
        let mut exact: Vec<&RankedPattern> = self
            .patterns_by_first_key
            .get(s::canonical_key(&word.key).as_ref())
            .into_iter()
            .flatten()
            .collect();
        // "GitHub's" can only match a one-word pattern "github"; longer patterns need the
        // possessive on their last word, which is not their first.
        if !s::has_suffix(&word.key, "'s") {
            return exact;
        }
        let singles: Vec<&RankedPattern> = self
            .patterns_by_first_key
            .get(s::canonical_key(s::drop_last(&word.key, 2)).as_ref())
            .into_iter()
            .flatten()
            .filter(|ranked| ranked.pattern.keys.len() == 1)
            .collect();
        if singles.is_empty() {
            return exact;
        }
        exact.extend(singles);
        exact.sort_by(|lhs, rhs| precedes(lhs, rhs));
        exact
    }
}

fn matching(pattern: &PhrasePattern, start: usize, words: &[TextWord], text: &str) -> Option<Match> {
    let count = pattern.keys.len();
    if start + count > words.len() {
        return None;
    }
    let mut possessive = false;
    for (offset, expected) in pattern.keys.iter().enumerate() {
        let word = &words[start + offset];
        if offset > 0 && !word.joins_previous {
            return None;
        }
        if s::canonically_equal(&word.key, expected) {
            continue;
        }
        if offset == count - 1 && word_tokenizer::is_possessive(&word.key, expected) {
            possessive = true;
            continue;
        }
        return None;
    }
    let last = &words[start + count - 1].range;
    // The key ends in "'s", so the word's last two characters are the apostrophe and the s.
    let end = if possessive {
        s::drop_last(&text[..last.end], 2).len()
    } else {
        last.end
    };
    Some(Match {
        term_index: pattern.term_index,
        word_count: count,
        range: words[start].range.start..end,
    })
}

fn precedes(lhs: &RankedPattern, rhs: &RankedPattern) -> std::cmp::Ordering {
    rhs.pattern
        .keys
        .len()
        .cmp(&lhs.pattern.keys.len())
        .then(lhs.order.cmp(&rhs.order))
}
