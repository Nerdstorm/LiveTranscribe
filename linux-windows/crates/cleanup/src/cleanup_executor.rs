use std::sync::Arc;
use std::time::{Duration, Instant};

use lt_shared::{CleanupLevel, edit_distance};
use lt_styles::FillerRemover;

use crate::placeholder_aliases::PlaceholderAliases;
use crate::{
    CancelFlag, CleanupModel, CleanupOptions, Clock, Deadline, FallbackReason, GenerationOutcome, GuardVerdict,
    OutputGuard, PromptBuilder, SystemClock, cleanup_scripts, prompt, uses_adapter,
};

/// What one cleanup made of a text.
#[derive(Clone, Debug, PartialEq)]
pub struct CleanedText {
    /// The model's output, when the guard accepted it. Otherwise the text the model was given:
    /// the raw text, less fillers at Medium and High.
    pub text: String,
    /// Why the model's output was not used; `None` when it was, or when the model had nothing to
    /// do.
    pub fallback_reason: Option<FallbackReason>,
    /// Time spent in cleanup, in whole milliseconds; 0 when the model did not run.
    pub latency_ms: u64,
}

impl CleanedText {
    /// Whether cleanup fell back to the text the model was given.
    pub fn fell_back(&self) -> bool {
        self.fallback_reason.is_some()
    }

    fn without_the_model(text: String) -> Self {
        Self {
            text,
            fallback_reason: None,
            latency_ms: 0,
        }
    }
}

/// Runs one cleanup: applies the level's deterministic rules, builds the prompt, generates under
/// a deadline, and applies the output guard.
///
/// Model-agnostic: the model is passed in, so the policy (levels, timeout, cancellation,
/// fallback) is testable without loading one.
///
/// The text the model sees is the raw transcript with fillers removed at Medium and High. When
/// the guard rejects the output, that text is the result: fillers stay removed, so a fallback
/// differs from a success only in what the model would have corrected.
///
/// High runs in two passes when the text has a correction cue ("sorry", "no", "I mean"): the
/// Medium prompt resolves the self-correction, as the adapter was trained to, then the High prompt
/// rewords the result. Both share the one deadline. If the rewording is rejected or there is no
/// time left for it, the resolved text is used; that is a success at Medium's standard, not a
/// fallback.
#[derive(Clone)]
pub struct CleanupExecutor {
    context_limit: usize,
    timeout_seconds: f64,
    output_guard: OutputGuard,
    prompts: PromptBuilder,
    clock: Arc<dyn Clock>,
}

impl CleanupExecutor {
    /// - `context_limit`: how many earlier segments the model sees before the text.
    /// - `timeout_seconds`: how long one cleanup may take, both of High's passes together.
    pub fn new(context_limit: usize, timeout_seconds: f64, output_guard: OutputGuard, prompts: PromptBuilder) -> Self {
        Self {
            context_limit,
            timeout_seconds,
            output_guard,
            prompts,
            clock: Arc::new(SystemClock),
        }
    }

    /// The executor reading the time from `clock` instead of the system's.
    pub fn with_clock(self, clock: Arc<dyn Clock>) -> Self {
        Self { clock, ..self }
    }

    pub fn context_limit(&self) -> usize {
        self.context_limit
    }

    pub fn timeout_seconds(&self) -> f64 {
        self.timeout_seconds
    }

    pub fn output_guard(&self) -> &OutputGuard {
        &self.output_guard
    }

    pub fn prompts(&self) -> &PromptBuilder {
        &self.prompts
    }

