use lt_shared::swift_string::{self as s};

/// Qwen3's answer without its reasoning. With thinking on, the model reasons in a `<think>` block
/// and then answers; only the answer may reach the text field, and the output guard still rejects
/// any tag left in it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ThinkingOutput {
    /// The text after the reasoning, or the whole output when the model answered without any.
    Answer(String),
    /// The reasoning used up the token budget or was cut off before it ended, so there is no
    /// answer to use.
    Unfinished,
}

const OPENING: &str = "<think>";
const CLOSING: &str = "</think>";

impl ThinkingOutput {
    /// The answer in `output`: what follows the last closing tag, found as Foundation finds it
    /// (whole characters, compared by canonical equivalence).
    pub(crate) fn new(output: &str) -> Self {
        if let Some(closing) = s::last_range_of(output, CLOSING) {
            Self::Answer(output[closing.end..].to_owned())
        } else if s::contains_string(output, OPENING) {
            Self::Unfinished
        } else {
            Self::Answer(output.to_owned())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn answer(text: &str) -> ThinkingOutput {
        ThinkingOutput::Answer(text.to_owned())
    }

    #[test]
    fn strips_the_reasoning() {
        assert_eq!(
            ThinkingOutput::new("<think>\nhmm\n</think>\n\nThe answer."),
            answer("\n\nThe answer.")
        );
        assert_eq!(ThinkingOutput::new("The answer."), answer("The answer."));
        assert_eq!(
            ThinkingOutput::new("<think>a</think>b</think>c"),
            answer("c"),
            "the answer follows the last closing tag"
        );
        assert_eq!(ThinkingOutput::new("<think>\nstill going"), ThinkingOutput::Unfinished);
    }

    /// A tag with a combining mark on it is another character, as Swift reads it: the closing tag
    /// is not one, and neither is the opening tag.
    #[test]
    fn tags_are_whole_characters() {
        assert_eq!(
            ThinkingOutput::new("<think>a</think>\u{301}b"),
            ThinkingOutput::Unfinished
        );
        assert_eq!(ThinkingOutput::new("<think>\u{301}a"), answer("<think>\u{301}a"));
        assert_eq!(ThinkingOutput::new("x</think>"), answer(""));
    }
}
