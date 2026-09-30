use std::ops::Range;

use lt_shared::phrase_grammar::{self, is_word_in};
use lt_shared::swift_string::{self as s};
use lt_shared::{PhraseMatch, PhraseMatcher, Replacement, Role, TokenizedText, token_edges};

const NUMBERED_KEYWORDS: [&str; 3] = ["number", "item", "step"];
const NUMBER_WORDS: [(&str, usize); 20] = [
    ("one", 1),
    ("two", 2),
    ("three", 3),
    ("four", 4),
    ("five", 5),
    ("six", 6),
    ("seven", 7),
    ("eight", 8),
    ("nine", 9),
    ("ten", 10),
    ("eleven", 11),
    ("twelve", 12),
    ("thirteen", 13),
    ("fourteen", 14),
    ("fifteen", 15),
    ("sixteen", 16),
    ("seventeen", 17),
    ("eighteen", 18),
    ("nineteen", 19),
    ("twenty", 20),
];
const BULLET: [&str; 2] = ["bullet", "point"];
/// Words after which "number one" is a predicate, not a list marker.
const COPULAS: [&str; 12] = [
    "is", "was", "are", "were", "be", "been", "being", "am", "isn't", "wasn't", "aren't", "weren't",
];
/// Words after a number that introduce its item: "number one is ship the release".
const ITEM_COPULAS: [&str; 2] = ["is", "was"];
const SENTENCE_ENDERS: [&str; 3] = [".", "!", "?"];
/// Endings of contracted copulas: "we're", "I'm".
const COPULA_CONTRACTIONS: [&str; 2] = ["'re", "'m"];
/// Words after which "bullet point" names a bullet on a slide or page.
const ORDINALS: [&str; 11] = [
    "first", "second", "third", "fourth", "fifth", "sixth", "last", "next", "previous", "final", "other",
];

/// Spoken list markers: "number one … number two …" (or "item", "step", with digits or words)
/// and "bullet point … bullet point …". Each marker goes behind a placeholder that becomes the
/// start of a list line, "1. " or "- ", which [`crate::MarkedListLayout`] then lays out.
///
/// Numbered markers count only in a run that starts at one and goes up by one, with the same
/// word, at least two of them, so "we're number one" stays as said. Bullets need two markers too.
/// Every marker needs words after it. A marker is talked about, not said, after a determiner
/// ("the number one priority", "a bullet point"), after a form of "be" ("speed is number one and
/// cost is number two"), and, for bullets, after an ordinal ("the second bullet point is wrong").
/// An "is" straight after a number belongs to the marker ("number one is ship the release"), but
/// not after a comma ("number one, is it ready?") or in a question ("number one is it ready?").
///
/// Used only where lists are laid out: from Medium up, in fields that take several lines.
#[derive(Clone, Copy, Debug, Default)]
pub struct ListMarkerCommand;

struct Candidate {
    words: Range<usize>,
    keyword: String,
    number: usize,
}

impl PhraseMatcher for ListMarkerCommand {
    fn matches(&self, text: &TokenizedText) -> Vec<PhraseMatch> {
        let mut found = numbered_markers(text);
        found.extend(bullet_markers(text));
        found
    }
}

fn numbered_markers(text: &TokenizedText) -> Vec<PhraseMatch> {
    let words = text.words();
    let mut candidates = Vec::new();
    for position in 0..words.len().saturating_sub(1) {
        if !is_word_in(&words[position].text, &NUMBERED_KEYWORDS) {
            continue;
        }
        let marker = position..position + 2;
        if !text.covers_whole_tokens(marker.clone())
            || phrase_grammar::ends_clause(text.token_of_word(position))
            || phrase_grammar::follows_determiner(position, text)
            || follows(position, text, &COPULAS, &COPULA_CONTRACTIONS)
        {
            continue;
        }
        let Some(number) = number(&words[position + 1].text) else {
            continue;
        };
        let range = including_item_copula(marker, text);
        if range.end >= words.len() {
            continue;
        }
        candidates.push(Candidate {
            words: range,
            keyword: words[position].text.clone(),
            number,
        });
    }

    let mut runs: Vec<Vec<&Candidate>> = Vec::new();
    for keyword in NUMBERED_KEYWORDS {
        let mut run: Vec<&Candidate> = Vec::new();
        for candidate in candidates
            .iter()
            .filter(|candidate| s::canonically_equal(&candidate.keyword, keyword))
        {
            if candidate.number == run.len() + 1 {
                run.push(candidate);
            } else if candidate.number == 1 {
                runs.push(std::mem::replace(&mut run, vec![candidate]));
            }
        }
        runs.push(run);
    }
    runs.into_iter()
        .filter(|run| run.len() >= 2)
        .flatten()
        .map(|candidate| {
            let line_start = format!("{}. ", candidate.number);
            let trigger = format!("{} {}", candidate.keyword, candidate.number);
            marker(candidate.words.clone(), &line_start, &trigger, text)
        })
        .collect()
}

