use lt_shared::edit_distance;
use lt_shared::swift_string::{self as s};
use lt_shared::token_edges;

use crate::Snippet;

/// A snippet's trigger prepared for matching.
#[derive(Clone, Debug)]
pub(crate) struct TriggerPattern {
    pub words: Vec<String>,
    /// Punctuation before the trigger's first word that belongs to the trigger ("@" in "@home").
    leading_punctuation: String,
    /// Punctuation after the trigger's last word that belongs to the trigger ("++" in "c++").
    trailing_punctuation: String,
    pub snippet: Snippet,
}

impl TriggerPattern {
    /// `None` when the trigger has no words, which could never match.
    pub fn new(snippet: &Snippet) -> Option<Self> {
        let words = snippet.trigger_words();
        if words.is_empty() {
            return None;
        }
        let word_tokens: Vec<&str> = s::split_whitespace(&snippet.trigger)
            .into_iter()
            .filter(|token| !edit_distance::normalize(token).is_empty())
            .collect();
        Some(Self {
            words,
            leading_punctuation: word_tokens
                .first()
                .map_or("", |token| token_edges::leading(token))
                .to_owned(),
            trailing_punctuation: word_tokens
                .last()
                .map_or("", |token| token_edges::trailing(token))
                .to_owned(),
            snippet: snippet.clone(),
        })
    }

    /// The part of a matched token's leading punctuation that stays in the text, next to the
    /// placeholder: an opening bracket or quote, but not punctuation the trigger itself starts with.
    pub fn kept_leading<'t>(&self, token: &'t str) -> &'t str {
        let leading = token_edges::leading(token);
        if self.leading_punctuation.is_empty() || !s::has_suffix(leading, &self.leading_punctuation) {
            return leading;
        }
        s::drop_last(leading, s::character_count(&self.leading_punctuation))
    }

    /// The part of a matched token's trailing punctuation that stays in the text: a full stop or
    /// comma, but not punctuation the trigger itself ends with.
    pub fn kept_trailing<'t>(&self, token: &'t str) -> &'t str {
        let trailing = token_edges::trailing(token);
        if self.trailing_punctuation.is_empty() || !s::has_prefix(trailing, &self.trailing_punctuation) {
            return trailing;
        }
        s::drop_first(trailing, s::character_count(&self.trailing_punctuation))
    }
}
