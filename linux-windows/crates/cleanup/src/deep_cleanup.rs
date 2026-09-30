use crate::Adapter;

/// How the Deep level asks the model to repair a dictation: in one pass or after Medium's, with
/// which adapter, thinking or not, what it shows when its repair is turned down, and within what
/// budget.
///
/// The shipped values were chosen by measuring each choice on the same examples (the Mac app's
/// `Train measure`, docs/design-notes.md). Tools vary them to compare; the app uses
/// [`DeepCleanup::SHIPPED`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DeepCleanup {
    pub passes: DeepPasses,
    /// The adapter on during the Deep pass: Deep's own, trained on Deep's prompts; the
    /// self-correction adapter, trained on Medium's prompt only ([`crate::prompt::adapted`]); or
    /// none.
    pub adapter: Adapter,
    /// Qwen3 reasons in a `<think>` block before answering. The reasoning is removed before the
    /// answer is checked, and an answer whose reasoning never finished falls back.
    pub thinking: bool,
    /// Tokens the model may spend reasoning, on top of the answer's budget.
    pub thinking_tokens: usize,
    /// When Deep's repair is turned down and Medium's pass hasn't run, whether Medium's pass runs
    /// in the time left, so Deep never shows less than Medium would have.
    pub falls_back_to_medium: bool,
    /// Deep's shortest deadline for the whole cleanup; the Advanced timeout applies when it is
    /// longer.
    pub minimum_timeout_seconds: f64,
}

/// How many generations Deep's repair takes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DeepPasses {
    /// One Deep generation of the text.
    One,
    /// When the text has a correction cue, Medium's pass first (the adapter, on the prompt it was
    /// trained on) resolves what it can, then the Deep pass repairs the rest.
    AfterMedium,
}

impl DeepPasses {
    pub const ALL: [Self; 2] = [Self::One, Self::AfterMedium];

    /// The name the Mac app gives it: `one` or `afterMedium`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::One => "one",
            Self::AfterMedium => "afterMedium",
        }
    }
}

impl DeepCleanup {
    /// What the app runs: one pass with Deep's adapter, without thinking, which was right on 108
    /// of 114 hand-written cases, against 88 with the self-correction adapter and 52 with none;
    /// with thinking and no adapter, 58, taking 20 times as long (docs/design-notes.md). A repair
    /// `SelfRepair` turns down gets Medium's cleanup instead.
    pub const SHIPPED: Self = Self {
        passes: DeepPasses::One,
        adapter: Adapter::Deep,
        thinking: false,
        thinking_tokens: 768,
        falls_back_to_medium: true,
        minimum_timeout_seconds: 8.0,
    };

    /// The deadline for a cleanup under `timeout_seconds`, the Advanced setting: the longer of the
    /// two, as Swift's `max` picks it (the setting when the minimum is not a number).
    pub fn deadline(&self, timeout_seconds: f64) -> f64 {
        if self.minimum_timeout_seconds >= timeout_seconds {
            self.minimum_timeout_seconds
        } else {
            timeout_seconds
        }
    }
}

impl Default for DeepCleanup {
    fn default() -> Self {
        Self::SHIPPED
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shipped_deep_runs_one_pass_with_deeps_adapter_and_no_thinking() {
        let shipped = DeepCleanup::default();
        assert_eq!(shipped, DeepCleanup::SHIPPED);
        assert_eq!(shipped.adapter, Adapter::Deep);
        assert_eq!(shipped.passes, DeepPasses::One);
        assert!(!shipped.thinking);
        assert!(shipped.falls_back_to_medium);
    }

    #[test]
    fn the_deadline_is_the_longer_of_the_setting_and_deeps_minimum() {
        let deep = DeepCleanup::SHIPPED;
        assert_eq!(deep.deadline(3.0), 8.0);
        assert_eq!(deep.deadline(12.5), 12.5);
        assert!(deep.deadline(f64::NAN).is_nan());
        let unset = DeepCleanup {
            minimum_timeout_seconds: f64::NAN,
            ..deep
        };
        assert_eq!(unset.deadline(3.0), 3.0);
    }

    #[test]
    fn passes_have_the_mac_apps_names() {
        assert_eq!(DeepPasses::ALL.map(DeepPasses::as_str), ["one", "afterMedium"]);
    }
}
