use lt_shared::sentence_case::capitalizing_first_word;
use lt_shared::swift_string::{self as s, CharacterSet};

const SENTENCE_ENDERS: [&str; 3] = [".", "!", "?"];

/// How a list reads once laid out, whether it was spoken with ordinals ("first, …") or with
/// markers ("number one …", "bullet point …").
///
/// - The line before the list ends with a colon: "Tasks for the week." becomes "Tasks for the
///   week:". A question or exclamation keeps its mark.
/// - Items start with a capital and lose trailing commas and semicolons.
/// - Items keep their full stops only when every item is a sentence: it ended with a full stop,
///   question or exclamation mark, and has at least `minimum_sentence_words` words. Question and
///   exclamation marks always stay.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ListStyle {
    /// Fewest words for an item to count as a sentence.
    pub minimum_sentence_words: usize,
}

impl Default for ListStyle {
    fn default() -> Self {
        Self {
            minimum_sentence_words: 4,
        }
    }
}

/// The start of a laid-out list line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Marker {
    /// "1. " or "- ".
    pub prefix: String,
    pub is_numbered: bool,
}

impl ListStyle {
    /// The line before a list, ending in a colon; `None` for a blank line.
    pub fn lead_in(&self, line: &str) -> Option<String> {
        let mut text = s::trimming(line, CharacterSet::Whitespaces).to_owned();
        let last = s::last_character(&text)?;
        if s::is_one_of(last, &[":", "?", "!"]) {
            return Some(text);
        }
        while s::last_character(&text).is_some_and(|end| s::is_one_of(end, &[".", ",", ";"]) || s::is_whitespace(end)) {
            s::pop_last_character(&mut text);
        }
        (!text.is_empty()).then(|| text + ":")
    }

    /// Items as they read in the list; see the type's rules.
    pub fn items(&self, raw: &[String]) -> Vec<String> {
        let trimmed: Vec<String> = raw
            .iter()
            .map(|item| {
                let rest = s::drop_while(item, |c| s::is_one_of(c, &[",", ";", ":"]) || s::is_whitespace(c));
                s::trimming(rest, CharacterSet::Whitespaces).to_owned()
            })
            .collect();
        let all_sentences = trimmed.iter().all(|item| {
            s::last_character(item).is_some_and(|last| s::is_one_of(last, &SENTENCE_ENDERS))
                && s::split_whitespace(item).len() >= self.minimum_sentence_words
        });
        trimmed
            .into_iter()
            .map(|mut text| {
                while s::last_character(&text).is_some_and(|end| {
                    s::is_one_of(end, &[",", ";"])
                        || s::is_whitespace(end)
                        || (!all_sentences && s::canonically_equal(end, "."))
                }) {
                    s::pop_last_character(&mut text);
                }
                capitalizing_first_word(&text)
            })
            .collect()
    }

    /// The marker a laid-out list line starts with, "1. " or "- "; `None` for any other line.
    pub(crate) fn marker(line: &str) -> Option<Marker> {
        if s::has_prefix(line, "- ") {
            return Some(Marker {
                prefix: "- ".to_owned(),
                is_numbered: false,
            });
        }
        let digits = s::prefix_while(line, s::is_number);
        if digits.is_empty() || s::character_count(digits) > 3 || !s::has_prefix(&line[digits.len()..], ". ") {
            return None;
        }
        Some(Marker {
            prefix: format!("{digits}. "),
            is_numbered: true,
        })
    }

    /// `text` split after its first sentence, or `None` when it is one sentence. The text after a
    /// list's last item starts a new paragraph after the list.
    pub(crate) fn split_after_first_sentence(text: &str) -> Option<(String, String)> {
        let tokens = s::split_whitespace(text);
        let end = tokens
            .iter()
            .position(|token| s::last_character(token).is_some_and(|last| s::is_one_of(last, &SENTENCE_ENDERS)))?;
        (end + 1 < tokens.len()).then(|| (tokens[..=end].join(" "), tokens[end + 1..].join(" ")))
    }
}
