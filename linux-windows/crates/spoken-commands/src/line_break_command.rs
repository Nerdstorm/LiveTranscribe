use lt_shared::phrase_grammar;
use lt_shared::swift_string::{self as s};
use lt_shared::{InlineText, PhraseMatch, PhraseMatcher, Replacement, Role, TokenizedText};

struct Phrase {
    words: &'static [&'static str],
    lines: usize,
}

const PHRASES: [Phrase; 3] = [
    Phrase {
        words: &["new", "line"],
        lines: 1,
    },
    Phrase {
        words: &["newline"],
        lines: 1,
    },
    Phrase {
        words: &["new", "paragraph"],
        lines: 2,
    },
];

/// "New line" and "new paragraph": a line break, or a blank line, where the field takes several
/// lines, and a space where it does not, since a newline there could send a message or submit a
/// form.
///
/// The words stay words after a determiner or a possessive ("a new line of laptops", "Apple's new
/// line") or before "of" ("new line of code"). A break goes behind a placeholder, so the model
/// cannot drop it; [`crate::tidy_line_breaks`] tidies the text around it once it is put back. A
/// space is written straight into the text.
#[derive(Clone, Copy, Debug)]
pub struct LineBreakCommand {
    multiline: bool,
}

impl LineBreakCommand {
    pub fn new(multiline: bool) -> Self {
        Self { multiline }
    }
}

impl PhraseMatcher for LineBreakCommand {
    fn matches(&self, text: &TokenizedText) -> Vec<PhraseMatch> {
        let mut found = Vec::new();
        for position in 0..text.words().len() {
            if phrase_grammar::follows_determiner(position, text) {
                continue;
            }
            for phrase in &PHRASES {
                if !phrase_grammar::matches(phrase.words, position, text) {
                    continue;
                }
                let end = position + phrase.words.len();
                if end < text.words().len() && s::canonically_equal(&text.words()[end].text, "of") {
                    continue;
                }
                let replacement = if self.multiline {
                    Replacement::Placeholder {
                        trigger: phrase.words.join(" "),
                        expansion: "\n".repeat(phrase.lines),
                        role: Role::LineBreak,
                    }
                } else {
                    Replacement::Inline(InlineText {
                        joins_previous: true,
                        joins_next: true,
                        ..InlineText::new(" ")
                    })
                };
                let kept_trailing = phrase_grammar::trailing_after_clause_punctuation(text.token_of_word(end - 1));
                found.push(PhraseMatch {
                    kept_trailing,
                    ..PhraseMatch::new(position..end, replacement)
                });
            }
        }
        found
    }
}
