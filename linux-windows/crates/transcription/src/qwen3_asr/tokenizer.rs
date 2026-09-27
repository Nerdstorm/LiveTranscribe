use std::collections::HashMap;
use std::fmt;
use std::path::Path;

use serde::Deserialize;

/// The parts of Qwen3-ASR's tokenizer that speech to text needs: the ids of the prompt's tokens,
/// and turning the model's reply back into text. Read from the model's `vocab.json` and
/// `tokenizer_config.json` (Qwen2's byte-level BPE, with added tokens such as `<|im_start|>`).
///
/// Only whole tokens are looked up: the prompt is made of tokens the vocabulary holds whole, so
/// no BPE merging is needed. Decoding is the byte-level decoder: each character of a vocabulary
/// token stands for one byte (GPT-2's byte-to-unicode table), the bytes are read as UTF-8, and any
/// invalid sequence becomes U+FFFD, as the tokenizer's `errors: replace` asks. Added tokens decode
/// as their text.
#[derive(Debug)]
pub struct Tokenizer {
    ids: HashMap<String, u32>,
    pieces: HashMap<u32, Piece>,
}

#[derive(Debug)]
enum Piece {
    Bytes(Vec<u8>),
    Added(String),
}

/// Why a tokenizer could not be read or used.
#[derive(Debug)]
pub enum TokenizerError {
    Read {
        file: String,
        message: String,
    },
    Parse {
        file: String,
        message: String,
    },
    /// A vocabulary token holds a character that stands for no byte.
    NotByteLevel {
        token: String,
    },
    /// The prompt needs a token the vocabulary doesn't hold.
    MissingToken {
        token: String,
    },
}

impl fmt::Display for TokenizerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Read { file, message } => write!(f, "couldn't read {file}: {message}"),
            Self::Parse { file, message } => write!(f, "couldn't parse {file}: {message}"),
            Self::NotByteLevel { token } => write!(f, "vocabulary token {token:?} isn't byte-level"),
            Self::MissingToken { token } => write!(f, "the tokenizer has no token {token:?}"),
        }
    }
}

impl std::error::Error for TokenizerError {}

#[derive(Deserialize)]
struct TokenizerConfig {
    #[serde(default)]
    added_tokens_decoder: HashMap<String, AddedToken>,
}

#[derive(Deserialize)]
struct AddedToken {
    content: String,
}

impl Tokenizer {
    /// Reads `vocab.json` and `tokenizer_config.json` from a model's folder.
    pub fn load(folder: &Path) -> Result<Self, TokenizerError> {
        let read = |name: &str| {
            std::fs::read_to_string(folder.join(name)).map_err(|error| TokenizerError::Read {
                file: name.to_owned(),
                message: error.to_string(),
            })
        };
        Self::from_json(&read("vocab.json")?, &read("tokenizer_config.json")?)
    }

    /// Builds the tokenizer from the text of `vocab.json` and `tokenizer_config.json`.
    pub fn from_json(vocab: &str, tokenizer_config: &str) -> Result<Self, TokenizerError> {
        let vocab: HashMap<String, u32> = serde_json::from_str(vocab).map_err(|error| TokenizerError::Parse {
            file: "vocab.json".to_owned(),
            message: error.to_string(),
        })?;
        let config: TokenizerConfig =
            serde_json::from_str(tokenizer_config).map_err(|error| TokenizerError::Parse {
                file: "tokenizer_config.json".to_owned(),
                message: error.to_string(),
            })?;

        let byte_of_char = byte_decoder();
        let mut pieces = HashMap::with_capacity(vocab.len() + config.added_tokens_decoder.len());
        for (token, &id) in &vocab {
            let bytes = token
                .chars()
                .map(|character| byte_of_char.get(&character).copied())
                .collect::<Option<Vec<u8>>>()
                .ok_or_else(|| TokenizerError::NotByteLevel { token: token.clone() })?;
            pieces.insert(id, Piece::Bytes(bytes));
        }
        let mut ids = vocab;
        for (id, token) in config.added_tokens_decoder {
            let id: u32 = id.parse().map_err(|_| TokenizerError::Parse {
                file: "tokenizer_config.json".to_owned(),
                message: format!("added token id {id:?} isn't a number"),
            })?;
            ids.insert(token.content.clone(), id);
            pieces.insert(id, Piece::Added(token.content));
        }
        Ok(Self { ids, pieces })
    }

    /// The id of a whole token: an added token's text (`<|im_start|>`), or a vocabulary token in
    /// its byte-level spelling (`Ċ` for a line feed).
    pub fn id(&self, token: &str) -> Result<u32, TokenizerError> {
        self.ids
            .get(token)
            .copied()
            .ok_or_else(|| TokenizerError::MissingToken {
                token: token.to_owned(),
            })
    }

    /// The text of `ids`. Ids the tokenizer doesn't know are skipped.
    pub fn decode(&self, ids: &[u32]) -> String {
        let mut bytes = Vec::new();
        let mut unknown = 0;
        for id in ids {
            match self.pieces.get(id) {
                Some(Piece::Bytes(piece)) => bytes.extend_from_slice(piece),
                Some(Piece::Added(text)) => bytes.extend_from_slice(text.as_bytes()),
                None => unknown += 1,
            }
        }
        if unknown > 0 {
            tracing::warn!("Skipped {unknown} token ids the tokenizer doesn't know");
        }
        String::from_utf8_lossy(&bytes).into_owned()
    }
}

/// GPT-2's byte-to-unicode table, reversed: printable Latin-1 bytes stand for themselves, and the
/// other 68 bytes for the characters from U+0100 on, in byte order.
fn byte_decoder() -> HashMap<char, u8> {
    let printable = |byte: u8| matches!(byte, b'!'..=b'~' | 0xA1..=0xAC | 0xAE..=0xFF);
    let mut next = 0x100;
    (0..=u8::MAX)
        .map(|byte| {
            if printable(byte) {
                (char::from(byte), byte)
            } else {
                let character = char::from_u32(next).expect("U+0100 to U+0143 are characters");
                next += 1;
                (character, byte)
            }
        })
        .collect()
}

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

    #[test]
    fn the_byte_table_covers_every_byte_once() {
        let table = byte_decoder();
        assert_eq!(table.len(), 256);
        assert_eq!(table[&'Ġ'], b' ');
        assert_eq!(table[&'Ċ'], b'\n');
        assert_eq!(table[&'A'], b'A');
    }
}
