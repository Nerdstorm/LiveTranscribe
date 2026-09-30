use lt_cleanup::deterministic_cleanup;
use lt_shared::swift_string::{self as s};
use lt_shared::{CleanupLevel, PhraseMatcher, PhraseProtector, Placeholder, ProtectedText, Role};
use lt_snippets::SnippetExpander;
use lt_styles::{Layout, ListMarkerCommand, TextFrame};
use lt_vocabulary::VocabularyReplacer;

use crate::Configuration;

const SENTENCE_ENDERS: [&str; 3] = [".", "!", "?"];

/// One transcript made ready for cleanup, and the steps that turn the cleaned text into the text
/// to insert.
///
/// Snippet triggers, spoken commands (emoji, punctuation, line breaks, addresses) and, where lists
/// are laid out, spoken list markers are replaced before vocabulary and the model run (see
/// [`PhraseProtector`]); the user's snippets come first, so a snippet wins over a command with the
/// same words. Afterwards the placeholders come back in two steps: line breaks and list markers
/// first, so the layout rules see lines, then snippets, emoji and addresses, so no rule can change
/// them.
pub(crate) struct PreparedDictation {
    /// The transcript with phrases replaced and vocabulary applied: what cleanup starts from.
    text: String,
    /// Lists and letters are laid out: from Medium up, in fields that take several lines.
    lays_out: bool,
    protected: ProtectedText,
    layout: Layout,
}

