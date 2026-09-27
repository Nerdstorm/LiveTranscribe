//! The opaque tokens (`⟦S1⟧`, `⟦S2⟧`, …) that stand in for snippets, spoken commands and list
//! markers while a transcript goes through the language model, so the model can neither see nor
//! change what they stand for. Speech-to-text never writes the brackets.
//!
//! Defined once here because several slices must agree on it: the phrase protector makes the
//! tokens, and vocabulary replacement skips them.

/// Opens every token.
pub const OPENING: &str = "⟦";
/// Closes every token.
pub const CLOSING: &str = "⟧";

/// The token for the `index`th placeholder in a text, counting from 1.
pub fn make(index: usize) -> String {
    format!("{OPENING}S{index}{CLOSING}")
}
