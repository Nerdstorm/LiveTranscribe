//! The cleanup prompt: the template's system instruction and examples, then prior segments as
//! already-answered turns (read-only context), then the text to fix as the final user turn.
//!
//! Context goes in earlier turns rather than in the final message because a small model asked to
//! correct "CONTEXT + TEXT" in one message tends to return both, which the output guard then has
//! to reject.

use std::collections::BTreeMap;

use lt_shared::swift_string::{self as s, CharacterSet};
use lt_shared::{CleanupLevel, edit_distance, placeholder_token};

use crate::{CleanupOptions, PromptBuilder};

/// Who says a message in the chat the model continues.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Role {
    System,
    User,
    Assistant,
}

impl Role {
    /// The role's name in the chat template.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::User => "user",
            Self::Assistant => "assistant",
        }
    }
}

/// One message of the chat.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    pub role: Role,
    pub content: String,
}

impl Message {
    pub fn new(role: Role, content: impl Into<String>) -> Self {
        Self {
            role,
            content: content.into(),
        }
    }
}

/// How the model picks each token of its reply.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sampling {
    /// The likeliest token every time (temperature 0), as the Mac app generates, so the same text
    /// always cleans up the same way.
    Greedy,
}

/// Everything the cleanup model is asked, as plain values: what a runtime needs to generate the
/// reply.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CleanupRequest {
    pub messages: Vec<Message>,
    /// Variables for the chat template (see [`template_context`]).
    pub template_context: BTreeMap<String, bool>,
    /// The most tokens the reply may have (see [`max_tokens`]).
    pub max_tokens: usize,
    /// Whether the fine-tuned adapter is switched on for this request, when the model has one
    /// (see [`crate::uses_adapter`]).
    pub use_adapter: bool,
    pub sampling: Sampling,
}

impl CleanupRequest {
    /// The request with the adapter switched on or off.
    pub fn with_adapter(self, use_adapter: bool) -> Self {
        Self { use_adapter, ..self }
    }
}

/// The system instruction and worked examples that frame every cleanup request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PromptTemplate {
    pub system: String,
    pub examples: Vec<Example>,
}

/// A raw text and its cleaned version, sent as an answered turn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Example {
    pub text: String,
    pub cleaned: String,
}

/// Qwen3's chat template reads this variable. Thinking must be off: with it on, latency grows by
/// seconds and `<think>` blocks leak into the output.
pub const ENABLE_THINKING: &str = "enable_thinking";

/// Output budget: two tokens per input word plus a fixed allowance for punctuation, plus room for
/// each placeholder, whose brackets take several tokens each.
pub const MAX_TOKENS_PER_INPUT_WORD: usize = 2;
pub const MAX_TOKENS_ALLOWANCE: usize = 16;
pub const MAX_TOKENS_PER_PLACEHOLDER: usize = 6;

/// Strict correction, the Light level's prompt and every level's without the adapter: the model is
/// told to remove nothing, so spoken self-corrections normally stay as said ("cars, sorry,
/// buses"). Asking Qwen3-1.7B to resolve them, by instruction or by worked examples, resolved at
/// most 1 in 7 correctly, usually kept the retracted words instead of the correction, and made it
/// drop hedges such as "I think" elsewhere. At Medium and High, the output guard still accepts a
/// correct resolution if the model makes one.
pub fn cleanup() -> PromptTemplate {
    PromptBuilder::new(false).template(&CleanupOptions::new(CleanupLevel::Light))
}

/// Used with the bundled fine-tuned adapter, which was trained on exactly this prompt: the Medium
/// level's. The one removal it allows is a spoken self-correction; the adapter supplies the
/// ability the base model lacks, and the output guard checks that nothing else was removed.
pub fn adapted() -> PromptTemplate {
    PromptBuilder::new(true).template(&CleanupOptions::new(CleanupLevel::Medium))
}

/// The chat template's variables for every request: thinking off.
pub fn template_context() -> BTreeMap<String, bool> {
    BTreeMap::from([(ENABLE_THINKING.to_owned(), false)])
}

/// The request for cleaning `text`, with the most recent `context_limit` segments of `context`
/// before it. The adapter is off; the executor switches it on for the levels that use it.
pub fn request(text: &str, context: &[String], context_limit: usize, template: &PromptTemplate) -> CleanupRequest {
    let mut messages = vec![Message::new(Role::System, template.system.clone())];
    for example in &template.examples {
        messages.push(Message::new(Role::User, user_message(&example.text)));
        messages.push(Message::new(Role::Assistant, example.cleaned.clone()));
    }
    for previous in context_window(context, context_limit) {
        messages.push(Message::new(Role::User, user_message(&previous)));
        messages.push(Message::new(Role::Assistant, previous));
    }
    messages.push(Message::new(Role::User, user_message(text)));
    CleanupRequest {
        messages,
        template_context: template_context(),
        max_tokens: max_tokens(text),
        use_adapter: false,
        sampling: Sampling::Greedy,
    }
}

