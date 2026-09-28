//! Capitalising the word that starts a sentence, a line or a list item.

use crate::swift_string::{self as s};

/// Characters skipped to reach the first word: opening quotes and brackets.
const OPENERS: [&str; 8] = ["\"", "'", "(", "[", "{", "\u{201C}", "\u{2018}", "\u{00AB}"];

/// `text` with the first letter of its first word uppercased.
///
/// Whitespace and opening quotes or brackets before the word are skipped ("\"so" becomes
/// "\"So"). A word that already has a capital ("iPhone", "eBay") stays as written, and so does
/// text that starts with anything else, such as a digit or an emoji.
pub fn capitalizing_first_word(text: &str) -> String {
    let Some(start) = s::first_index(text, |c| !s::is_whitespace(c) && !s::is_one_of(c, &OPENERS)) else {
        return text.to_owned();
    };
    let rest = &text[start..];
    let Some(first) = s::first_character(rest) else {
        return text.to_owned();
    };
    if !s::is_lowercase(first) {
        return text.to_owned();
    }
    let word = s::prefix_while(rest, |c| !s::is_whitespace(c));
    if s::any_character(word, s::is_uppercase) {
        return text.to_owned();
    }
    format!("{}{}{}", &text[..start], s::uppercased(first), &rest[first.len()..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capitalizes_the_first_word() {
        assert_eq!(capitalizing_first_word("so it begins"), "So it begins");
        assert_eq!(capitalizing_first_word("  \u{201C}so\u{201D}"), "  \u{201C}So\u{201D}");
        assert_eq!(capitalizing_first_word("iPhone first"), "iPhone first");
        assert_eq!(capitalizing_first_word("2 things"), "2 things");
        assert_eq!(capitalizing_first_word("éclair"), "Éclair");
        assert_eq!(capitalizing_first_word(""), "");
    }
}
