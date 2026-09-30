use std::collections::HashMap;

use lt_shared::swift_string::{self as s};

use crate::VocabularyEntry;
use crate::phrase_matcher::{PhraseMatcher, PhrasePattern};
use crate::term_similarity::TermSimilarity;
use crate::word_tokenizer;

/// Picks which vocabulary terms to list in the cleanup prompt, most relevant first.
///
/// The prompt has room for a limited number of terms (the app passes 50): every extra term costs
/// prompt tokens and latency on a small model, and a long list dilutes the ones that matter. The
/// terms that matter most are those the speaker actually said, then those the transcript nearly
/// contains (a mishearing nobody listed as a variant, which the model can still fix), and only then
/// the rest, to fill the remaining room in the order the user added them.
#[derive(Clone, Debug)]
pub struct VocabularySelector {
    terms: Vec<String>,
    matcher: PhraseMatcher,
    similarity: TermSimilarity,
}

impl VocabularySelector {
    /// - `entries`: the vocabulary in stored order, sanitised here as the replacer does (see
    ///   [`VocabularyEntry::sanitized`]) so the prompt lists the stored spelling. Entries whose
    ///   terms differ only in casing are merged under the first, so no term is listed twice.
    /// - `similarity_threshold`: the lowest [`normalized_similarity`] (0...1) between a term or
    ///   variant and a word or adjacent word pair of the text for the term to count as nearly said.
    ///   Lower values admit more distant mishearings, and cost more: the search can skip less. In
    ///   an optimised build on an Apple M4 Pro, 1,000 terms against a 300-word dictation take
    ///   about 20 ms at 0.8 but about 0.1 s at 0.5 (see `TermSimilarity`).
    ///
    /// [`normalized_similarity`]: lt_shared::edit_distance::normalized_similarity
    pub fn new(entries: &[VocabularyEntry], similarity_threshold: f64) -> Self {
        let mut terms: Vec<String> = Vec::new();
        let mut phrases_by_term: Vec<Vec<String>> = Vec::new();
        let mut index_by_lowercased_term: HashMap<String, usize> = HashMap::new();
        for entry in entries.iter().map(VocabularyEntry::sanitized) {
            if entry.term.is_empty() {
                continue;
            }
            let lowercased = s::canonical_key(&s::lowercased(&entry.term)).into_owned();
            let index = match index_by_lowercased_term.get(&lowercased) {
                Some(&existing) => existing,
                None => {
                    let index = terms.len();
                    index_by_lowercased_term.insert(lowercased, index);
                    phrases_by_term.push(vec![entry.term.clone()]);
                    terms.push(entry.term);
                    index
                }
            };
            phrases_by_term[index].extend(entry.spoken_variants);
        }
        let patterns = phrases_by_term
            .iter()
            .enumerate()
            .flat_map(|(term_index, phrases)| {
                phrases.iter().map(move |phrase| PhrasePattern {
                    keys: word_tokenizer::keys(phrase),
                    term_index,
                })
            })
            .collect();
        Self {
            terms,
            matcher: PhraseMatcher::new(patterns),
            similarity: TermSimilarity::new(&phrases_by_term, similarity_threshold),
        }
    }

    /// Up to `limit` canonical terms for a prompt about `text`, without duplicates:
    ///
    /// 1. terms whose spelling or a variant occurs in the text (whole words, any casing), in the
    ///    order they occur;
    /// 2. terms similar to a word or adjacent word pair of the text, most similar first;
    /// 3. every other term, in stored order.
    ///
    /// Ties keep the stored order, so the same text always yields the same list.
    pub fn relevant_terms(&self, text: &str, limit: usize) -> Vec<String> {
        if limit == 0 || self.terms.is_empty() {
            return Vec::new();
        }
        let mut selection = Selection::new(self.terms.len(), limit);

        let words = word_tokenizer::words(text);
        for start in 0..words.len() {
            for found in self.matcher.all_matches(start, &words, text) {
                selection.add(found.term_index);
                if selection.is_full() {
                    return selection.terms(&self.terms);
                }
            }
        }

        for index in self.similarity.similar_terms(text, |index| selection.contains(index)) {
            selection.add(index);
            if selection.is_full() {
                return selection.terms(&self.terms);
            }
        }

        for index in 0..self.terms.len() {
            selection.add(index);
            if selection.is_full() {
                break;
            }
        }
        selection.terms(&self.terms)
    }
}

