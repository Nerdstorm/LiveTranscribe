use std::collections::HashSet;

use lt_shared::sentence_case::capitalizing_first_word;
use lt_shared::swift_string::{self as s, CharacterSet};

/// Hesitation sounds that never carry meaning.
pub const STANDARD_FILLERS: [&str; 10] = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "hmmm"];

const SENTENCE_ENDERS: [&str; 4] = [".", "!", "?", "…"];

/// Removes hesitation fillers ("um", "uh", "er") from a transcript, deterministically.
///
/// Only standalone filler words go; words that merely contain one ("umbrella", "uh-oh") stay,
/// and ambiguous fillers ("like", "you know") are left to the speaker. A sentence-final
/// punctuation mark on a removed filler moves to the word before it, and a sentence that started
/// with a filler starts with a capital again.
#[derive(Clone, Debug)]
pub struct FillerRemover {
    fillers: HashSet<String>,
}

impl Default for FillerRemover {
    fn default() -> Self {
        Self::new(&STANDARD_FILLERS)
    }
}

impl FillerRemover {
    pub fn new(fillers: &[&str]) -> Self {
        let fillers = fillers
            .iter()
            .map(|filler| s::canonical_key(&s::lowercased(filler)).into_owned())
            .collect();
        Self { fillers }
    }

    pub fn removing_fillers(&self, text: &str) -> String {
        let mut kept: Vec<String> = Vec::new();
        let mut capitalize_next = false;
        for token in s::split_whitespace(text) {
            let core = s::lowercased(s::trimming(token, CharacterSet::Punctuation));
            if !self.fillers.contains(s::canonical_key(&core).as_ref()) {
                kept.push(if capitalize_next {
                    capitalizing_first_word(token)
                } else {
                    token.to_owned()
                });
                capitalize_next = false;
                continue;
            }
            let starts_sentence = kept.last().is_none_or(|last| ends_sentence(last));
            if starts_sentence && s::first_character(token).is_some_and(s::is_uppercase) {
                capitalize_next = true;
            }
            if let Some(ender) = s::characters(token).rev().find(|c| s::is_one_of(c, &SENTENCE_ENDERS))
                && let Some(last) = kept.pop()
            {
                kept.push(ending_sentence(&last, ender));
            }
        }
        kept.join(" ")
    }
}

fn ends_sentence(token: &str) -> bool {
    s::last_character(token).is_some_and(|last| s::is_one_of(last, &SENTENCE_ENDERS))
}

/// `token` with its trailing commas, semicolons and colons replaced by `ender`.
fn ending_sentence(token: &str, ender: &str) -> String {
    if ends_sentence(token) {
        return token.to_owned();
    }
    let mut trimmed = token.to_owned();
    while s::last_character(&trimmed).is_some_and(|last| s::is_one_of(last, &[",", ";", ":"])) {
        s::pop_last_character(&mut trimmed);
    }
    trimmed + ender
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removes_standalone_fillers_only() {
        let remover = FillerRemover::default();
        assert_eq!(
            remover.removing_fillers("so um I think uh-oh, umbrella"),
            "so I think uh-oh, umbrella"
        );
        assert_eq!(remover.removing_fillers("Um, dear Sam"), "Dear Sam");
        assert_eq!(remover.removing_fillers("it works, um."), "it works.");
        assert_eq!(remover.removing_fillers("Uh."), "");
    }
}
