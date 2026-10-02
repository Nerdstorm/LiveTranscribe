//! The self-corrections Deep's check lets a repair resolve, as the Mac app's
//! `SelfRepair.Corrections` (Cleanup/SelfRepairCorrections.swift).
//!
//! A correction replaces the words it corrects with its phrase, and the cue goes. Deep reads two
//! kinds:
//! - Medium's: up to [`GuardPolicy::max_retracted_words`](crate::GuardPolicy) words just before a
//!   run of cues, taken out with the cues ("we need three, sorry, four"), in the cue's sentence;
//!   or at the end of the one before, when the cues open the next: one phrase that doesn't start
//!   it ("I left my charger in the garage. Actually, the lobby."), or more after a "scratch that"
//!   ("I'll call the plumber tomorrow. Scratch that, I'll fix the tap myself.") or after cues
//!   followed by "not" and exactly those words ("We'll need compasses. Sorry, not compasses.
//!   Stoves.");
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
//! The cues may be followed by "not" and corrected words said again, which go with them ("room
//! four, no, not four, five"; [`SelfRepair::restates`]).
//!
//! A correction must also keep its meaning: the word that says what it says instead, its phrase's
//! key word ([`SelfRepair::key_word`]), stays, as itself or a word like it ("busses" → "buses"),
//! and the corrected words it takes back are never written again ([`SelfRepair::taken_back`],
//! [`SelfRepair::stood_in_for`]), so "the blue room, sorry, the green room" is "the green room",
//! and neither "the blue room" nor "the blue green room". Nor does a phrase that says the
//! corrected words again after a new word leave the word before them, which the new word takes
//! back ([`SelfRepair::leaves_taken_back`]); it corrects that word too ("The billing service goes
//! live. Sorry, I mean the login service." → "The login service goes live."). Nor does a fact or
//! a name leave the one of its sort just before the words it corrects ("three servers, sorry,
//! four" corrects "three", never only "servers").

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::ops::Range;

use lt_shared::edit_distance;
use lt_shared::swift_string::{self as s};

use super::{CORRECTION_PHRASE_WORDS, SaidWord, SelfRepair, occurrences, phrase_length};
use crate::self_correction::RESTATING_WORD;
use crate::word_forms;
use crate::words::{WordSet, same};

/// How many corrections whose phrase goes back one dictation may have resolved.
const MAX_APPLIED: usize = 2;
/// How many ways of applying them are checked, which bounds the search.
const MAX_REWRITES: usize = 256;
/// Words that start a new clause, which a correction of the sentence before doesn't.
const SUBJECTS: [&str; 30] = [
    "i", "we", "you", "he", "she", "it", "they", "i'm", "i'll", "i've", "i'd", "we're", "we'll", "we've", "we'd",
    "you're", "you'll", "you've", "he's", "he'll", "she's", "she'll", "it's", "it'll", "they're", "they'll", "they've",
    "there's", "that's", "let's",
];
/// Cue words that as often start a new point as correct the last one.
const WEAK_CUES: [&str; 4] = ["no", "wait", "actually", "rather"];
/// Words that join a number said in parts ("half past two", "ten to five", "two point five").
const NUMBER_JOINERS: [&str; 4] = ["past", "to", "and", "point"];
/// Words speech-to-text writes for a cue ("know" for "no", "weight" for "wait", "made" for "make"),
/// which say nothing a correction says instead.
const CUE_SOUND_ALIKES: [&str; 9] = ["know", "now", "note", "node", "weight", "weigh", "way", "made", "maid"];
/// How alike a word and one that only holds the grammar together must be for the word to be that
/// one misheard ("thee" for "the", "theon" for "then").
const MIN_MISHEARD_SIMILARITY: f64 = 0.75;
/// The days of the week, which a key word that is one takes back one of.
const DAYS: [&str; 7] = [
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
];

