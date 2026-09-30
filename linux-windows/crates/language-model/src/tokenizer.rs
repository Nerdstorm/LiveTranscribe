//! Qwen2's byte-level BPE tokenizer, which Qwen3 and Qwen3-ASR use unchanged, read from a model's
//! `vocab.json`, `merges.txt` and `tokenizer_config.json`.
//!
//! Encoding is what Hugging Face's `tokenizers` does with the model's tokenizer.json:
//!
//! 1. the added tokens (`<|im_start|>`, `<think>`, ...) are cut out of the text wherever they are,
//!    the longest first where two start at the same place (none of Qwen's strips the space beside
//!    it or is normalised);
//! 2. the text between them is normalised to NFC;
//! 3. and cut into pieces by Qwen2's pattern ([`crate::pretokenizer`]);
//! 4. each piece's UTF-8 bytes are spelt in GPT-2's byte-level alphabet, one character a byte, and
//!    merged by byte-pair encoding: the pair `merges.txt` ranks first, every time.
//!
//! Decoding reverses the byte-level spelling: each character of a vocabulary token stands for one
//! byte, the bytes are read as UTF-8, and any invalid sequence becomes U+FFFD, as the tokenizer's
//! `errors: replace` asks. Added tokens decode as their text.

use std::collections::HashMap;
use std::fmt;
use std::path::Path;

use serde::Deserialize;
use unicode_normalization::UnicodeNormalization;

use crate::pretokenizer;

/// A byte-level BPE tokenizer. Read with [`Tokenizer::load`] it looks tokens up and decodes, which
/// is all speech to text needs; with [`Tokenizer::load_with_merges`] it encodes text too.
#[derive(Debug)]
pub struct Tokenizer {
    ids: HashMap<String, u32>,
    pieces: HashMap<u32, Piece>,
    /// The added tokens, the longest first, as encoding cuts them out of text.
    added: Vec<(String, u32)>,
    encoder: Option<Encoder>,
}

#[derive(Debug)]
enum Piece {
    Bytes(Vec<u8>),
    Added(String),
}

/// What encoding needs beyond the vocabulary.
#[derive(Debug)]
struct Encoder {
    /// The id of each byte's one-character token.
    bytes: Vec<u32>,
    /// Each pair of tokens BPE merges: its rank (the lower merges first) and the merged token's id.
    merges: HashMap<(u32, u32), (u32, u32)>,
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
    /// Text was to be encoded by a tokenizer read without its merges.
    NoMerges,
}

