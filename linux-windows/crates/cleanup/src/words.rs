//! Words as the output guard compares them: normalised and split as `EditDistance` does it, and
//! equal when they are canonically equivalent, as Swift's `==` and `Set<String>` treat them.

use std::collections::HashSet;

use lt_shared::edit_distance;
use lt_shared::swift_string::{self as s};

/// The normalised words of `text` ([`edit_distance::normalize`], then split on whitespace).
pub(crate) fn normalized_words(text: &str) -> Vec<String> {
    edit_distance::words(&edit_distance::normalize(text))
        .into_iter()
        .map(str::to_owned)
        .collect()
}

/// Whether two words are the same word, as Swift's `==` on strings.
pub(crate) fn same(a: &str, b: &str) -> bool {
    s::canonically_equal(a, b)
}

/// Whether `words` begins with the words of `prefix`, as Swift's `starts(with:)` on arrays of
/// strings.
pub(crate) fn starts_with(words: &[String], prefix: &[String]) -> bool {
    words.len() >= prefix.len() && words.iter().zip(prefix).all(|(word, expected)| same(word, expected))
}

/// A set of words that finds a word canonically equivalent to one it holds, as Swift's
/// `Set<String>` does.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct WordSet(HashSet<String>);

impl WordSet {
    pub(crate) fn new<I>(words: I) -> Self
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        Self(
            words
                .into_iter()
                .map(|word| s::canonical_key(word.as_ref()).into_owned())
                .collect(),
        )
    }

    /// The set of each word normalised, as `Set(words.map(EditDistance.normalize))`.
    pub(crate) fn normalized<I>(words: I) -> Self
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        Self::new(words.into_iter().map(|word| edit_distance::normalize(word.as_ref())))
    }

    pub(crate) fn contains(&self, word: &str) -> bool {
        self.0.contains(s::canonical_key(word).as_ref())
    }

    /// Adds every word of `other`, as `formUnion(_:)`.
    pub(crate) fn form_union(&mut self, other: &WordSet) {
        self.0.extend(other.0.iter().cloned());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_are_normalised() {
        assert_eq!(
            normalized_words("Hi, John — it\u{2019}s ⟦S1⟧!"),
            ["hi", "john", "it's", "s1"]
        );
        assert!(normalized_words(" … ").is_empty());
    }

    #[test]
    fn equal_words_are_canonically_equivalent() {
        let set = WordSet::new(["caf\u{E9}"]);
        assert!(set.contains("cafe\u{301}"));
        assert!(!set.contains("cafe"));
        assert!(same("cafe\u{301}", "caf\u{E9}"));
        assert!(WordSet::normalized(["⟦S1⟧", "Um,"]).contains("s1"));
        assert!(starts_with(
            &["sure".to_owned(), "thing".to_owned()],
            &["sure".to_owned()]
        ));
        assert!(!starts_with(
            &["sure".to_owned()],
            &["sure".to_owned(), "thing".to_owned()]
        ));
    }
}
