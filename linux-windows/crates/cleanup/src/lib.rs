//! Cleanup at the chosen level. Mirrors the Mac app's `Cleanup` module
//! (Packages/LiveTranscribeKit/Sources/Cleanup), one module per Swift file: the rules that need no
//! language model, what the model is asked ([`PromptBuilder`], [`prompt`]), and whether its output
//! may replace the text ([`OutputGuard`], with the checks for self-corrections, dropped words,
//! names and content words).

mod cleanup_options;
mod content_words;
mod dropped_words;
mod guard_policy;
mod output_guard;
pub mod prompt;
mod prompt_builder;
mod self_correction;
mod spoken_names;
mod word_alignment;
mod words;

use lt_shared::CleanupLevel;
use lt_styles::FillerRemover;

pub use cleanup_options::CleanupOptions;
pub use content_words::STANDARD_FUNCTION_WORDS;
pub use guard_policy::GuardPolicy;
pub use output_guard::{FallbackReason, GenerationOutcome, GuardVerdict, OutputGuard};
pub use prompt::{CleanupRequest, Example, Message, PromptTemplate, Role, Sampling};
pub use prompt_builder::PromptBuilder;

/// `text` with only the level's rules that need no language model: filler removal at Medium and
/// High. Used when cleanup's model is turned off, and before the model runs.
pub fn deterministic_cleanup(text: &str, level: CleanupLevel) -> String {
    if level.removes_fillers() {
        FillerRemover::default().removing_fillers(text)
    } else {
        text.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removes_fillers_from_medium_up() {
        assert_eq!(deterministic_cleanup("Um, hi", CleanupLevel::Light), "Um, hi");
        assert_eq!(deterministic_cleanup("Um, hi", CleanupLevel::Medium), "Hi");
        assert_eq!(deterministic_cleanup("so um hi", CleanupLevel::High), "so hi");
    }
}
