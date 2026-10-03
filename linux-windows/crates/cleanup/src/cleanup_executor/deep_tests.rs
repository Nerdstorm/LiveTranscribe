//! Deep's cleanup, as the Mac app's `DeepCleanupTests`.

use std::sync::Arc;
use std::time::Duration;

use lt_shared::CleanupLevel;

use super::*;
use crate::prompt::{ENABLE_THINKING, max_tokens};
use crate::test_support::{FakeClock, ScriptedFailure, ScriptedModel, replying};
use crate::{CleanupRequest, Sampling};

const KIRK: &str = "I tried to speak with Kirk, but he didn't. I don't think he actually check whether the release is tomorrow. No, sorry, the after tomorrow.";
const REPAIRED: &str = "I tried to speak with Kirk, but he didn't. I don't think he actually checked whether the release is the day after tomorrow.";
const LEASE: &str = "the lease ends in april no wait may";

/// Deep as the Mac app's tests vary it: one pass, no adapter, no thinking, no fallback, and no
/// minimum deadline.
fn deep() -> DeepCleanup {
    DeepCleanup {
        passes: DeepPasses::One,
        adapter: Adapter::Off,
        thinking: false,
        thinking_tokens: 64,
        falls_back_to_medium: false,
        minimum_timeout_seconds: 0.0,
    }
}

/// A deadline no test meets by chance, except those that pass their own.
fn executor(deep: DeepCleanup, timeout_seconds: f64) -> (CleanupExecutor, Arc<FakeClock>) {
    let clock = FakeClock::new();
    let executor = CleanupExecutor::new(3, timeout_seconds, OutputGuard::default(), PromptBuilder::new(true))
        .with_deep(deep)
        .with_clock(clock.clone());
    (executor, clock)
}

fn run<M: CleanupModel>(executor: &CleanupExecutor, raw: &str, model: &mut M) -> CleanedText {
    executor.run(
        raw,
        &[],
        &CleanupOptions::new(CleanupLevel::Deep),
        model,
        &CancelFlag::new(),
    )
}

fn adapters<F>(model: &ScriptedModel<F>) -> Vec<Adapter> {
    model.requests.iter().map(|request| request.adapter).collect()
}

#[test]
fn one_pass_sends_deeps_prompt_and_accepts_the_repair() {
    let (executor, _) = executor(deep(), 30.0);
    let mut model = replying(REPAIRED);
    let cleaned = run(&executor, KIRK, &mut model);
    assert!(!cleaned.fell_back());
    assert_eq!(cleaned.text, REPAIRED);
    assert_eq!(model.requests.len(), 1);
    let request = &model.requests[0];
    assert_eq!(
        request.messages[0].content,
        PromptBuilder::new(true)
            .template(&CleanupOptions::new(CleanupLevel::Deep))
            .system
    );
    assert_eq!(request.adapter, Adapter::Off);
    assert!(!request.thinks());
    assert_eq!(request.sampling, Sampling::GREEDY);
}

#[test]
fn deep_runs_with_the_adapter_it_says() {
    for adapter in Adapter::ALL {
        let (executor, _) = executor(DeepCleanup { adapter, ..deep() }, 30.0);
        let mut model = replying(REPAIRED);
        run(&executor, KIRK, &mut model);
        assert_eq!(adapters(&model), [adapter]);
    }
}

#[test]
fn a_rejected_repair_gets_mediums_cleanup() {
    let resolved = "The lease ends in May.";
    let deep = DeepCleanup {
        adapter: Adapter::Deep,
        falls_back_to_medium: true,
        ..deep()
    };
    let (executor, _) = executor(deep, 30.0);
    // Deep's answer keeps the month taken back; Medium's resolves it.
    let mut model = ScriptedModel::new(|_, request: &CleanupRequest, _| {
        Ok::<_, ScriptedFailure>(if request.adapter == Adapter::Deep {
            "The lease ends in April.".to_owned()
        } else {
            resolved.to_owned()
        })
    });
    let cleaned = run(&executor, LEASE, &mut model);
    assert!(
        !cleaned.fell_back(),
        "Medium's cleanup is a success at Medium's standard"
    );
    assert_eq!(cleaned.text, resolved);
    assert_eq!(adapters(&model), [Adapter::Deep, Adapter::Medium]);
    let medium = &model.requests[1];
    assert_eq!(
        medium.messages[0].content,
        prompt::adapted().system,
        "Medium's pass gets the prompt its adapter was trained on"
    );
    assert_eq!(
        medium.messages.last().map(|message| message.content.as_str()),
        Some(format!("TEXT:\n{LEASE}").as_str()),
        "Medium cleans what was said, not Deep's answer"
    );
}

