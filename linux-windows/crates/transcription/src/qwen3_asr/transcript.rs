use std::collections::HashMap;

use lt_shared::swift_string::{self as s, CharacterSet};
use serde::Deserialize;

/// What a reply says: the language the model named, and the transcript.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reply {
    pub language: Option<String>,
    pub text: String,
}

/// The languages a model names, from its `config.json` (`support_languages`), for reading its
/// replies as mlx-audio-swift reads them (`parseGeneratedChunk` with no forced language).
#[derive(Clone, Debug, Default)]
pub struct Languages {
    /// Each supported name, keyed by its lowercased form.
    supported: HashMap<String, String>,
}

/// Language names and codes the model may write, and the name each stands for.
const ALIASES: [(&str, &str); 23] = [
    ("zh", "Chinese"),
    ("chinese", "Chinese"),
    ("mandarin", "Chinese"),
    ("yue", "Cantonese"),
    ("cantonese", "Cantonese"),
    ("en", "English"),
    ("english", "English"),
    ("de", "German"),
    ("german", "German"),
    ("es", "Spanish"),
    ("spanish", "Spanish"),
    ("fr", "French"),
    ("french", "French"),
    ("it", "Italian"),
    ("italian", "Italian"),
    ("pt", "Portuguese"),
    ("portuguese", "Portuguese"),
    ("ru", "Russian"),
    ("russian", "Russian"),
    ("ko", "Korean"),
    ("korean", "Korean"),
    ("ja", "Japanese"),
    ("japanese", "Japanese"),
];

const LANGUAGE_PREFIX: &str = "language ";
const TRANSCRIPT_MARKER: &str = "<asr_text>";

#[derive(Deserialize)]
struct ModelConfig {
    #[serde(default)]
    support_languages: Vec<String>,
}

impl Languages {
    pub fn new(supported: impl IntoIterator<Item = String>) -> Self {
        Self {
            supported: supported.into_iter().map(|name| (s::lowercased(&name), name)).collect(),
        }
    }

    /// The languages in a model's `config.json`.
    pub fn from_config(config_json: &str) -> Result<Self, serde_json::Error> {
        let config: ModelConfig = serde_json::from_str(config_json)?;
        Ok(Self::new(config.support_languages))
    }

    /// The model's reply, decoded, read as its language and transcript. A reply the model began
    /// with "language X<asr_text>" gives X, as the model or an alias names it, and what follows; a
    /// reply without that is taken whole, as English, and an empty reply has no language.
    pub fn read(&self, decoded: &str) -> Reply {
        let trimmed = s::trimming(decoded, CharacterSet::WhitespacesAndNewlines);
        let (named, transcript) = extract_language(trimmed);
        if let Some(language) = named.and_then(|named| self.normalized(named)) {
            return Reply {
                language: Some(language),
                text: transcript.to_owned(),
            };
        }
        if trimmed.is_empty() {
            return Reply {
                language: None,
                text: String::new(),
            };
        }
        Reply {
            language: Some("English".to_owned()),
            text: trimmed.to_owned(),
        }
    }

    /// `name` as the model's supported languages spell it, through the aliases; a name it doesn't
    /// know stays as written.
    fn normalized(&self, name: &str) -> Option<String> {
        let name = s::trimming(name, CharacterSet::WhitespacesAndNewlines);
        if name.is_empty() {
            return None;
        }
        let lowercased = s::lowercased(name);
        if let Some(supported) = self.supported.get(&lowercased) {
            return Some(supported.clone());
        }
        if let Some((_, alias)) = ALIASES.iter().find(|(key, _)| *key == lowercased) {
            if self.supported.is_empty() {
                return Some((*alias).to_owned());
            }
            if let Some(supported) = self.supported.get(&s::lowercased(alias)) {
                return Some(supported.clone());
            }
        }
        Some(name.to_owned())
    }
}

/// The language named before the marker, and the transcript after it; or no language and the
/// whole text when the text doesn't start that way. `text` is already trimmed.
fn extract_language(text: &str) -> (Option<&str>, &str) {
    let Some(marker) = s::range_of(text, TRANSCRIPT_MARKER).filter(|_| s::has_prefix(text, LANGUAGE_PREFIX)) else {
        return (None, text);
    };
    // The marker cannot start inside the prefix, which holds no "<".
    let named = s::trimming(
        &text[LANGUAGE_PREFIX.len()..marker.start],
        CharacterSet::WhitespacesAndNewlines,
    );
    let transcript = s::trimming(&text[marker.end..], CharacterSet::WhitespacesAndNewlines);
    ((!named.is_empty()).then_some(named), transcript)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn languages() -> Languages {
        Languages::from_config(r#"{"support_languages": ["Chinese", "English", "Sinhala"], "other": 1}"#).unwrap()
    }

    #[test]
    fn reads_the_named_language_and_the_transcript() {
        let reply = languages().read(" language Sinhala<asr_text> meeting එක cancel කරන්න \n");
        assert_eq!(reply.language.as_deref(), Some("Sinhala"));
        assert_eq!(reply.text, "meeting එක cancel කරන්න");
    }

    #[test]
    fn spells_languages_as_the_model_lists_them() {
        assert_eq!(
            languages().read("language zh<asr_text>你好").language.as_deref(),
            Some("Chinese")
        );
        assert_eq!(
            languages().read("language ENGLISH<asr_text>Hi").language.as_deref(),
            Some("English")
        );
        // Unknown, and not an alias: kept as the model wrote it.
        let silence = languages().read("language None<asr_text>");
        assert_eq!(silence.language.as_deref(), Some("None"));
        assert_eq!(silence.text, "");
    }

    #[test]
    fn a_reply_without_a_language_is_english() {
        assert_eq!(
            languages().read("Ship it on Friday."),
            Reply {
                language: Some("English".to_owned()),
                text: "Ship it on Friday.".to_owned()
            }
        );
        assert_eq!(
            languages().read("  \n"),
            Reply {
                language: None,
                text: String::new()
            }
        );
    }

    #[test]
    fn a_marker_with_no_language_takes_the_whole_reply() {
        let reply = languages().read("language <asr_text>Hi");
        assert_eq!(reply.language.as_deref(), Some("English"));
        assert_eq!(reply.text, "language <asr_text>Hi");
    }

    #[test]
    fn without_a_list_the_aliases_still_apply() {
        let reply = Languages::default().read("language en<asr_text>Hi");
        assert_eq!(reply.language.as_deref(), Some("English"));
    }
}
