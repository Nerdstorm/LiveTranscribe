//! The word normalisation that phrase matching compares words in.

use crate::swift_string::{self, CharacterSet};

/// Whitespace-separated words, ignoring empty runs.
pub fn words(text: &str) -> Vec<&str> {
    swift_string::split_whitespace(text)
}

/// Lowercases, turns hyphens and dashes into spaces, removes punctuation and symbols except
/// in-word apostrophes, and collapses whitespace.
pub fn normalize(text: &str) -> String {
    let lowered = swift_string::replacing_character(&swift_string::lowercased(text), "\u{2019}", "'");
    let mut kept = String::with_capacity(lowered.len());
    for scalar in lowered.chars() {
        if matches!(scalar, '-' | '\u{2014}' | '\u{2013}') {
            kept.push(' ');
        } else if scalar == '\''
            || !(CharacterSet::Punctuation.contains(scalar) || CharacterSet::Symbols.contains(scalar))
        {
            kept.push(scalar);
        }
    }
    words(&kept)
        .into_iter()
        .map(|word| word.trim_matches('\''))
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_case_punctuation_and_hyphens() {
        assert_eq!(normalize("My Calendar-Link!"), "my calendar link");
        assert_eq!(normalize("It\u{2019}s 'quoted' — ok"), "it's quoted ok");
        assert_eq!(normalize("C++ and C#"), "c and c");
        assert_eq!(normalize("…"), "");
        assert_eq!(normalize("ශ්‍රී ලංකාව."), "ශ්‍රී ලංකාව");
    }

    #[test]
    fn splits_on_any_whitespace() {
        assert_eq!(words(" a\tb\n\nc "), ["a", "b", "c"]);
    }
}
