use lt_shared::swift_string::{self as s};

use crate::VocabularyEntry;
use crate::distinctive_casing;
use crate::phrase_matcher::{PhraseMatcher, PhrasePattern};
use crate::word_tokenizer;

/// Rewrites known mishearings in a transcript to their canonical spelling, before cleanup.
///
/// This is the deterministic half of the vocabulary: a spoken variant the user listed is always
/// fixed, even at cleanup level None and even when the language model would have missed it.
///
/// Matching works on whole words ("git hub" never matches inside "git hubs"), ignores case, and
/// ignores the punctuation around a phrase, which stays where it was: "I work at nerd storm."
/// becomes "I work at Nerdstorm.". A phrase's words must be separated by spaces or hyphens only.
/// Where phrases overlap, the leftmost wins, and at the same position the longest wins. A
/// possessive "'s" on the last word is kept ("git hub's" becomes "GitHub's").
///
/// A term with distinctive casing ("GitHub", "iPhone", "Qwen3") is also re-cased where it appears
/// in other casing; plain words, all-capital acronyms and plain words next to a number never are.
#[derive(Clone, Debug, Default)]
pub struct VocabularyReplacer {
    terms: Vec<String>,
    matcher: PhraseMatcher,
}

impl VocabularyReplacer {
    /// Entries are used in order: where two claim the same phrase, the first wins. Entries without
    /// a term are ignored. Each entry is sanitised first (see [`VocabularyEntry::sanitized`]).
    pub fn new(entries: &[VocabularyEntry]) -> Self {
        let mut terms = Vec::new();
        let mut patterns = Vec::new();
        for entry in entries.iter().map(VocabularyEntry::sanitized) {
            if entry.term.is_empty() {
                continue;
            }
            let term_index = terms.len();
            let mut phrases = entry.spoken_variants;
            if distinctive_casing::is_distinctive_term(&entry.term) {
                phrases.push(entry.term.clone());
            }
            patterns.extend(phrases.iter().map(|phrase| PhrasePattern {
                keys: word_tokenizer::keys(phrase),
                term_index,
            }));
            terms.push(entry.term);
        }
        Self {
            terms,
            matcher: PhraseMatcher::new(patterns),
        }
    }

    /// `text` with every listed spoken variant replaced by its term. Text with nothing to replace
    /// is returned as it came in.
    pub fn apply(&self, text: &str) -> String {
        if self.matcher.is_empty() {
            return text.to_owned();
        }
        let words = word_tokenizer::words(text);
        let mut result = String::with_capacity(text.len());
        let mut copied_up_to = 0;
        let mut replacements = 0;
        let mut index = 0;
        while index < words.len() {
            let Some(found) = self.matcher.longest_match(index, &words, text) else {
                index += 1;
                continue;
            };
            let term = &self.terms[found.term_index];
            if !s::canonically_equal(&text[found.range.clone()], term) {
                result.push_str(&text[copied_up_to..found.range.start]);
                result.push_str(term);
                copied_up_to = found.range.end;
                replacements += 1;
            }
            index += found.word_count;
        }
        if replacements == 0 {
            return text.to_owned();
        }
        result.push_str(&text[copied_up_to..]);
        tracing::debug!("Replaced {replacements} vocabulary phrase(s)");
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replaces_variants_and_recases_distinctive_terms() {
        let replacer = VocabularyReplacer::new(&[
            VocabularyEntry::new("Nerdstorm", &["nerd storm"]),
            VocabularyEntry::new("GitHub", &["git hub"]),
            VocabularyEntry::new("Go", &["go"]),
        ]);
        assert_eq!(replacer.apply("I work at nerd storm."), "I work at Nerdstorm.");
        assert_eq!(
            replacer.apply("git hub's and github, nerd, storm"),
            "GitHub's and GitHub, nerd, storm"
        );
        assert_eq!(replacer.apply("let's go"), "let's go");
        assert_eq!(replacer.apply("git ⟦S1⟧ hub"), "git ⟦S1⟧ hub");
    }
}
