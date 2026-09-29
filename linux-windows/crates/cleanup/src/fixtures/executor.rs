//! executor.jsonl: whole cleanups with a scripted model, replayed with a clock the test controls.
//! A step that times out moves the clock to its deadline; a step that is cancelled sets the
//! cleanup's cancel flag while the model is generating.

use std::sync::Arc;

use serde::Deserialize;

use super::{OptionsJson, RequestJson, TemplateJson, assert_no_differences, number, prompts, read_lines};
use crate::test_support::{FakeClock, ScriptedFailure, ScriptedModel};
use crate::{CancelFlag, CleanedText, CleanupExecutor, OutputGuard};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExecutorLine {
    name: String,
    adapted: bool,
    #[serde(rename = "override")]
    override_template: Option<TemplateJson>,
    context_limit: usize,
    timeout_seconds: String,
    options: OptionsJson,
    raw: String,
    context: Vec<String>,
    script: Vec<StepJson>,
    requests: Vec<RequestJson>,
    result: CleanedJson,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StepJson {
    reply: Option<String>,
    fail: Option<String>,
    #[serde(default)]
    time_out: bool,
    #[serde(default)]
    cancel: bool,
}

/// What the scripted model does with one request.
enum Step {
    Reply(String),
    Fail(String),
    /// Still generating when the deadline passes.
    TimeOut,
    /// The cleanup is cancelled while the model generates.
    Cancel,
}

impl StepJson {
    fn step(&self) -> Step {
        match self {
            Self { reply: Some(text), .. } => Step::Reply(text.clone()),
            Self {
                fail: Some(message), ..
            } => Step::Fail(message.clone()),
            Self { time_out: true, .. } => Step::TimeOut,
            Self { cancel: true, .. } => Step::Cancel,
            _ => panic!("no step in {self:?}"),
        }
    }
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CleanedJson {
    text: String,
    fell_back: bool,
    fallback_reason: Option<String>,
    /// Recorded only when the model never ran.
    latency_ms: Option<u64>,
}

impl CleanedJson {
    fn from(cleaned: &CleanedText, model_ran: bool) -> Self {
        Self {
            text: cleaned.text.clone(),
            fell_back: cleaned.fell_back(),
            fallback_reason: cleaned.fallback_reason.as_ref().map(ToString::to_string),
            latency_ms: (!model_ran).then_some(cleaned.latency_ms),
        }
    }
}

/// The requests the executor made with `line`'s script, and what it returned.
fn replay(line: &ExecutorLine) -> (Vec<RequestJson>, CleanedJson) {
    let clock = FakeClock::new();
    let executor = CleanupExecutor::new(
        line.context_limit,
        number(&line.timeout_seconds),
        OutputGuard::default(),
        prompts(line.adapted, line.override_template.as_ref()),
    )
    .with_clock(clock.clone());
    let cancel = CancelFlag::new();
    let steps: Vec<Step> = line.script.iter().map(StepJson::step).collect();
    let script_cancel = cancel.clone();
    let script_clock = Arc::clone(&clock);
    let mut model = ScriptedModel::new(|index, _, deadline| match steps.get(index) {
        Some(Step::Reply(text)) => Ok(text.clone()),
        Some(Step::Fail(message)) => Err(ScriptedFailure(message.clone())),
        Some(Step::TimeOut) => {
            script_clock.advance(deadline.remaining().expect("a timed-out generation has a deadline"));
            Ok("too late".to_owned())
        }
        Some(Step::Cancel) => {
            script_cancel.cancel();
            Ok("cancelled".to_owned())
        }
        None => Err(ScriptedFailure("the script has no step for this request".to_owned())),
    });
    let cleaned = executor.run(&line.raw, &line.context, &line.options.options(), &mut model, &cancel);
    let requests: Vec<RequestJson> = model.requests.iter().map(RequestJson::from).collect();
    let model_ran = !requests.is_empty();
    (requests, CleanedJson::from(&cleaned, model_ran))
}

#[test]
fn the_executor_traces_match_the_mac_apps() {
    let lines: Vec<ExecutorLine> = read_lines("executor.jsonl");
    assert!(lines.len() > 50, "executor.jsonl was read");

    let mut differences = Vec::new();
    for line in &lines {
        let (requests, cleaned) = replay(line);
        if requests.len() != line.requests.len() {
            differences.push(format!(
                "{}: the Mac app made {} requests, this port {}",
                line.name,
                line.requests.len(),
                requests.len()
            ));
        }
        for (index, (made, recorded)) in requests.iter().zip(&line.requests).enumerate() {
            if made != recorded {
                differences.push(format!(
                    "{}: request {}\n  Mac app: {recorded:?}\n  this port: {made:?}",
                    line.name,
                    index + 1
                ));
            }
        }
        if cleaned != line.result {
            differences.push(format!(
                "{}\n  Mac app: {:?}\n  this port: {cleaned:?}",
                line.name, line.result
            ));
        }
    }
    assert_no_differences("executor.jsonl", &differences);
}
