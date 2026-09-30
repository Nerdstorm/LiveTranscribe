//! The self-corrections Deep's check lets a repair resolve, as the Mac app's
//! `SelfRepair.Corrections` (Cleanup/SelfRepairCorrections.swift).
//!
//! A correction replaces the words it corrects with its phrase, and the cue goes. Deep reads two
//! kinds:
//! - Medium's: up to [`GuardPolicy::max_retracted_words`](crate::GuardPolicy) words just before a
//!   run of cues, taken out with the cues ("we need three, sorry, four"), in the cue's sentence;
//!   or, after a "scratch that" that opens a sentence, at the end of the one before ("I'll call
//!   the plumber tomorrow. Scratch that, I'll fix the tap myself.");
//! - one whose phrase goes back in place of what it corrects, with the words in between kept: in
//!   an earlier sentence ("The demo is on Tuesday at noon. Sorry, Wednesday." → "The demo is on
//!   Wednesday at noon.") or earlier in the same one ("three servers at noon, sorry, four" → "four
//!   servers at noon"). Its corrected words must start and end with a word the phrase is about
//!   ([`SelfRepair::relates`]), and its phrase must be short.
//!
//! Either way, the phrase must take back every fact in the corrected words with one of the same
//! kind ([`SelfRepair::takes_back_facts`]), so a correction can't also drop "not" or "at noon",
//! except after "scratch that", which takes back what was said whole; and inside the phrase, a
//! repair may re-use only the words it corrects ("the Monday after" → "the Monday after next").

use std::collections::{BTreeMap, HashMap};
use std::ops::Range;

use super::{CORRECTION_PHRASE_WORDS, SaidWord, SelfRepair, occurrences, phrase_length};
use crate::word_forms;
use crate::words::{WordSet, same};

/// How many corrections whose phrase goes back one dictation may have resolved.
const MAX_APPLIED: usize = 2;
/// How many ways of applying them are checked, which bounds the search.
const MAX_REWRITES: usize = 256;
/// Cue words that as often start a new point as correct the last one.
const WEAK_CUES: [&str; 4] = ["no", "wait", "actually", "rather"];
/// Words that join a number said in parts ("half past two", "ten to five", "two point five").
const NUMBER_JOINERS: [&str; 4] = ["past", "to", "and", "point"];

/// Medium's corrections in the words said, by said index.
pub(super) struct Spans {
    /// For each start, the ends of the corrected words and cues that may be taken out from there.
    pub(super) ends: Vec<Vec<usize>>,
    /// For each phrase that follows, by where it starts, the words it may correct.
    pub(super) corrected: Vec<WordSet>,
    /// Of those, the ones its repair may re-use (none after "scratch that").
    pub(super) spare: Vec<WordSet>,
}

/// Medium's corrections in `words`.
pub(super) fn spans(words: &[SaidWord], repair: &SelfRepair, placeholders: &WordSet) -> Spans {
    let mut spans = Spans {
        ends: vec![Vec::new(); words.len() + 1],
        corrected: vec![WordSet::default(); words.len() + 1],
        spare: vec![WordSet::default(); words.len() + 1],
    };
    for (cue_start, run_ends) in cue_runs(words, repair) {
        // Other corrections of an earlier sentence must be about the same thing, which only a
        // phrase that goes back is checked for ([`once`]).
        let retracts_statement = SelfRepair::retracts_statement(&words[cue_start..]);
        let crosses = cue_start > 0 && words[cue_start - 1].ends_sentence;
        if crosses && !retracts_statement {
            continue;
        }
        for start in cue_start.saturating_sub(repair.max_retracted_words)..cue_start {
            let corrected = &words[start..cue_start];
            if corrected[..corrected.len() - 1].iter().any(|word| word.ends_sentence)
                || corrected.iter().all(|word| repair.is_cue(&word.word))
                || corrected.iter().any(|word| placeholders.contains(&word.word))
            {
                continue;
            }
            let corrected_words = WordSet::new(corrected.iter().map(|word| &word.word));
            // A phrase starts after the whole run of cues.
            for &end in run_ends
                .iter()
                .filter(|&&end| end == words.len() || !repair.is_cue(&words[end].word))
            {
                if !retracts_statement {
                    let length = phrase_length(end, words).min(CORRECTION_PHRASE_WORDS);
                    if !repair.takes_back_facts(&words[end..end + length], corrected, placeholders) {
                        continue;
                    }
                    spans.spare[end].form_union(&corrected_words);
                }
                spans.ends[start].push(end);
                spans.corrected[end].form_union(&corrected_words);
            }
        }
    }
    spans
}

