use lt_cleanup::{CleanedText, CleanupOptions, deterministic_cleanup};
use lt_shared::CleanupLevel;
use lt_shared::swift_string::{self as s, CharacterSet};
use lt_snippets::Snippet;
use lt_styles::TextFrame;
use lt_vocabulary::{VocabularyEntry, VocabularySelector};

use crate::prepared_dictation::PreparedDictation;

/// Everything that shapes one dictation's text, read fresh for each dictation.
#[derive(Clone, Debug, PartialEq)]
pub struct Configuration {
    pub level: CleanupLevel,
    pub snippets: Vec<Snippet>,
    pub vocabulary: Vec<VocabularyEntry>,
    /// Most vocabulary terms listed in the cleanup prompt.
    pub vocabulary_prompt_limit: usize,
    /// How close a spoken word must be to a term for the term to be listed in the prompt (see
    /// [`VocabularySelector`]).
    pub vocabulary_similarity_threshold: f64,
    /// The text may break across lines, so spoken line breaks are newlines and spoken lists and
    /// letters can be laid out on lines.
    pub multiline: bool,
}

impl Configuration {
    /// Most vocabulary terms listed in the cleanup prompt, as the Mac app lists them.
    pub const VOCABULARY_PROMPT_LIMIT: usize = 50;
    /// How close a spoken word must be to a term for the term to be listed, as on the Mac.
    pub const VOCABULARY_SIMILARITY_THRESHOLD: f64 = 0.8;
}

/// What dictation makes of one transcript.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Output {
    /// Exactly what speech-to-text heard, trimmed.
    pub raw_transcript: String,
    /// The transcript with snippets, spoken commands and vocabulary applied but neither cleaned
    /// nor laid out: what Undo AI edit puts back.
    pub uncleaned_text: String,
    /// What to insert.
    pub text: String,
    pub fell_back: bool,
    pub fallback_reason: Option<String>,
    /// Time the cleanup model took; 0 when it didn't run.
    pub cleanup_ms: u64,
}

impl Output {
    fn unchanged(raw_transcript: &str, uncleaned: String) -> Self {
        Self {
            raw_transcript: raw_transcript.to_owned(),
            text: uncleaned.clone(),
            uncleaned_text: uncleaned,
            fell_back: false,
            fallback_reason: None,
            cleanup_ms: 0,
        }
    }

    /// Nothing was heard.
    pub fn is_empty(&self) -> bool {
        s::trimming(&self.text, CharacterSet::WhitespacesAndNewlines).is_empty()
    }
}

/// What [`prepare`] made of a transcript.
pub enum Prepared {
    /// Nothing for cleanup's model to do: nothing was heard, or the level doesn't use it.
    Done(Output),
    /// The model cleans [`Pending::text`], and [`Pending::finish`] makes the result the text to
    /// insert.
    Pending(Box<Pending>),
}

/// A transcript made ready for cleanup's model: what it cleans and how, and what turns its
/// result into the text to insert.
pub struct Pending {
    raw: String,
    uncleaned: String,
    prepared: PreparedDictation,
    frame: Option<TextFrame>,
    body: String,
    options: CleanupOptions,
}

impl Pending {
    /// What the model cleans: the transcript with its phrases replaced, or a letter's body.
    pub fn text(&self) -> &str {
        &self.body
    }

    /// How: the level, the vocabulary terms and placeholders for the prompt, and whether the field
    /// takes several lines.
    pub fn options(&self) -> &CleanupOptions {
        &self.options
    }

    /// The text with the level's rules that need no model, filler removal and layout from Medium
    /// up, and nothing reworded: cleanup's model is turned off. That was chosen, so it is not
    /// reported as a fallback.
    pub fn without_the_model(self) -> Output {
        // Placeholders are single words that are never fillers, so they come through intact.
        let cleaned = deterministic_cleanup(&self.body, self.options.level);
        self.finished(cleaned, None, 0)
    }

    /// `cleaned`, the cleanup of [`Self::text`], as the text to insert.
    pub fn finish(self, cleaned: CleanedText) -> Output {
        let reason = cleaned.fallback_reason.map(|reason| reason.to_string());
        self.finished(cleaned.text, reason, cleaned.latency_ms)
    }

