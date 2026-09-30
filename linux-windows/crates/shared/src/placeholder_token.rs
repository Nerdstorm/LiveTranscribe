//! The opaque tokens (`⟦S1⟧`, `⟦S2⟧`, …) that stand in for snippets, spoken commands and list
//! markers while a transcript goes through the language model, so the model can neither see nor
//! change what they stand for. Speech-to-text never writes the brackets.
//!
//! The model itself sees each token as a plain word ("S1"), since it strips or drops the
//! brackets; cleanup's placeholder aliases swap the two either side of the model.
//!
//! Defined once here because several slices must agree on it: the phrase protector makes the
//! tokens, vocabulary replacement skips them, and cleanup's output guard checks that they came
//! back intact.

use crate::swift_string::{self as s};

/// Opens every token.
pub const OPENING: &str = "⟦";
/// Closes every token.
pub const CLOSING: &str = "⟧";

/// The token for the `index`th placeholder in a text, counting from 1.
pub fn make(index: usize) -> String {
    format!("{OPENING}S{index}{CLOSING}")
}

/// Opening brackets in `text`: the number of tokens it holds, whole or damaged.
pub fn opening_count(text: &str) -> usize {
    s::characters(text)
        .filter(|&character| s::canonically_equal(character, OPENING))
        .count()
}

/// Closing brackets in `text`.
pub fn closing_count(text: &str) -> usize {
    s::characters(text)
        .filter(|&character| s::canonically_equal(character, CLOSING))
        .count()
}

/// Occurrences of `token` in `text`; none of an empty token.
pub fn occurrences(token: &str, text: &str) -> usize {
    s::ranges_of(text, token).len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_are_numbered_from_one() {
        assert_eq!(make(1), "⟦S1⟧");
        assert_eq!(make(12), "⟦S12⟧");
    }

    #[test]
    fn counts_opening_brackets_whole_or_damaged() {
        assert_eq!(opening_count("Send ⟦S1⟧ and ⟦S2⟧."), 2);
        assert_eq!(opening_count("Send ⟦S 1 and more"), 1);
        assert_eq!(opening_count("No tokens [S1] here"), 0);
        assert_eq!(closing_count("Send S1⟧ and ⟦S2⟧."), 2);
        // A bracket with a combining mark on it is another character, as Swift counts it.
        assert_eq!(opening_count("⟦\u{301}S1⟧"), 0);
    }

    #[test]
    fn counts_occurrences_of_one_token() {
        assert_eq!(occurrences("⟦S1⟧", "⟦S1⟧ then ⟦S1⟧ and ⟦S11⟧"), 2);
        assert_eq!(occurrences("⟦S2⟧", "⟦S1⟧"), 0);
        assert_eq!(occurrences("", "anything"), 0);
    }
}
