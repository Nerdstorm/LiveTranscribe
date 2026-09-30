//! Qwen3 language models on OpenVINO, as the Mac app runs its cleanup model through mlx-swift-lm:
//! the same prompt, token for token, and the same decoding.
//!
//! - [`tokenizer`] is Qwen2's byte-level BPE (Qwen3's, and Qwen3-ASR's), with [`pretokenizer`]
//!   its split pattern written out by hand.
//! - [`chat`] renders Qwen3's chat template, with or without thinking, as Hugging Face's
//!   `apply_chat_template` does; the tests check the ids against Hugging Face's for real chats.
//! - [`sampling`] picks each token: greedily, or at random from the likeliest with a seed.
//! - [`openvino_model`] runs a stateful OpenVINO model (optimum-intel's export, or one with
//!   adapter inputs); [`runtime`] loads OpenVINO once for the whole process.
//! - [`adapter`] reads the Mac's LoRA adapters, any number of them, for a model with adapter
//!   inputs to run with, one or none a request.
//! - [`LanguageModel`] puts them together: a chat in, a reply out, with its timings.
//! - [`pinned_model`] is the cleanup model the app downloads, pinned to a commit and checked.
//!
//! Prompts and replies are never logged: log lines carry counts only.

pub mod adapter;
pub mod chat;
mod language_model;
pub mod openvino_model;
pub mod pinned_model;
pub mod pretokenizer;
pub mod runtime;
pub mod sampling;
pub mod tokenizer;

pub use adapter::{Adapter, AdapterError};
pub use chat::{Message, Role};
pub use language_model::{GenerateError, LanguageModel, OpenError, Reply, Request, Stop};
pub use openvino_model::Options;
pub use pinned_model::{CLEANUP_MODEL, PinnedModel, prepare};
pub use sampling::Sampling;
pub use tokenizer::{Tokenizer, TokenizerError};
