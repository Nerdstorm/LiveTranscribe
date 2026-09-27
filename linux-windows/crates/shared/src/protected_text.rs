use std::collections::HashMap;
use std::fmt;

use crate::placeholder_token;
use crate::swift_string::{self as s};

/// What a placeholder token stands for, which decides when it is put back.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Role {
    /// Text that must arrive verbatim: a snippet's expansion, an emoji, an address. Put back
    /// last, so layout never changes it.
    Content,
    /// A line or paragraph break the speaker asked for. Put back before layout, which works on
    /// lines.
    LineBreak,
    /// A structure marker the layout rules lay out, such as a spoken list item number. Put back
    /// before layout; text that is not laid out gets the spoken words back instead.
    Structure,
}

/// One phrase occurrence hidden behind an opaque token such as `⟦S1⟧` while the language model
/// runs: a snippet's trigger, a spoken emoji or line break, a list item number.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Placeholder {
    /// The token that stands in for the phrase, `⟦S<n>⟧`, numbered per occurrence from 1.
    pub token: String,
    /// The phrase as it was defined: a snippet's trigger, or a spoken command's words.
    pub trigger: String,
    /// The matched words exactly as the transcript had them, less the punctuation kept next to
    /// the token.
    pub spoken: String,
    /// What the token becomes once the language model is done.
    pub expansion: String,
    pub role: Role,
}

/// The pieces a protected text is made of.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Segment {
    Literal(String),
    /// An index into the placeholders.
    Placeholder(usize),
}

/// A transcript with its spoken phrases replaced by placeholder tokens, and what each token
/// stands for.
///
/// Built by [`crate::PhraseProtector::protect`]. Dictation sends [`ProtectedText::text`] to the
/// language model and calls [`ProtectedText::restore`] on the output; `None` means the output
/// changed a placeholder, and dictation falls back to the text it had before the model.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProtectedText {
    text: String,
    placeholders: Vec<Placeholder>,
    segments: Vec<Segment>,
}

impl ProtectedText {
    pub(crate) fn new(segments: Vec<Segment>, placeholders: Vec<Placeholder>) -> Self {
        let text = segments
            .iter()
            .map(|segment| match segment {
                Segment::Literal(literal) => literal.as_str(),
                Segment::Placeholder(index) => placeholders[*index].token.as_str(),
            })
            .collect();
        Self {
            text,
            placeholders,
            segments,
        }
    }

    pub fn unchanged(text: &str) -> Self {
        Self {
            text: text.to_owned(),
            placeholders: Vec::new(),
            segments: vec![Segment::Literal(text.to_owned())],
        }
    }

    /// The transcript with each phrase replaced by its token or its text; identical to the input
    /// when no phrase was found.
    pub fn text(&self) -> &str {
        &self.text
    }

    /// One entry per protected phrase occurrence, in order of appearance.
    pub fn placeholders(&self) -> &[Placeholder] {
        &self.placeholders
    }

    /// The tokens the language model must keep verbatim, in order of appearance.
    pub fn tokens(&self) -> Vec<&str> {
        self.placeholders
            .iter()
            .map(|placeholder| placeholder.token.as_str())
            .collect()
    }

    /// Whether any token stands for a line break or a structure marker, which need tidying and
    /// layout once they are put back.
    pub fn has_layout_placeholders(&self) -> bool {
        self.placeholders
            .iter()
            .any(|placeholder| placeholder.role != Role::Content)
    }

    /// The text with every token replaced by its expansion: the transcript as it would read had
    /// the language model not been used.
    pub fn expanded(&self) -> String {
        self.expanded_with(|placeholder| &placeholder.expansion)
    }

    /// The text with every token replaced by `replacement(placeholder)`. Built from the pieces
    /// rather than by searching the text, so token-like text already in the transcript stays.
    pub fn expanded_with(&self, replacement: impl Fn(&Placeholder) -> &str) -> String {
        self.segments
            .iter()
            .map(|segment| match segment {
                Segment::Literal(literal) => literal.as_str(),
                Segment::Placeholder(index) => replacement(&self.placeholders[*index]),
            })
            .collect()
    }

    /// `output` with each token replaced by its expansion, or `None` if the tokens did not
    /// survive intact.
    ///
    /// Every token must appear exactly once, and no other `⟦` or `⟧` may appear: a missing,
    /// repeated or altered token means the model rewrote something it was told to keep. Tokens
    /// may move. Each expansion is inserted verbatim in one pass, so an expansion that itself
    /// looks like a token is never substituted again.
    pub fn restore(&self, output: &str) -> Option<String> {
        self.restore_resolving(output, |placeholder| Some(&placeholder.expansion))
    }

    /// `output` with each token of `roles` replaced by its expansion and every other token left
    /// in place, or `None` if the tokens did not survive intact.
    pub fn restore_roles(&self, output: &str, roles: &[Role]) -> Option<String> {
        self.restore_resolving(output, |placeholder| {
            roles.contains(&placeholder.role).then_some(&placeholder.expansion)
        })
    }