    fn finished(self, cleaned: String, fallback_reason: Option<String>, cleanup_ms: u64) -> Output {
        let assembled = self
            .frame
            .as_ref()
            .map_or_else(|| cleaned.clone(), |frame| frame.assembled(&cleaned));
        match self.prepared.finished(&assembled) {
            Some(text) => Output {
                raw_transcript: self.raw,
                uncleaned_text: self.uncleaned,
                text,
                fell_back: fallback_reason.is_some(),
                fallback_reason,
                cleanup_ms,
            },
            None => {
                // The guard checks placeholders, so this means a later step damaged one.
                tracing::error!("Placeholders could not be restored; inserting the uncleaned text");
                Output {
                    fell_back: true,
                    fallback_reason: Some("placeholders could not be restored".to_owned()),
                    cleanup_ms,
                    ..Output::unchanged(&self.raw, self.uncleaned)
                }
            }
        }
    }
}

/// Everything after speech-to-text up to cleanup's model: snippets, spoken commands and vocabulary
/// at every level, then, when the level uses the model, what it is to clean. A letter's greeting
/// and sign-off are laid out already, from Medium up in fields that take several lines, and only
/// its body is cleaned.
///
/// Snippet triggers, emoji, addresses and spoken line breaks become opaque placeholders first (see
/// `PreparedDictation`), so the model can neither see nor change them.
pub fn prepare(transcript: &str, configuration: &Configuration) -> Prepared {
    let raw = s::trimming(transcript, CharacterSet::WhitespacesAndNewlines);
    if raw.is_empty() {
        return Prepared::Done(Output::unchanged("", String::new()));
    }

    let prepared = PreparedDictation::new(raw, configuration);
    let uncleaned = prepared.uncleaned();
    if !configuration.level.uses_language_model() {
        return Prepared::Done(Output::unchanged(raw, uncleaned));
    }

    let frame = prepared.frame(configuration.level);
    let body = frame
        .as_ref()
        .map_or_else(|| prepared.text().to_owned(), |frame| frame.body.clone());
    let options = CleanupOptions {
        level: configuration.level,
        vocabulary: VocabularySelector::new(&configuration.vocabulary, configuration.vocabulary_similarity_threshold)
            .relevant_terms(&body, configuration.vocabulary_prompt_limit),
        placeholders: prepared
            .placeholders()
            .into_iter()
            .filter(|token| body.contains(token.as_str()))
            .collect(),
        // What the speaker laid out, the layout rules lay out, so the model keeps one paragraph.
        multiline: configuration.multiline && !prepared.has_spoken_layout(&body),
        // The greeting and sign-off are laid out already; Deep must write neither.
        letter_body: frame.is_some(),
    };
    Prepared::Pending(Box::new(Pending {
        raw: raw.to_owned(),
        uncleaned,
        prepared,
        frame,
        body,
        options,
    }))
}

/// Everything after speech-to-text, with cleanup's language model turned off: snippets, spoken
/// commands and vocabulary at every level, then the level's rules that need no model, filler
/// removal and layout from Medium up. Nothing is reworded, and that was chosen, so it is not
/// reported as a fallback.
pub fn finish(transcript: &str, configuration: &Configuration) -> Output {
    match prepare(transcript, configuration) {
        Prepared::Done(output) => output,
        Prepared::Pending(pending) => pending.without_the_model(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options(transcript: &str, multiline: bool) -> CleanupOptions {
        let configuration = Configuration {
            level: CleanupLevel::Deep,
            snippets: Vec::new(),
            vocabulary: Vec::new(),
            vocabulary_prompt_limit: Configuration::VOCABULARY_PROMPT_LIMIT,
            vocabulary_similarity_threshold: Configuration::VOCABULARY_SIMILARITY_THRESHOLD,
            multiline,
        };
        match prepare(transcript, &configuration) {
            Prepared::Pending(pending) => pending.options().clone(),
            Prepared::Done(_) => panic!("{transcript:?} goes to the model at Deep"),
        }
    }

    #[test]
    fn deep_lays_out_only_what_the_speaker_did_not() {
        assert!(options("we need milk eggs and bread", true).multiline);
        assert!(
            !options(
                "shopping list bullet point milk bullet point eggs bullet point bread",
                true
            )
            .multiline,
            "spoken list markers are laid out by the rules, so the model keeps one paragraph"
        );
        assert!(
            !options("first line new line second line", true).multiline,
            "as are spoken line breaks"
        );
        assert!(!options("we need milk eggs and bread", false).multiline);
    }

    #[test]
    fn deep_is_told_when_the_text_is_an_emails_body() {
        let letter = "Hi Sam, thanks for the report. I'll review it tomorrow. Cheers, Priya";
        assert!(options(letter, true).letter_body);
        assert!(!options("thanks for the report i'll review it tomorrow", true).letter_body);
        assert!(
            !options(letter, false).letter_body,
            "a one-line field lays out no letter"
        );
    }
}
