//! Cleanup at the chosen level: the level's rules that need no language model, and everything
//! around the model, which a runtime implements behind [`CleanupModel`]. Mirrors the Mac app's
//! `Cleanup` module (Packages/LiveTranscribeKit/Sources/Cleanup), one module per Swift file:
//!
//! - [`CleanupExecutor`] runs one cleanup: the level's deterministic rules, the prompt, the model
//!   under a [`Deadline`], and the [`OutputGuard`]'s verdict, falling back to the text the model
//!   was given when the guard rejects the output. High runs two passes when the text has a
//!   correction cue; Deep runs as [`DeepCleanup`] says, with Medium's cleanup to fall back on.
//! - [`PromptBuilder`] and [`prompt`] compose what the model is asked ([`CleanupRequest`]),
//!   byte for byte as the Mac app asks it.
//! - [`OutputGuard`] decides whether the model's output may replace the text, with the checks
//!   for self-corrections, dropped words, names and content words, and for Deep, whether the
//!   output is a repair of what was said and nothing more.
//!
//! The fixtures in `Fixtures/cleanup` hold the Mac app's prompts, verdicts and executor traces;
//! the tests check this port against them. Dictated text is never logged.

mod cleanup_executor;
mod cleanup_model;
mod cleanup_options;
pub mod cleanup_scripts;
mod content_words;
mod deadline;
mod deep_cleanup;
mod dropped_words;
mod guard_policy;
mod output_guard;
mod placeholder_aliases;
pub mod prompt;
mod prompt_builder;
mod self_correction;
mod self_repair;
mod spoken_names;
mod thinking_output;
mod word_alignment;
mod word_forms;
mod word_fragments;
mod words;

#[cfg(test)]
mod fixtures;
#[cfg(test)]
mod test_support;

pub use cleanup_executor::{CleanedText, CleanupExecutor, deterministic_cleanup};
pub use cleanup_model::{CleanupModel, CleanupModelNotLoaded, WARM_UP_TIMEOUT_SECONDS, warm_up_request};
pub use cleanup_options::CleanupOptions;
pub use content_words::STANDARD_FUNCTION_WORDS;
pub use deadline::{CancelFlag, Clock, Deadline, SystemClock};
pub use deep_cleanup::{DeepCleanup, DeepPasses};
pub use guard_policy::GuardPolicy;
pub use output_guard::{FallbackReason, GenerationOutcome, GuardVerdict, OutputGuard};
pub use prompt::{Adapter, CleanupRequest, Example, Message, PromptTemplate, Role, Sampling};
pub use prompt_builder::PromptBuilder;