impl PreparedDictation {
    pub fn new(transcript: &str, configuration: &Configuration) -> Self {
        let lays_out = configuration.level.formats_layout() && configuration.multiline;
        let mut matchers: Vec<Box<dyn PhraseMatcher>> = vec![Box::new(SnippetExpander::new(&configuration.snippets))];
        matchers.extend(lt_spoken_commands::matchers(configuration.multiline));
        if lays_out {
            matchers.push(Box::new(ListMarkerCommand));
        }
        let protected = PhraseProtector::new(matchers).protect(transcript);
        let text = VocabularyReplacer::new(&configuration.vocabulary).apply(protected.text());
        Self {
            text,
            lays_out,
            protected,
            layout: Layout::default(),
        }
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    /// The placeholder tokens in the text, which cleanup must keep.
    pub fn placeholders(&self) -> Vec<String> {
        self.protected.tokens().into_iter().map(str::to_owned).collect()
    }

    /// Whether the speaker laid `body` out: it holds a line break or list marker they said, which
    /// the layout rules lay out after cleanup. Deep's model then leaves the layout to the rules, or
    /// both would lay out the same list.
    pub fn has_spoken_layout(&self, body: &str) -> bool {
        self.protected
            .placeholders()
            .iter()
            .any(|placeholder| placeholder.role != Role::Content && body.contains(placeholder.token.as_str()))
    }

    /// The text before cleanup, which Undo AI edit puts back: phrases replaced and line breaks in
    /// place, but list markers as they were said and nothing laid out.
    pub fn uncleaned(&self) -> String {
        let text = self.without_full_stops_after_emoji(&self.text);
        if let Some(restored) = self
            .protected
            .restore_resolving(&text, |placeholder| Some(as_said(placeholder)))
        {
            return self.tidied(&restored);
        }
        // Vocabulary replacement skips placeholders, so this means a bug there.
        tracing::error!("Placeholders did not survive vocabulary replacement; using the text without vocabulary");
        self.tidied(&self.protected.expanded_with(as_said))
    }

    /// The structure in the text that must be laid out before the model runs, such as a letter's
    /// greeting and sign-off; `None` when there is none or nothing is laid out. Found after the
    /// level's filler removal, so "Um, dear Sam" still starts with its greeting.
    pub fn frame(&self, level: CleanupLevel) -> Option<TextFrame> {
        if !self.lays_out {
            return None;
        }
        let list_markers: Vec<String> = self
            .protected
            .placeholders()
            .iter()
            .filter(|placeholder| placeholder.role == Role::Structure)
            .map(|placeholder| placeholder.token.clone())
            .collect();
        self.layout
            .frame(&deterministic_cleanup(&self.text, level), &list_markers)
    }

    /// `cleaned`, cleanup's output with every placeholder in it, as the text to insert; `None` when
    /// a placeholder did not survive.
    pub fn finished(&self, cleaned: &str) -> Option<String> {
        let punctuated = self.without_full_stops_after_emoji(&self.without_added_commas_around_emoji(cleaned));
        let lines = self.protected.restore_resolving(&punctuated, layout_expansion)?;
        let tidy = self.tidied(&lines);
        let arranged = if self.lays_out {
            self.layout.arrange(&tidy)
        } else {
            tidy
        };
        self.protected.restore_roles(&arranged, &[Role::Content])
    }

    /// The emoji placeholders: content placeholders whose expansion is emoji.
    fn emoji_placeholders(&self) -> impl Iterator<Item = &Placeholder> {
        self.protected
            .placeholders()
            .iter()
            .filter(|placeholder| placeholder.role == Role::Content && is_emoji(&placeholder.expansion))
    }

    /// `cleaned` without the commas the model put next to an emoji's placeholder and the speaker
    /// did not say. The model sees the placeholder as a word and punctuates it like a name: "Great
    /// job, S1, see you tomorrow."
    fn without_added_commas_around_emoji(&self, cleaned: &str) -> String {
        let mut result = cleaned.to_owned();
        for placeholder in self.emoji_placeholders() {
            let Some(said) = s::range_of(&self.text, &placeholder.token) else {
                continue;
            };
            let said_comma_before = last_non_whitespace(&self.text[..said.start]).is_some_and(is_comma);
            let said_comma_after = first_non_whitespace(&self.text[said.end..]).is_some_and(is_comma);
            if !said_comma_after
                && let Some(token) = s::range_of(&result, &placeholder.token)
                && let Some((offset, after)) =
                    s::character_indices(&result[token.end..]).find(|(_, c)| !s::is_whitespace(c))
                && is_comma(after)
            {
                let start = token.end + offset;
                result.replace_range(start..start + after.len(), "");
            }
            if !said_comma_before
                && let Some(token) = s::range_of(&result, &placeholder.token)
                && let Some(before) = s::last_index(&result[..token.start], |c| !s::is_whitespace(c))
                && is_comma(&result[before.clone()])
            {
                result.replace_range(before, "");
            }
        }
        result
    }

    /// `text` without the full stop after an emoji that stands as a sentence of its own.
    /// Speech-to-text can write an emoji's name that way ("See you soon. Smiley face emoji."), and
    /// the model can keep it, but an emoji ends no sentence: "See you soon. 🙂".
    fn without_full_stops_after_emoji(&self, text: &str) -> String {
        let mut result = text.to_owned();
        for placeholder in self.emoji_placeholders() {
            let Some(token) = s::range_of(&result, &placeholder.token) else {
                continue;
            };
            let starts_sentence =
                last_non_whitespace(&result[..token.start]).is_none_or(|before| s::is_one_of(before, &SENTENCE_ENDERS));
            let after = &result[token.end..];
            if !starts_sentence || !s::has_prefix(after, ".") || s::has_prefix(after, "..") {
                continue;
            }
            let full_stop = s::first_character(after).map_or(0, str::len);
            result.replace_range(token.end..token.end + full_stop, "");
        }
        result
    }

    /// Line breaks and list markers leave stray spaces and punctuation around them.
    fn tidied(&self, text: &str) -> String {
        if self.protected.has_layout_placeholders() {
            lt_spoken_commands::tidy_line_breaks(text)
        } else {
            text.to_owned()
        }
    }
}

/// What a placeholder reads as in the uncleaned text: list markers as they were said, everything
/// else as it expands.
fn as_said(placeholder: &Placeholder) -> &str {
    if placeholder.role == Role::Structure {
        &placeholder.spoken
    } else {
        &placeholder.expansion
    }
}

/// The expansion of a line break or list marker, which layout needs in place; `None` for content,
/// which stays a placeholder until layout is done.
fn layout_expansion(placeholder: &Placeholder) -> Option<&str> {
    (placeholder.role != Role::Content).then_some(placeholder.expansion.as_str())
}

/// Whether `text` is emoji and spaces only, such as an emoji command's expansion.
fn is_emoji(text: &str) -> bool {
    let glyphs: String = s::characters(text).filter(|c| !s::is_whitespace(c)).collect();
    !glyphs.is_empty()
        && s::characters(&glyphs).all(|character| {
            let Some(first) = character.chars().next() else {
                return false;
            };
            s::is_emoji_presentation_scalar(first)
                || (s::is_emoji_scalar(first) && (u32::from(first) > 0xFF || character.contains('\u{FE0F}')))
        })
}

fn first_non_whitespace(text: &str) -> Option<&str> {
    s::characters(text).find(|c| !s::is_whitespace(c))
}

fn last_non_whitespace(text: &str) -> Option<&str> {
    s::characters(text).rev().find(|c| !s::is_whitespace(c))
}

fn is_comma(character: &str) -> bool {
    s::canonically_equal(character, ",")
}
