//! Finding and replacing every occurrence of a string, as Foundation does it for Swift's `String`.

use std::ops::Range;

use super::{canonically_equal, character_indices, characters};

/// The byte ranges of the occurrences of `needle` in `text`, left to right and never overlapping,
/// each starting and ending on character boundaries and matched character by character by
/// canonical equivalence: where `components(separatedBy:)` splits `text` and
/// `replacingOccurrences(of:with:)` replaces. Empty for an empty needle.
pub fn ranges_of(text: &str, needle: &str) -> Vec<Range<usize>> {
    let wanted: Vec<&str> = characters(needle).collect();
    if wanted.is_empty() {
        return Vec::new();
    }
    let found: Vec<(usize, &str)> = character_indices(text).collect();
    let mut ranges = Vec::new();
    let mut index = 0;
    while index + wanted.len() <= found.len() {
        let window = &found[index..index + wanted.len()];
        if window
            .iter()
            .zip(&wanted)
            .all(|(&(_, character), expected)| canonically_equal(character, expected))
        {
            let (last, character) = window[window.len() - 1];
            ranges.push(window[0].0..last + character.len());
            index += wanted.len();
        } else {
            index += 1;
        }
    }
    ranges
}

/// `text` with every occurrence of `target` replaced by `replacement`, as
/// `replacingOccurrences(of:with:)`: occurrences as [`ranges_of`] finds them, so an empty target
/// replaces nothing.
pub fn replacing_occurrences(text: &str, target: &str, replacement: &str) -> String {
    let mut replaced = String::with_capacity(text.len());
    let mut copied_up_to = 0;
    for range in ranges_of(text, target) {
        replaced.push_str(&text[copied_up_to..range.start]);
        replaced.push_str(replacement);
        copied_up_to = range.end;
    }
    replaced.push_str(&text[copied_up_to..]);
    replaced
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_every_occurrence_without_overlap() {
        assert_eq!(ranges_of("⟦S1⟧ then ⟦S1⟧ and ⟦S11⟧", "⟦S1⟧"), [0..8, 14..22]);
        let bounds = |text: &str, needle: &str| {
            ranges_of(text, needle)
                .into_iter()
                .map(|range| (range.start, range.end))
                .collect::<Vec<_>>()
        };
        assert_eq!(bounds("aaa", "aa"), [(0, 2)]);
        assert_eq!(ranges_of("anything", ""), []);
        assert_eq!(ranges_of("", "x"), []);
    }

    /// A match must cover whole characters: a token with a combining mark on its last bracket is
    /// a different character, and is not found, as Foundation leaves it.
    #[test]
    fn matches_whole_characters_by_canonical_equivalence() {
        assert_eq!(ranges_of("a⟦S1⟧\u{301}b⟦S1⟧", "⟦S1⟧").len(), 1);
        assert_eq!(ranges_of("caf\u{E9} cafe\u{301}", "cafe\u{301}"), [0..5, 6..12]);
        assert_eq!(ranges_of("cafe\u{301}", "cafe"), []);
    }

    #[test]
    fn replaces_every_occurrence() {
        assert_eq!(
            replacing_occurrences("send ⟦S1⟧ to ⟦S1⟧", "⟦S1⟧", "S1"),
            "send S1 to S1"
        );
        assert_eq!(
            replacing_occurrences("a⟦S1⟧\u{301}b⟦S1⟧", "⟦S1⟧", "X"),
            "a⟦S1⟧\u{301}bX"
        );
        assert_eq!(replacing_occurrences("abc", "", "X"), "abc");
    }
}