/// `words` without each correction that opens a later sentence, from its cue to the end of that
/// sentence: the text an answer would be that dropped the correction and kept what it corrects as
/// said ("Meet me at the Old Town Hall. Actually no, the Town Hall." → "Meet me at the Old Town
/// Hall."), which no repair gives.
pub(super) fn dropped(words: &[SaidWord], repair: &SelfRepair) -> Vec<Vec<SaidWord>> {
    cue_runs(words, repair)
        .into_keys()
        .filter(|&cue_start| cue_start > 0 && words[cue_start - 1].ends_sentence)
        .map(|cue_start| {
            let sentence_end = words[cue_start..]
                .iter()
                .position(|word| word.ends_sentence)
                .map_or(words.len(), |offset| cue_start + offset + 1);
            words[..cue_start]
                .iter()
                .chain(&words[sentence_end..])
                .cloned()
                .collect()
        })
        .collect()
}

/// The words said with the corrections whose phrase goes back applied, in every way they may be:
/// first one, then, in each result, one more, up to [`MAX_APPLIED`]. In each result, a moved
/// phrase opens a correction phrase ([`SaidWord::opens_phrase`]) that may re-use the words it
/// corrected ([`SaidWord::spare`]).
pub(super) fn applied(words: &[SaidWord], repair: &SelfRepair, placeholders: &WordSet) -> Vec<Vec<SaidWord>> {
    let mut results: Vec<Vec<SaidWord>> = Vec::new();
    let mut frontier = vec![words.to_vec()];
    for _ in 0..MAX_APPLIED {
        let mut next = Vec::new();
        for said in &frontier {
            for rewritten in once(said, repair, placeholders) {
                if results.len() < MAX_REWRITES && !results.contains(&rewritten) {
                    results.push(rewritten.clone());
                    next.push(rewritten);
                }
            }
        }
        frontier = next;
    }
    results
}

/// Every way of applying one correction whose phrase goes back to `words`.
fn once(words: &[SaidWord], repair: &SelfRepair, placeholders: &WordSet) -> Vec<Vec<SaidWord>> {
    let mut results = Vec::new();
    for (cue_start, run_ends) in cue_runs(words, repair) {
        if cue_start == 0 || words[cue_start].opens_phrase != 0 {
            continue;
        }
        // A cue that opens a sentence corrects the one before, unless it answers it: a lone "No"
        // after a question does; "No, sorry, …" corrects it.
        let crosses = words[cue_start - 1].ends_sentence;
        let answers = crosses && words[cue_start - 1].ends_question && same(&words[cue_start].word, "no");
        // The sentence corrected: the one before the cue's, or the cue's own up to the cue.
        let sentence_start = words[..cue_start - 1]
            .iter()
            .rposition(|word| word.ends_sentence)
            .map_or(0, |index| index + 1);
        for end in run_ends {
            if (answers && end - cue_start == 1) || end >= words.len() || repair.is_cue(&words[end].word) {
                continue;
            }
            let longest = phrase_length(end, words);
            if longest == 0 {
                continue;
            }
            let weak = end - cue_start == 1 && WEAK_CUES.iter().any(|cue| same(&words[cue_start].word, cue));
            for length in 1..=longest.min(CORRECTION_PHRASE_WORDS) {
                let phrase = &words[end..end + length];
                for start in sentence_start..cue_start {
                    // Empty when the policy lets no words be taken back, as the prompt probe's does.
                    for count in 1..=repair.max_retracted_words.min(cue_start - start) {
                        let corrected = start..start + count;
                        let replaces = || count == 1 && !weak && repair.replaces(&words[start], phrase);
                        // Within a sentence, a phrase that stays where it is was Medium's.
                        if !(crosses || corrected.end < cue_start)
                            || words[corrected.clone()].iter().any(|word| word.opens_phrase > 0)
                            || !(repair.relates(&words[start], phrase, weak) || replaces())
                            || !(repair.relates(&words[corrected.end - 1], phrase, weak) || replaces())
                            || !repair.takes_back_facts(phrase, &words[corrected.clone()], placeholders)
                        {
                            continue;
                        }
                        results.push(rewrite(words, corrected, cue_start..end, end..end + length));
                    }
                }
            }
        }
    }
    results
}

