//! The cleanup language model, which a runtime implements, and what the Mac app asks of it beyond
//! the prompt: the adapter per level, and the warm-up after loading (its `Cleaner` protocol and
//! `MLXCleaner`).

use std::fmt;

use lt_shared::CleanupLevel;

use crate::{CleanupOptions, CleanupRequest, Deadline, PromptBuilder, prompt};

/// The cleanup model: one request in, the model's reply out. Everything around it (the level's
/// rules, the prompt, the deadline, the output guard and the fallback) is
/// [`crate::CleanupExecutor`]'s, so that every runtime cleans up as the Mac app does.
pub trait CleanupModel {
    type Error: std::error::Error;

    /// The model's reply to `request`: its messages through the model's chat template, with the
    /// template's variables set as `request.template_context` says; the fine-tuned adapter on or
    /// off as `request.use_adapter` says, when the model has one; at most `request.max_tokens`
    /// tokens, chosen as `request.sampling` says. The reply is the generated text only, without
    /// the end-of-turn token.
    ///
    /// Generation must stop soon after `deadline.should_stop()` turns true, which the model checks
    /// between tokens: the time is up, or the cleanup was cancelled. What it returns then is
    /// discarded, and the cleanup falls back.
    fn generate(&mut self, request: &CleanupRequest, deadline: &Deadline<'_>) -> Result<String, Self::Error>;
}

/// Whether the fine-tuned adapter is on for a request at `level`: only at the levels that resolve
/// self-corrections, Medium and High. Trained to resolve them whatever the prompt says, the
/// adapter would otherwise do so at Light too, where every word must stay, and the output guard
/// would reject the result. Off, it leaves the base model and costs no compute. High's two passes
/// both have it on.
pub fn uses_adapter(level: CleanupLevel) -> bool {
    level.resolves_self_corrections()
}

/// The first generation compiles kernels and can be slow; it gets a generous deadline.
pub const WARM_UP_TIMEOUT_SECONDS: f64 = 60.0;

/// The request that warms the model up once it has loaded: Medium's prompt, with the adapter on.
pub fn warm_up_request(prompts: &PromptBuilder) -> CleanupRequest {
    let template = prompts.template(&CleanupOptions::new(CleanupLevel::Medium));
    prompt::request("this is a warm up sentence", &[], 0, &template).with_adapter(true)
}

/// A cleanup was asked for before the model loaded. As a model it fails every request, so the
/// level's rules still apply and the cleanup falls back with the Mac app's reason.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CleanupModelNotLoaded;

impl fmt::Display for CleanupModelNotLoaded {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "cleanup model not loaded")
    }
}

impl std::error::Error for CleanupModelNotLoaded {}

impl CleanupModel for CleanupModelNotLoaded {
    type Error = Self;

    fn generate(&mut self, _request: &CleanupRequest, _deadline: &Deadline<'_>) -> Result<String, Self> {
        Err(Self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Message, Role};

    #[test]
    fn only_the_levels_that_resolve_self_corrections_use_the_adapter() {
        let using: Vec<_> = CleanupLevel::ALL
            .into_iter()
            .filter(|&level| uses_adapter(level))
            .collect();
        assert_eq!(using, [CleanupLevel::Medium, CleanupLevel::High]);
    }

    #[test]
    fn the_warm_up_is_a_medium_request_with_the_adapter_on() {
        let prompts = PromptBuilder::new(true);
        let request = warm_up_request(&prompts);
        assert_eq!(
            request.messages,
            [
                Message::new(Role::System, prompt::adapted().system),
                Message::new(Role::User, "TEXT:\nthis is a warm up sentence"),
            ]
        );
        assert!(request.use_adapter);
        assert_eq!(request.max_tokens, 6 * 2 + 16);
    }
}
