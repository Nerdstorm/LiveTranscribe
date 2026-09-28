use std::collections::HashSet;

use lt_shared::swift_string::{self as s};

use crate::word_tokenizer;

/// A word or name the user wants spelled their way, with the ways speech-to-text mishears it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VocabularyEntry {
    /// The canonical spelling, for example "Nerdstorm", "GitHub" or "Siobhan".
    pub term: String,
    /// What speech-to-text writes instead, for example "nerd storm" or "nerd store". Matched as
    /// whole words, ignoring case and the punctuation around them.
    pub spoken_variants: Vec<String>,
}

impl VocabularyEntry {
    pub fn new(term: &str, spoken_variants: &[&str]) -> Self {
        Self {
            term: term.to_owned(),
            spoken_variants: spoken_variants.iter().map(|&variant| variant.to_owned()).collect(),
        }
    }

    /// The entry as it is stored: whitespace trimmed and collapsed, and variants that are empty,
    /// repeated, or only the term in different casing or punctuation removed.
    ///
    /// A variant equal to the term would make the replacer re-case the term everywhere, which for
    /// a plain word ("Go", "Swift") corrupts ordinary speech. Variants are compared as the
    /// replacer sees them, so "Nerd storm." and "nerd storm" count as one.
    pub fn sanitized(&self) -> Self {
        let term = collapsing_whitespace(&self.term);
        let mut seen: HashSet<String> =
            HashSet::from([s::canonical_key(&word_tokenizer::phrase_key(&term)).into_owned()]);
        let mut variants = Vec::new();
        for variant in self
            .spoken_variants
            .iter()
            .map(|variant| collapsing_whitespace(variant))
        {
            let key = word_tokenizer::phrase_key(&variant);
            if key.is_empty() || !seen.insert(s::canonical_key(&key).into_owned()) {
                continue;
            }
            variants.push(variant);
        }
        Self {
            term,
            spoken_variants: variants,
        }
    }
}

fn collapsing_whitespace(text: &str) -> String {
    s::split_whitespace(text).join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizing_drops_repeats_and_the_term_itself() {
        let entry = VocabularyEntry::new("  Go ", &["go!", "Nerd  storm.", "nerd storm", "", "golang"]);
        assert_eq!(
            entry.sanitized(),
            VocabularyEntry::new("Go", &["Nerd storm.", "golang"])
        );
    }
}
