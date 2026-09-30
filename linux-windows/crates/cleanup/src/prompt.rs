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

/// Which fine-tuned adapter is on for a request: the Mac app's `CleanupRequest.Adapter`, named as
/// it names them ([`Adapter::as_str`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Adapter {
    /// The base model.
    Off,
    /// The self-correction adapter, trained on Medium's prompt ([`adapted`]).
    Medium,
    /// Deep's adapter, trained on Deep's prompts.
    Deep,
}

impl Adapter {
    pub const ALL: [Self; 3] = [Self::Off, Self::Medium, Self::Deep];

    /// The name the Mac app records and trains the adapter under: `none`, `medium` or `deep`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "none",
            Self::Medium => "medium",
            Self::Deep => "deep",
        }
    }
}

/// How the model picks each token of its reply.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sampling {
    pub temperature: f32,
    pub top_p: f32,
    pub top_k: usize,
    /// Seeds the sampler, so the same text always gets the same answer; unused when greedy.
    pub seed: Option<u64>,
}

impl Sampling {
    /// The likeliest token every time (temperature 0), as the Mac app generates unless Deep
    /// thinks, so the same text always cleans up the same way.
    pub const GREEDY: Self = Self {
        temperature: 0.0,
        top_p: 1.0,
        top_k: 0,
        seed: None,
    };

    /// Qwen3's settings for thinking mode, where greedy decoding tends to repeat itself.
    pub fn thinking(seed: u64) -> Self {
        Self {
            temperature: 0.6,
            top_p: 0.95,
            top_k: 20,
            seed: Some(seed),
        }
    }
}

/// Everything the cleanup model is asked, as plain values: what a runtime needs to generate the
/// reply.
#[derive(Clone, Debug, PartialEq)]
pub struct CleanupRequest {
    pub messages: Vec<Message>,
    /// Variables for the chat template (see [`template_context`]).
    pub template_context: BTreeMap<String, bool>,
    /// The most tokens the reply may have (see [`max_tokens`]), reasoning included.
    pub max_tokens: usize,
    /// The fine-tuned adapter on for this request (see [`crate::CleanupModel`]).
    pub adapter: Adapter,
    pub sampling: Sampling,
}