/// Medium's corrections in the words said, by said index.
pub(super) struct Spans {
    /// For each start, the ends of the corrected words and cues that may be taken out from there.
    pub(super) ends: Vec<Vec<usize>>,
    /// For each phrase that follows, by where it starts, the words it may correct.
    pub(super) corrected: Vec<WordSet>,
    /// Of those, the ones its repair may re-use (none after "scratch that").
    pub(super) spare: Vec<WordSet>,
    /// For each phrase, by where it starts, the corrected words its key word takes back, which no
    /// repair may write again.
    pub(super) taken: Vec<WordSet>,
    /// Where the key words of the phrases are, which no repair may change.
    pub(super) keys: Vec<usize>,
}

/// Medium's corrections in `words`.
pub(super) fn spans(words: &[SaidWord], repair: &SelfRepair, placeholders: &WordSet) -> Spans {
    let mut spans = Spans {
        ends: vec![Vec::new(); words.len() + 1],
        corrected: vec![WordSet::default(); words.len() + 1],
        spare: vec![WordSet::default(); words.len() + 1],
        taken: vec![WordSet::default(); words.len() + 1],
        keys: Vec::new(),
    };
    // Every word each phrase may correct, by where it starts. Which of them a repair took back
    // isn't known, so its key word and the words that takes back are found among them all.
    let mut taken_back: BTreeMap<usize, BTreeSet<usize>> = BTreeMap::new();
    for (cue_start, run_ends) in cue_runs(words, repair) {
        // Speech-to-text ends a sentence where the speaker paused, so a cue that opens one may
        // take back the end of the one before ("I left my charger in the garage. Actually, the
        // lobby."): one phrase, after a word that stays, for a phrase that starts like it and not
        // with a subject. "Sorry, I haven't had time" after "I finished the report.", "Actually,
        // it's quite fast" after "It works." and "Actually, we shipped it early" after "We shipped
        // version two." start a new thought; "Sorry, four" after "three servers for the launch."
        // and "No, three" after "Bring two chairs." take back only the number ([`once`]). Saying
        // the corrected words again ("compasses. Sorry, not compasses. Stoves and water.") or
        // "scratch that" takes back more.
        let retracts_statement = SelfRepair::retracts_statement(&words[cue_start..]);
        let crosses = cue_start > 0 && words[cue_start - 1].ends_sentence;
        let sentence_start = match crosses {
            true => words[..cue_start - 1]
                .iter()
                .rposition(|word| word.ends_sentence)
                .map_or(0, |end| end + 1),
            false => 0,
        };
        // A lone "No" after a question answers it ("Is it on Tuesday? No, not Tuesday,
        // Thursday."), as [`once`] reads it.
        let answers = crosses && words[cue_start - 1].ends_question && same(&words[cue_start].word, "no");
        for start in cue_start.saturating_sub(repair.max_retracted_words)..cue_start {
            let corrected = &words[start..cue_start];
            if corrected[..corrected.len() - 1].iter().any(|word| word.ends_sentence)
                || corrected.iter().all(|word| repair.is_cue(&word.word))
                || corrected.iter().any(|word| placeholders.contains(&word.word))
            {
                continue;
            }
            let corrected_words = WordSet::new(corrected.iter().map(|word| &word.word));
            let content = |word: &SaidWord| {
                !repair.is_function_word(&word.word) && !repair.is_filler(&word.word) && !repair.is_cue(&word.word)
            };
            let ends_sentence_before =
                words[sentence_start..start].iter().any(content) && corrected[1..].iter().all(content);
            let says_more_than_a_fact = corrected
                .iter()
                .any(|word| content(word) && repair.fact_kind(word, false).is_none());
            // A phrase starts after the whole run of cues, and after the corrected words said
            // again.
            for &run_end in &run_ends {
                if answers && run_end - cue_start == 1 {
                    continue;
                }
                for (end, restated) in phrase_starts(run_end, words, repair) {
                    let among_corrected = restated
                        .clone()
                        .is_none_or(|restated| repair.restates(&words[restated], corrected));
                    let all_corrected = restated.is_some_and(|restated| repair.restates(corrected, &words[restated]));
                    let stands_in = ends_sentence_before
                        && words.get(end).is_some_and(|first| {
                            content(first) == content(&corrected[0])
                                && !SUBJECTS.iter().any(|subject| same(&first.word, subject))
                        })
                        && !(says_more_than_a_fact
                            && words[end..]
                                .iter()
                                .take(CORRECTION_PHRASE_WORDS)
                                .find(|word| content(word))
                                .is_some_and(|word| repair.fact_kind(word, false).is_some()));
                    let phrase = &words[end..end + phrase_length(end, words).min(CORRECTION_PHRASE_WORDS)];
                    if (end < words.len() && repair.is_cue(&words[end].word))
                        || !among_corrected
                        || (crosses && !retracts_statement && !all_corrected && !stands_in)
                        || repair.leaves_taken_back(words, start..cue_start, phrase)
                    {
                        continue;
                    }
                    if !retracts_statement {
                        if !repair.takes_back_facts(phrase, corrected, placeholders) {
                            continue;
                        }
                        spans.spare[end].form_union(&corrected_words);
                    }
                    taken_back.entry(end).or_default().extend(start..cue_start);
                    spans.ends[start].push(end);
                    spans.corrected[end].form_union(&corrected_words);
                }
            }
        }
    }
    for (end, indices) in taken_back {
        let phrase = &words[end..end + phrase_length(end, words).min(CORRECTION_PHRASE_WORDS)];
        let corrected: Vec<SaidWord> = indices.into_iter().map(|index| words[index].clone()).collect();
        if let Some(key) = repair.key_word(phrase, &corrected) {
            spans.keys.push(end + key);
            spans.taken[end] = repair.stood_in_for(phrase, key, &corrected);
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
        for run_end in run_ends {
            if answers && run_end - cue_start == 1 {
                continue;
            }
            for (end, restated) in phrase_starts(run_end, words, repair) {
                if end >= words.len() || repair.is_cue(&words[end].word) {
                    continue;
                }
                let longest = phrase_length(end, words);
                if longest == 0 {
                    continue;
                }
                // Saying the corrected words again makes even a weak cue a correction.
                let weak = restated.is_none()
                    && end - cue_start == 1
                    && WEAK_CUES.iter().any(|cue| same(&words[cue_start].word, cue));
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
                                || restated.as_ref().is_some_and(|restated| {
                                    !repair.restates(&words[restated.clone()], &words[corrected.clone()])
                                })
                                || !(repair.relates(&words[start], phrase, weak)
                                    || replaces()
                                    || repair.takes_back_first(&words[corrected.clone()], phrase))
                                || !(repair.relates(&words[corrected.end - 1], phrase, weak) || replaces())
                                || !repair.takes_back_facts(phrase, &words[corrected.clone()], placeholders)
                                || repair.leaves_taken_back(words, corrected.clone(), phrase)
                            {
                                continue;
                            }
                            results.push(rewrite(words, corrected, cue_start..end, end..end + length));
                        }
                    }
                }
            }
        }
    }
    results
}

