use std::ops::Range;

use crate::edit_distance;
use crate::swift_string::{self as s};

/// One normalised word of a [`TokenizedText`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Word {
    /// The word as [`edit_distance::normalize`] leaves it: lowercased, without punctuation.
    pub text: String,
    /// Index into [`TokenizedText::tokens`] of the token the word is in.
    pub token: usize,
    pub starts_token: bool,
    pub ends_token: bool,
}

/// Text split the way phrase matching sees it: whitespace-delimited tokens, and the normalised
/// words each token contributes.
///
/// A token usually contributes one word, but a hyphenated token ("calendar-link") contributes
/// several and a lone dash or ellipsis none, because [`edit_distance::normalize`] splits on
/// hyphens and drops punctuation. Matches must start at a token's first word and end at a
/// token's last word, so only whole tokens are ever replaced.
#[derive(Clone, Debug)]
pub struct TokenizedText<'a> {
    text: &'a str,
    tokens: Vec<Range<usize>>,
    words: Vec<Word>,
}

impl<'a> TokenizedText<'a> {
    pub fn new(text: &'a str) -> Self {
        let mut tokens = Vec::new();
        let mut token_start = None;
        for (index, character) in s::character_indices(text) {
            if s::is_whitespace(character) {
                if let Some(start) = token_start.take() {
                    tokens.push(start..index);
                }
            } else if token_start.is_none() {
                token_start = Some(index);
            }
        }
        if let Some(start) = token_start {
            tokens.push(start..text.len());
        }

        let mut words = Vec::new();
        for (token_index, range) in tokens.iter().enumerate() {
            let normalized = edit_distance::normalize(&text[range.clone()]);
            let token_words = edit_distance::words(&normalized);
            let last = token_words.len().saturating_sub(1);
            for (position, word) in token_words.iter().enumerate() {
                words.push(Word {
                    text: (*word).to_owned(),
                    token: token_index,
                    starts_token: position == 0,
                    ends_token: position == last,
                });
            }
        }
        Self { text, tokens, words }
    }

    /// The text that was split.
    pub fn text(&self) -> &'a str {
        self.text
    }

    /// Byte ranges of the whitespace-delimited tokens, in order.
    pub fn tokens(&self) -> &[Range<usize>] {
        &self.tokens
    }

    pub fn words(&self) -> &[Word] {
        &self.words
    }

    /// The characters of token `index`.
    pub fn token(&self, index: usize) -> &'a str {
        &self.text[self.tokens[index].clone()]
    }

    /// The characters of the token that word `index` is in.
    pub fn token_of_word(&self, index: usize) -> &'a str {
        self.token(self.words[index].token)
    }

    /// The normalised words in `range`, for comparing with a phrase.
    pub fn words_in(&self, range: Range<usize>) -> Vec<&str> {
        self.words[range].iter().map(|word| word.text.as_str()).collect()
    }

    /// Whether the words in `range` are whole tokens: the first starts a token and the last ends one.
    pub fn covers_whole_tokens(&self, range: Range<usize>) -> bool {
        if range.is_empty() || range.end > self.words.len() {
            return false;
        }
        self.words[range.start].starts_token && self.words[range.end - 1].ends_token
    }
}

/// The punctuation around a token's letters and digits.
pub mod token_edges {
    use crate::swift_string::{self as s};

    /// Characters before the first letter or digit. Empty for a token with no letters or digits,
    /// so its characters are never counted twice as both leading and trailing.
    pub fn leading(token: &str) -> &str {
        match s::first_index(token, is_word_character) {
            Some(first) => &token[..first],
            None => "",
        }
    }

    /// Characters after the last letter or digit; empty for a token with no letters or digits.
    pub fn trailing(token: &str) -> &str {
        match s::last_index(token, is_word_character) {
            Some(last) => &token[last.end..],
            None => "",
        }
    }

    fn is_word_character(character: &str) -> bool {
        s::is_letter(character) || s::is_number(character)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_tokens_into_normalised_words() {
        let text = TokenizedText::new("Send my calendar-link, — now.");
        assert_eq!(text.tokens().len(), 5);
        let words: Vec<_> = text
            .words()
            .iter()
            .map(|w| (w.text.as_str(), w.token, w.starts_token, w.ends_token))
            .collect();
        assert_eq!(
            words,
            [
                ("send", 0, true, true),
                ("my", 1, true, true),
                ("calendar", 2, true, false),
                ("link", 2, false, true),
                ("now", 4, true, true),
            ]
        );
        assert!(text.covers_whole_tokens(2..4));
        assert!(!text.covers_whole_tokens(2..3));
        assert_eq!(text.token_of_word(3), "calendar-link,");
    }

    #[test]
    fn edges_are_the_punctuation_around_letters_and_digits() {
        assert_eq!(token_edges::leading("(\"hello"), "(\"");
        assert_eq!(token_edges::trailing("world!\")"), "!\")");
        assert_eq!(token_edges::leading("…"), "");
        assert_eq!(token_edges::trailing("…"), "");
    }
}