/// `words` with `phrase` put in place of `corrected`, and `cues` taken out. The phrase ends a
/// sentence when it replaced words that did.
fn rewrite(words: &[SaidWord], corrected: Range<usize>, cues: Range<usize>, phrase: Range<usize>) -> Vec<SaidWord> {
    let mut moved = words[phrase.clone()].to_vec();
    let length = moved.len();
    moved[0].opens_phrase = length;
    moved[0].spare = words[corrected.clone()].iter().map(|word| word.word.clone()).collect();
    let last_corrected = &words[corrected.end - 1];
    moved[length - 1].ends_sentence = last_corrected.ends_sentence;
    moved[length - 1].ends_question = last_corrected.ends_question;
    words[..corrected.start]
        .iter()
        .cloned()
        .chain(moved)
        .chain(words[corrected.end..cues.start].iter().cloned())
        .chain(words[phrase.end..].iter().cloned())
        .collect()
}

/// Where each run of cues can end, by where it starts, in order of start. The ends of a run
/// follow the order of the policy's cues, which decides which rewrites [`MAX_REWRITES`] keeps.
fn cue_runs(words: &[SaidWord], repair: &SelfRepair) -> BTreeMap<usize, Vec<usize>> {
    let mut cue_ends: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
    for cue in &repair.cues {
        for start in occurrences(cue, words) {
            cue_ends.entry(start).or_default().push(start + cue.len());
        }
    }
    fn run_ends(start: usize, cue_ends: &BTreeMap<usize, Vec<usize>>) -> Vec<usize> {
        cue_ends
            .get(&start)
            .into_iter()
            .flatten()
            .flat_map(|&end| std::iter::once(end).chain(run_ends(end, cue_ends)))
            .collect()
    }
    cue_ends
        .keys()
        .map(|&start| (start, run_ends(start, &cue_ends)))
        .collect()
}

// MARK: - Facts

/// Kinds of fact a correction takes back one for one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) enum FactKind {
    /// A number or when: "three", "2:30", "noon", "Tuesday", "May", "tomorrow", "next week". A
    /// run of them is one ("next Monday", "two thirty pm").
    Number,
    Unit,
    Negation,
}

impl SelfRepair {
    /// What fact `word` states, if any. "May" is the month when capitalised, or, with
    /// `may_is_month`, when it corrects a month ("the lease ends in april, no wait, may").
    pub(super) fn fact_kind(&self, word: &SaidWord, may_is_month: bool) -> Option<FactKind> {
        let text = word.word.as_str();
        if self.is_negation(text) {
            return Some(FactKind::Negation);
        }
        if word_forms::is_unit_word(text) {
            return Some(FactKind::Unit);
        }
        if same(text, "may") {
            return (word.is_capitalised || may_is_month).then_some(FactKind::Number);
        }
        (word_forms::is_number(text) || word_forms::is_part_of_day(text) || word_forms::is_time_word(text))
            .then_some(FactKind::Number)
    }