#[test]
fn when_mediums_cleanup_is_rejected_too_what_was_said_is_shown() {
    let (executor, _) = executor(
        DeepCleanup {
            falls_back_to_medium: true,
            ..deep()
        },
        30.0,
    );
    let cleaned = run(&executor, LEASE, &mut replying("The lease ends in April."));
    assert!(cleaned.fell_back());
    assert_eq!(
        cleaned.fallback_reason.as_ref().map(ToString::to_string).as_deref(),
        Some("changed more than a repair may"),
        "the reason is Deep's"
    );
    assert_eq!(cleaned.text, LEASE);
}

/// Medium's guard accepts a correction that takes back the name with the word it corrects; Deep's
/// check doesn't, so Deep shows what was said, not Medium's answer.
#[test]
fn mediums_cleanup_must_pass_deeps_check_too() {
    let raw = "Kofi's brother, no wait, not brother, cousin, is hosting the barbecue.";
    let medium = "Cousin is hosting the barbecue.";
    let review = |level| {
        OutputGuard::default().review(
            raw,
            &GenerationOutcome::Completed(medium.to_owned()),
            &CleanupOptions::new(level),
        )
    };
    assert_eq!(review(CleanupLevel::Medium), GuardVerdict::Accepted(medium.to_owned()));
    assert_eq!(
        review(CleanupLevel::Deep),
        GuardVerdict::Rejected(FallbackReason::InvalidRepair)
    );

    let deep = DeepCleanup {
        adapter: Adapter::Deep,
        falls_back_to_medium: true,
        ..deep()
    };
    let (executor, _) = executor(deep, 30.0);
    let mut model = ScriptedModel::new(|_, request: &CleanupRequest, _| {
        Ok::<_, ScriptedFailure>(if request.adapter == Adapter::Deep {
            "Here is the text: Kofi's cousin is hosting the barbecue.".to_owned()
        } else {
            medium.to_owned()
        })
    });
    let cleaned = run(&executor, raw, &mut model);
    assert_eq!(adapters(&model), [Adapter::Deep, Adapter::Medium]);
    assert!(cleaned.fell_back());
    assert_eq!(
        cleaned.fallback_reason.as_ref().map(ToString::to_string).as_deref(),
        Some("preamble in output (here is)"),
        "the reason is Deep's, for its own answer"
    );
    assert_eq!(cleaned.text, raw);
}

#[test]
fn no_answer_in_time_is_not_retried() {
    let deep = DeepCleanup {
        falls_back_to_medium: true,
        minimum_timeout_seconds: 0.1,
        ..deep()
    };
    let (executor, clock) = executor(deep, 0.1);
    let model_clock = clock.clone();
    let mut model = ScriptedModel::new(move |_, _, deadline| {
        while !deadline.should_stop() {
            model_clock.advance(Duration::from_millis(10));
        }
        Ok::<_, ScriptedFailure>("too late".to_owned())
    });
    let cleaned = run(&executor, KIRK, &mut model);
    assert!(cleaned.fell_back());
    assert_eq!(model.requests.len(), 1);
}

#[test]
fn without_the_fallback_a_rejected_repair_shows_what_was_said() {
    let (executor, _) = executor(deep(), 30.0);
    let mut model = replying("The lease ends in April.");
    let cleaned = run(&executor, LEASE, &mut model);
    assert!(cleaned.fell_back());
    assert_eq!(model.requests.len(), 1);
}

#[test]
fn after_medium_resolves_first_then_repairs() {
    let raw = "The meeting is on Tuesday. Sorry, Wednesday. We will review the the budget.";
    let resolved = "The meeting is on Wednesday. We will review the budget.";
    let (executor, _) = executor(
        DeepCleanup {
            passes: DeepPasses::AfterMedium,
            ..deep()
        },
        30.0,
    );
    let mut model = replying(resolved);
    let cleaned = run(&executor, raw, &mut model);
    assert_eq!(cleaned.text, resolved);
    assert_eq!(
        adapters(&model),
        [Adapter::Medium, Adapter::Off],
        "Medium's pass runs with the adapter it was trained with"
    );
    assert_eq!(model.requests[0].messages[0].content, prompt::adapted().system);
    assert_eq!(
        model.requests[1]
            .messages
            .last()
            .map(|message| message.content.as_str()),
        Some(format!("TEXT:\n{resolved}").as_str()),
        "Deep repairs what Medium resolved"
    );
}

