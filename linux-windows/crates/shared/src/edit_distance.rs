//! The word normalisation that phrase matching compares words in, and the Levenshtein distance
//! and similarity that cleanup's output guard measures changes with.

use crate::swift_string::{self, CharacterSet};

/// Minimum number of insertions, deletions and substitutions turning `source` into `target`.
pub fn levenshtein<T: PartialEq>(source: &[T], target: &[T]) -> usize {
    if source.is_empty() {
        return target.len();
    }
    if target.is_empty() {
        return source.len();
    }
    let mut previous: Vec<usize> = (0..=target.len()).collect();
    let mut current = vec![0; target.len() + 1];
    for (i, source_element) in source.iter().enumerate() {
        current[0] = i + 1;
        for (j, target_element) in target.iter().enumerate() {
            let substitution = previous[j] + usize::from(source_element != target_element);
            current[j + 1] = (previous[j + 1] + 1).min(current[j] + 1).min(substitution);
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[target.len()]
}

/// Similarity in 0...1 of two strings after [`normalize`]: `1 - distance / longer length`, in
/// characters.
///
/// Casing and punctuation are ignored, so the score reflects changes to the words themselves. A
/// character is a grapheme cluster, and two are the same when they are canonically equivalent, as
/// Swift's `Character` compares them.
pub fn normalized_similarity(lhs: &str, rhs: &str) -> f64 {
    let a = comparable_characters(&normalize(lhs));
    let b = comparable_characters(&normalize(rhs));
    let longer = a.len().max(b.len());
    if longer == 0 {
        return 1.0;
    }
    1.0 - levenshtein(&a, &b) as f64 / longer as f64
}

/// The characters of `text` in the form that compares equal exactly when Swift's `==` does.
fn comparable_characters(text: &str) -> Vec<String> {
    swift_string::characters(text)
        .map(|character| swift_string::canonical_key(character).into_owned())
        .collect()
}

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
        assert_eq!(normalize("Well-known, don\u{2019}t STOP!"), "well known don't stop");
    }

    #[test]
    fn splits_on_any_whitespace() {
        assert_eq!(words(" a\tb\n\nc "), ["a", "b", "c"]);
    }

    #[test]
    fn levenshtein_on_known_character_pairs() {
        let characters = |text: &str| text.chars().collect::<Vec<_>>();
        for (source, target, expected) in [
            ("kitten", "sitting", 3),
            ("flaw", "lawn", 2),
            ("", "abc", 3),
            ("abc", "", 3),
            ("same", "same", 0),
            ("", "", 0),
        ] {
            assert_eq!(
                levenshtein(&characters(source), &characters(target)),
                expected,
                "{source} → {target}"
            );
        }
    }

    #[test]
    fn word_distance_counts_whole_words() {
        let reference = ["the", "cat", "sat", "on", "the", "mat"];
        let hypothesis = ["the", "cat", "sat", "on", "mat", "today"];
        assert_eq!(levenshtein(&reference, &hypothesis), 2);
    }

    #[test]
    fn similarity_ignores_casing_and_punctuation() {
        assert_eq!(
            normalized_similarity("i think we should go", "I think we should go."),
            1.0
        );
        assert_eq!(normalized_similarity("", "…"), 1.0);
    }

    #[test]
    fn similarity_of_unrelated_text_is_low() {
        assert!(normalized_similarity("the meeting is on tuesday", "banana smoothie recipe") < 0.4);
    }

    /// Characters are grapheme clusters compared by canonical equivalence, as Swift compares
    /// them: "é" as one scalar and as "e" with a combining accent are one and the same.
    #[test]
    fn similarity_compares_characters_as_swift_does() {
        assert_eq!(normalized_similarity("caf\u{E9}", "cafe\u{301}"), 1.0);
        assert_eq!(normalized_similarity("cafe\u{301}", "cafe"), 0.75);
    }
}
