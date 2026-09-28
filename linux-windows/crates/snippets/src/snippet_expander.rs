use std::collections::{HashMap, HashSet};

use lt_shared::swift_string::{self as s};
use lt_shared::{PhraseMatch, PhraseMatcher, Replacement, Role, TokenizedText, Word};

use crate::Snippet;
use crate::trigger_matching::TriggerPattern;

/// Finds spoken snippet triggers in a transcript and swaps them for placeholder tokens, so the
/// language model never sees (and never "fixes") a URL, an address or a signature.
///
/// Matching:
/// - whole words only, after [`lt_shared::edit_distance::normalize`], so casing and punctuation
///   do not matter ("My calendar-link!" matches "my calendar link") but "link" never matches
///   "linked";
/// - leftmost match first and, among matches starting at the same word, the longest;
/// - punctuation around the matched words that is not part of the trigger (a closing full stop,
///   an opening bracket) stays next to the placeholder: "Here's my calendar link." becomes
///   "Here's ⟦S1⟧.";
/// - a snippet with a trigger of no words, an empty expansion, or an earlier snippet's trigger is
///   ignored.
#[derive(Clone, Debug, Default)]
pub struct SnippetExpander {
    /// Patterns keyed by their first word, longest first, so the first one that matches at a
    /// position is the longest.
    patterns_by_first_word: HashMap<String, Vec<TriggerPattern>>,
}

impl SnippetExpander {
    /// Prepares the triggers once, so each dictation only pays for the matching itself. The first
    /// of two snippets with the same trigger wins.
    pub fn new(snippets: &[Snippet]) -> Self {
        let mut seen_triggers: HashSet<Vec<String>> = HashSet::new();
        let mut patterns: HashMap<String, Vec<TriggerPattern>> = HashMap::new();
        let mut ignored = 0;
        for snippet in snippets {
            let pattern = TriggerPattern::new(snippet).filter(|_| !snippet.expansion.is_empty());
            let Some(pattern) = pattern.filter(|pattern| seen_triggers.insert(canonical_words(&pattern.words))) else {
                ignored += 1;
                continue;
            };
            patterns
                .entry(s::canonical_key(&pattern.words[0]).into_owned())
                .or_default()
                .push(pattern);
        }
        // Ties need no order: two different triggers of the same length cannot both match at the
        // same position.
        for candidates in patterns.values_mut() {
            candidates.sort_by_key(|pattern| std::cmp::Reverse(pattern.words.len()));
        }
        if ignored > 0 {
            tracing::warn!(
                "Ignoring {ignored} snippets with an empty trigger, an empty expansion or a repeated trigger"
            );
        }
        Self {
            patterns_by_first_word: patterns,
        }
    }
}

impl PhraseMatcher for SnippetExpander {
    /// The longest trigger starting at each word, each a placeholder for its snippet's expansion.
    fn matches(&self, text: &TokenizedText) -> Vec<PhraseMatch> {
        if self.patterns_by_first_word.is_empty() {
            return Vec::new();
        }
        let mut found = Vec::new();
        for (position, word) in text.words().iter().enumerate() {
            if !word.starts_token {
                continue;
            }
            let Some(candidates) = self.patterns_by_first_word.get(s::canonical_key(&word.text).as_ref()) else {
                continue;
            };
            let Some(pattern) = candidates
                .iter()
                .find(|pattern| words_match(text.words(), position, &pattern.words))
            else {
                continue;
            };
            let end = position + pattern.words.len();
            let replacement = Replacement::Placeholder {
                trigger: pattern.snippet.trigger.clone(),
                expansion: pattern.snippet.expansion.clone(),
                role: Role::Content,
            };
            found.push(PhraseMatch {
                kept_leading: pattern.kept_leading(text.token_of_word(position)).to_owned(),
                kept_trailing: pattern.kept_trailing(text.token_of_word(end - 1)).to_owned(),
                ..PhraseMatch::new(position..end, replacement)
            });
        }
        found
    }
}

/// Whether `pattern` matches the words starting at `position` and ends at the end of a token.
fn words_match(words: &[Word], position: usize, pattern: &[String]) -> bool {
    let end = position + pattern.len();
    if end > words.len() || !words[end - 1].ends_token {
        return false;
    }
    pattern
        .iter()
        .zip(&words[position..end])
        .all(|(expected, word)| s::canonically_equal(expected, &word.text))
}

fn canonical_words(words: &[String]) -> Vec<String> {
    words.iter().map(|word| s::canonical_key(word).into_owned()).collect()
}

#[cfg(test)]
mod tests {
    use lt_shared::PhraseProtector;

    use super::*;

    #[test]
    fn replaces_triggers_with_placeholders() {
        let snippets = [
            Snippet::new("my calendar link", "https://cal.example.com/me"),
            Snippet::new("my link", "x"),
        ];
        let protector = PhraseProtector::new(vec![Box::new(SnippetExpander::new(&snippets))]);
        let protected = protector.protect("Here's (My calendar-link).");
        assert_eq!(protected.text(), "Here's (⟦S1⟧).");
        assert_eq!(protected.placeholders()[0].spoken, "My calendar-link");
        assert_eq!(protected.expanded(), "Here's (https://cal.example.com/me).");
    }
}
