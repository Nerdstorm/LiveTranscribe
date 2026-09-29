//! Cleanup at the chosen level: the level's rules that need no language model, and everything
//! around the model, which a runtime implements behind [`CleanupModel`]. Mirrors the Mac app's
//! `Cleanup` module (Packages/LiveTranscribeKit/Sources/Cleanup), one module per Swift file:
//!
//! - [`CleanupExecutor`] runs one cleanup: the level's deterministic rules, the prompt, the model
//!   under a [`Deadline`], and the [`OutputGuard`]'s verdict, falling back to the text the model
//!   was given when the guard rejects the output. High runs two passes when the text has a
//!   correction cue.
//! - [`PromptBuilder`] and [`prompt`] compose what the model is asked ([`CleanupRequest`]),
//!   byte for byte as the Mac app asks it.
//! - [`OutputGuard`] decides whether the model's output may replace the text, with the checks
//!   for self-corrections, dropped words, names and content words.
//!
//! Dictated text is never logged.

mod cleanup_executor;
mod cleanup_model;
mod cleanup_options;
pub mod cleanup_scripts;
mod content_words;
mod deadline;
mod dropped_words;
mod guard_policy;
mod output_guard;
mod placeholder_aliases;
pub mod prompt;
mod prompt_builder;
mod self_correction;
mod spoken_names;
mod word_alignment;
mod words;

#[cfg(test)]
mod test_support;

pub use cleanup_executor::{CleanedText, CleanupExecutor, deterministic_cleanup};
pub use cleanup_model::{CleanupModel, CleanupModelNotLoaded, WARM_UP_TIMEOUT_SECONDS, uses_adapter, warm_up_request};
pub use cleanup_options::CleanupOptions;
pub use content_words::STANDARD_FUNCTION_WORDS;
pub use deadline::{CancelFlag, Clock, Deadline, SystemClock};
pub use guard_policy::GuardPolicy;
pub use output_guard::{FallbackReason, GenerationOutcome, GuardVerdict, OutputGuard};
pub use prompt::{CleanupRequest, Example, Message, PromptTemplate, Role, Sampling};
pub use prompt_builder::PromptBuilder;