/// `words` with `phrase` put in place of `corrected`, and `cues` taken out. The phrase ends a
/// sentence when it replaced words that did. A phrase an earlier correction opened ends where its
/// words stop following each other, as when this one takes a cue out of it ("email no one").
fn rewrite(said: &[SaidWord], corrected: Range<usize>, cues: Range<usize>, phrase: Range<usize>) -> Vec<SaidWord> {
    let mut words = said.to_vec();
    let count = words.len();
    for segment in [
        0..corrected.start,
        phrase.clone(),
        corrected.end..cues.start,
        phrase.end..count,
    ] {
        for index in segment.clone() {
            words[index].opens_phrase = words[index].opens_phrase.min(segment.end - index);
        }
    }
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

/// Where a correction's phrase can start after a run of cues that ends at `end`: there, or, when
/// "not" follows the cues, after the corrected words said again ("Tuesday, sorry, not Tuesday,
/// Thursday"), with the range of the words said again, which must be among the corrected words
/// ([`SelfRepair::restates`]). Those words may end their sentence, since speech-to-text ends one
/// where the speaker paused ("not Sunday. Thursday."), and the phrase then starts the next.
fn phrase_starts(end: usize, words: &[SaidWord], repair: &SelfRepair) -> Vec<(usize, Option<Range<usize>>)> {
    let mut starts = vec![(end, None)];
    if end >= words.len() || !same(&words[end].word, RESTATING_WORD) {
        return starts;
    }
    let first = end + 1;
    for (offset, word) in words[first..].iter().take(repair.max_retracted_words).enumerate() {
        let stop = first + offset + 1;
        starts.push((stop, Some(first..stop)));
        if word.ends_sentence {
            break;
        }
    }
    starts
}

/// Where each run of cues can end, by where it starts, in order of start; a cue misheard as another
/// word ([`CUE_SOUND_ALIKES`]) may end it. The ends of a run follow the order of the policy's cues,
/// which decides which rewrites [`MAX_REWRITES`] keeps.
fn cue_runs(words: &[SaidWord], repair: &SelfRepair) -> BTreeMap<usize, Vec<usize>> {
    let mut cue_ends: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
    for cue in &repair.cues {
        for start in occurrences(cue, words) {
            let end = start + cue.len();
            let ends = cue_ends.entry(start).or_default();
            ends.push(end);
            // A cue speech-to-text misheard, just after one it didn't, goes with it ("the monitor,
            // wait, node, the router").
            if words
                .get(end)
                .is_some_and(|word| CUE_SOUND_ALIKES.iter().any(|alike| same(&word.word, alike)))
            {
                ends.push(end + 1);
            }
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

    /// Whether `restated`, said after a cue and "not", says again some of the `corrected` words:
    /// its words that carry meaning, at least one, are a run of theirs ("not the kitchen" for
    /// "kitchen", "not marketing" for "marketing team"). Only then does the "not" go with the
    /// correction; any other keeps what it negates ("Thursday, not Friday").
    pub(super) fn restates(&self, restated: &[SaidWord], corrected: &[SaidWord]) -> bool {
        let content = |words: &[SaidWord]| -> Vec<String> {
            words
                .iter()
                .map(|word| word.word.clone())
                .filter(|word| !self.is_function_word(word) && !self.is_filler(word))
                .collect()
        };
        let (said, taken) = (content(restated), content(corrected));
        !said.is_empty()
            && said.len() <= taken.len()
            && taken
                .windows(said.len())
                .any(|run| run.iter().zip(&said).all(|(a, b)| same(a, b)))
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

    /// Whether `word` says something a correction can take back or say instead: it holds more than
    /// the grammar together, and isn't a filler, a cue, or a cue as speech-to-text misheard it
    /// ("know" for "no").
    fn carries_meaning(&self, word: &SaidWord) -> bool {
        let text = word.word.as_str();
        !self.is_function_word(text)
            && !self.is_filler(text)
            && !self.is_cue(text)
            && !CUE_SOUND_ALIKES.iter().any(|alike| same(text, alike))
    }

    /// Whether `word` is likely a word that holds the grammar together, misheard ("thee" for "the",
    /// "theon" for "then"): no fact or name, and close to one.
    fn is_misheard_function_word(&self, word: &SaidWord) -> bool {
        let length = s::character_count(&word.word);
        // Words further apart in length can't be as alike.
        let near = |function_word: &str| {
            let other = s::character_count(function_word);
            length.abs_diff(other) as f64 <= (1.0 - MIN_MISHEARD_SIMILARITY) * length.max(other) as f64
        };
        !word.may_be_name
            && self.fact_kind(word, false).is_none()
            && self.function_words.iter().any(|function_word| {
                near(function_word)
                    && edit_distance::normalized_similarity(&word.word, function_word) >= MIN_MISHEARD_SIMILARITY
            })
    }

    /// Where the key word of a correction's `phrase` is: the first word that carries meaning and
    /// isn't among the `corrected` words or a misheard word that only holds the grammar together,
    /// which says what the correction says instead ("green" in "the blue room, sorry, the green
    /// room"). No repair may change it into another word, so an answer can't keep what was
    /// corrected and lose the correction.
    pub(super) fn key_word(&self, phrase: &[SaidWord], corrected: &[SaidWord]) -> Option<usize> {
        phrase.iter().position(|word| {
            self.carries_meaning(word) && !said_in(word, corrected) && !self.is_misheard_function_word(word)
        })
    }

    /// What sort of thing `word` says, which a key word takes back one of its own sort of.
    fn sort(&self, word: &SaidWord, may_is_month: bool) -> Sort {
        match self.fact_kind(word, may_is_month) {
            None if word.is_name => Sort::Name,
            None => Sort::Word,
            Some(FactKind::Negation) => Sort::Negation,
            Some(FactKind::Unit) => Sort::Unit,
            Some(FactKind::Number) if word_forms::is_number(&word.word) => Sort::Number,
            Some(FactKind::Number) if DAYS.iter().any(|day| same(&word.word, day)) => Sort::Day,
            Some(FactKind::Number) if is_month(word) || same(&word.word, "may") => Sort::Month,
            Some(FactKind::Number) => Sort::Time,
        }
    }

    /// The `corrected` words a correction whose `phrase` goes back takes back, which no repair may
    /// write again once it has a key word: those that carry meaning and that the phrase doesn't say
    /// again ("Tuesday" for "Wednesday", "billing" for "the login service").
    pub(super) fn taken_back(&self, phrase: &[SaidWord], corrected: &[SaidWord]) -> WordSet {
        WordSet::new(
            corrected
                .iter()
                .filter(|word| self.carries_meaning(word) && !said_in(word, phrase))
                .map(|word| &word.word),
        )
    }

    /// Of the words a phrase of Medium's corrections may correct (`corrected`, all of them, since
    /// which a repair took back isn't known), the ones its key word stands in for, which no repair
    /// may write again: the one where the phrase puts it, found by a word the phrase says again
    /// after it ("blue" in "the blue room, sorry, the green room") or else before it ("Sam" in
    /// "send it to Sam, sorry, to Priya"); without one, for a fact, the corrected facts ("three" in
    /// "three servers, sorry, four"), and for a name, the one name corrected. Other corrected words
    /// may be written again ("I'm meeting divya at the station, actually nikhil" → "I'm meeting
    /// Nikhil at the station").
    fn stood_in_for(&self, phrase: &[SaidWord], key: usize, corrected: &[SaidWord]) -> WordSet {
        let may_is_month = corrected.iter().any(is_month);
        let sort = self.sort(&phrase[key], may_is_month);
        let taken = |word: &SaidWord| {
            self.carries_meaning(word) && self.sort(word, may_is_month) == sort && !said_in(word, phrase)
        };
        // The corrected word as far from the anchor said again as the key word is in the phrase.
        let at = |anchor: usize, offset: isize| {
            corrected
                .iter()
                .rposition(|word| same(&word.word, &phrase[anchor].word))
                .and_then(|index| index.checked_add_signed(offset))
                .and_then(|index| corrected.get(index))
                .filter(|word| taken(word))
        };
        let after = (key + 1..phrase.len())
            .find(|&index| self.carries_meaning(&phrase[index]) && said_in(&phrase[index], corrected));
        let before = (0..key).rev().find(|&index| said_in(&phrase[index], corrected));
        let found = match (after, before) {
            (Some(anchor), _) => Some(at(anchor, key as isize - anchor as isize)),
            (None, Some(anchor)) => Some(at(anchor, (key - anchor) as isize)),
            (None, None) => None,
        };
        match found {
            Some(word) => WordSet::new(word.map(|word| &word.word)),
            None if sort == Sort::Name => {
                let mut names = corrected.iter().filter(|word| taken(word));
                match (names.next(), names.next()) {
                    (Some(name), None) => WordSet::new([&name.word]),
                    _ => WordSet::default(),
                }
            }
            None if sort != Sort::Word => WordSet::new(
                corrected
                    .iter()
                    .filter(|word| self.fact_kind(word, may_is_month).is_some() && !said_in(word, phrase))
                    .map(|word| &word.word),
            ),
            None => WordSet::default(),
        }
    }

    /// Whether a reading of a correction would keep the word its key word takes back, just before
    /// the `corrected` words of `words`: its `phrase` says each of them that carries meaning again,
    /// after the key word, so it corrects that word too ("the blue room, sorry, the green room"
    /// corrects "blue room", and is never "the blue green room"); or the key word is a fact or a
    /// name, none of the corrected words is one of its sort, and the word before them that
    /// carries meaning is ("three servers, sorry, four" corrects "three", and is never "three,
    /// four servers"; "Invite Sam to the launch. Sorry, Priya." corrects "Sam", and is never
    /// "Invite Sam and Priya to the launch.").
    pub(super) fn leaves_taken_back(&self, words: &[SaidWord], corrected: Range<usize>, phrase: &[SaidWord]) -> bool {
        corrected.start > 0
            && !words[corrected.start - 1].ends_sentence
            && (self.takes_back_first(&words[corrected.start - 1..corrected.end], phrase)
                || self.leaves_its_sort(words, corrected, phrase))
    }

    /// Whether the key word of `phrase` is a fact or a name, none of the `corrected` words of
    /// `words` is of its sort, and the last word before them in their sentence that carries
    /// meaning is.
    fn leaves_its_sort(&self, words: &[SaidWord], corrected: Range<usize>, phrase: &[SaidWord]) -> bool {
        let corrected_words = &words[corrected.clone()];
        let Some(before) = words[..corrected.start]
            .iter()
            .rev()
            .take_while(|word| !word.ends_sentence)
            .find(|word| self.carries_meaning(word))
        else {
            return false;
        };
        let may_is_month = corrected_words.iter().any(is_month);
        let sort = self.sort(before, may_is_month);
        // The key word, the costliest to find, last.
        sort != Sort::Word
            && !said_in(before, phrase)
            && !corrected_words
                .iter()
                .any(|word| self.carries_meaning(word) && self.sort(word, may_is_month) == sort)
            && self
                .key_word(phrase, corrected_words)
                .is_some_and(|key| self.sort(&phrase[key], may_is_month) == sort)
    }

    /// Whether the key word of `phrase` takes back the first of the `corrected` words, and the
    /// phrase says each of the others that carries meaning again after it: "the green room" for
    /// "blue room", "the login service" for "billing service".
    pub(super) fn takes_back_first(&self, corrected: &[SaidWord], phrase: &[SaidWord]) -> bool {
        let (first, rest) = (&corrected[0], &corrected[1..]);
        if !self.carries_meaning(first)
            || said_in(first, phrase)
            || rest
                .iter()
                .any(|word| self.carries_meaning(word) && !said_in(word, phrase))
        {
            return false;
        }
        let Some(said_again) = phrase
            .iter()
            .position(|word| self.carries_meaning(word) && said_in(word, rest))
        else {
            return false;
        };
        self.key_word(phrase, corrected)
            .is_some_and(|key| key < said_again && self.sort(first, false) == self.sort(&phrase[key], false))
    }
}

/// What sort of thing a word says, finer than [`FactKind`], for what a key word takes back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Sort {
    Number,
    Day,
    Month,
    /// Another word of time ("tomorrow", "noon", "week").
    Time,
    Unit,
    Negation,
    /// A name, capitalised where no sentence starts.
    Name,
    /// Any other word that carries meaning.
    Word,
}

/// Whether `word` is among `words`, as itself or another form of it.
fn said_in(word: &SaidWord, words: &[SaidWord]) -> bool {
    words
        .iter()
        .any(|other| same(&other.word, &word.word) || word_forms::are_forms(&other.word, &word.word))
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
