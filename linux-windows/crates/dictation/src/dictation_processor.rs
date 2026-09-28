use lt_cleanup::deterministic_cleanup;
use lt_shared::CleanupLevel;
use lt_shared::swift_string::{self as s, CharacterSet};
use lt_snippets::Snippet;
use lt_vocabulary::VocabularyEntry;

use crate::prepared_dictation::PreparedDictation;

/// Everything that shapes one dictation's text, read fresh for each dictation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Configuration {
    pub level: CleanupLevel,
    pub snippets: Vec<Snippet>,
    pub vocabulary: Vec<VocabularyEntry>,
    /// The text may break across lines, so spoken line breaks are newlines and spoken lists and
    /// letters can be laid out on lines.
    pub multiline: bool,
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
}

impl Output {
    fn unchanged(raw_transcript: &str, uncleaned: String) -> Self {
        Self {
            raw_transcript: raw_transcript.to_owned(),
            text: uncleaned.clone(),
            uncleaned_text: uncleaned,
            fell_back: false,
            fallback_reason: None,
        }
    }

    /// Nothing was heard.
    pub fn is_empty(&self) -> bool {
        s::trimming(&self.text, CharacterSet::WhitespacesAndNewlines).is_empty()
    }
}

/// Everything after speech-to-text, with cleanup's language model turned off: snippets, spoken
/// commands and vocabulary at every level, then the level's rules that need no model, filler
/// removal and layout at Medium and High. Nothing is reworded, and that was chosen, so it is not
/// reported as a fallback.
///
/// Snippet triggers, emoji, addresses and spoken line breaks become opaque placeholders first (see
/// `PreparedDictation`), as they do before the model, so the two paths share every rule. At
/// Medium and High, in fields that take several lines, spoken lists and letters are laid out.
pub fn finish(transcript: &str, configuration: &Configuration) -> Output {
    let raw = s::trimming(transcript, CharacterSet::WhitespacesAndNewlines);
    if raw.is_empty() {
        return Output::unchanged("", String::new());
    }

    let prepared = PreparedDictation::new(raw, configuration);
    let uncleaned = prepared.uncleaned();
    if !configuration.level.uses_language_model() {
        return Output::unchanged(raw, uncleaned);
    }

    // A letter's greeting and sign-off are laid out already; cleanup works on the body.
    let frame = prepared.frame(configuration.level);
    let body = frame.as_ref().map_or(prepared.text(), |frame| frame.body.as_str());
    // Placeholders are single words that are never fillers, so they come through intact.
    let cleaned = deterministic_cleanup(body, configuration.level);
    let assembled = frame
        .as_ref()
        .map_or_else(|| cleaned.clone(), |frame| frame.assembled(&cleaned));
    match prepared.finished(&assembled) {
        Some(text) => Output {
            text,
            ..Output::unchanged(raw, uncleaned)
        },
        None => {
            // A placeholder was damaged after it was issued.
            tracing::error!("Placeholders could not be restored; inserting the uncleaned text");
            Output {
                fell_back: true,
                fallback_reason: Some("placeholders could not be restored".to_owned()),
                ..Output::unchanged(raw, uncleaned)
            }
        }
    }
}