/// The terms chosen so far, in order, up to the limit.
struct Selection {
    chosen: Vec<usize>,
    is_chosen: Vec<bool>,
    limit: usize,
}

impl Selection {
    fn new(term_count: usize, limit: usize) -> Self {
        Self {
            chosen: Vec::new(),
            is_chosen: vec![false; term_count],
            limit,
        }
    }

    fn is_full(&self) -> bool {
        self.chosen.len() >= self.limit
    }

    fn contains(&self, index: usize) -> bool {
        self.is_chosen[index]
    }

    fn add(&mut self, index: usize) {
        if self.is_chosen[index] || self.is_full() {
            return;
        }
        self.is_chosen[index] = true;
        self.chosen.push(index);
    }

    fn terms(&self, terms: &[String]) -> Vec<String> {
        self.chosen.iter().map(|&index| terms[index].clone()).collect()
    }
}

/// As the Mac app's `VocabularySelectorTests`.
#[cfg(test)]
mod tests {
    use lt_shared::{edit_distance, placeholder_token};

    use super::*;

    /// The app's default threshold, for the tests that don't choose one.
    const THRESHOLD: f64 = 0.8;

    fn entry(term: &str) -> VocabularyEntry {
        VocabularyEntry::new(term, &[])
    }

    #[test]
    fn terms_that_occur_come_first_in_the_order_they_occur() {
        let selector = VocabularySelector::new(
            &[
                entry("Alpha"),
                VocabularyEntry::new("Nerdstorm", &["nerd storm"]),
                VocabularyEntry::new("GitHub", &["git hub"]),
                entry("Zeta"),
            ],
            THRESHOLD,
        );
        assert_eq!(
            selector.relevant_terms("push to git hub, then tell nerd storm", 10),
            ["GitHub", "Nerdstorm", "Alpha", "Zeta"]
        );
    }

    #[test]
    fn a_term_occurs_in_any_casing() {
        let selector = VocabularySelector::new(&[entry("Alpha"), entry("Swift")], THRESHOLD);
        assert_eq!(selector.relevant_terms("A SWIFT reply.", 10), ["Swift", "Alpha"]);
    }

    #[test]
    fn similar_terms_follow_most_similar_first() {
        let selector = VocabularySelector::new(&[entry("Postgres"), entry("Kafka"), entry("Kubernetes")], 0.75);
        // "kubernetis" is 0.9 similar to "Kubernetes", "kafca" 0.8 to "Kafka".
        assert_eq!(
            selector.relevant_terms("we run kubernetis and kafca", 10),
            ["Kubernetes", "Kafka", "Postgres"]
        );
    }

    /// A name misheard as two words is only similar as a pair: "nerd storm" to "Nerdstorm".
    #[test]
    fn adjacent_word_pairs_count_as_candidates() {
        let selector = VocabularySelector::new(&[entry("Alpha"), entry("Nerdstorm")], 0.85);
        assert_eq!(
            selector.relevant_terms("we met at nerd storm", 10),
            ["Nerdstorm", "Alpha"]
        );
    }

    #[test]
    fn variants_count_for_similarity() {
        let selector = VocabularySelector::new(
            &[entry("Alpha"), VocabularyEntry::new("Siobhan", &["shivon"])],
            THRESHOLD,
        );
        assert_eq!(selector.relevant_terms("ask shivan", 10), ["Siobhan", "Alpha"]);
    }

    /// The threshold is compared with `edit_distance::normalized_similarity`, inclusive.
    #[test]
    fn the_threshold_is_inclusive() {
        let entries = [entry("Alpha"), entry("Kafka")];
        let similarity = edit_distance::normalized_similarity("Kafka", "kafca");
        assert_eq!(
            VocabularySelector::new(&entries, similarity).relevant_terms("kafca", 10),
            ["Kafka", "Alpha"]
        );
        assert_eq!(
            VocabularySelector::new(&entries, similarity + 0.01).relevant_terms("kafca", 10),
            ["Alpha", "Kafka"]
        );
    }

