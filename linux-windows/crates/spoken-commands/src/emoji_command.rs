use std::sync::Arc;

use lt_shared::phrase_grammar::{self, is_word_in};
use lt_shared::swift_string::{self as s};
use lt_shared::{PhraseMatch, PhraseMatcher, Replacement, Role, TokenizedText, token_edges};

use crate::emoji_names::EmojiNames;

const KEYWORD: &str = "emoji";

/// Words after which the next word is a verb: "I love emoji" is about emoji.
const SUBJECTS: &[&str] = &[
    "i",
    "you",
    "we",
    "they",
    "he",
    "she",
    "it",
    "who",
    "people",
    "i'm",
    "you're",
    "we're",
    "they're",
    "he's",
    "she's",
    "it's",
    "i've",
    "you've",
    "we've",
    "they've",
    "i'd",
    "you'd",
    "we'd",
    "they'd",
    "i'll",
    "you'll",
    "we'll",
    "they'll",
    "do",
    "does",
    "did",
    "don't",
    "doesn't",
    "didn't",
    "will",
    "would",
    "can",
    "could",
    "should",
    "might",
    "must",
    "won't",
    "wouldn't",
    "can't",
    "couldn't",
    "shouldn't",
    "to",
    "not",
    "never",
    "really",
    "also",
    "just",
];

/// An emoji said by name: "hi emoji fireworks" → "Hi 🎆", "thanks heart emoji" → "Thanks ❤️".
///
/// The keyword "emoji" comes before the name or after it. Before is tried first, so in "happy
/// birthday emoji cake" the cake is the emoji; the name after the keyword is the longest run of
/// up to `max_name_words` words that names an emoji, so "emoji party popper see you" finds the
/// party popper. A name never runs across a comma or a full stop. "emoji" with no name next to it
/// stays a word.
///
/// Speech about emoji stays as said: nothing is replaced after a determiner ("an emoji party",
/// "the fire emoji"), and a name before the keyword is not taken when a pronoun or auxiliary
/// comes before it, which makes it a verb ("I love emoji", "we'd like emoji").
///
/// The emoji goes behind a placeholder, so the model neither drops it nor rewrites its name.
#[derive(Clone, Debug)]
pub struct EmojiCommand {
    names: Arc<EmojiNames>,
    max_name_words: usize,
}

impl Default for EmojiCommand {
    fn default() -> Self {
        Self::new(EmojiNames::standard(), 6)
    }
}

impl EmojiCommand {
    /// `max_name_words` is the longest name tried, in words ("face with tears of joy" is 5).
    pub fn new(names: Arc<EmojiNames>, max_name_words: usize) -> Self {
        Self { names, max_name_words }
    }

    /// "emoji fireworks": the longest name right after the keyword.
    fn name_after(&self, keyword: usize, text: &TokenizedText) -> Option<PhraseMatch> {
        let keyword_token = text.token_of_word(keyword);
        if phrase_grammar::ends_clause(keyword_token) || phrase_grammar::follows_determiner(keyword, text) {
            return None;
        }
        let longest = self.max_name_words.min(text.words().len() - keyword - 1);
        (1..=longest).rev().find_map(|count| {
            let name = keyword + 1..keyword + 1 + count;
            if !text.covers_whole_tokens(name.clone()) || !phrase_grammar::runs_on(name.clone(), text) {
                return None;
            }
            let words = text.words_in(name.clone());
            let emoji = self.names.emoji(&words)?;
            Some(PhraseMatch {
                words: keyword..name.end,
                replacement: placeholder(&words, emoji),
                kept_leading: token_edges::leading(keyword_token).to_owned(),
                kept_trailing: token_edges::trailing(text.token_of_word(name.end - 1)).to_owned(),
            })
        })
    }

    /// "heart emoji": the longest name right before the keyword.
    fn name_before(&self, keyword: usize, first_free_word: usize, text: &TokenizedText) -> Option<PhraseMatch> {
        let longest = self.max_name_words.min(keyword - first_free_word);
        (1..=longest).rev().find_map(|count| {
            let name = keyword - count..keyword;
            if !text.covers_whole_tokens(name.clone())
                || phrase_grammar::ends_clause(text.token_of_word(keyword - 1))
                || !phrase_grammar::runs_on(name.clone(), text)
                || phrase_grammar::follows_determiner(name.start, text)
                || follows_subject(name.start, text)
            {
                return None;
            }
            let words = text.words_in(name.clone());
            let emoji = self.names.emoji(&words)?;
            Some(PhraseMatch {
                words: name.start..keyword + 1,
                replacement: placeholder(&words, emoji),
                kept_leading: token_edges::leading(text.token_of_word(name.start)).to_owned(),
                kept_trailing: token_edges::trailing(text.token_of_word(keyword)).to_owned(),
            })
        })
    }
}

impl PhraseMatcher for EmojiCommand {
    fn matches(&self, text: &TokenizedText) -> Vec<PhraseMatch> {
        let mut found = Vec::new();
        // A name may not reuse words an earlier match took: "emoji heart emoji" is one heart.
        let mut first_free_word = 0;
        for keyword in 0..text.words().len() {
            if !is_keyword(keyword, text) || keyword < first_free_word {
                continue;
            }
            if let Some(phrase) = self
                .name_after(keyword, text)
                .or_else(|| self.name_before(keyword, first_free_word, text))
            {
                first_free_word = phrase.words.end;
                found.push(phrase);
            }
        }
        found
    }
}

fn is_keyword(index: usize, text: &TokenizedText) -> bool {
    let word = &text.words()[index];
    s::canonically_equal(&word.text, KEYWORD) && word.starts_token && word.ends_token
}

fn placeholder(name: &[&str], emoji: String) -> Replacement {
    let trigger = std::iter::once(KEYWORD)
        .chain(name.iter().copied())
        .collect::<Vec<_>>()
        .join(" ");
    Replacement::Placeholder {
        trigger,
        expansion: emoji,
        role: Role::Content,
    }
}

fn follows_subject(position: usize, text: &TokenizedText) -> bool {
    if position == 0 {
        return false;
    }
    let previous = &text.words()[position - 1];
    previous.ends_token
        && !phrase_grammar::ends_clause(text.token(previous.token))
        && is_word_in(&previous.text, SUBJECTS)
}
