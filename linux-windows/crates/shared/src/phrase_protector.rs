use std::ops::Range;

use crate::placeholder_token;
use crate::protected_text::{Placeholder, ProtectedText, Role, Segment};
use crate::sentence_case;
use crate::swift_string::{self as s};
use crate::tokenized_text::{TokenizedText, token_edges};

/// Text a phrase is replaced with directly, in the text the language model sees: punctuation the
/// speaker dictated ("question mark" → "?"), which the model may still adjust.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct InlineText {
    pub text: String,
    /// Attaches to the text before it: the space before is removed ("ready?", not "ready ?").
    pub joins_previous: bool,
    /// Attaches to the text after it: the space after is removed ("(page", not "( page").
    pub joins_next: bool,
    /// Punctuation just before it gives way to it ("ready," then a spoken question mark becomes
    /// "ready?"). Speech-to-text often punctuates the word before a dictated mark.
    pub replaces_preceding_punctuation: bool,
    /// The next word starts a sentence.
    pub capitalizes_next: bool,
}

impl InlineText {
    pub fn new(text: &str) -> Self {
        Self {
            text: text.to_owned(),
            ..Self::default()
        }
    }
}

/// What a matched phrase stands for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Replacement {
    /// Hidden behind a placeholder token until cleanup is done (see [`Placeholder`]).
    Placeholder {
        trigger: String,
        expansion: String,
        role: Role,
    },
    /// Written into the text straight away.
    Inline(InlineText),
}

/// A spoken phrase found in a transcript, and what it stands for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PhraseMatch {
    /// The matched words, as indices into [`TokenizedText::words`]. The first must start a token
    /// and the last must end one, so only whole tokens are replaced.
    pub words: Range<usize>,
    pub replacement: Replacement,
    /// The part of the first token's leading punctuation that stays in the text: an opening
    /// bracket before a snippet trigger, say. Must be a prefix of that punctuation.
    pub kept_leading: String,
    /// The part of the last token's trailing punctuation that stays in the text: a full stop
    /// after an emoji, say. Must be a suffix of that punctuation.
    pub kept_trailing: String,
}

impl PhraseMatch {
    pub fn new(words: Range<usize>, replacement: Replacement) -> Self {
        Self {
            words,
            replacement,
            kept_leading: String::new(),
            kept_trailing: String::new(),
        }
    }
}

/// Finds one kind of spoken phrase in a transcript: snippet triggers, emoji names, dictated
/// punctuation, line breaks, list markers.
///
/// A new kind of phrase is a new matcher passed to [`PhraseProtector`]; nothing else changes.
pub trait PhraseMatcher: Send + Sync {
    /// Every match in `text`. Matches may overlap one another and other matchers' matches;
    /// [`PhraseProtector`] chooses among them.
    fn matches(&self, text: &TokenizedText) -> Vec<PhraseMatch>;
}

/// Replaces the spoken phrases that matchers find in a transcript: placeholders for text the
/// language model must not see or change, inline text for dictated punctuation.
///
/// Where matches overlap, the leftmost wins, then the longest, then the one from the matcher
/// listed first. Listing the user's snippets first lets a snippet replace a built-in command with
/// the same words.
pub struct PhraseProtector {
    matchers: Vec<Box<dyn PhraseMatcher>>,
}

impl PhraseProtector {
    pub fn new(matchers: Vec<Box<dyn PhraseMatcher>>) -> Self {
        Self { matchers }
    }

    /// `text` with every chosen phrase replaced, placeholders numbered in order of appearance.
    /// Text without phrases comes back unchanged.
    pub fn protect(&self, text: &str) -> ProtectedText {
        if self.matchers.is_empty() {
            return ProtectedText::unchanged(text);
        }
        let tokenized = TokenizedText::new(text);
        if tokenized.words().is_empty() {
            return ProtectedText::unchanged(text);
        }
        let chosen = choose(self.candidates(&tokenized));
        if chosen.is_empty() {
            return ProtectedText::unchanged(text);
        }

        let mut builder = SegmentBuilder::default();
        let mut cursor = 0;
        for phrase in &chosen {
            let first_token = &tokenized.tokens()[tokenized.words()[phrase.words.start].token];
            let last_token = &tokenized.tokens()[tokenized.words()[phrase.words.end - 1].token];
            builder.append_literal(&text[cursor..first_token.start]);
            builder.append_literal(&phrase.kept_leading);
            match &phrase.replacement {
                Replacement::Placeholder {
                    trigger,
                    expansion,
                    role,
                } => {
                    let span = &text[first_token.start..last_token.end];
                    let spoken = s::drop_last(
                        s::drop_first(span, s::character_count(&phrase.kept_leading)),
                        s::character_count(&phrase.kept_trailing),
                    );
                    builder.append_placeholder(trigger, spoken, expansion, *role);
                }
                Replacement::Inline(inline) => builder.append_inline(inline),
            }
            builder.append_literal(&phrase.kept_trailing);
            cursor = last_token.end;
        }
        builder.append_literal(&text[cursor..]);

        let protected = builder.build();
        tracing::debug!(
            "Replaced {} spoken phrases, {} behind placeholders",
            chosen.len(),
            protected.placeholders().len()
        );
        protected
    }

