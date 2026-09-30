use std::sync::Arc;
use std::time::{Duration, Instant};

use lt_shared::{CleanupLevel, edit_distance};
use lt_styles::FillerRemover;

use crate::placeholder_aliases::PlaceholderAliases;
use crate::thinking_output::ThinkingOutput;
use crate::{
    Adapter, CancelFlag, CleanupModel, CleanupOptions, CleanupRequest, Clock, Deadline, DeepCleanup, DeepPasses,
    FallbackReason, GenerationOutcome, GuardVerdict, OutputGuard, PromptBuilder, SystemClock, cleanup_scripts, prompt,
};

/// What one cleanup made of a text.
#[derive(Clone, Debug, PartialEq)]
pub struct CleanedText {
    /// The model's output, when the guard accepted it. Otherwise the text the model was given:
    /// the raw text, less fillers from Medium up.
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
/// The text the model sees is the raw transcript with fillers removed from Medium up. When the
/// guard rejects the output, that text is the result: fillers stay removed, so a fallback differs
/// from a success only in what the model would have corrected.
///
/// High runs in two passes when the text has a correction cue ("sorry", "no", "I mean"): the
/// Medium prompt resolves the self-correction, as the adapter was trained to, then the High prompt
/// rewords the result. Both share the one deadline. If the rewording is rejected or there is no
/// time left for it, the resolved text is used; that is a success at Medium's standard, not a
/// fallback.
///
/// Deep runs as [`DeepCleanup`] says: its own prompt, with or without the adapter, thinking or
/// not, after Medium's pass or on its own, under a longer deadline. When its repair is turned
/// down, Medium's result is used, from the pass before it or one run in the time left: a success
/// at Medium's standard, not a fallback.
#[derive(Clone)]
pub struct CleanupExecutor {
    context_limit: usize,
    timeout_seconds: f64,
    output_guard: OutputGuard,
    prompts: PromptBuilder,
    deep: DeepCleanup,
    clock: Arc<dyn Clock>,
}

impl CleanupExecutor {
    /// - `context_limit`: how many earlier segments the model sees before the text.
    /// - `timeout_seconds`: how long one cleanup may take, both of High's passes together. Deep
    ///   takes the longer of this and its own minimum ([`DeepCleanup::deadline`]).
    ///
    /// Deep runs as the app ships it ([`DeepCleanup::SHIPPED`]).
    pub fn new(context_limit: usize, timeout_seconds: f64, output_guard: OutputGuard, prompts: PromptBuilder) -> Self {
        Self {
            context_limit,
            timeout_seconds,
            output_guard,
            prompts,
            deep: DeepCleanup::SHIPPED,
            clock: Arc::new(SystemClock),
        }
    }

    /// The executor reading the time from `clock` instead of the system's.
    pub fn with_clock(self, clock: Arc<dyn Clock>) -> Self {
        Self { clock, ..self }
    }

