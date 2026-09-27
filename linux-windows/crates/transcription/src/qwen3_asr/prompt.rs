use super::tokenizer::{Tokenizer, TokenizerError};

/// The prompt the Mac app gives Qwen3-ASR: no context and no language, so the model names the
/// language itself before the transcript ("language English<asr_text>…"), as mlx-audio-swift's
/// `buildPromptText` writes it when no language is given:
///
/// ```text
/// <|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>
/// <|audio_pad|> × the clip's placeholders
/// <|audio_end|><|im_end|>\n<|im_start|>assistant\n
/// ```
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PromptFormat {
    prefix: Vec<u32>,
    suffix: Vec<u32>,
    audio_pad: u32,
}

/// The prompt's tokens before the placeholders and after them. The text between the special
/// tokens is "system", "user" or "assistant" and a line feed, which Qwen's tokenizer splits into
/// the word and the line feed, each a single token (`Ċ` is the line feed's byte-level spelling).
const PREFIX: [&str; 9] = [
    "<|im_start|>",
    "system",
    "Ċ",
    "<|im_end|>",
    "Ċ",
    "<|im_start|>",
    "user",
    "Ċ",
    "<|audio_start|>",
];
const SUFFIX: [&str; 6] = ["<|audio_end|>", "<|im_end|>", "Ċ", "<|im_start|>", "assistant", "Ċ"];
const AUDIO_PAD: &str = "<|audio_pad|>";

impl PromptFormat {
    pub fn new(tokenizer: &Tokenizer) -> Result<Self, TokenizerError> {
        let ids = |tokens: &[&str]| {
            tokens
                .iter()
                .map(|token| tokenizer.id(token))
                .collect::<Result<Vec<_>, _>>()
        };
        Ok(Self {
            prefix: ids(&PREFIX)?,
            suffix: ids(&SUFFIX)?,
            audio_pad: tokenizer.id(AUDIO_PAD)?,
        })
    }

    /// The prompt's ids for a clip with `placeholders` audio placeholders.
    pub fn ids(&self, placeholders: usize) -> Vec<u32> {
        let mut ids = Vec::with_capacity(self.prefix.len() + placeholders + self.suffix.len());
        ids.extend_from_slice(&self.prefix);
        ids.extend(std::iter::repeat_n(self.audio_pad, placeholders));
        ids.extend_from_slice(&self.suffix);
        ids
    }

    /// Where the placeholders start in the prompt.
    pub fn audio_start(&self) -> usize {
        self.prefix.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn surrounds_the_placeholders_with_the_chat_turns() {
        let vocab = r#"{"system": 8948, "user": 872, "assistant": 77091, "Ċ": 198}"#;
        let config = r#"{"added_tokens_decoder": {
            "151644": {"content": "<|im_start|>"}, "151645": {"content": "<|im_end|>"},
            "151669": {"content": "<|audio_start|>"}, "151670": {"content": "<|audio_end|>"},
            "151676": {"content": "<|audio_pad|>"}
        }}"#;
        let format = PromptFormat::new(&Tokenizer::from_json(vocab, config).unwrap()).unwrap();
        assert_eq!(
            format.ids(2),
            [
                151644, 8948, 198, 151645, 198, 151644, 872, 198, 151669, 151676, 151676, 151670, 151645, 198, 151644,
                77091, 198
            ]
        );
        assert_eq!(format.audio_start(), 9);
    }
}