    fn candidates(&self, text: &TokenizedText) -> Vec<Candidate> {
        let mut candidates = Vec::new();
        let mut invalid = 0;
        for (priority, matcher) in self.matchers.iter().enumerate() {
            for phrase in matcher.matches(text) {
                if is_valid(&phrase, text) {
                    candidates.push(Candidate { phrase, priority });
                } else {
                    invalid += 1;
                }
            }
        }
        if invalid > 0 {
            tracing::error!("Ignored {invalid} phrase matches that did not cover whole tokens");
        }
        candidates
    }
}

struct Candidate {
    phrase: PhraseMatch,
    priority: usize,
}

/// Leftmost, then longest, then earliest matcher; no two chosen matches share a word.
fn choose(mut candidates: Vec<Candidate>) -> Vec<PhraseMatch> {
    candidates.sort_by(|lhs, rhs| {
        lhs.phrase
            .words
            .start
            .cmp(&rhs.phrase.words.start)
            .then(rhs.phrase.words.len().cmp(&lhs.phrase.words.len()))
            .then(lhs.priority.cmp(&rhs.priority))
    });
    let mut chosen = Vec::new();
    let mut next_free_word = 0;
    for candidate in candidates {
        if candidate.phrase.words.start >= next_free_word {
            next_free_word = candidate.phrase.words.end;
            chosen.push(candidate.phrase);
        }
    }
    chosen
}

/// Covers whole tokens, and keeps only punctuation those tokens have.
fn is_valid(phrase: &PhraseMatch, text: &TokenizedText) -> bool {
    if !text.covers_whole_tokens(phrase.words.clone()) {
        return false;
    }
    let leading = token_edges::leading(text.token_of_word(phrase.words.start));
    let trailing = token_edges::trailing(text.token_of_word(phrase.words.end - 1));
    s::has_prefix(leading, &phrase.kept_leading) && s::has_suffix(trailing, &phrase.kept_trailing)
}

/// Assembles a [`ProtectedText`] piece by piece, applying inline text's spacing and casing to
/// the text around it.
#[derive(Default)]
struct SegmentBuilder {
    segments: Vec<Segment>,
    placeholders: Vec<Placeholder>,
    /// The previous inline text joins the next text: drop the whitespace before it.
    joins_next: bool,
    /// The previous inline text ended a sentence: capitalise the next word.
    capitalizes_next: bool,
    /// The text so far ends with inline text, whose punctuation a following mark adds to rather
    /// than replaces ("?!").
    ends_with_inline: bool,
}

impl SegmentBuilder {
    const PRECEDING_PUNCTUATION: [&str; 6] = [",", ";", ":", ".", "!", "?"];

    fn append_literal(&mut self, literal: &str) {
        let mut text = literal.to_owned();
        if self.joins_next {
            text = s::drop_while(&text, s::is_whitespace).to_owned();
            if !text.is_empty() {
                self.joins_next = false;
            }
        }
        let has_words = s::any_character(&text, |c| !s::is_whitespace(c));
        if self.capitalizes_next && has_words {
            text = sentence_case::capitalizing_first_word(&text);
            self.capitalizes_next = false;
        }
        if has_words {
            self.ends_with_inline = false;
        }
        self.append(text);
    }

    fn append_placeholder(&mut self, trigger: &str, spoken: &str, expansion: &str, role: Role) {
        self.joins_next = false;
        self.capitalizes_next = false;
        self.ends_with_inline = false;
        self.segments.push(Segment::Placeholder(self.placeholders.len()));
        self.placeholders.push(Placeholder {
            token: placeholder_token::make(self.placeholders.len() + 1),
            trigger: trigger.to_owned(),
            spoken: spoken.to_owned(),
            expansion: expansion.to_owned(),
            role,
        });
    }

    fn append_inline(&mut self, inline: &InlineText) {
        if inline.joins_previous {
            self.trim_tail(inline.replaces_preceding_punctuation && !self.ends_with_inline);
        }
        self.append(inline.text.clone());
        self.joins_next = inline.joins_next;
        self.capitalizes_next = inline.capitalizes_next;
        self.ends_with_inline = !inline.text.is_empty();
    }

    fn build(self) -> ProtectedText {
        ProtectedText::new(self.segments, self.placeholders)
    }

    fn append(&mut self, text: String) {
        if text.is_empty() {
            return;
        }
        if let Some(Segment::Literal(previous)) = self.segments.last_mut() {
            previous.push_str(&text);
        } else {
            self.segments.push(Segment::Literal(text));
        }
    }

    /// Removes the whitespace, and optionally the punctuation, at the end of the text so far.
    /// Stops at a placeholder: its expansion is not known here.
    fn trim_tail(&mut self, punctuation: bool) {
        let Some(Segment::Literal(tail)) = self.segments.last_mut() else {
            return;
        };
        while let Some(last) = s::last_character(tail) {
            if !(s::is_whitespace(last) || (punctuation && s::is_one_of(last, &Self::PRECEDING_PUNCTUATION))) {
                break;
            }
            s::pop_last_character(tail);
        }
        if tail.is_empty() {
            self.segments.pop();
        }
    }
}