    /// How many facts of each kind `words` has. A run of numbers is one, also across the words
    /// that join a number said in parts ("half past two", "ten to five", "two point five").
    fn facts(&self, words: &[SaidWord], may_is_month: bool) -> HashMap<FactKind, usize> {
        let mut counts = HashMap::new();
        let mut previous = None;
        for (index, word) in words.iter().enumerate() {
            if previous == Some(FactKind::Number)
                && NUMBER_JOINERS.iter().any(|joiner| same(&word.word, joiner))
                && words
                    .get(index + 1)
                    .is_some_and(|next| self.fact_kind(next, may_is_month) == Some(FactKind::Number))
            {
                continue;
            }
            let kind = self.fact_kind(word, may_is_month);
            if let Some(kind) = kind
                && !(kind == FactKind::Number && previous == Some(FactKind::Number))
            {
                *counts.entry(kind).or_default() += 1;
            }
            previous = kind;
        }
        counts
    }

    /// Whether `phrase` puts one thing in place of `word`, one for one: after a cue that only ever
    /// takes back, a phrase whose only content word is, like `word`, no fact ("paris, sorry, to
    /// madrid"; "the red one, sorry, blue"), which in lowercase text may be a name no capital
    /// shows.
    pub(super) fn replaces(&self, word: &SaidWord, phrase: &[SaidWord]) -> bool {
        let is_content = |text: &str| !self.is_function_word(text) && !self.is_filler(text) && !self.is_cue(text);
        let mut content = phrase.iter().filter(|other| is_content(&other.word));
        let (Some(other), None) = (content.next(), content.next()) else {
            return false;
        };
        is_content(&word.word) && self.fact_kind(word, false).is_none() && self.fact_kind(other, false).is_none()
    }

    /// Whether `phrase` takes back every fact in `corrected` with one of its own kind: a number
    /// with a number, "Tuesday" with "Wednesday", "not" with a negation or the verb it negated ("I
    /// don't, sorry, I do"). A placeholder is never taken back.
    pub(super) fn takes_back_facts(&self, phrase: &[SaidWord], corrected: &[SaidWord], placeholders: &WordSet) -> bool {
        if corrected.iter().any(|word| placeholders.contains(&word.word)) {
            return false;
        }
        let taken = self.facts(corrected, false);
        let given = self.facts(phrase, corrected.iter().any(is_month));
        taken.into_iter().all(|(kind, count)| {
            let mut available = given.get(&kind).copied().unwrap_or(0);
            if kind == FactKind::Negation {
                available += corrected
                    .iter()
                    .filter(|word| self.is_negation(&word.word) && has_verb(&word.word, phrase))
                    .count();
            }
            count <= available
        })
    }

    /// Whether `word` of a correction's corrected words is something its `phrase` is about: a fact
    /// of the same kind, a name for a name, or, after a cue that only ever takes back (not
    /// `weak`), the same word or a form of it.
    pub(super) fn relates(&self, word: &SaidWord, phrase: &[SaidWord], weak: bool) -> bool {
        if let Some(kind) = self.fact_kind(word, false)
            && kind != FactKind::Negation
            && phrase
                .iter()
                .any(|other| self.fact_kind(other, is_month(word)) == Some(kind))
        {
            return true;
        }
        if word.may_be_name && phrase.iter().any(|other| other.is_name) {
            return true;
        }
        let text = word.word.as_str();
        if weak || self.is_function_word(text) || self.is_filler(text) || self.is_cue(text) {
            return false;
        }
        phrase
            .iter()
            .any(|other| same(&other.word, text) || word_forms::are_forms(&other.word, text))
    }
}

fn is_month(word: &SaidWord) -> bool {
    word_forms::is_month_name(&word.word) || (same(&word.word, "may") && word.is_capitalised)
}

/// Whether `words` has the verb `negation` negated, in any form: "do" or "did" for "don't".
fn has_verb(negation: &str, words: &[SaidWord]) -> bool {
    let Some([verb, _]) = word_forms::expansions(negation).into_iter().next() else {
        return false;
    };
    words
        .iter()
        .any(|word| same(&word.word, &verb) || word_forms::are_forms(&word.word, &verb))
}
