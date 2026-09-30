//! Scripts the cleanup model can't write back, so text in them skips the model.
//!
//! Qwen3-1.7B drops Sinhala's vowel signs when it copies Sinhala text: "ඒකෙ තියෙන magic වැඩ" comes
//! back as "ඒක තයන magic වඩ". The output guard reads each damaged word as a respelling of the one
//! that was said and accepts it. At Medium the model garbled 4 of 24 Sinhala dictations this way,
//! and the guard rejected the other 20 after about 250 ms of generation, so the model does no good
//! on Sinhala at any level. Only Sinhala has been measured; other scripts are untested.

use std::ops::RangeInclusive;

/// Sinhala, U+0D80–U+0DFF.
const SINHALA: RangeInclusive<char> = '\u{0D80}'..='\u{0DFF}';

/// Whether the cleanup model can be given `text`: false when it has a character in a script the
/// model can't write back, even among English words.
pub fn model_can_rewrite(text: &str) -> bool {
    !text.chars().any(|scalar| SINHALA.contains(&scalar))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_sinhala_is_kept_from_the_model() {
        assert!(!model_can_rewrite("මේ film එක බලන්න"));
        assert!(!model_can_rewrite("ශ්‍රී"));
        assert!(model_can_rewrite("Let's meet on Tuesday."));
        assert!(model_can_rewrite("Café, naïve, 東京, नमस्ते"));
    }
}