impl CleanupRequest {
    /// The model reasons in a `<think>` block before it answers (Deep, when thinking is on).
    pub fn thinks(&self) -> bool {
        self.template_context.get(ENABLE_THINKING) == Some(&true)
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

/// Qwen3's chat template reads this variable. Thinking is off at every level but in Deep's thinking
/// mode: with it on, latency grows by seconds and the `<think>` block has to be removed from the
/// output (see `ThinkingOutput`).
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
/// drop hedges such as "I think" elsewhere. From Medium up, the output guard still accepts a correct
/// resolution if the model makes one.
pub fn cleanup() -> PromptTemplate {
    PromptBuilder::new(false).template(&CleanupOptions::new(CleanupLevel::Light))
}

/// Used with the bundled fine-tuned adapter, which was trained on exactly this prompt: the Medium
/// level's. The one removal it allows is a spoken self-correction; the adapter supplies the
/// ability the base model lacks, and the output guard checks that nothing else was removed.
pub fn adapted() -> PromptTemplate {
    PromptBuilder::new(true).template(&CleanupOptions::new(CleanupLevel::Medium))
}

/// The chat template's variables for a request without thinking.
pub fn template_context() -> BTreeMap<String, bool> {
    BTreeMap::from([(ENABLE_THINKING.to_owned(), false)])
}

/// The chat template's variables for a request that thinks first.
fn thinking_template_context() -> BTreeMap<String, bool> {
    BTreeMap::from([(ENABLE_THINKING.to_owned(), true)])
}

/// The request for cleaning `text`, with the most recent `context_limit` segments of `context`
/// before it, and `adapter` on.
///
/// With `thinking_tokens`, the model thinks first, with that many tokens for its reasoning on top
/// of the answer's budget, sampled as Qwen3 recommends from a seed that depends only on `text`.
/// Without, it answers at once and is decoded greedily.
pub fn request(
    text: &str,
    context: &[String],
    context_limit: usize,
    template: &PromptTemplate,
    adapter: Adapter,
    thinking_tokens: Option<usize>,
) -> CleanupRequest {
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
    match thinking_tokens {
        None => CleanupRequest {
            messages,
            template_context: template_context(),
            max_tokens: max_tokens(text),
            adapter,
            sampling: Sampling::GREEDY,
        },
        Some(thinking_tokens) => CleanupRequest {
            messages,
            template_context: thinking_template_context(),
            max_tokens: max_tokens(text) + thinking_tokens,
            adapter,
            sampling: Sampling::thinking(seed(text)),
        },
    }
}

/// A seed that depends only on `text` (FNV-1a over its UTF-8), so sampling is repeatable.
fn seed(text: &str) -> u64 {
    text.bytes().fold(14_695_981_039_346_656_037, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(1_099_511_628_211)
    })
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

    /// A request with no adapter that answers at once.
    fn plain(text: &str, context: &[String], context_limit: usize, template: &PromptTemplate) -> CleanupRequest {
        request(text, context, context_limit, template, Adapter::Off, None)
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
        let request = plain(
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
            plain("hello", &[], 3, &template).messages,
            [
                Message::new(Role::System, "Fix the TEXT."),
                Message::new(Role::User, "TEXT:\nhello"),
            ]
        );
    }

    #[test]
    fn thinking_is_disabled_and_decoding_is_greedy() {
        let request = plain("hello", &[], 3, &cleanup());
        assert_eq!(request.template_context.get(ENABLE_THINKING), Some(&false));
        assert_eq!(request.template_context.len(), 1);
        assert_eq!(request.sampling, Sampling::GREEDY);
        assert!(!request.thinks());
        assert_eq!(request.adapter, Adapter::Off);
        let adapted = super::request("hello", &[], 3, &cleanup(), Adapter::Deep, None);
        assert_eq!(adapted.adapter, Adapter::Deep);
        assert_eq!(adapted.max_tokens, request.max_tokens);
    }

    /// Deep's thinking mode: the template's variable on, the reasoning's tokens on top of the
    /// answer's, and Qwen3's sampling from a seed that depends only on the text.
    #[test]
    fn thinking_samples_from_a_seed_that_depends_on_the_text() {
        let thinking = |text: &str| request(text, &[], 0, &cleanup(), Adapter::Deep, Some(32));
        let first = thinking("I tried to speak with Kirk.");
        assert!(first.thinks());
        assert_eq!(first.template_context.get(ENABLE_THINKING), Some(&true));
        assert_eq!(first.max_tokens, max_tokens("I tried to speak with Kirk.") + 32);
        assert_eq!(first.sampling.temperature, 0.6);
        assert_eq!(first.sampling.top_p, 0.95);
        assert_eq!(first.sampling.top_k, 20);
        assert_eq!(first.sampling, thinking("I tried to speak with Kirk.").sampling);
        assert_ne!(first.sampling.seed, thinking("Something else.").sampling.seed);
    }

    /// FNV-1a's offset basis for no bytes, and its published value for "a".
    #[test]
    fn the_seed_is_fnv_1a() {
        assert_eq!(seed(""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(seed("a"), 0xaf63_dc4c_8601_ec8c);
    }

    #[test]
    fn adapters_have_the_mac_apps_names() {
        assert_eq!(Adapter::ALL.map(Adapter::as_str), ["none", "medium", "deep"]);
    }

    #[test]
    fn requests_use_the_template_they_are_given() {
        let request = plain("hello", &[], 3, &cleanup());
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
        assert_eq!(plain("a b c d e", &[], 0, &cleanup()).max_tokens, 26);
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
