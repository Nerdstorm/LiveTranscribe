use std::ops::RangeInclusive;

use lt_shared::CleanupLevel;

/// One of the requests a cleanup makes of the model: what its prompt allows, and the limits its
/// answer is checked against.
///
/// Standard asks once, with [`Self::Rewording`]. When the text has a correction cue ("sorry",
/// "no", "I mean"), it asks twice: [`Self::Correcting`] resolves the self-correction and changes
/// nothing else, as the self-correction adapter was trained to (`prompt::adapted`), then
/// [`Self::Rewording`] rewords what that left. Deep asks with [`Self::Repairing`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CleanupPass {
    /// Standard's first pass when it hears a correction cue: fix the text and resolve the
    /// correction, without rewording.
    Correcting,
    /// Standard's own pass: fix the text and resolve corrections, and reword lightly for grammar
    /// and clarity.
    Rewording,
    /// Deep's pass, with its own prompt and check (`SelfRepair`).
    Repairing,
}

impl CleanupPass {
    pub const ALL: [Self; 3] = [Self::Correcting, Self::Rewording, Self::Repairing];

    /// The pass a request at `level` makes unless the executor asks for another. None never
    /// reaches the model.
    pub fn for_level(level: CleanupLevel) -> Self {
        if level.repairs_across_sentences() {
            Self::Repairing
        } else {
            Self::Rewording
        }
    }

    /// The name the fixtures and tools give it, as the Mac app's raw value.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Correcting => "correcting",
            Self::Rewording => "rewording",
            Self::Repairing => "repairing",
        }
    }

    /// The model may reword, not only correct, so a run of spoken words may be replaced.
    pub fn allows_rewording(self) -> bool {
        self == Self::Rewording
    }

    /// Allowed ratio of the cleaned text's word count to the input's. Rewording needs more room.
    /// Deep's own check replaces these limits, so its bounds, Standard's, are not used.
    pub fn word_ratio_bounds(self) -> RangeInclusive<f64> {
        match self {
            Self::Correcting => 0.5..=1.2,
            Self::Rewording | Self::Repairing => 0.4..=1.3,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_level_has_its_own_pass() {
        assert_eq!(CleanupPass::for_level(CleanupLevel::Standard), CleanupPass::Rewording);
        assert_eq!(CleanupPass::for_level(CleanupLevel::Deep), CleanupPass::Repairing);
        assert_eq!(
            CleanupPass::ALL.map(CleanupPass::as_str),
            ["correcting", "rewording", "repairing"]
        );
    }

    #[test]
    fn rewording_widens_the_word_ratio_bounds() {
        assert_eq!(CleanupPass::Correcting.word_ratio_bounds(), 0.5..=1.2);
        assert_eq!(CleanupPass::Rewording.word_ratio_bounds(), 0.4..=1.3);
        assert_eq!(CleanupPass::Repairing.word_ratio_bounds(), 0.4..=1.3);
        assert!(!CleanupPass::Correcting.allows_rewording() && CleanupPass::Rewording.allows_rewording());
    }
}
