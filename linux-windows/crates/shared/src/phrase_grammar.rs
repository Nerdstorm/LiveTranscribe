//! Word checks that spoken commands share: whether a phrase is being used as a command or
//! talked about, and how it sits among the punctuation around it.

use std::ops::Range;

use crate::swift_string::{self as s};
use crate::tokenized_text::{TokenizedText, token_edges};

/// Punctuation that ends a clause.
pub const CLAUSE_ENDERS: [&str; 6] = [",", ";", ":", ".", "!", "?"];

/// Words after which a command's words are a noun phrase, as in "a question mark", "the new line
/// of laptops" or "our new line": the speaker is talking about the thing, not asking for it.
pub const DETERMINERS: [&str; 25] = [
    "a", "an", "the", "this", "that", "these", "those", "each", "every", "any", "no", "one", "my", "your", "his",
    "her", "its", "our", "their", "another", "which", "what", "whose", "same", "some",
];

/// Whether the word before `position` is a determiner or a possessive ("Apple's") in the same
/// clause.
pub fn follows_determiner(position: usize, text: &TokenizedText) -> bool {
    if position == 0 {
        return false;
    }
    let previous = &text.words()[position - 1];
    if !previous.ends_token || ends_clause(text.token(previous.token)) {
        return false;
    }
    is_word_in(&previous.text, &DETERMINERS) || s::has_suffix(&previous.text, "'s")
}

/// Whether `token` ends with punctuation that ends a clause.
pub fn ends_clause(token: &str) -> bool {
    s::characters(token_edges::trailing(token)).any(|c| s::is_one_of(c, &CLAUSE_ENDERS))
}

/// The token's trailing punctuation after any clause punctuation at its start: what stays in the
/// text when a command replaces the punctuation the transcript had ("mark.\"" keeps the closing
/// quote).
pub fn trailing_after_clause_punctuation(token: &str) -> String {
    s::drop_while(token_edges::trailing(token), |c| s::is_one_of(c, &CLAUSE_ENDERS)).to_owned()
}

/// Whether the words at `position` are `phrase` and cover whole tokens.
pub fn matches<W: AsRef<str>>(phrase: &[W], position: usize, text: &TokenizedText) -> bool {
    let range = position..position + phrase.len();
    if range.end > text.words().len() || !text.covers_whole_tokens(range.clone()) {
        return false;
    }
    text.words()[range]
        .iter()
        .zip(phrase)
        .all(|(word, expected)| s::canonically_equal(&word.text, expected.as_ref()))
}

/// Whether no token inside `range` other than the last ends a clause, so the words run on in one
/// phrase.
pub fn runs_on(range: Range<usize>, text: &TokenizedText) -> bool {
    let last_token = text.words()[range.end - 1].token;
    range.into_iter().all(|index| {
        let word = &text.words()[index];
        word.token == last_token || !word.ends_token || !ends_clause(text.token(word.token))
    })
}

/// Whether `word` is one of `words`, as a `Set<String>` lookup.
pub fn is_word_in(word: &str, words: &[&str]) -> bool {
    words.iter().any(|candidate| s::canonically_equal(word, candidate))
}
