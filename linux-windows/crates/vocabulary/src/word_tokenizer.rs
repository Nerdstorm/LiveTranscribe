use std::ops::Range;

use lt_shared::placeholder_token;
use lt_shared::swift_string::{self as s};

/// One word of a text, located in the original string so a match can be replaced in place.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TextWord {
    /// The word without the punctuation around it: from its first letter or digit to its last.
    /// Punctuation inside the word stays ("don't", "Node.js", "1,000").
    pub range: Range<usize>,
    /// The word as matching sees it: lowercased, with typographic apostrophes made plain.
    pub key: String,
    /// Whether only spaces and hyphens separate this word from the one before it. A comma, a
    /// full stop or a line break in between means the two words were not said as one phrase.
    pub joins_previous: bool,
}

/// Characters that separate words without breaking a phrase: spaces, tabs and hyphens, so
/// "nerd-storm" matches the variant "nerd storm". Line breaks are deliberately not included.
fn is_phrase_separator(character: &str) -> bool {
    (s::is_whitespace(character) && !s::is_newline(character))
        || s::is_one_of(character, &["-", "\u{2010}", "\u{2011}"])
}

/// Letters and digits start and end a word; anything else at the edges is punctuation.
fn is_word_character(character: &str) -> bool {
    s::is_letter(character) || s::is_number(character)
}

fn ends_chunk(character: &str) -> bool {
    is_phrase_separator(character)
        || s::is_newline(character)
        || s::canonically_equal(character, placeholder_token::OPENING)
}

/// Every word of `text`, in order, for vocabulary matching.
///
/// Placeholders (`⟦S1⟧`) for snippets and spoken commands are already in the text when the
/// replacer runs. They yield no words, so no vocabulary phrase can alter one and break what it
/// stands for.
pub(crate) fn words(text: &str) -> Vec<TextWord> {
    let characters: Vec<(usize, &str)> = s::character_indices(text).collect();
    let mut words = Vec::new();
    let mut gap_is_plain = true;
    let mut index = 0;
    while index < characters.len() {
        let character = characters[index].1;
        if is_phrase_separator(character) {
            index += 1;
            continue;
        }
        if s::is_newline(character) {
            gap_is_plain = false;
            index += 1;
            continue;
        }
        if s::canonically_equal(character, placeholder_token::OPENING)
            && let Some(closing) = (index..characters.len())
                .find(|&candidate| s::canonically_equal(characters[candidate].1, placeholder_token::CLOSING))
        {
            gap_is_plain = false;
            index = closing + 1;
            continue;
        }
        // A chunk runs to the next separator, line break or placeholder.
        let mut chunk_end = index + 1;
        while chunk_end < characters.len() && !ends_chunk(characters[chunk_end].1) {
            chunk_end += 1;
        }
        let chunk = &characters[index..chunk_end];
        let first = chunk.iter().position(|&(_, c)| is_word_character(c));
        let last = chunk.iter().rposition(|&(_, c)| is_word_character(c));
        if let (Some(first), Some(last)) = (first, last) {
            let range = chunk[first].0..chunk[last].0 + chunk[last].1.len();
            words.push(TextWord {
                key: key(&text[range.clone()]),
                range,
                joins_previous: gap_is_plain && first == 0,
            });
            gap_is_plain = last == chunk.len() - 1;
        } else {
            // A chunk of punctuation only ("…", "—", a lone comma).
            gap_is_plain = false;
        }
        index = chunk_end;
    }
    words
}

/// The keys of a phrase's words, the form in which variants and terms are compared.
pub(crate) fn keys(phrase: &str) -> Vec<String> {
    words(phrase).into_iter().map(|word| word.key).collect()
}

/// One string per phrase for de-duplication: "Nerd-storm." and "nerd storm" are the same phrase
/// to the matcher, so they share a key.
pub(crate) fn phrase_key(phrase: &str) -> String {
    keys(phrase).join(" ")
}

pub(crate) fn key(word: &str) -> String {
    s::replacing_character(&s::lowercased(word), "\u{2019}", "'")
}

/// Whether `word` (a matched word's key) is `key` followed by a possessive "'s", so "GitHub's" is
/// recognised as "GitHub" and keeps its "'s".
pub(crate) fn is_possessive(word: &str, key: &str) -> bool {
    s::canonically_equal(word, &format!("{key}'s"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_keep_their_positions_and_joins() {
        let text = "I work at nerd-storm. Git ⟦S1⟧ hub\nnow";
        let found: Vec<_> = words(text)
            .into_iter()
            .map(|w| (&text[w.range], w.key, w.joins_previous))
            .collect();
        assert_eq!(
            found,
            [
                ("I", "i".to_owned(), true),
                ("work", "work".to_owned(), true),
                ("at", "at".to_owned(), true),
                ("nerd", "nerd".to_owned(), true),
                ("storm", "storm".to_owned(), true),
                ("Git", "git".to_owned(), false),
                ("hub", "hub".to_owned(), false),
                ("now", "now".to_owned(), false),
            ]
        );
    }
}
