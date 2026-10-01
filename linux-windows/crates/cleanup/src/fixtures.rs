//! Parity with the Mac app: the fixtures in `Fixtures/cleanup` (see its README), which the Mac
//! app's `CleanupFixtureWriterTests` write from the Swift implementation. The prompts, the output
//! guard's verdicts and the executor's traces here must match them exactly.
//!
//! Numbers other than counts are recorded as Swift prints a `Double` or a `Float`, the shortest text
//! that reads back as the same value, so they are compared bit for bit.

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

use crate::{Adapter, CleanupOptions, CleanupRequest, DeepCleanup, DeepPasses, Example, PromptBuilder, PromptTemplate};

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

/// A `Float` as the Mac app recorded it, as its bits.
fn float_bits(text: &str) -> u32 {
    text.parse::<f32>()
        .unwrap_or_else(|error| panic!("{text:?} is not a number: {error}"))
        .to_bits()
}

fn adapter(name: &str) -> Adapter {
    Adapter::ALL
        .into_iter()
        .find(|adapter| adapter.as_str() == name)
        .unwrap_or_else(|| panic!("no adapter {name:?}"))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct OptionsJson {
    level: String,
    vocabulary: Vec<String>,
    placeholders: Vec<String>,
    multiline: bool,
    #[serde(default, rename = "letterBody")]
    letter_body: bool,
}

impl OptionsJson {
    fn options(&self) -> CleanupOptions {
        CleanupOptions {
            level: level(&self.level),
            vocabulary: self.vocabulary.clone(),
            placeholders: self.placeholders.clone(),
            multiline: self.multiline,
            letter_body: self.letter_body,
        }
    }
}

/// How Deep runs, where a case says.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DeepJson {
    passes: String,
    adapter: String,
    thinking: bool,
    thinking_tokens: usize,
    falls_back_to_medium: bool,
    minimum_timeout_seconds: String,
}

impl DeepJson {
    fn deep(&self) -> DeepCleanup {
        DeepCleanup {
            passes: DeepPasses::ALL
                .into_iter()
                .find(|passes| passes.as_str() == self.passes)
                .unwrap_or_else(|| panic!("no passes {:?}", self.passes)),
            adapter: adapter(&self.adapter),
            thinking: self.thinking,
            thinking_tokens: self.thinking_tokens,
            falls_back_to_medium: self.falls_back_to_medium,
            minimum_timeout_seconds: number(&self.minimum_timeout_seconds),
        }
    }
}

/// How Deep runs for a case: as recorded, or as shipped.
fn deep(recorded: Option<&DeepJson>) -> DeepCleanup {
    recorded.map_or(DeepCleanup::SHIPPED, DeepJson::deep)
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
#[derive(Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RequestJson {
    messages: Vec<MessageJson>,
    template_context: BTreeMap<String, bool>,
    max_tokens: usize,
    adapter: String,
    sampling: SamplingJson,
}

/// How the model picks tokens, with each `Float` as Swift prints it and the seed as text.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SamplingJson {
    temperature: String,
    top_p: String,
    top_k: usize,
    seed: Option<String>,
}

/// Numbers are equal when they read back as the same value, bit for bit.
impl PartialEq for SamplingJson {
    fn eq(&self, other: &Self) -> bool {
        let seed = |recorded: &Self| {
            recorded.seed.as_deref().map(|seed| {
                seed.parse::<u64>()
                    .unwrap_or_else(|error| panic!("{seed:?} is not a seed: {error}"))
            })
        };
        float_bits(&self.temperature) == float_bits(&other.temperature)
            && float_bits(&self.top_p) == float_bits(&other.top_p)
            && self.top_k == other.top_k
            && seed(self) == seed(other)
    }
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct MessageJson {
    role: String,
    content: String,
}

impl From<&CleanupRequest> for RequestJson {
    fn from(request: &CleanupRequest) -> Self {
        let sampling = &request.sampling;
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
            adapter: request.adapter.as_str().to_owned(),
            sampling: SamplingJson {
                temperature: format!("{:?}", sampling.temperature),
                top_p: format!("{:?}", sampling.top_p),
                top_k: sampling.top_k,
                seed: sampling.seed.map(|seed| seed.to_string()),
            },
        }
    }
}
