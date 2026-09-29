//! Cleanup at the chosen level. Mirrors the Mac app's `Cleanup` module
//! (Packages/LiveTranscribeKit/Sources/Cleanup), one module per Swift file: the rules that need no
//! language model, and what the model is asked ([`PromptBuilder`], [`prompt`]).

mod cleanup_options;
pub mod prompt;
mod prompt_builder;

use lt_shared::CleanupLevel;
use lt_styles::FillerRemover;

pub use cleanup_options::CleanupOptions;
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
