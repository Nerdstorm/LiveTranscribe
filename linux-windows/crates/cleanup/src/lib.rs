//! Cleanup at the chosen level. Mirrors the Mac app's `Cleanup` module
//! (Packages/LiveTranscribeKit/Sources/Cleanup).

use lt_shared::CleanupLevel;
use lt_styles::FillerRemover;

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
