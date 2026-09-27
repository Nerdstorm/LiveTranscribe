//! Which canonical terms may be re-cased wherever they appear.
//!
//! Re-casing "github" to "GitHub" is safe because nobody writes "github" meaning anything else.
//! Re-casing "go" to "Go" or "swift" to "Swift" would corrupt ordinary speech, so only terms whose
//! spelling cannot be an ordinary word qualify. The replacer runs at every cleanup level,
//! including None, so a wrong re-casing here is never corrected later.

use lt_shared::swift_string::{self as s};

use crate::word_tokenizer;

/// A term qualifies when any of its words does (see [`is_distinctive_word`]). A multi-word term is
/// only ever re-cased as the whole phrase, never word by word.
pub(crate) fn is_distinctive_term(term: &str) -> bool {
    word_tokenizer::words(term)
        .iter()
        .any(|word| is_distinctive_word(&term[word.range.clone()]))
}

/// A word qualifies when it mixes letters and digits ("Qwen3", "M4", "4K") or mixes cases with a
/// capital after its first character ("GitHub", "iPhone", "macOS").
///
/// All-capital words ("NASA", "IT", "US") and numbers on their own ("6", "11") look distinctive
/// but are not: many acronyms are also ordinary words, and a number has no casing.
pub(crate) fn is_distinctive_word(word: &str) -> bool {
    if s::any_character(word, s::is_letter) && s::any_character(word, s::is_number) {
        return true;
    }
    s::any_character(word, s::is_lowercase) && s::any_character(s::drop_first(word, 1), s::is_uppercase)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn distinctive_terms() {
        assert!(is_distinctive_term("GitHub") && is_distinctive_term("Qwen3") && is_distinctive_term("iPhone"));
        assert!(!is_distinctive_term("Go") && !is_distinctive_term("NASA") && !is_distinctive_term("Swift 6"));
    }
}
