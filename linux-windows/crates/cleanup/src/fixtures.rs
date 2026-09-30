//! Parity with the Mac app: the fixtures in `Fixtures/cleanup` (see its README), which the Mac
//! app's `CleanupFixtureWriterTests` write from the Swift implementation. The prompts, the output
//! guard's verdicts and the executor's traces here must match them exactly.
//!
//! Numbers other than counts are recorded as Swift prints a `Double`, the shortest text that reads
//! back as the same value, so they are compared bit for bit.

mod executor;
mod guard;
mod guard_policy;
mod prompts;

use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use lt_shared::CleanupLevel;
use serde::Deserialize;
use serde::de::DeserializeOwned;

use crate::{CleanupOptions, CleanupRequest, Example, PromptBuilder, PromptTemplate, Sampling};

/// Differences shown in full when a fixture fails; the rest are counted.
const SHOWN: usize = 10;

fn directory() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Fixtures/cleanup")
}

/// Each line of `file`, parsed.
fn read_lines<T: DeserializeOwned>(file: &str) -> Vec<T> {
    let path = directory().join(file);
    let text = fs::read_to_string(&path).unwrap_or_else(|error| panic!("reading {}: {error}", path.display()));
    text.lines()
        .enumerate()
        .map(|(number, line)| {
            serde_json::from_str(line).unwrap_or_else(|error| panic!("{file} line {}: {error}", number + 1))
        })
        .collect()
}

/// Fails with the first few differences, if there are any, and how many there were.
fn assert_no_differences(file: &str, differences: &[String]) {
    if differences.is_empty() {
        return;
    }
    let shown: Vec<&str> = differences.iter().take(SHOWN).map(String::as_str).collect();
    panic!(
        "{} of the cases in {file} differ from the Mac app's; the first {}:\n\n{}",
        differences.len(),
        shown.len(),
        shown.join("\n\n")
    );
}

fn level(name: &str) -> CleanupLevel {
    CleanupLevel::ALL
        .into_iter()
        .find(|level| level.as_str() == name)
        .unwrap_or_else(|| panic!("no cleanup level {name:?}"))
}

/// A number as the Mac app recorded it.
fn number(text: &str) -> f64 {
    text.parse()
        .unwrap_or_else(|error| panic!("{text:?} is not a number: {error}"))
}

/// A number compared bit for bit, shown as a number.
#[derive(Clone, Copy)]
struct Exact(f64);

impl PartialEq for Exact {
    fn eq(&self, other: &Self) -> bool {
        self.0.to_bits() == other.0.to_bits()
    }
}

impl Eq for Exact {}

impl fmt::Debug for Exact {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}", self.0)
    }
}

fn exact(text: &str) -> Exact {
    Exact(number(text))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct OptionsJson {
    level: String,
    vocabulary: Vec<String>,
    placeholders: Vec<String>,
    multiline: bool,
}

impl OptionsJson {
    fn options(&self) -> CleanupOptions {
        CleanupOptions {
            level: level(&self.level),
            vocabulary: self.vocabulary.clone(),
            placeholders: self.placeholders.clone(),
            multiline: self.multiline,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TemplateJson {
    system: String,
    examples: Vec<ExampleJson>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ExampleJson {
    text: String,
    cleaned: String,
}

impl TemplateJson {
    fn template(&self) -> PromptTemplate {
        PromptTemplate {
            system: self.system.clone(),
            examples: self
                .examples
                .iter()
                .map(|example| Example {
                    text: example.text.clone(),
                    cleaned: example.cleaned.clone(),
                })
                .collect(),
        }
    }
}

/// The prompts of a builder with or without the adapter, and with the recorded override.
fn prompts(adapted: bool, override_template: Option<&TemplateJson>) -> PromptBuilder {
    match override_template {
        Some(template) => PromptBuilder::with_override(adapted, template.template()),
        None => PromptBuilder::new(adapted),
    }
}

/// A request as the fixtures record it.
#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RequestJson {
    messages: Vec<MessageJson>,
    template_context: BTreeMap<String, bool>,
    max_tokens: usize,
    adapter: bool,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct MessageJson {
    role: String,
    content: String,
}

impl From<&CleanupRequest> for RequestJson {
    fn from(request: &CleanupRequest) -> Self {
        assert_eq!(request.sampling, Sampling::Greedy, "the Mac app generates greedily");
        Self {
            messages: request
                .messages
                .iter()
                .map(|message| MessageJson {
                    role: message.role.as_str().to_owned(),
                    content: message.content.clone(),
                })
                .collect(),
            template_context: request.template_context.clone(),
            max_tokens: request.max_tokens,
            adapter: request.use_adapter,
        }
    }
}
