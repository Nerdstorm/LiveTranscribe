//! Qwen3's chat template, rendered as Hugging Face's
//! `tokenizer.apply_chat_template(messages, add_generation_prompt=True, enable_thinking=...)`
//! renders it for messages of text: system, user and assistant turns, without tools.
//!
//! The template is Jinja in the model's tokenizer_config.json. Rather than interpret Jinja, this
//! module writes out what the template does for such messages, and [`is_known_template`] checks
//! that a model's template is one it was written from. The prompt's ids then come from encoding
//! the rendered text, as `apply_chat_template(tokenize=True)` makes them.

use std::fmt;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Who a message is from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    System,
    User,
    Assistant,
}

impl Role {
    fn name(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::User => "user",
            Self::Assistant => "assistant",
        }
    }
}

/// One turn of a chat.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct Message {
    pub role: Role,
    pub content: String,
}

impl Message {
    pub fn system(content: impl Into<String>) -> Self {
        Self {
            role: Role::System,
            content: content.into(),
        }
    }

    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: Role::User,
            content: content.into(),
        }
    }

    pub fn assistant(content: impl Into<String>) -> Self {
        Self {
            role: Role::Assistant,
            content: content.into(),
        }
    }
}

/// Why a chat couldn't be rendered.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChatError {
    /// The template reads the first message, so a chat needs one.
    NoMessages,
}

impl fmt::Display for ChatError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoMessages => f.write_str("a chat needs at least one message"),
        }
    }
}

impl std::error::Error for ChatError {}

/// The SHA-256s of the chat templates [`render`] was written from: Qwen/Qwen3-1.7B's since July
/// 2025 (revision 70d244c), and the one before it, which mlx-community/Qwen3-1.7B-4bit (the Mac's
/// model) and OpenVINO/Qwen3-1.7B-int4-ov carry. The two render text messages alike; they differ
/// only for contents that aren't text.
const KNOWN_TEMPLATES: [&str; 2] = [
    "a55ee1b1660128b7098723e0abcd92caa0788061051c62d51cbe87d9cf1974d8",
    "87a2728cb8dc9fe424d624542f6060ec05a1d285ebbec578bb078900e33396b5",
];

/// Whether `template`, a model's `chat_template`, is one [`render`] renders.
pub fn is_known_template(template: &str) -> bool {
    let digest = Sha256::digest(template.as_bytes());
    let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    KNOWN_TEMPLATES.contains(&hex.as_str())
}

/// The prompt for `messages`: each turn as `<|im_start|>role\n…<|im_end|>\n`, then the assistant's
/// turn opened for its reply. With `thinking` off, that turn starts with an empty think block, as
/// `enable_thinking=False` makes it, so the model answers straight away.
///
/// As the template does:
/// - a first system message comes first; a later one is a turn like a user's;
/// - an assistant message's reasoning (`<think>…</think>` before its answer) is dropped, except in
///   turns after the last user message, where it is kept (and a last assistant turn gets a think
///   block even when it has none);
/// - a user message that is wholly a `<tool_response>` doesn't count as the last user message.
pub fn render(messages: &[Message], thinking: bool) -> Result<String, ChatError> {
    let first = messages.first().ok_or(ChatError::NoMessages)?;
    let mut prompt = String::new();
    if first.role == Role::System {
        push_turn(&mut prompt, Role::System, &first.content);
    }
    let last_query = messages
        .iter()
        .rposition(|message| message.role == Role::User && !is_tool_response(&message.content))
        .unwrap_or(messages.len() - 1);
    for (index, message) in messages.iter().enumerate() {
        match message.role {
            Role::User => push_turn(&mut prompt, Role::User, &message.content),
            Role::System if index > 0 => push_turn(&mut prompt, Role::System, &message.content),
            Role::System => {}
            Role::Assistant => {
                let (reasoning, answer) = split_reasoning(&message.content);
                prompt.push_str("<|im_start|>assistant\n");
                let is_last = index + 1 == messages.len();
                if index > last_query && (is_last || !reasoning.is_empty()) {
                    prompt.push_str("<think>\n");
                    prompt.push_str(reasoning.trim_matches('\n'));
                    prompt.push_str("\n</think>\n\n");
                    prompt.push_str(answer.trim_start_matches('\n'));
                } else {
                    prompt.push_str(answer);
                }
                prompt.push_str("<|im_end|>\n");
            }
        }
    }
    prompt.push_str("<|im_start|>assistant\n");
    if !thinking {
        prompt.push_str("<think>\n\n</think>\n\n");
    }
    Ok(prompt)
}

fn push_turn(prompt: &mut String, role: Role, content: &str) {
    prompt.push_str("<|im_start|>");
    prompt.push_str(role.name());
    prompt.push('\n');
    prompt.push_str(content);
    prompt.push_str("<|im_end|>\n");
}

fn is_tool_response(content: &str) -> bool {
    content.starts_with("<tool_response>") && content.ends_with("</tool_response>")
}

/// An assistant message's reasoning and answer, as the template splits them: with a `</think>` in
/// it, the reasoning is what comes before the first `</think>` and after the last `<think>` before
/// that, and the answer what comes after the last `</think>`, line breaks trimmed where the
/// template trims them. Without one, it is all answer.
fn split_reasoning(content: &str) -> (&str, &str) {
    if !content.contains("</think>") {
        return ("", content);
    }
    let before_close = content.split("</think>").next().unwrap_or_default();
    let reasoning = before_close
        .trim_end_matches('\n')
        .rsplit("<think>")
        .next()
        .unwrap_or_default()
        .trim_start_matches('\n');
    let answer = content
        .rsplit("</think>")
        .next()
        .unwrap_or_default()
        .trim_start_matches('\n');
    (reasoning, answer)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opens_the_reply_with_an_empty_think_block_without_thinking() {
        let messages = [Message::system("Fix it."), Message::user("TEXT:\nhi")];
        assert_eq!(
            render(&messages, false).unwrap(),
            "<|im_start|>system\nFix it.<|im_end|>\n<|im_start|>user\nTEXT:\nhi<|im_end|>\n\
             <|im_start|>assistant\n<think>\n\n</think>\n\n"
        );
        assert!(render(&messages, true).unwrap().ends_with("<|im_start|>assistant\n"));
    }

    #[test]
    fn drops_reasoning_from_turns_before_the_last_question() {
        let messages = [
            Message::user("q1"),
            Message::assistant("<think>\nr\n</think>\n\na1"),
            Message::user("q2"),
        ];
        assert_eq!(
            render(&messages, true).unwrap(),
            "<|im_start|>user\nq1<|im_end|>\n<|im_start|>assistant\na1<|im_end|>\n\
             <|im_start|>user\nq2<|im_end|>\n<|im_start|>assistant\n"
        );
    }

    #[test]
    fn a_chat_needs_a_message() {
        assert_eq!(render(&[], false), Err(ChatError::NoMessages));
    }

    #[test]
    fn splits_reasoning_as_the_template_does() {
        assert_eq!(split_reasoning("a<think>\nx\n</think>\n\nb"), ("x", "b"));
        assert_eq!(split_reasoning("<think>a<think>b</think>c</think>\nd"), ("b", "d"));
        assert_eq!(split_reasoning("plain"), ("", "plain"));
    }
}
