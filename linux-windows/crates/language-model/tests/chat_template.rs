//! The prompt, checked against Hugging Face's for Qwen/Qwen3-1.7B.
//!
//! The fixtures were written by transformers and tokenizers (their versions are in each file) from
//! Qwen/Qwen3-1.7B's tokenizer at revision 70d244c:
//!
//! - `fixtures/chat-template.json`: chats (single and multi-turn, thinking on and off, Sinhala and
//!   other scripts, special tokens and reasoning in the messages) with the text and ids of
//!   `apply_chat_template(messages, tokenize=True, add_generation_prompt=True,
//!   enable_thinking=...)`, and texts with the ids of `encode(text, add_special_tokens=False)`;
//! - `fixtures/pretokenize.json`: texts with the pieces Qwen's Split pre-tokenizer makes of them
//!   after NFC, and the NFC of those that change.
//!
//! The rendering and the pre-tokenizer are checked here without a model. The ids need the model's
//! vocabulary and merges, which CI doesn't have; run those with a folder holding Qwen3's
//! vocab.json, merges.txt and tokenizer_config.json (any Qwen3 model folder, such as the cleanup
//! model's):
//!
//! ```text
//! LT_QWEN3_DIR=/path/to/qwen3-1.7b-mlx-4bit-ov cargo test -p lt-language-model -- --ignored
//! ```

use std::path::PathBuf;

use lt_language_model::{Message, Tokenizer, chat, pretokenizer};
use serde::Deserialize;
use unicode_normalization::UnicodeNormalization;

#[derive(Deserialize)]
struct ChatFixture {
    chats: Vec<Chat>,
    texts: Vec<EncodedText>,
}

#[derive(Deserialize)]
struct Chat {
    name: String,
    messages: Vec<Message>,
    thinking: bool,
    text: String,
    ids: Vec<u32>,
}

#[derive(Deserialize)]
struct EncodedText {
    text: String,
    ids: Vec<u32>,
}

#[derive(Deserialize)]
struct PretokenizeFixture {
    cases: Vec<Pieces>,
    nfc: Vec<Normalized>,
}

#[derive(Deserialize)]
struct Pieces {
    text: String,
    pieces: Vec<String>,
}

#[derive(Deserialize)]
struct Normalized {
    text: String,
    nfc: String,
}

fn chats() -> ChatFixture {
    serde_json::from_str(include_str!("fixtures/chat-template.json")).unwrap()
}

fn pretokenized() -> PretokenizeFixture {
    serde_json::from_str(include_str!("fixtures/pretokenize.json")).unwrap()
}

#[test]
fn renders_each_chat_as_hugging_face_does() {
    for chat in chats().chats {
        assert_eq!(
            chat::render(&chat.messages, chat.thinking).unwrap(),
            chat.text,
            "{}",
            chat.name
        );
    }
}

#[test]
fn splits_text_into_the_pieces_hugging_face_does() {
    let fixture = pretokenized();
    assert!(fixture.cases.len() > 300);
    for case in fixture.cases {
        let normalized: String = case.text.nfc().collect();
        assert_eq!(pretokenizer::split(&normalized), case.pieces, "{:?}", case.text);
    }
}

#[test]
fn normalises_to_nfc_as_hugging_face_does() {
    for case in pretokenized().nfc {
        assert_eq!(case.text.nfc().collect::<String>(), case.nfc, "{:?}", case.text);
    }
}

fn tokenizer() -> Tokenizer {
    let folder = PathBuf::from(std::env::var("LT_QWEN3_DIR").expect("LT_QWEN3_DIR names a Qwen3 model folder"));
    Tokenizer::load_with_merges(&folder).unwrap()
}

#[test]
#[ignore = "needs a Qwen3 model folder in LT_QWEN3_DIR"]
fn each_chats_prompt_has_hugging_faces_ids() {
    let tokenizer = tokenizer();
    for chat in chats().chats {
        let text = chat::render(&chat.messages, chat.thinking).unwrap();
        assert_eq!(tokenizer.encode(&text).unwrap(), chat.ids, "{}", chat.name);
    }
}

#[test]
#[ignore = "needs a Qwen3 model folder in LT_QWEN3_DIR"]
fn each_text_has_hugging_faces_ids_and_decodes_back() {
    let tokenizer = tokenizer();
    let texts = chats().texts;
    assert!(texts.len() > 100);
    for case in texts {
        let ids = tokenizer.encode(&case.text).unwrap();
        assert_eq!(ids, case.ids, "{:?}", case.text);
        assert_eq!(
            tokenizer.decode(&ids),
            case.text.nfc().collect::<String>(),
            "{:?}",
            case.text
        );
    }
}
