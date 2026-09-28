use lt_shared::phrase_grammar::{self, is_word_in};
use lt_shared::swift_string::{self as s, CharacterSet};

use crate::list_style::ListStyle;

const ORDINALS: [(&str, usize); 15] = [
    ("first", 1),
    ("firstly", 1),
    ("second", 2),
    ("secondly", 2),
    ("third", 3),
    ("thirdly", 3),
    ("fourth", 4),
    ("fourthly", 4),
    ("fifth", 5),
    ("fifthly", 5),
    ("sixth", 6),
    ("seventh", 7),
    ("eighth", 8),
    ("ninth", 9),
    ("tenth", 10),
];
const CARDINALS: [(&str, usize); 20] = [
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
    ("1", 1),
    ("2", 2),
    ("3", 3),
    ("4", 4),
    ("5", 5),
    ("6", 6),
    ("7", 7),
    ("8", 8),
    ("9", 9),
    ("10", 10),
];
/// Marks after a cardinal that make it a list number: "Two, …", "Three: …", "Four. …".
const CARDINAL_ENDERS: [&str; 3] = [",", ":", "."];
const CLOSERS: [&str; 2] = ["finally", "lastly"];
const CONNECTORS: [&str; 2] = ["and", "then"];
/// "First is …", "Second was …".
const COPULAS: [&str; 2] = ["is", "was"];
/// "First thing is …", "Second one's …".
const MARKER_NOUNS: [&str; 5] = ["one", "thing", "item", "task", "step"];
const SENTENCE_ENDERS: [&str; 3] = [".", "!", "?"];

/// Turns a spoken enumeration into a numbered list: "We need three things: first, milk; second,
/// eggs; and third, bread." becomes "We need three things:\n1. Milk\n2. Eggs\n3. Bread".
///
/// Deterministic, so it never changes words: it only moves them onto lines. A list needs at
/// least two items numbered in order from one, each number starting a clause (at the start of
/// the text, after punctuation, or after "and" / "then"); "finally" or "lastly" may end it. The
/// numbers are spoken ordinals ("first", "second", … or "firstly", …) or cardinals ("one",
/// "two", … or 1, 2, …). A cardinal counts only when "is", a comma, a colon or a full stop follows
/// it, so "One of them left" and "Two people came" stay as said. A one before the list's second
/// item starts it again. The last item runs to the end of its sentence, and any text after that
/// starts a new paragraph. The lead-in and items are punctuated by [`ListStyle`].
///
/// Words that only introduce an item belong to its number: "First of all, …", "First is …", "One
/// is …", "Second thing is …", "Third one's …". The "is" stays in the item after a comma ("First,
/// is it ready?") or in a question ("First is it ready?").
#[derive(Clone, Debug, Default)]
pub struct ListFormatter {
    style: ListStyle,
}

impl ListFormatter {
    pub fn new(style: ListStyle) -> Self {
        Self { style }
    }

    /// `text` as a numbered list, or `None` when it is not a spoken enumeration.
    pub fn formatted(&self, text: &str) -> Option<String> {
        self.lines(text).map(|lines| lines.join("\n"))
    }

    /// The list's lines: the lead-in if there is one, the items, and any text after the list.
    pub fn lines(&self, text: &str) -> Option<Vec<String>> {
        let tokens = s::split_whitespace(text);
        let markers = markers(&tokens)?;
        if markers.len() < 2 {
            return None;
        }

        let mut items = Vec::new();
        for (index, &marker) in markers.iter().enumerate() {
            let start = item_start(marker, &tokens);
            let end = if let Some(&next) = markers.get(index + 1) {
                let mut end = next;
                while end > start && is_word_in(&core(tokens[end - 1]), &CONNECTORS) {
                    end -= 1;
                }
                end
            } else {
                sentence_end(&tokens, start)
            };
            if start >= end {
                return None;
            }
            items.push(tokens[start..end].join(" "));
        }
        let styled = self.style.items(&items);
        if styled.iter().any(String::is_empty) {
            return None;
        }

        let mut lines = Vec::new();
        if let Some(lead_in) = self.style.lead_in(&tokens[..markers[0]].join(" ")) {
            lines.push(lead_in);
        }
        lines.extend(
            styled
                .iter()
                .enumerate()
                .map(|(offset, item)| format!("{}. {item}", offset + 1)),
        );
        let last_item_end = sentence_end(&tokens, markers[markers.len() - 1] + 1);
        if last_item_end < tokens.len() {
            lines.push(String::new());
            lines.push(tokens[last_item_end..].join(" "));
        }
        Some(lines)
    }
}

/// The index after the first token from `start` that ends a sentence, or the token count.
fn sentence_end(tokens: &[&str], start: usize) -> usize {
    tokens[start..]
        .iter()
        .position(|token| ends_sentence(token))
        .map_or(tokens.len(), |offset| start + offset + 1)
}

/// Token indices of the list's numbers, in order from one: the run of ordinals or of cardinals
/// that starts first.
fn markers(tokens: &[&str]) -> Option<Vec<usize>> {
    [run(tokens, ordinal), run(tokens, cardinal)]
        .into_iter()
        .flatten()
        .min_by_key(|markers| markers[0])
}

