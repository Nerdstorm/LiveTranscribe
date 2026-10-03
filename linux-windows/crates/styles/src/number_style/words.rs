//! The text as [`NumberStyle`](super::NumberStyle) reads it: words, and what comes between them.

use std::ops::Range;

use lt_shared::swift_string::{self as s};

use crate::number_words as numbers;

/// One word of the text: a whole token, or one part of a hyphenated token ("twenty-one").
pub(super) struct Word<'a> {
    /// Lowercased, without the punctuation around it, in the form map keys take.
    pub(super) text: String,
    /// Byte range in the text.
    pub(super) range: Range<usize>,
    pub(super) starts_token: bool,
    /// The token mixes number words with others, "twenty-five-year-old": its number words end any
    /// number they continue.
    pub(super) in_mixed_token: bool,
    /// The punctuation after the word when it ends its token, such as the comma of "thousand,".
    pub(super) trailing: &'a str,
    /// A line break, punctuation on its own or the next token's opening punctuation comes after the
    /// word, or the text ends.
    pub(super) separated_from_next: bool,
}

impl Word<'_> {
    /// Nothing but a space comes between this word and the next.
    pub(super) fn runs_on(&self) -> bool {
        self.trailing.is_empty() && !self.separated_from_next
    }
}

/// The words of `text`, split at whitespace and hyphens, with what comes between them.
pub(super) fn words(text: &str) -> Vec<Word<'_>> {
    // Whitespace-delimited tokens, and whether a line break comes before each.
    let mut tokens: Vec<(Range<usize>, bool)> = Vec::new();
    let mut start: Option<usize> = None;
    let mut line_break = false;
    for (offset, character) in s::character_indices(text) {
        if s::is_whitespace(character) {
            if let Some(begin) = start.take() {
                tokens.push((begin..offset, line_break));
                line_break = false;
            }
            if s::is_newline(character) {
                line_break = true;
            }
        } else if start.is_none() {
            start = Some(offset);
        }
    }
    if let Some(begin) = start {
        tokens.push((begin..text.len(), line_break));
    }

    let mut words: Vec<Word> = Vec::new();
    for (range, after_line_break) in tokens {
        let token = &text[range.clone()];
        let first = s::first_index(token, is_word_character);
        let last = s::last_index(token, is_word_character);
        let (Some(first), Some(last)) = (first, last) else {
            // Punctuation on its own, such as a dash, ends a number.
            if let Some(previous) = words.last_mut() {
                previous.separated_from_next = true;
            }
            continue;
        };
        if (after_line_break || first > 0)
            && let Some(previous) = words.last_mut()
        {
            previous.separated_from_next = true;
        }
        let core = range.start + first..range.start + last.end;
        let parts = hyphenated_parts(text, core.clone());
        let texts: Vec<String> = parts
            .iter()
            .map(|part| s::canonical_key(&s::lowercased(&text[part.clone()])).into_owned())
            .collect();
        let mixed = texts.iter().any(|word| numbers::is_number_word(word))
            && !texts.iter().all(|word| numbers::is_number_word(word));
        let count = parts.len();
        for (offset, (part, word)) in parts.into_iter().zip(texts).enumerate() {
            let ends_token = offset == count - 1;
            words.push(Word {
                text: word,
                range: part,
                starts_token: offset == 0,
                in_mixed_token: mixed,
                trailing: if ends_token { &text[core.end..range.end] } else { "" },
                separated_from_next: false,
            });
        }
    }
    if let Some(last) = words.last_mut() {
        last.separated_from_next = true;
    }
    words
}

/// The parts of a hyphenated word ("twenty-one"), or the whole word when a part is empty.
fn hyphenated_parts(text: &str, core: Range<usize>) -> Vec<Range<usize>> {
    let mut parts = Vec::new();
    let mut part_start = core.start;
    for (offset, character) in s::character_indices(&text[core.clone()]) {
        if character == "-" {
            parts.push(part_start..core.start + offset);
            part_start = core.start + offset + character.len();
        }
    }
    parts.push(part_start..core.end);
    if parts.iter().any(Range::is_empty) {
        vec![core]
    } else {
        parts
    }
}

fn is_word_character(character: &str) -> bool {
    s::is_letter(character) || s::is_number(character)
}

/// The word before word `index` with only a space between, or `None`.
pub(super) fn text_before<'w>(index: usize, words: &'w [Word]) -> Option<&'w str> {
    (index > 0 && words[index - 1].runs_on()).then(|| words[index - 1].text.as_str())
}

/// The word after word `index` with only a space between, or `None`.
pub(super) fn text_after<'w>(index: usize, words: &'w [Word]) -> Option<&'w str> {
    (index + 1 < words.len() && words[index].runs_on()).then(|| words[index + 1].text.as_str())
}
