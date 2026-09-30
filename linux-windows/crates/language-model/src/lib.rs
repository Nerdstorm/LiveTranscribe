//! Qwen3 language models on OpenVINO, as the Mac app runs its cleanup model through mlx-swift-lm:
//! the same prompt, token for token, and the same decoding.
//!
//! - [`tokenizer`] is Qwen2's byte-level BPE (Qwen3's, and Qwen3-ASR's), with [`pretokenizer`]
//!   its split pattern written out by hand.
//! - [`chat`] renders Qwen3's chat template, with or without thinking, as Hugging Face's
//!   `apply_chat_template` does; the tests check the ids against Hugging Face's for real chats.
//!
//! Prompts and replies are never logged: log lines carry counts only.

pub mod chat;
pub mod pretokenizer;
pub mod tokenizer;

pub use chat::{Message, Role};
pub use tokenizer::{Tokenizer, TokenizerError};