#[test]
fn after_medium_keeps_mediums_result_when_the_repair_is_rejected() {
    let resolved = "The meeting is on Wednesday.";
    let (executor, _) = executor(
        DeepCleanup {
            passes: DeepPasses::AfterMedium,
            ..deep()
        },
        30.0,
    );
    let mut model = ScriptedModel::new(|index, _, _| {
        Ok::<_, ScriptedFailure>(if index == 0 {
            resolved.to_owned()
        } else {
            "The meeting is on Wednesday, as agreed.".to_owned()
        })
    });
    let cleaned = run(&executor, "The meeting is on Tuesday. Sorry, Wednesday.", &mut model);
    assert!(!cleaned.fell_back());
    assert_eq!(cleaned.text, resolved);
}

#[test]
fn after_medium_runs_one_pass_without_a_cue() {
    let (executor, _) = executor(
        DeepCleanup {
            passes: DeepPasses::AfterMedium,
            ..deep()
        },
        30.0,
    );
    let mut model = replying("She doesn't know.");
    run(&executor, "she don't know", &mut model);
    assert_eq!(model.requests.len(), 1);
}

#[test]
fn thinking_is_sampled_and_its_reasoning_removed() {
    let (executor, _) = executor(
        DeepCleanup {
            thinking: true,
            ..deep()
        },
        30.0,
    );
    let reply = format!("<think>\nThe speaker corrects tomorrow to the day after tomorrow.\n</think>\n\n{REPAIRED}");
    let mut model = replying(&reply);
    let cleaned = run(&executor, KIRK, &mut model);
    assert!(!cleaned.fell_back());
    assert_eq!(cleaned.text, REPAIRED);
    let request = &model.requests[0];
    assert!(request.thinks());
    assert_eq!(request.template_context.get(ENABLE_THINKING), Some(&true));
    assert_eq!((request.sampling.temperature, request.sampling.top_k), (0.6, 20));
    assert!(request.sampling.seed.is_some());
    assert_eq!(request.max_tokens, max_tokens(KIRK) + 64);
}

#[test]
fn unfinished_thinking_falls_back() {
    let (executor, _) = executor(
        DeepCleanup {
            thinking: true,
            ..deep()
        },
        30.0,
    );
    let cleaned = run(
        &executor,
        KIRK,
        &mut replying("<think>\nThe speaker says tomorrow, then"),
    );
    assert!(cleaned.fell_back());
    assert_eq!(
        cleaned.fallback_reason.as_ref().map(ToString::to_string).as_deref(),
        Some("ran out of tokens while thinking")
    );
    assert_eq!(cleaned.text, KIRK);
}

#[test]
fn thinking_tags_without_thinking_are_rejected() {
    let (executor, _) = executor(deep(), 30.0);
    let reply = format!("<think></think>{REPAIRED}");
    let cleaned = run(&executor, KIRK, &mut replying(&reply));
    assert_eq!(
        cleaned.fallback_reason.as_ref().map(ToString::to_string).as_deref(),
        Some("thinking tags in output")
    );
}

#[test]
fn deep_gets_its_longer_deadline() {
    let (executor, clock) = executor(
        DeepCleanup {
            minimum_timeout_seconds: 0.5,
            ..deep()
        },
        0.05,
    );
    let model_clock = clock.clone();
    let mut model = ScriptedModel::new(move |_, _, _| {
        model_clock.advance(Duration::from_millis(200));
        Ok::<_, ScriptedFailure>(REPAIRED.to_owned())
    });
    let cleaned = run(&executor, KIRK, &mut model);
    assert!(
        !cleaned.fell_back(),
        "Deep waits for its own minimum, not the shorter Advanced timeout"
    );
}

/// Only Deep asks for its adapter or thinks; the other levels ignore how Deep runs.
#[test]
fn each_level_asks_for_its_adapter() {
    let thinking = DeepCleanup {
        adapter: Adapter::Deep,
        thinking: true,
        ..deep()
    };
    let (executor, _) = executor(thinking, 30.0);
    for (level, adapter, thinks) in [
        (CleanupLevel::Light, Adapter::Off, false),
        (CleanupLevel::Medium, Adapter::Medium, false),
        (CleanupLevel::High, Adapter::Medium, false),
        (CleanupLevel::Deep, Adapter::Deep, true),
    ] {
        let request = executor.request("hello there", &[], &CleanupOptions::new(level));
        assert_eq!((request.adapter, request.thinks()), (adapter, thinks), "{level:?}");
    }
}
