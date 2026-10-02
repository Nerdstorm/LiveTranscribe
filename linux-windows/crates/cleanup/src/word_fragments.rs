use std::collections::HashSet;

use lt_shared::swift_string::{self as s};

use crate::GuardPolicy;
use crate::self_repair::{SaidWord, said_words};
use crate::word_forms;
use crate::words::WordSet;

/// Fewest letters the whole word has beyond its fragment, so that a word and its plural or another
/// short form of it ("plan plans", "test tests") are never taken for one.
pub(crate) const MIN_ADDED_LETTERS: usize = 2;

/// Finds the start of a word the speaker broke off and then said in full, which speech-to-text
/// writes as a word of its own: "She wants few ex expenses", "we should con consider", "send the
/// rep report". Cleanup rightly drops it, so both checks let it go: Deep's (`SelfRepair`) and the
/// others' (`DroppedWords`, `ContentWords`). As the Mac app's `WordFragments`.
///
/// A said word is a fragment when the next word said in its sentence starts with it and has at
/// least [`MIN_ADDED_LETTERS`] letters more ("rep" → "report"), whatever the capitals, and it is
/// all letters, so "ex-" counts once its hyphen is gone. It is never a word that starts a longer
/// one by chance and says something of its own: a function word ("for forty", "to tomorrow", "so
/// soon", "the theory", "an another"), a negation ("not nothing"), a number, a unit or a word of
/// time; nor a name or a correction cue, nor the last word of a sentence ("Call the rep. Report
/// it.").
///
/// What it can't tell apart is a word that carries meaning and happens to start the next one:
/// "car" in "the car carpet" is a fragment of "carpet", so an answer that drops it is accepted.
/// Such pairs are rare in speech, and the model has no reason to drop the word.
#[derive(Clone, Debug)]
pub(crate) struct WordFragments {
    function_words: WordSet,
    negations: WordSet,
}

impl WordFragments {
    pub(crate) fn new(policy: &GuardPolicy) -> Self {
        Self {
            function_words: WordSet::normalized(&policy.function_words),
            negations: WordSet::normalized(&policy.negations),
        }
    }

    /// The indices of the normalised words of `text` ([`crate::words::normalized_words`]) that are
    /// fragments of the word after them, with its sentences and names read as [`said_words`] reads
    /// them. `placeholders` are the normalised placeholder tokens.
    pub(crate) fn indices_in_text(&self, text: &str, placeholders: &WordSet) -> HashSet<usize> {
        self.indices(&said_words(text, &self.function_words, placeholders))
    }

    /// The indices of the words in `said` that are fragments of the word after them.
    pub(crate) fn indices(&self, said: &[SaidWord]) -> HashSet<usize> {
        said.windows(2)
            .enumerate()
            .filter(|(_, pair)| {
                let word = &pair[0];
                !word.ends_sentence && !word.is_name && !word.is_cue && self.is_fragment(&word.word, &pair[1].word)
            })
            .map(|(index, _)| index)
            .collect()
    }

    /// Whether `word` is the start of `next`, broken off. Both are normalised words.
    pub(crate) fn is_fragment(&self, word: &str, next: &str) -> bool {
        let length = s::character_count(word);
        if length == 0
            || !s::characters(word).all(s::is_letter)
            || s::character_count(next) < length + MIN_ADDED_LETTERS
            || !s::has_prefix(next, word)
        {
            return false;
        }
        !self.function_words.contains(word)
            && !self.negations.contains(word)
            && !word_forms::is_number(word)
            && !word_forms::is_unit_word(word)
            && !word_forms::is_time_word(word)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fragments(text: &str) -> HashSet<usize> {
        WordFragments::new(&GuardPolicy::default()).indices_in_text(text, &WordSet::default())
    }

    #[test]
    fn the_start_of_a_word_broken_off_and_said_again_in_full_is_a_fragment() {
        for (text, index) in [
            ("She wants few ex expenses paid back.", 3),
            ("We should con consider the budget first.", 2),
            ("can you send the rep report by friday", 4),
            ("We should con- consider the budget first.", 2),
            ("Con consider the budget first.", 0),
        ] {
            assert_eq!(fragments(text), HashSet::from([index]), "{text}");
        }
    }

    #[test]
    fn a_word_that_starts_the_next_by_chance_or_across_a_sentence_is_not_one() {
        for text in [
            // Function words.
            "wait for forty minutes",
            "move it to tomorrow",
            "so soon",
            "the theory",
            "an another",
            // A negation, a number, a unit and a word of time.
            "there is not nothing left",
            "bring ten tennis balls",
            "a cent centrally",
            "the week weekend",
            // Across the end of a sentence.
            "We met the new rep. Reports are due on Monday.",
            // Not the start of the next word, or only one letter short of it.
            "can you send the rap report by friday",
            "check the plan plans",
            // A name.
            "Ask Ed Edwards about it.",
        ] {
            assert!(fragments(text).is_empty(), "{text}");
        }
    }
}