    /// Equally similar terms keep the stored order.
    #[test]
    fn ties_keep_stored_order() {
        for (terms, expected) in [
            (["Bert", "Bart"], ["Bert", "Bart"]),
            (["Bart", "Bert"], ["Bart", "Bert"]),
        ] {
            let entries: Vec<VocabularyEntry> = terms.into_iter().map(entry).collect();
            let selector = VocabularySelector::new(&entries, 0.7);
            assert_eq!(selector.relevant_terms("bort", 10), expected, "{terms:?}");
        }
    }

    #[test]
    fn the_rest_follows_in_stored_order_up_to_the_limit() {
        let entries: Vec<VocabularyEntry> = (0..60).map(|index| entry(&format!("Term{index:02}"))).collect();
        let selector = VocabularySelector::new(&entries, 0.9);
        let terms = selector.relevant_terms("about term59", 50);
        assert_eq!(terms.len(), 50);
        let expected: Vec<String> = std::iter::once("Term59".to_owned())
            .chain((0..49).map(|index| format!("Term{index:02}")))
            .collect();
        assert_eq!(terms, expected);
    }

    #[test]
    fn terms_that_occur_fill_a_small_limit_first() {
        let selector = VocabularySelector::new(&[entry("Alpha"), entry("Kafka"), entry("GitHub")], THRESHOLD);
        assert_eq!(selector.relevant_terms("github and kafca", 1), ["GitHub"]);
        assert_eq!(selector.relevant_terms("github and kafca", 2), ["GitHub", "Kafka"]);
    }

    /// A limit below one selects nothing. The Mac app's test also passes -1, which a `usize`
    /// limit can't hold.
    #[test]
    fn a_limit_below_one_selects_nothing() {
        let selector = VocabularySelector::new(&[entry("GitHub")], THRESHOLD);
        assert!(selector.relevant_terms("github", 0).is_empty());
    }

    #[test]
    fn no_entries_select_nothing() {
        assert!(
            VocabularySelector::new(&[], THRESHOLD)
                .relevant_terms("anything", 50)
                .is_empty()
        );
    }

    #[test]
    fn a_term_is_listed_once_however_often_it_matches() {
        let selector = VocabularySelector::new(&[VocabularyEntry::new("GitHub", &["git hub"])], THRESHOLD);
        assert_eq!(selector.relevant_terms("github and git hub and gitub", 10), ["GitHub"]);
    }

    #[test]
    fn entries_with_the_same_term_are_merged() {
        let selector = VocabularySelector::new(
            &[
                VocabularyEntry::new("GitHub", &["git hub"]),
                VocabularyEntry::new("github", &["gid hub"]),
                entry("Alpha"),
            ],
            THRESHOLD,
        );
        assert_eq!(selector.relevant_terms("on gid hub", 10), ["GitHub", "Alpha"]);
    }

    /// A snippet placeholder is not speech: "⟦S1⟧" must not make the term "S1" look said, neither
    /// as a match nor as a similar word.
    #[test]
    fn placeholders_do_not_count_as_words() {
        let selector = VocabularySelector::new(&[entry("Alpha"), entry("S1")], THRESHOLD);
        let text = format!("send {} now", placeholder_token::make(1));
        assert_eq!(selector.relevant_terms(&text, 10), ["Alpha", "S1"]);
    }

    /// Punctuation between two words does not stop them forming a pair for similarity: the list
    /// only ranks terms for the prompt, so recall matters more than precision.
    #[test]
    fn similarity_uses_words_across_punctuation() {
        let selector = VocabularySelector::new(&[entry("Alpha"), entry("Nerdstorm")], 0.85);
        assert_eq!(selector.relevant_terms("a nerd, storm", 10), ["Nerdstorm", "Alpha"]);
    }

    /// Entries read from a hand-edited file have not been sanitised by the store.
    #[test]
    fn terms_are_listed_as_they_would_be_stored() {
        let selector = VocabularySelector::new(&[entry("  Visual\n Studio   Code "), entry("Alpha")], THRESHOLD);
        assert_eq!(selector.relevant_terms("", 10), ["Visual Studio Code", "Alpha"]);
    }

    #[test]
    fn empty_text_lists_terms_in_stored_order() {
        let selector = VocabularySelector::new(&[entry("Zeta"), entry("Alpha")], THRESHOLD);
        assert_eq!(selector.relevant_terms("", 10), ["Zeta", "Alpha"]);
    }
}