    /// Cleans `raw` with `model`. `context` holds earlier segments, oldest first, which the model
    /// sees as read-only context. Setting `cancel` from another thread stops the cleanup, which
    /// then falls back.
    pub fn run<M: CleanupModel>(
        &self,
        raw: &str,
        context: &[String],
        options: &CleanupOptions,
        model: &mut M,
        cancel: &CancelFlag,
    ) -> CleanedText {
        let started = self.clock.now();
        if !options.level.uses_language_model() {
            return CleanedText::without_the_model(raw.to_owned());
        }
        let input = deterministic_cleanup(raw, options.level);
        if edit_distance::words(&input).is_empty() {
            return CleanedText::without_the_model(input);
        }
        // Text the model would damage gets the level's deterministic rules only, as when the model
        // is off (see `cleanup_scripts`).
        if !cleanup_scripts::model_can_rewrite(&input) {
            tracing::info!("Cleanup skipped the model: the text is in a script it can't write");
            return CleanedText::without_the_model(input);
        }

        let verdict = if options.level.allows_rewording() && self.output_guard.correction_cue_count(&input) > 0 {
            self.resolving_then_rewording(&input, context, options, started, model, cancel)
        } else {
            self.pass(&input, context, options, self.timeout_seconds, model, cancel)
        };

        let latency_ms = whole_milliseconds(self.elapsed_since(started));
        match verdict {
            GuardVerdict::Accepted(cleaned) => CleanedText {
                text: cleaned,
                fallback_reason: None,
                latency_ms,
            },
            GuardVerdict::Rejected(reason) => {
                tracing::info!("Cleanup fell back to the uncorrected text: {reason}");
                CleanedText {
                    text: input,
                    fallback_reason: Some(reason),
                    latency_ms,
                }
            }
        }
    }

    /// High with a self-correction: Medium resolves it, then High rewords what is left in the time
    /// remaining. A rejected rewording keeps the resolved text.
    fn resolving_then_rewording<M: CleanupModel>(
        &self,
        input: &str,
        context: &[String],
        options: &CleanupOptions,
        started: Instant,
        model: &mut M,
        cancel: &CancelFlag,
    ) -> GuardVerdict {
        let resolving = CleanupOptions {
            level: CleanupLevel::Medium,
            ..options.clone()
        };
        let first = self.pass(input, context, &resolving, self.timeout_seconds, model, cancel);
        let GuardVerdict::Accepted(resolved) = &first else {
            return first;
        };

        let remaining = self.timeout_seconds - whole_milliseconds(self.elapsed_since(started)) as f64 / 1_000.0;
        let has_time = remaining > 0.0;
        if !has_time || cancel.is_cancelled() {
            tracing::info!("No time left to reword; keeping the resolved self-correction");
            return first;
        }
        let second = self.pass(resolved, context, options, remaining, model, cancel);
        if let GuardVerdict::Rejected(reason) = &second {
            tracing::info!("Rewording rejected, keeping the resolved self-correction: {reason}");
            return first;
        }
        second
    }

    /// One generation of `input` under `options`, within `seconds`, reviewed by the guard. The
    /// model sees the placeholders as words (see `PlaceholderAliases`); the guard sees tokens.
    fn pass<M: CleanupModel>(
        &self,
        input: &str,
        context: &[String],
        options: &CleanupOptions,
        seconds: f64,
        model: &mut M,
        cancel: &CancelFlag,
    ) -> GuardVerdict {
        let aliases = PlaceholderAliases::new(&options.placeholders, input);
        let model_options = CleanupOptions {
            placeholders: aliases.aliases(),
            ..options.clone()
        };
        let request = prompt::request(
            &aliases.aliased(input),
            context,
            self.context_limit,
            &self.prompts.template(&model_options),
        )
        .with_adapter(uses_adapter(options.level));
        let deadline = Deadline::new(self.clock.as_ref(), seconds, cancel);
        let generated = model.generate(&request, &deadline);
        // As the Mac app's race between the model and the timer ends: a cancelled cleanup is
        // cancelled whatever the model returned, and a reply after the deadline is too late.
        let outcome = if deadline.is_cancelled() {
            GenerationOutcome::Cancelled
        } else if deadline.has_passed() {
            GenerationOutcome::TimedOut { seconds }
        } else {
            match generated {
                Ok(text) => GenerationOutcome::Completed(aliases.restored(&text)),
                Err(error) => GenerationOutcome::Failed(error.to_string()),
            }
        };
        self.output_guard.review(input, &outcome, options)
    }

    fn elapsed_since(&self, started: Instant) -> Duration {
        self.clock.now().saturating_duration_since(started)
    }
}

/// What `level` does without the model: fillers removed at Medium and High, otherwise the text
/// unchanged. It is what the model is given, what a fallback returns, and what dictation inserts
/// when the cleanup model is turned off, so all three agree.
pub fn deterministic_cleanup(text: &str, level: CleanupLevel) -> String {
    if level.removes_fillers() {
        FillerRemover::default().removing_fillers(text)
    } else {
        text.to_owned()
    }
}

/// Whole milliseconds, rounded down.
fn whole_milliseconds(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests;