impl fmt::Display for TokenizerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Read { file, message } => write!(f, "couldn't read {file}: {message}"),
            Self::Parse { file, message } => write!(f, "couldn't parse {file}: {message}"),
            Self::NotByteLevel { token } => write!(f, "vocabulary token {token:?} isn't byte-level"),
            Self::MissingToken { token } => write!(f, "the tokenizer has no token {token:?}"),
            Self::NoMerges => f.write_str("the tokenizer was read without merges.txt, so it can't encode text"),
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
    /// Reads `vocab.json` and `tokenizer_config.json` from a model's folder: enough to look tokens
    /// up and to decode, not to encode.
    pub fn load(folder: &Path) -> Result<Self, TokenizerError> {
        Self::from_json(&read(folder, "vocab.json")?, &read(folder, "tokenizer_config.json")?)
    }

    /// Reads `vocab.json`, `merges.txt` and `tokenizer_config.json` from a model's folder.
    pub fn load_with_merges(folder: &Path) -> Result<Self, TokenizerError> {
        Self::load(folder)?.with_merges(&read(folder, "merges.txt")?)
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
        let mut added = Vec::with_capacity(config.added_tokens_decoder.len());
        for (id, token) in config.added_tokens_decoder {
            let id: u32 = id.parse().map_err(|_| TokenizerError::Parse {
                file: "tokenizer_config.json".to_owned(),
                message: format!("added token id {id:?} isn't a number"),
            })?;
            ids.insert(token.content.clone(), id);
            added.push((token.content.clone(), id));
            pieces.insert(id, Piece::Added(token.content));
        }
        // The longest first, so that of two added tokens starting at one place the longer is cut.
        added.sort_by(|(a, _), (b, _)| b.len().cmp(&a.len()).then_with(|| a.cmp(b)));
        Ok(Self {
            ids,
            pieces,
            added,
            encoder: None,
        })
    }

    /// Adds the merges of `merges.txt`, one pair a line in rank order after a `#version` line, so
    /// that the tokenizer encodes.
    pub fn with_merges(mut self, merges: &str) -> Result<Self, TokenizerError> {
        let byte_to_char = byte_encoder();
        let bytes = byte_to_char
            .iter()
            .map(|&character| self.id(&character.to_string()))
            .collect::<Result<Vec<u32>, _>>()?;
        let mut pairs = HashMap::new();
        let lines = merges
            .lines()
            .filter(|line| !line.starts_with("#version") && !line.is_empty());
        for (rank, line) in lines.enumerate() {
            let parse = |message: &str| TokenizerError::Parse {
                file: "merges.txt".to_owned(),
                message: format!("{message}: {line:?}"),
            };
            let (left, right) = line.split_once(' ').ok_or_else(|| parse("a line isn't a pair"))?;
            if right.contains(' ') {
                return Err(parse("a line has more than a pair"));
            }
            let merged = self.id(&format!("{left}{right}"))?;
            let rank = u32::try_from(rank).map_err(|_| parse("too many merges"))?;
            pairs.insert((self.id(left)?, self.id(right)?), (rank, merged));
        }
        self.encoder = Some(Encoder { bytes, merges: pairs });
        Ok(self)
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

    /// The ids of `text`, with any added token in it as that token, as Hugging Face's
    /// `tokenizer.encode(text, add_special_tokens=False)` gives them.
    pub fn encode(&self, text: &str) -> Result<Vec<u32>, TokenizerError> {
        let encoder = self.encoder.as_ref().ok_or(TokenizerError::NoMerges)?;
        let mut ids = Vec::new();
        let mut rest = text;
        while let Some((start, token, id)) = self.next_added_token(rest) {
            encoder.encode_text(&rest[..start], &mut ids);
            ids.push(id);
            rest = &rest[start + token.len()..];
        }
        encoder.encode_text(rest, &mut ids);
        Ok(ids)
    }

    /// The first added token in `text`: where it starts, its text and its id.
    fn next_added_token<'a>(&'a self, text: &str) -> Option<(usize, &'a str, u32)> {
        text.char_indices().find_map(|(start, _)| {
            self.added
                .iter()
                .find(|(token, _)| text[start..].starts_with(token.as_str()))
                .map(|(token, id)| (start, token.as_str(), *id))
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

impl Encoder {
    /// Appends the ids of `text`, which holds no added token.
    fn encode_text(&self, text: &str, ids: &mut Vec<u32>) {
        if text.is_empty() {
            return;
        }
        let normalized: String = text.nfc().collect();
        for piece in pretokenizer::split(&normalized) {
            self.merge(piece.as_bytes(), ids);
        }
    }

    /// Appends the ids BPE makes of one piece's bytes: while any two neighbours merge, every
    /// occurrence of the best-ranked pair is merged, left to right.
    fn merge(&self, piece: &[u8], ids: &mut Vec<u32>) {
        let mut symbols: Vec<u32> = piece.iter().map(|&byte| self.bytes[usize::from(byte)]).collect();
        while let Some((pair, merged)) = self.best_pair(&symbols) {
            let mut next = Vec::with_capacity(symbols.len());
            let mut index = 0;
            while index < symbols.len() {
                if index + 1 < symbols.len() && (symbols[index], symbols[index + 1]) == pair {
                    next.push(merged);
                    index += 2;
                } else {
                    next.push(symbols[index]);
                    index += 1;
                }
            }
            symbols = next;
        }
        ids.extend(symbols);
    }

    /// The neighbouring pair with the best (lowest) rank, and the token it merges into.
    fn best_pair(&self, symbols: &[u32]) -> Option<((u32, u32), u32)> {
        symbols
            .windows(2)
            .filter_map(|pair| {
                let pair = (pair[0], pair[1]);
                self.merges.get(&pair).map(|&(rank, merged)| (rank, pair, merged))
            })
            .min_by_key(|&(rank, ..)| rank)
            .map(|(_, pair, merged)| (pair, merged))
    }
}

fn read(folder: &Path, name: &str) -> Result<String, TokenizerError> {
    std::fs::read_to_string(folder.join(name)).map_err(|error| TokenizerError::Read {
        file: name.to_owned(),
        message: error.to_string(),
    })
}

/// GPT-2's byte-to-unicode table: printable Latin-1 bytes stand for themselves, and the other 68
/// bytes for the characters from U+0100 on, in byte order. Indexed by byte.
fn byte_encoder() -> Vec<char> {
    let printable = |byte: u8| matches!(byte, b'!'..=b'~' | 0xA1..=0xAC | 0xAE..=0xFF);
    let mut next = 0x100;
    (0..=u8::MAX)
        .map(|byte| {
            if printable(byte) {
                char::from(byte)
            } else {
                let character = char::from_u32(next).expect("U+0100 to U+0143 are characters");
                next += 1;
                character
            }
        })
        .collect()
}

/// [`byte_encoder`] reversed.
fn byte_decoder() -> HashMap<char, u8> {
    byte_encoder().into_iter().zip(0..=u8::MAX).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each byte's token, with the byte as its id.
    fn byte_vocab() -> HashMap<String, u32> {
        byte_encoder()
            .into_iter()
            .zip(0..)
            .map(|(character, id)| (character.to_string(), id))
            .collect()
    }

    /// A vocabulary of every byte, a few merges and Qwen's added tokens around chat turns.
    fn tokenizer() -> Tokenizer {
        let mut vocab = byte_vocab();
        for (id, token) in (256..).zip(["he", "ll", "hell", "hello", "Ġw", "Ġwo", "ĠĊ", "ĊĊ"]) {
            vocab.insert(token.to_owned(), id);
        }
        let config = r#"{"added_tokens_decoder": {
            "300": {"content": "<|im_start|>", "special": true},
            "301": {"content": "<|im_end|>", "special": true},
            "302": {"content": "<think>", "special": false},
            "303": {"content": "<|im", "special": true}
        }}"#;
        let merges = "#version: 0.2\nh e\nl l\nhe ll\nhell o\nĠ w\nĠw o\nĊ Ċ\n";
        Tokenizer::from_json(&serde_json::to_string(&vocab).unwrap(), config)
            .unwrap()
            .with_merges(merges)
            .unwrap()
    }

    fn id(tokenizer: &Tokenizer, token: &str) -> u32 {
        tokenizer.id(token).unwrap()
    }

    #[test]
    fn merges_the_best_ranked_pair_first() {
        let tokenizer = tokenizer();
        let ids = tokenizer.encode("hello world").unwrap();
        let expected: Vec<u32> = ["hello", "Ġwo", "r", "l", "d"]
            .iter()
            .map(|t| id(&tokenizer, t))
            .collect();
        assert_eq!(ids, expected);
        assert_eq!(tokenizer.decode(&ids), "hello world");
    }

    #[test]
    fn cuts_added_tokens_out_the_longest_first() {
        let tokenizer = tokenizer();
        let ids = tokenizer.encode("<|im_start|>he<think><|im_end|><|imx").unwrap();
        let expected: Vec<u32> = ["<|im_start|>", "he", "<think>", "<|im_end|>", "<|im", "x"]
            .iter()
            .map(|t| id(&tokenizer, t))
            .collect();
        assert_eq!(ids, expected);
    }

    #[test]
    fn normalises_to_nfc_before_encoding() {
        let tokenizer = tokenizer();
        assert_eq!(
            tokenizer.encode("e\u{301}").unwrap(),
            tokenizer.encode("\u{e9}").unwrap()
        );
    }

    #[test]
    fn a_tokenizer_without_merges_decodes_but_does_not_encode() {
        let tokenizer = Tokenizer::from_json(r#"{"a": 0}"#, "{}").unwrap();
        assert!(matches!(tokenizer.encode("a"), Err(TokenizerError::NoMerges)));
        assert_eq!(tokenizer.decode(&[0]), "a");
    }

    #[test]
    fn refuses_merges_of_tokens_the_vocabulary_lacks() {
        let tokenizer = Tokenizer::from_json(&serde_json::to_string(&byte_vocab()).unwrap(), "{}").unwrap();
        assert!(matches!(
            tokenizer.with_merges("x y\n"),
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
