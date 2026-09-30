//! The cleanup language model, which a runtime implements, and what the Mac app asks of it beyond
//! the prompt: the adapters, and the warm-up after loading (its `Cleaner` protocol and
//! `MLXCleaner`).

use std::fmt;

use lt_shared::CleanupLevel;

use crate::{Adapter, CleanupOptions, CleanupRequest, Deadline, PromptBuilder, prompt};

/// The cleanup model: one request in, the model's reply out. Everything around it (the level's
/// rules, the prompt, the adapter each request asks for, the deadline, the output guard and the
/// fallback) is [`crate::CleanupExecutor`]'s, so that every runtime cleans up as the Mac app does.
pub trait CleanupModel {
    type Error: std::error::Error;

    /// The model's reply to `request`: its messages through the model's chat template, with the
    /// template's variables set as `request.template_context` says; the fine-tuned adapter that
    /// `request.adapter` names switched on, and none for [`Adapter::Off`]; at most
    /// `request.max_tokens` tokens, chosen as `request.sampling` says. The reply is the generated
    /// text only, without the end-of-turn token; when the request thinks, with its reasoning, which
    /// the executor removes.
    ///
    /// As the Mac app's `MLXCleaner` does, a model without the adapter a request names runs Deep's
    /// requests with the self-correction adapter when it has that one, and any other on the base
    /// model. Trained to resolve self-corrections whatever the prompt says, an adapter would
    /// otherwise do so at Light too, where every word must stay, and the output guard would reject
    /// the result.
    ///
    /// Generation must stop soon after `deadline.should_stop()` turns true, which the model checks
    /// between tokens: the time is up, or the cleanup was cancelled. What it returns then is
    /// discarded, and the cleanup falls back.
    fn generate(&mut self, request: &CleanupRequest, deadline: &Deadline<'_>) -> Result<String, Self::Error>;
}

/// The first generation compiles kernels and can be slow; it gets a generous deadline.
pub const WARM_UP_TIMEOUT_SECONDS: f64 = 60.0;

/// The request that warms the model up once it has loaded: Medium's prompt, with the
/// self-correction adapter on when the model has it (`prompts.adapted`), and otherwise Deep's.
pub fn warm_up_request(prompts: &PromptBuilder) -> CleanupRequest {
    let template = prompts.template(&CleanupOptions::new(CleanupLevel::Medium));
    let adapter = if prompts.adapted {
        Adapter::Medium
    } else {
        Adapter::Deep
    };
    prompt::request("this is a warm up sentence", &[], 0, &template, adapter, None)
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
        assert_eq!(request.adapter, Adapter::Medium);
        assert_eq!(request.max_tokens, 6 * 2 + 16);
        assert!(!request.thinks());
    }

    /// Without the self-correction adapter, the warm-up asks for Deep's, which the model may have
    /// on its own.
    #[test]
    fn without_the_self_correction_adapter_the_warm_up_asks_for_deeps() {
        let prompts = PromptBuilder::new(false);
        let request = warm_up_request(&prompts);
        assert_eq!(request.adapter, Adapter::Deep);
        assert_eq!(
            request.messages[0].content,
            prompts.template(&CleanupOptions::new(CleanupLevel::Medium)).system
        );
    }
}
