//! Qwen3-ASR's tokenizer is Qwen2's byte-level BPE, as the cleanup model's is:
//! lt-language-model reads it for both. Speech to text needs the parts [`Tokenizer::load`] reads
//! (`vocab.json` and `tokenizer_config.json`): the ids of the prompt's tokens, which the
//! vocabulary holds whole, and turning the model's reply back into text.

pub use lt_language_model::tokenizer::{Tokenizer, TokenizerError};

#[cfg(test)]
mod tests {
    use super::*;

    fn tokenizer() -> Tokenizer {
        let vocab = r#"{"Hello": 0, "Ġworld": 1, "Ċ": 2, "à¶": 3, "ļ": 4, "system": 5}"#;
        let config = r#"{"added_tokens_decoder": {
            "10": {"content": "<|im_start|>", "special": true},
            "11": {"content": "<asr_text>", "special": false}
        }}"#;
        Tokenizer::from_json(vocab, config).unwrap()
    }

    #[test]
    fn decodes_byte_level_tokens_and_added_tokens() {
        let tokenizer = tokenizer();
        assert_eq!(tokenizer.decode(&[0, 1, 2]), "Hello world\n");
        assert_eq!(tokenizer.decode(&[11, 0]), "<asr_text>Hello");
    }

    #[test]
    fn joins_the_bytes_of_a_character_split_across_tokens() {
        // "ක" (U+0D9A) is E0 B6 9A: "à¶" holds E0 B6 and "ļ" stands for 9A.
        let tokenizer = tokenizer();
        assert_eq!(tokenizer.decode(&[3, 4]), "ක");
        // Cut off after its first two bytes, it becomes one replacement character.
        assert_eq!(tokenizer.decode(&[0, 3]), "Hello\u{FFFD}");
    }

    #[test]
    fn looks_up_whole_tokens() {
        let tokenizer = tokenizer();
        assert_eq!(tokenizer.id("<|im_start|>").unwrap(), 10);
        assert_eq!(tokenizer.id("Ċ").unwrap(), 2);
        assert!(matches!(
            tokenizer.id("assistant"),
            Err(TokenizerError::MissingToken { .. })
        ));
    }
}
