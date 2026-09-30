//! The golden cases shared with the Mac app (see Fixtures/golden/README.md): what the Mac app
//! makes of every transcript in dictation-inputs.txt, at each cleanup level, in single-line and
//! multi-line fields, with cleanup's language model off. This port must type the same text.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use lt_dictation::{Configuration, finish};
use lt_shared::CleanupLevel;
use lt_snippets::Snippet;
use lt_vocabulary::VocabularyEntry;
use serde::Deserialize;

/// Differences shown in full when the cases fail; the rest are counted.
const SHOWN: usize = 15;

#[derive(Deserialize)]
struct Settings {
    snippets: Vec<SnippetSetting>,
    vocabulary: Vec<VocabularySetting>,
}

#[derive(Deserialize)]
struct SnippetSetting {
    trigger: String,
    expansion: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VocabularySetting {
    term: String,
    spoken_variants: Vec<String>,
}

/// One line of dictation-text.jsonl.
#[derive(Deserialize)]
struct GoldenLine {
    transcript: String,
    /// By cleanup level, then by "singleLine" or "multiline".
    expected: BTreeMap<String, BTreeMap<String, GoldenOutput>>,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct GoldenOutput {
    /// What Undo AI edit puts back.
    uncleaned: String,
    /// What dictation types.
    text: String,
    fell_back: bool,
}

fn golden_directory() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Fixtures/golden")
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|error| panic!("reading {}: {error}", path.display()))
}

#[test]
fn the_text_path_matches_the_golden_cases() {
    let directory = golden_directory();
    let settings: Settings = serde_json::from_str(&read(&directory.join("dictation-settings.json")))
        .expect("dictation-settings.json parses");
    let snippets: Vec<Snippet> = settings
        .snippets
        .iter()
        .map(|snippet| Snippet::new(&snippet.trigger, &snippet.expansion))
        .collect();
    let vocabulary: Vec<VocabularyEntry> = settings
        .vocabulary
        .iter()
        .map(|entry| VocabularyEntry {
            term: entry.term.clone(),
            spoken_variants: entry.spoken_variants.clone(),
        })
        .collect();

    let inputs = read(&directory.join("dictation-inputs.txt"));
    let transcripts: Vec<&str> = inputs
        .split('\n')
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .collect();
    let recorded = read(&directory.join("dictation-text.jsonl"));
    let lines: Vec<GoldenLine> = recorded
        .lines()
        .enumerate()
        .map(|(number, line)| {
            serde_json::from_str(line)
                .unwrap_or_else(|error| panic!("dictation-text.jsonl line {}: {error}", number + 1))
        })
        .collect();
    assert!(transcripts.len() > 1_000, "the inputs file was read");
    assert_eq!(
        lines.len(),
        transcripts.len(),
        "one golden line per input; after changing the inputs, run make golden"
    );

    let mut cases = 0;
    let mut differences = Vec::new();
    for (transcript, line) in transcripts.iter().zip(&lines) {
        assert_eq!(
            &line.transcript, transcript,
            "the golden lines follow the inputs; run make golden"
        );
        for level in CleanupLevel::ALL {
            for multiline in [false, true] {
                let field = if multiline { "multiline" } else { "singleLine" };
                let expected = line
                    .expected
                    .get(level.as_str())
                    .and_then(|fields| fields.get(field))
                    .unwrap_or_else(|| panic!("no {} {field} case for {transcript:?}", level.as_str()));
                let configuration = Configuration {
                    level,
                    snippets: snippets.clone(),
                    vocabulary: vocabulary.clone(),
                    multiline,
                    vocabulary_prompt_limit: Configuration::VOCABULARY_PROMPT_LIMIT,
                    vocabulary_similarity_threshold: Configuration::VOCABULARY_SIMILARITY_THRESHOLD,
                };
                let output = finish(transcript, &configuration);
                let produced = GoldenOutput {
                    uncleaned: output.uncleaned_text,
                    text: output.text,
                    fell_back: output.fell_back,
                };
                cases += 1;
                if &produced != expected {
                    differences.push(format!(
                        "{transcript:?} at {} {field}\n  Mac app: {expected:?}\n  port:    {produced:?}",
                        level.as_str()
                    ));
                }
            }
        }
    }

    assert!(
        differences.is_empty(),
        "{} of {cases} golden cases differ from the Mac app's:\n\n{}{}",
        differences.len(),
        differences.iter().take(SHOWN).cloned().collect::<Vec<_>>().join("\n\n"),
        if differences.len() > SHOWN {
            format!("\n\n…and {} more", differences.len() - SHOWN)
        } else {
            String::new()
        }
    );
}