    /// The executor running Deep as `deep` says.
    pub fn with_deep(self, deep: DeepCleanup) -> Self {
        Self { deep, ..self }
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

    pub fn deep(&self) -> &DeepCleanup {
        &self.deep
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

        let verdict = if options.level.repairs_across_sentences() {
            self.repairing(&input, context, options, started, model, cancel)
        } else if options.level.allows_rewording() && self.output_guard.correction_cue_count(&input) > 0 {
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

    /// What the model is asked for `text` under `options`. The adapter is on where the level
    /// resolves self-corrections, as it was trained to, and at Deep as [`DeepCleanup::adapter`]
    /// says; only Deep thinks.
    pub fn request(&self, text: &str, context: &[String], options: &CleanupOptions) -> CleanupRequest {
        let repairs = options.level.repairs_across_sentences();
        let adapter = if repairs {
            self.deep.adapter
        } else if options.level.resolves_self_corrections() {
            Adapter::Medium
        } else {
            Adapter::Off
        };
        prompt::request(
            text,
            context,
            self.context_limit,
            &self.prompts.template(options),
            adapter,
            (repairs && self.deep.thinking).then_some(self.deep.thinking_tokens),
        )
    }

    /// Deep: its own pass, under Deep's deadline. With [`DeepPasses::AfterMedium`] and a
    /// correction cue in the text, Medium's pass resolves what it can first; if Deep's pass is then
    /// rejected or out of time, Medium's result is kept, a success at Medium's standard. Otherwise,
    /// when Deep's answer is turned down, Medium's pass runs in the time left
    /// ([`DeepCleanup::falls_back_to_medium`]).
    fn repairing<M: CleanupModel>(
        &self,
        input: &str,
        context: &[String],
        options: &CleanupOptions,
        started: Instant,
        model: &mut M,
        cancel: &CancelFlag,
    ) -> GuardVerdict {
        let seconds = self.deep.deadline(self.timeout_seconds);
        let resolving = CleanupOptions {
            level: CleanupLevel::Medium,
            ..options.clone()
        };
        let resolves_first =
            self.deep.passes == DeepPasses::AfterMedium && self.output_guard.correction_cue_count(input) > 0;
        let mut resolved = None;
        if resolves_first {
            let first = self.pass(input, context, &resolving, seconds, model, cancel);
            if let GuardVerdict::Accepted(text) = first {
                resolved = Some(text);
            }
        }

        let remaining = self.remaining(seconds, started);
        let has_time = remaining > 0.0;
        if !has_time || cancel.is_cancelled() {
            return match resolved {
                Some(text) => GuardVerdict::Accepted(text),
                None if cancel.is_cancelled() => GuardVerdict::Rejected(FallbackReason::Cancelled),
                None => GuardVerdict::Rejected(FallbackReason::TimedOut { seconds }),
            };
        }
        let text = resolved.as_deref().unwrap_or(input);
        let repaired = self.pass(text, context, options, remaining, model, cancel);
        let GuardVerdict::Rejected(reason) = &repaired else {
            return repaired;
        };
        if let Some(text) = resolved {
            tracing::info!("Deep repair rejected, keeping Medium's result: {reason}");
            return GuardVerdict::Accepted(text);
        }
        if !self.deep.falls_back_to_medium || resolves_first || !reason.rejects_an_answer() {
            return repaired;
        }
        let left = self.remaining(seconds, started);
        let has_time = left > 0.0;
        if !has_time || cancel.is_cancelled() {
            return repaired;
        }
        let fallback = self.pass(input, context, &resolving, left, model, cancel);
        if !matches!(fallback, GuardVerdict::Accepted(_)) {
            return repaired;
        }
        tracing::info!("Deep repair rejected, showing Medium's cleanup: {reason}");
        fallback
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

        let remaining = self.remaining(self.timeout_seconds, started);
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
    /// model sees the placeholders as words (see `PlaceholderAliases`); the guard sees tokens. A
    /// model that thinks has its reasoning removed first, and one that never finished reasoning
    /// has no answer for the guard to review.
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
        let request = self.request(&aliases.aliased(input), context, &model_options);
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
                Ok(text) if request.thinks() => match ThinkingOutput::new(&text) {
                    ThinkingOutput::Answer(answer) => GenerationOutcome::Completed(aliases.restored(&answer)),
                    ThinkingOutput::Unfinished => return GuardVerdict::Rejected(FallbackReason::ThinkingUnfinished),
                },
                Ok(text) => GenerationOutcome::Completed(aliases.restored(&text)),
                Err(error) => GenerationOutcome::Failed(error.to_string()),
            }
        };
        self.output_guard.review(input, &outcome, options)
    }

    fn elapsed_since(&self, started: Instant) -> Duration {
        self.clock.now().saturating_duration_since(started)
    }

    /// What is left of `seconds` since `started`, counted in whole milliseconds as the Mac app
    /// counts it.
    fn remaining(&self, seconds: f64, started: Instant) -> f64 {
        seconds - whole_milliseconds(self.elapsed_since(started)) as f64 / 1_000.0
    }
}

/// What `level` does without the model: fillers removed from Medium up, otherwise the text
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
mod deep_tests;
#[cfg(test)]
mod tests;