/// The first run of at least two numbers in order from one, each starting a clause, with
/// "finally" or "lastly" after the second or later; `None` when there is none. A one before the
/// run's second number starts it again: "One is enough. One is the launch. Two, …".
fn run(tokens: &[&str], numbering: fn(usize, &[&str]) -> Option<usize>) -> Option<Vec<usize>> {
    let mut markers: Vec<usize> = Vec::new();
    for index in 0..tokens.len() {
        if !starts_clause(index, tokens) {
            continue;
        }
        let number = numbering(index, tokens);
        if number == Some(1) && markers.len() < 2 {
            markers = vec![index];
        } else if !markers.is_empty() && number == Some(markers.len() + 1) {
            markers.push(index);
        } else if markers.len() >= 2 && is_word_in(&core(tokens[index]), &CLOSERS) {
            markers.push(index);
            break;
        }
    }
    (markers.len() >= 2).then_some(markers)
}

fn look_up(table: &[(&str, usize)], word: &str) -> Option<usize> {
    table
        .iter()
        .find(|(name, _)| s::canonically_equal(name, word))
        .map(|&(_, number)| number)
}

/// The number the ordinal at `index` gives its item ("second" → 2), or `None`.
fn ordinal(index: usize, tokens: &[&str]) -> Option<usize> {
    look_up(&ORDINALS, &core(tokens[index]))
}

/// The number the cardinal at `index` gives its item, or `None` when it is not followed by "is",
/// a comma, a colon or a full stop, or ends the text.
fn cardinal(index: usize, tokens: &[&str]) -> Option<usize> {
    let number = look_up(&CARDINALS, &core(tokens[index]))?;
    if index + 1 >= tokens.len() {
        return None;
    }
    if s::last_character(tokens[index]).is_some_and(|last| s::is_one_of(last, &CARDINAL_ENDERS)) {
        return Some(number);
    }
    is_word_in(&core(tokens[index + 1]), &COPULAS).then_some(number)
}

/// Where the item introduced by the number at `marker` starts: after the words that belong to
/// the marker (see the type's rules).
fn item_start(marker: usize, tokens: &[&str]) -> usize {
    let next = marker + 1;
    if next + 1 < tokens.len()
        && s::canonically_equal(&core(tokens[marker]), "first")
        && s::canonically_equal(&core(tokens[next]), "of")
        && s::canonically_equal(&core(tokens[next + 1]), "all")
    {
        return next + 2;
    }
    if !(next < tokens.len() && !ends_in_punctuation(tokens[marker]) && !asks_question(next, tokens)) {
        return next;
    }
    let word = core(tokens[next]);
    if is_word_in(&word, &COPULAS) || (s::has_suffix(&word, "'s") && is_word_in(s::drop_last(&word, 2), &MARKER_NOUNS))
    {
        return next + 1;
    }
    if is_word_in(&word, &MARKER_NOUNS)
        && !ends_in_punctuation(tokens[next])
        && next + 1 < tokens.len()
        && is_word_in(&core(tokens[next + 1]), &COPULAS)
    {
        return next + 2;
    }
    next
}

fn ends_in_punctuation(token: &str) -> bool {
    s::last_character(token).is_some_and(s::is_punctuation)
}

/// Whether the sentence from token `index` ends with a question mark.
fn asks_question(index: usize, tokens: &[&str]) -> bool {
    tokens[index..]
        .iter()
        .find(|token| ends_sentence(token))
        .and_then(|token| s::last_character(token))
        .is_some_and(|last| s::canonically_equal(last, "?"))
}

fn starts_clause(index: usize, tokens: &[&str]) -> bool {
    if index == 0 || ends_with_clause_ender(tokens[index - 1]) {
        return true;
    }
    // "…, and second" / "and then third"
    let mut previous = index - 1;
    while is_word_in(&core(tokens[previous]), &CONNECTORS) {
        if previous == 0 || ends_with_clause_ender(tokens[previous - 1]) {
            return true;
        }
        previous -= 1;
    }
    false
}

fn ends_with_clause_ender(token: &str) -> bool {
    s::last_character(token).is_some_and(|last| s::is_one_of(last, &phrase_grammar::CLAUSE_ENDERS))
}

/// The token's word, lowercased, without the punctuation around it, with a typographic
/// apostrophe written as "'" ("one’s" → "one's").
fn core(token: &str) -> String {
    s::replacing_character(
        &s::lowercased(s::trimming(token, CharacterSet::Punctuation)),
        "\u{2019}",
        "'",
    )
}

fn ends_sentence(token: &str) -> bool {
    s::last_character(token).is_some_and(|last| s::is_one_of(last, &SENTENCE_ENDERS))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lays_out_a_spoken_enumeration() {
        let formatter = ListFormatter::default();
        assert_eq!(
            formatter
                .formatted("We need three things: first, milk; second, eggs; and third, bread.")
                .as_deref(),
            Some("We need three things:\n1. Milk\n2. Eggs\n3. Bread")
        );
        assert_eq!(formatter.formatted("One of them left. Two people came."), None);
    }
}