    /// `output` with each token replaced by the text `replacement` returns for it, or left in
    /// place when it returns `None`; `None` if the tokens did not survive intact.
    ///
    /// A token that is replaced must appear exactly once. One left in place may appear at most
    /// once, since a later call replaces it and checks it then.
    pub fn restore_resolving(
        &self,
        output: &str,
        replacement: impl Fn(&Placeholder) -> Option<&str>,
    ) -> Option<String> {
        match self.substitute(output, replacement) {
            Ok(restored) => Some(restored),
            Err(problem) => {
                tracing::warn!("Placeholders not intact in the cleaned text: {problem}");
                None
            }
        }
    }

    fn substitute(
        &self,
        output: &str,
        replacement: impl Fn(&Placeholder) -> Option<&str>,
    ) -> Result<String, PlaceholderProblem> {
        let issued: HashMap<&str, &Placeholder> = self
            .placeholders
            .iter()
            .map(|placeholder| (placeholder.token.as_str(), placeholder))
            .collect();
        let mut occurrences: HashMap<&str, usize> = HashMap::new();
        let characters: Vec<(usize, &str)> = s::character_indices(output).collect();
        let mut restored = String::with_capacity(output.len());
        let mut copied_up_to = 0;
        let mut index = 0;

        while index < characters.len() {
            let (start, character) = characters[index];
            if s::canonically_equal(character, placeholder_token::CLOSING) {
                return Err(PlaceholderProblem::UnpairedBracket);
            }
            if !s::canonically_equal(character, placeholder_token::OPENING) {
                index += 1;
                continue;
            }
            let close = (index..characters.len())
                .find(|&candidate| s::canonically_equal(characters[candidate].1, placeholder_token::CLOSING))
                .ok_or(PlaceholderProblem::UnpairedBracket)?;
            let end = characters[close].0 + characters[close].1.len();
            let candidate = s::canonical_key(&output[start..end]);
            let placeholder = *issued.get(candidate.as_ref()).ok_or(PlaceholderProblem::UnknownToken)?;
            *occurrences.entry(placeholder.token.as_str()).or_default() += 1;
            if let Some(text) = replacement(placeholder) {
                restored.push_str(&output[copied_up_to..start]);
                restored.push_str(text);
                copied_up_to = end;
            }
            index = close + 1;
        }
        restored.push_str(&output[copied_up_to..]);

        let missing = self
            .placeholders
            .iter()
            .filter(|placeholder| {
                !occurrences.contains_key(placeholder.token.as_str()) && replacement(placeholder).is_some()
            })
            .count();
        if missing > 0 {
            return Err(PlaceholderProblem::Missing(missing));
        }
        let repeated = occurrences.values().filter(|&&count| count > 1).count();
        if repeated > 0 {
            return Err(PlaceholderProblem::Repeated(repeated));
        }
        Ok(restored)
    }
}

#[derive(Debug)]
enum PlaceholderProblem {
    UnpairedBracket,
    UnknownToken,
    Missing(usize),
    Repeated(usize),
}

impl fmt::Display for PlaceholderProblem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnpairedBracket => write!(f, "a placeholder bracket without its partner"),
            Self::UnknownToken => write!(f, "a placeholder that was not issued"),
            Self::Missing(count) => write!(f, "{count} placeholders missing"),
            Self::Repeated(count) => write!(f, "{count} placeholders repeated"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> ProtectedText {
        let placeholder = |index: usize, expansion: &str, role| Placeholder {
            token: placeholder_token::make(index),
            trigger: String::new(),
            spoken: format!("spoken {index}"),
            expansion: expansion.to_owned(),
            role,
        };
        ProtectedText::new(
            vec![
                Segment::Literal("Hi ".into()),
                Segment::Placeholder(0),
                Segment::Literal(" there".into()),
                Segment::Placeholder(1),
            ],
            vec![
                placeholder(1, "🎆", Role::Content),
                placeholder(2, "\n", Role::LineBreak),
            ],
        )
    }

    #[test]
    fn restores_every_token_once() {
        let text = sample();
        assert_eq!(text.text(), "Hi ⟦S1⟧ there⟦S2⟧");
        assert_eq!(text.restore("hi ⟦S1⟧, there ⟦S2⟧").as_deref(), Some("hi 🎆, there \n"));
        assert_eq!(text.expanded(), "Hi 🎆 there\n");
        assert_eq!(text.expanded_with(|p| &p.spoken), "Hi spoken 1 therespoken 2");
    }

    #[test]
    fn restores_in_steps_by_role() {
        let text = sample();
        let lines = text.restore_roles("Hi ⟦S1⟧ there⟦S2⟧", &[Role::LineBreak]);
        assert_eq!(lines.as_deref(), Some("Hi ⟦S1⟧ there\n"));
        assert_eq!(
            text.restore_roles(&lines.unwrap_or_default(), &[Role::Content])
                .as_deref(),
            Some("Hi 🎆 there\n")
        );
    }

    #[test]
    fn rejects_damaged_tokens() {
        let text = sample();
        assert_eq!(text.restore("Hi ⟦S1⟧ there"), None);
        assert_eq!(text.restore("⟦S1⟧⟦S1⟧⟦S2⟧"), None);
        assert_eq!(text.restore("⟦S3⟧ ⟦S1⟧⟦S2⟧"), None);
        assert_eq!(text.restore("⟦S1⟧ ⟦S2⟧ ⟧"), None);
        assert_eq!(text.restore("⟦S1⟧ ⟦S2⟧ ⟦"), None);
    }
}