fn bullet_markers(text: &TokenizedText) -> Vec<PhraseMatch> {
    let positions: Vec<usize> = (0..text.words().len())
        .filter(|&position| {
            phrase_grammar::matches(&BULLET, position, text)
                && position + BULLET.len() < text.words().len()
                && !phrase_grammar::follows_determiner(position, text)
                && !follows(position, text, &ORDINALS, &[])
        })
        .collect();
    if positions.len() < 2 {
        return Vec::new();
    }
    positions
        .into_iter()
        .map(|position| marker(position..position + 2, "- ", "bullet point", text))
        .collect()
}

/// A marker starts a new line, except at the start of the text.
fn marker(words: Range<usize>, line_start: &str, trigger: &str, text: &TokenizedText) -> PhraseMatch {
    let expansion = format!("{}{line_start}", if words.start == 0 { "" } else { "\n" });
    let kept_trailing = phrase_grammar::trailing_after_clause_punctuation(text.token_of_word(words.end - 1));
    let replacement = Replacement::Placeholder {
        trigger: trigger.to_owned(),
        expansion,
        role: Role::Structure,
    };
    PhraseMatch {
        kept_trailing,
        ..PhraseMatch::new(words, replacement)
    }
}

/// `marker` and the "is" after it, when that "is" introduces the item (see the type's rules).
fn including_item_copula(marker: Range<usize>, text: &TokenizedText) -> Range<usize> {
    let next = marker.end;
    let with_copula = marker.start..next + 1;
    if next < text.words().len()
        && is_word_in(&text.words()[next].text, &ITEM_COPULAS)
        && text.covers_whole_tokens(with_copula.clone())
        && !phrase_grammar::ends_clause(text.token_of_word(next - 1))
        && !asks_question(next, text)
    {
        with_copula
    } else {
        marker
    }
}

/// Whether the sentence from word `position` ends with a question mark.
fn asks_question(position: usize, text: &TokenizedText) -> bool {
    let first = text.words()[position].token;
    (first..text.tokens().len())
        .map(|token| token_edges::trailing(text.token(token)))
        .find(|trailing| s::characters(trailing).any(|c| s::is_one_of(c, &SENTENCE_ENDERS)))
        .is_some_and(|trailing| s::contains_character(trailing, "?"))
}

/// Whether the word before `position`, in the same clause, is one of `words` or ends with one of
/// `endings`.
fn follows(position: usize, text: &TokenizedText, words: &[&str], endings: &[&str]) -> bool {
    if position == 0 {
        return false;
    }
    let previous = &text.words()[position - 1];
    if !previous.ends_token || phrase_grammar::ends_clause(text.token(previous.token)) {
        return false;
    }
    is_word_in(&previous.text, words) || endings.iter().any(|ending| s::has_suffix(&previous.text, ending))
}

fn number(word: &str) -> Option<usize> {
    if let Some(&(_, value)) = NUMBER_WORDS.iter().find(|(name, _)| s::canonically_equal(name, word)) {
        return Some(value);
    }
    if s::character_count(word) > 2 {
        return None;
    }
    // Swift's `Int(_:)`: an optional sign and ASCII digits.
    let value: i64 = word.parse().ok()?;
    usize::try_from(value).ok().filter(|&value| value > 0)
}
