//! The tokens a [`ScriptLock`] lets Qwen3-ASR write next, as LockedVocabulary.swift and
//! LockedLogits in Qwen3ASR+ScriptLock.swift find them on the Mac: each vocabulary token whose
//! bytes the lock allows after the character the reply has left unfinished, and the end of the
//! reply after a whole character. Qwen's added tokens write no text, so they never are.

use std::collections::HashMap;

use super::generation::END_OF_REPLY;
use super::tokenizer::Tokenizer;
use crate::script_lock::{PartialCharacter, ScriptLock, WritingScript};

/// The model's tokens as the bytes each writes, and the tokens each lock allows after each
/// unfinished character, kept once found: finding them reads all 151,936 tokens.
#[derive(Debug)]
pub struct LockedTokens {
    /// Each token's bytes, by id, for as many tokens as the model has logits; `None` for an added
    /// token or the logits' padding.
    bytes: Vec<Option<Vec<u8>>>,
    allowed: HashMap<(WritingScript, PartialCharacter), Vec<bool>>,
}

impl LockedTokens {
    /// The tokens of a model with `count` logits.
    pub fn new(tokenizer: &Tokenizer, count: usize) -> Self {
        let bytes = (0..count)
            .map(|id| {
                u32::try_from(id)
                    .ok()
                    .and_then(|id| tokenizer.bytes_of(id))
                    .map(<[u8]>::to_vec)
            })
            .collect();
        Self {
            bytes,
            allowed: HashMap::new(),
        }
    }

    /// Which tokens `lock` allows after `partial`, by id.
    fn allowed(&mut self, lock: &ScriptLock, partial: PartialCharacter) -> &[bool] {
        let bytes = &self.bytes;
        self.allowed.entry((lock.script(), partial)).or_insert_with(|| {
            let mut allowed: Vec<bool> = bytes
                .iter()
                .map(|written| {
                    written
                        .as_deref()
                        .is_some_and(|written| !written.is_empty() && lock.partial_after(partial, written).is_some())
                })
                .collect();
            if partial.is_whole() {
                for end in END_OF_REPLY {
                    if let Some(allowed) = allowed.get_mut(end as usize) {
                        *allowed = true;
                    }
                }
            }
            allowed
        })
    }

    fn bytes_of(&self, token: u32) -> &[u8] {
        self.bytes
            .get(token as usize)
            .and_then(Option::as_deref)
            .unwrap_or_default()
    }
}

/// A reply locked to a language's letters while it's decoded: the lock, the tokens, and the
/// character the reply has left unfinished so far.
pub struct Locked<'a> {
    lock: &'a ScriptLock,
    tokens: &'a mut LockedTokens,
    partial: PartialCharacter,
}

impl<'a> Locked<'a> {
    pub fn new(lock: &'a ScriptLock, tokens: &'a mut LockedTokens) -> Self {
        Self {
            lock,
            tokens,
            partial: PartialCharacter::NOTHING,
        }
    }

    /// Which tokens may come next, by id.
    pub fn allowed(&mut self) -> &[bool] {
        self.tokens.allowed(self.lock, self.partial)
    }

    /// Reads `token`, which came next.
    pub fn write(&mut self, token: u32) {
        self.partial = self
            .lock
            .partial_after(self.partial, self.tokens.bytes_of(token))
            .unwrap_or(PartialCharacter::NOTHING);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// "Hello", " world", E0 B6 and 9A ("ක" is E0 B6 9A), 我 (E6 88 91), with an added token at 10.
    fn tokenizer() -> Tokenizer {
        let vocab = r#"{"Hello": 0, "Ġworld": 1, "à¶": 2, "ļ": 3, "æĪĳ": 4}"#;
        let config = r#"{"added_tokens_decoder": {"10": {"content": "<|im_end|>", "special": true}}}"#;
        Tokenizer::from_json(vocab, config).unwrap()
    }

    #[test]
    fn a_lock_allows_the_tokens_that_write_what_it_allows() {
        let mut tokens = LockedTokens::new(&tokenizer(), 12);
        let english = ScriptLock::new(WritingScript::Latin);
        let allowed = tokens.allowed(&english, PartialCharacter::NOTHING).to_vec();
        assert_eq!(&allowed[..5], [true, true, false, false, false]);
        assert!(!allowed[10], "an added token writes no text");
        let han = ScriptLock::new(WritingScript::Han);
        assert!(tokens.allowed(&han, PartialCharacter::NOTHING)[4]);
    }

    /// Only the rest of an unfinished character may follow it, and no end of the reply.
    #[test]
    fn an_unfinished_character_is_finished_first() {
        let mut tokens = LockedTokens::new(&tokenizer(), 151_936);
        let sinhala = ScriptLock::new(WritingScript::Sinhala);
        let mut locked = Locked::new(&sinhala, &mut tokens);
        assert!(locked.allowed()[151_645], "a reply may end after a whole character");
        locked.write(2);
        let allowed = locked.allowed();
        assert_eq!(&allowed[..5], [false, false, false, true, false]);
        assert!(!allowed[151_645] && !allowed[151_643]);
        locked.write(3);
        assert!(locked.allowed()[151_645]);
    }
}
