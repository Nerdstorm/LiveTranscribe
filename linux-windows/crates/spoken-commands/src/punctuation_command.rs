use std::ops::Range;

use lt_shared::phrase_grammar::{self, is_word_in};
use lt_shared::swift_string::{self as s};
use lt_shared::{InlineText, PhraseMatch, PhraseMatcher, Replacement, TokenizedText, token_edges};

/// A mark that attaches to the word before it.
#[derive(Clone, Copy, Debug)]
pub struct Mark {
    pub names: &'static [&'static [&'static str]],
    pub text: &'static str,
    /// Ends a sentence: the next word is capitalised.
    pub ends_sentence: bool,
}

/// An opening and a closing mark that enclose words.
#[derive(Clone, Copy, Debug)]
pub struct Pair {
    pub opening_names: &'static [&'static [&'static str]],
    pub closing_names: &'static [&'static [&'static str]],
    pub opening: &'static str,
    pub closing: &'static str,
}

pub const STANDARD_MARKS: [Mark; 5] = [
    Mark {
        names: &[&["question", "mark"]],
        text: "?",
        ends_sentence: true,
    },
    Mark {
        names: &[&["exclamation", "mark"], &["exclamation", "point"]],
        text: "!",
        ends_sentence: true,
    },
    Mark {
        names: &[&["full", "stop"]],
        text: ".",
        ends_sentence: true,
    },
    Mark {
        names: &[&["comma"]],
        text: ",",
        ends_sentence: false,
    },
    Mark {
        names: &[&["semicolon"], &["semi", "colon"]],
        text: ";",
        ends_sentence: false,
    },
];

/// Straight quotes, which suit code editors and terminals as well as prose.
pub const STANDARD_PAIRS: [Pair; 3] = [
    Pair {
        opening_names: &[
            &["open", "quote"],
            &["open", "quotes"],
            &["begin", "quote"],
            &["start", "quote"],
        ],
        closing_names: &[
            &["close", "quote"],
            &["close", "quotes"],
            &["end", "quote"],
            &["end", "quotes"],
        ],
        opening: "\"",
        closing: "\"",
    },
    Pair {
        opening_names: &[&["quote"]],
        closing_names: &[&["unquote"]],
        opening: "\"",
        closing: "\"",
    },
    Pair {
        opening_names: &[
            &["open", "bracket"],
            &["open", "paren"],
            &["open", "parenthesis"],
            &["open", "parentheses"],
        ],
        closing_names: &[
            &["close", "bracket"],
            &["close", "paren"],
            &["close", "parenthesis"],
            &["close", "parentheses"],
        ],
        opening: "(",
        closing: ")",
    },
];

/// Punctuation dictated by name: "is it ready question mark" → "is it ready?", "he said open
/// quote I'll be late close quote" → "he said "I'll be late"".
///
/// Only names people rarely say for their own sake are commands, and none after a determiner ("a
/// question mark", "the full stop"). "Period", "colon" and "dash" stay words: they are common
/// nouns. A comma or semicolon needs a word on each side. Quotes and brackets are commands only in
/// pairs, an opening one with a closing one later and words between, so a lone "end quote" or the
/// idiom "quote unquote" stays as said.
///
/// The mark is written into the text the model sees, not hidden behind a placeholder: the model
/// may still adjust it, as it does any punctuation.
#[derive(Clone, Debug)]
pub struct PunctuationCommand {
    marks: Vec<Mark>,
    pairs: Vec<Pair>,
}

impl Default for PunctuationCommand {
    fn default() -> Self {
        Self::new(STANDARD_MARKS.to_vec(), STANDARD_PAIRS.to_vec())
    }
}

impl PunctuationCommand {
    pub fn new(marks: Vec<Mark>, pairs: Vec<Pair>) -> Self {
        Self { marks, pairs }
    }

    fn mark_matches(&self, text: &TokenizedText) -> Vec<PhraseMatch> {
        let mut found = Vec::new();
        for position in 1..text.words().len() {
            if phrase_grammar::follows_determiner(position, text) {
                continue;
            }
            for mark in &self.marks {
                let Some(name) = longest_name(mark.names, position, text) else {
                    continue;
                };
                let end = position + name.len();
                // A comma or semicolon between words only: at the end it would dangle.
                if !mark.ends_sentence && end >= text.words().len() {
                    continue;
                }
                let inline = InlineText {
                    joins_previous: true,
                    replaces_preceding_punctuation: true,
                    capitalizes_next: mark.ends_sentence,
                    ..InlineText::new(mark.text)
                };
                let kept_trailing = phrase_grammar::trailing_after_clause_punctuation(text.token_of_word(end - 1));
                found.push(PhraseMatch {
                    kept_trailing,
                    ..PhraseMatch::new(position..end, Replacement::Inline(inline))
                });
            }
        }
        found
    }

    /// Openings paired with the next closing that has words between them; nested pairs of the
    /// same kind close innermost first.
    fn pair_matches(pair: &Pair, text: &TokenizedText) -> Vec<PhraseMatch> {
        let mut open: Vec<Range<usize>> = Vec::new();
        let mut found = Vec::new();
        let mut position = 0;
        while position < text.words().len() {
            if phrase_grammar::follows_determiner(position, text) {
                position += 1;
                continue;
            }
            if let Some(name) = longest_name(pair.closing_names, position, text)
                && let Some(opening) = open.last().cloned()
                && opening.end < position
            {
                open.pop();
                let closing = position..position + name.len();
                // Speech-to-text may write the mark as well as its name ("Open quote I will be
                // late." Close quote): the mark it wrote stands, so it is not written twice.
                let opening_written =
                    s::has_prefix(token_edges::leading(text.token_of_word(opening.end)), pair.opening);
                let closing_written = s::has_suffix(
                    token_edges::trailing(text.token_of_word(closing.start - 1)),
                    pair.closing,
                );
                let opening_text = if opening_written { "" } else { pair.opening };
                let closing_text = if closing_written { "" } else { pair.closing };
                found.push(PhraseMatch::new(
                    opening,
                    Replacement::Inline(InlineText {
                        joins_next: true,
                        ..InlineText::new(opening_text)
                    }),
                ));
                let kept_trailing = token_edges::trailing(text.token_of_word(closing.end - 1)).to_owned();
                let inline = InlineText {
                    joins_previous: true,
                    ..InlineText::new(closing_text)
                };
                position = closing.end;
                found.push(PhraseMatch {
                    kept_trailing,
                    ..PhraseMatch::new(closing, Replacement::Inline(inline))
                });
            } else if let Some(name) = longest_name(pair.opening_names, position, text)
                && !is_part_of_longer_name(position, text)
            {
                open.push(position..position + name.len());
                position += name.len();
            } else {
                position += 1;
            }
        }
        found
    }
}

impl PhraseMatcher for PunctuationCommand {
    fn matches(&self, text: &TokenizedText) -> Vec<PhraseMatch> {
        let mut found = self.mark_matches(text);
        for pair in &self.pairs {
            found.extend(Self::pair_matches(pair, text));
        }
        found
    }
}

/// The longest of `names` at `position`; the first listed among equally long ones.
fn longest_name(
    names: &'static [&'static [&'static str]],
    position: usize,
    text: &TokenizedText,
) -> Option<&'static [&'static str]> {
    let mut longest: Option<&'static [&'static str]> = None;
    for &name in names {
        if phrase_grammar::matches(name, position, text) && longest.is_none_or(|current| name.len() > current.len()) {
            longest = Some(name);
        }
    }
    longest
}

/// "quote" right after "open", "close", "end", "start" or "begin" belongs to that two-word name,
/// never to the "quote … unquote" pair.
fn is_part_of_longer_name(position: usize, text: &TokenizedText) -> bool {
    if position == 0 || !s::canonically_equal(&text.words()[position].text, "quote") {
        return false;
    }
    is_word_in(
        &text.words()[position - 1].text,
        &["open", "close", "end", "start", "begin"],
    )
}
