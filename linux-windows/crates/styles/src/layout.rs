use lt_shared::sentence_case::capitalizing_first_word;
use lt_shared::swift_string::{self as s, CharacterSet};

use crate::letter_frame::LetterFrame;
use crate::list_layouts::{MarkedListLayout, OrdinalListLayout};

/// Rearranges one paragraph of cleaned text.
pub trait LayoutRule: Send + Sync {
    /// `lines`, one paragraph without blank lines, laid out; `None` to leave them as they are. A
    /// blank line in the result starts a new paragraph, as after a list.
    fn arrange(&self, lines: &[String]) -> Option<Vec<String>>;
}

/// Finds a structure in the words before cleanup.
pub trait FrameRule: Send + Sync {
    /// The frame around `text`, or `None` when the structure is not there. `list_markers` are the
    /// placeholders in `text` that start list items, such as a spoken "number one".
    fn frame(&self, text: &str, list_markers: &[String]) -> Option<TextFrame>;
}

/// Text split into a body the language model cleans and the laid-out text around it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextFrame {
    /// Laid out before the body, ending in the break that separates them.
    pub opening: String,
    /// The words the model cleans, placeholders and all.
    pub body: String,
    /// Laid out after the body, starting with the break that separates them.
    pub closing: String,
}

impl TextFrame {
    /// The frame around `cleaned_body`, which starts a paragraph and so a sentence.
    pub fn assembled(&self, cleaned_body: &str) -> String {
        let body = capitalizing_first_word(s::trimming(cleaned_body, CharacterSet::WhitespacesAndNewlines));
        format!("{}{}{}", self.opening, body, self.closing)
    }
}

/// Lays out dictated text by intent: lists become numbered or bulleted lines, a letter gets its
/// salutation and sign-off on lines of their own. Runs at Medium and High, in fields that take
/// several lines.
///
/// Two kinds of rule, so a new structure is one more rule:
/// - a [`FrameRule`] finds a structure in the words before cleanup and lays out the parts the
///   model must not rearrange, leaving the rest for the model to clean;
/// - a [`LayoutRule`] rearranges a paragraph of the cleaned text, whose spoken line breaks and
///   list markers are already newlines.
///
/// Rules only move and punctuate words; they never reword. Snippets, emoji and addresses are
/// still placeholders while the rules run, so a rule cannot change them either.
pub struct Layout {
    rules: Vec<Box<dyn LayoutRule>>,
    frames: Vec<Box<dyn FrameRule>>,
}

impl Default for Layout {
    /// Marked lists first, so the ordinal rule sees only prose.
    fn default() -> Self {
        Self::new(
            vec![
                Box::new(MarkedListLayout::default()),
                Box::new(OrdinalListLayout::default()),
            ],
            vec![Box::new(LetterFrame)],
        )
    }
}

impl Layout {
    pub fn new(rules: Vec<Box<dyn LayoutRule>>, frames: Vec<Box<dyn FrameRule>>) -> Self {
        Self { rules, frames }
    }

    /// The first frame that fits `text`, the transcript before cleanup; `None` when none does.
    pub fn frame(&self, text: &str, list_markers: &[String]) -> Option<TextFrame> {
        self.frames.iter().find_map(|rule| rule.frame(text, list_markers))
    }

    /// `text` with every rule applied to each paragraph in turn. Paragraphs are separated by a
    /// blank line and keep their order.
    pub fn arrange(&self, text: &str) -> String {
        text.split("\n\n")
            .map(|paragraph| {
                let mut lines: Vec<String> = paragraph.split('\n').map(str::to_owned).collect();
                for rule in &self.rules {
                    if let Some(arranged) = rule.arrange(&lines) {
                        lines = arranged;
                    }
                }
                lines.join("\n")
            })
            .collect::<Vec<_>>()
            .join("\n\n")
    }
}