/// The most recent `limit` non-empty context segments, trimmed, oldest first.
pub fn context_window(context: &[String], limit: usize) -> Vec<String> {
    if limit == 0 {
        return Vec::new();
    }
    let non_empty: Vec<&str> = context
        .iter()
        .map(|segment| s::trimming(segment, CharacterSet::WhitespacesAndNewlines))
        .filter(|segment| !segment.is_empty())
        .collect();
    non_empty[non_empty.len().saturating_sub(limit)..]
        .iter()
        .map(|&segment| segment.to_owned())
        .collect()
}

/// The reply's token budget for `text`.
pub fn max_tokens(text: &str) -> usize {
    edit_distance::words(text).len() * MAX_TOKENS_PER_INPUT_WORD
        + placeholder_token::opening_count(text) * MAX_TOKENS_PER_PLACEHOLDER
        + MAX_TOKENS_ALLOWANCE
}

pub(crate) fn user_message(text: &str) -> String {
    format!("TEXT:\n{text}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|&value| value.to_owned()).collect()
    }

    #[test]
    fn context_is_truncated_to_the_most_recent_segments() {
        let context = strings(&["one.", "two.", "three.", "four.", "five."]);
        assert_eq!(context_window(&context, 3), ["three.", "four.", "five."]);
        assert_eq!(context_window(&context, 10), context);
        assert!(context_window(&context, 0).is_empty());
    }

    #[test]
    fn blank_context_segments_are_skipped() {
        assert_eq!(context_window(&strings(&["a.", "  ", "", "b."]), 3), ["a.", "b."]);
        assert_eq!(context_window(&strings(&[" \n a. \t"]), 3), ["a."]);
    }

    fn template() -> PromptTemplate {
        PromptTemplate {
            system: "Fix the TEXT.".to_owned(),
            examples: vec![Example {
                text: "example in".to_owned(),
                cleaned: "Example out.".to_owned(),
            }],
        }
    }

    #[test]
    fn examples_then_context_become_answered_turns_before_the_text() {
        let request = request(
            "the text to fix",
            &strings(&["Earlier one.", "Earlier two."]),
            1,
            &template(),
        );
        assert_eq!(
            request.messages,
            [
                Message::new(Role::System, "Fix the TEXT."),
                Message::new(Role::User, "TEXT:\nexample in"),
                Message::new(Role::Assistant, "Example out."),
                Message::new(Role::User, "TEXT:\nEarlier two."),
                Message::new(Role::Assistant, "Earlier two."),
                Message::new(Role::User, "TEXT:\nthe text to fix"),
            ]
        );
    }

    #[test]
    fn without_examples_or_context_only_the_text_is_sent() {
        let template = PromptTemplate {
            system: "Fix the TEXT.".to_owned(),
            examples: Vec::new(),
        };
        assert_eq!(
            request("hello", &[], 3, &template).messages,
            [
                Message::new(Role::System, "Fix the TEXT."),
                Message::new(Role::User, "TEXT:\nhello"),
            ]
        );
    }

    #[test]
    fn thinking_is_disabled_and_decoding_is_greedy() {
        let request = request("hello", &[], 3, &cleanup());
        assert_eq!(request.template_context.get(ENABLE_THINKING), Some(&false));
        assert_eq!(request.template_context.len(), 1);
        assert_eq!(request.sampling, Sampling::Greedy);
        assert!(!request.use_adapter);
        assert!(request.clone().with_adapter(true).use_adapter);
    }

    #[test]
    fn requests_use_the_template_they_are_given() {
        let request = request("hello", &[], 3, &cleanup());
        assert_eq!(
            request.messages,
            [
                Message::new(Role::System, cleanup().system),
                Message::new(Role::User, "TEXT:\nhello"),
            ]
        );
        assert!(
            cleanup()
                .system
                .contains("Do not add, remove, summarise or rephrase content.")
        );
        assert!(cleanup().system.contains("Output only the corrected text."));
    }

    #[test]
    fn token_budget_is_twice_per_word_plus_allowance() {
        assert_eq!(max_tokens("one two three"), 2 * 3 + 16);
        assert_eq!(request("a b c d e", &[], 0, &cleanup()).max_tokens, 26);
    }

    #[test]
    fn placeholders_get_extra_token_budget() {
        assert_eq!(max_tokens("send ⟦S1⟧ and ⟦S2⟧"), 2 * 4 + 2 * 6 + 16);
    }

    #[test]
    fn roles_have_the_chat_templates_names() {
        assert_eq!(
            [Role::System, Role::User, Role::Assistant].map(Role::as_str),
            ["system", "user", "assistant"]
        );
    }
}
