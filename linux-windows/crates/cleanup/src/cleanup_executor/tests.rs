use std::sync::Arc;
use std::time::Duration;

use lt_shared::CleanupLevel;

use super::*;
use crate::test_support::{FakeClock, ScriptedFailure, ScriptedModel, replying};
use crate::{CleanupModelNotLoaded, CleanupRequest, Message, Role};

const RAW: &str = "i think the build is broken on main";
const CORRECTED: &str = "meet on tuesday no wait wednesday at the office";
const RESOLVED: &str = "Meet on Wednesday at the office.";

fn executor(timeout_seconds: f64, adapted: bool) -> (CleanupExecutor, Arc<FakeClock>) {
    let clock = FakeClock::new();
    let executor = CleanupExecutor::new(3, timeout_seconds, OutputGuard::default(), PromptBuilder::new(adapted))
        .with_clock(clock.clone());
    (executor, clock)
}

fn run<M: CleanupModel>(executor: &CleanupExecutor, raw: &str, options: &CleanupOptions, model: &mut M) -> CleanedText {
    executor.run(raw, &[], options, model, &CancelFlag::new())
}

fn options(level: CleanupLevel) -> CleanupOptions {
    CleanupOptions::new(level)
}

fn reason(cleaned: &CleanedText) -> Option<String> {
    cleaned.fallback_reason.as_ref().map(FallbackReason::to_string)
}

/// A model that must not be asked anything.
fn never_asked() -> ScriptedModel<impl FnMut(usize, &CleanupRequest, &Deadline<'_>) -> Result<String, ScriptedFailure>>
{
    ScriptedModel::new(|_, _, _| panic!("generation should not run"))
}

/// Replies `first` to the first request and `rest` to the others.
fn first_then(
    first: &str,
    rest: &str,
) -> ScriptedModel<impl FnMut(usize, &CleanupRequest, &Deadline<'_>) -> Result<String, ScriptedFailure>> {
    let (first, rest) = (first.to_owned(), rest.to_owned());
    ScriptedModel::new(move |index, _, _| Ok(if index == 0 { first.clone() } else { rest.clone() }))
}

/// Generates a token every 10 ms, as the clock tells it, until the deadline says to stop.
fn generate_until_stopped(clock: &FakeClock, deadline: &Deadline<'_>) -> Result<String, ScriptedFailure> {
    for _ in 0..100_000 {
        if deadline.should_stop() {
            return Ok("too late".to_owned());
        }
        clock.advance(Duration::from_millis(10));
    }
    panic!("the model was never told to stop");
}

#[test]
fn accepted_output_replaces_raw_text() {
    let (executor, _) = executor(1.0, false);
    let cleaned = run(
        &executor,
        RAW,
        &options(CleanupLevel::Medium),
        &mut replying("I think the build is broken on main."),
    );
    assert!(!cleaned.fell_back());
    assert_eq!(cleaned.text, "I think the build is broken on main.");
}

#[test]
fn generation_error_falls_back_to_raw() {
    let (executor, _) = executor(1.0, false);
    let mut model = ScriptedModel::new(|_, _, _| Err(ScriptedFailure("GPU error".to_owned())));
    let cleaned = run(&executor, RAW, &options(CleanupLevel::Medium), &mut model);
    assert!(cleaned.fell_back());
    assert_eq!(cleaned.text, RAW);
    assert_eq!(reason(&cleaned).as_deref(), Some("generation failed: GPU error"));
}

#[test]
fn a_model_that_is_not_loaded_falls_back_with_the_mac_apps_reason() {
    let (executor, _) = executor(1.0, false);
    let cleaned = run(
        &executor,
        RAW,
        &options(CleanupLevel::Medium),
        &mut CleanupModelNotLoaded,
    );
    assert_eq!(cleaned.text, RAW);
    assert_eq!(
        reason(&cleaned).as_deref(),
        Some("generation failed: cleanup model not loaded")
    );
}

#[test]
fn slow_generation_is_told_to_stop_and_falls_back() {
    let (executor, clock) = executor(0.1, false);
    let model_clock = clock.clone();
    let mut model = ScriptedModel::new(move |_, _, deadline| generate_until_stopped(&model_clock, deadline));
    let cleaned = run(&executor, RAW, &options(CleanupLevel::Medium), &mut model);
    assert!(cleaned.fell_back());
    assert_eq!(reason(&cleaned).as_deref(), Some("timed out after 0.1s"));
    assert_eq!(cleaned.latency_ms, 100, "the generation stopped at the deadline");
}

/// The model can't be interrupted from outside, but a reply after the deadline is too late all
/// the same, as the Mac app's timer would have won the race.
#[test]
fn a_reply_after_the_deadline_is_too_late() {
    let (executor, clock) = executor(0.5, false);
    let model_clock = clock.clone();
    let mut model = ScriptedModel::new(move |_, _, _| {
        model_clock.advance(Duration::from_secs(2));
        Ok("I think the build is broken on main.".to_owned())
    });
    let cleaned = run(&executor, RAW, &options(CleanupLevel::Medium), &mut model);
    assert_eq!(reason(&cleaned).as_deref(), Some("timed out after 0.5s"));
    assert_eq!(cleaned.text, RAW);
}

#[test]
fn a_cancelled_cleanup_falls_back() {
    let (executor, _) = executor(1.0, false);
    let cancel = CancelFlag::new();
    let flag = cancel.clone();
    let mut model = ScriptedModel::new(move |_, _, deadline| {
        flag.cancel();
        assert!(deadline.should_stop(), "the model is told to stop");
        Ok("I think the build is broken on main.".to_owned())
    });
    let cleaned = executor.run(RAW, &[], &options(CleanupLevel::Medium), &mut model, &cancel);
    assert_eq!(reason(&cleaned).as_deref(), Some("cancelled"));
    assert_eq!(cleaned.text, RAW);
}

#[test]
fn guard_rejection_falls_back() {
    let (executor, _) = executor(1.0, false);
    let cleaned = run(
        &executor,
        RAW,
        &options(CleanupLevel::Medium),
        &mut replying("<think>hmm</think> I think the build is broken."),
    );
    assert!(cleaned.fell_back());
    assert_eq!(reason(&cleaned).as_deref(), Some("thinking tags in output"));
}

#[test]
fn context_is_passed_through_the_window() {
    let (executor, _) = executor(1.0, false);
    let mut model = replying("I think the build is broken on main.");
    let context: Vec<String> = ["a.", "b.", "c.", "d."].map(str::to_owned).to_vec();
    executor.run(
        RAW,
        &context,
        &options(CleanupLevel::Medium),
        &mut model,
        &CancelFlag::new(),
    );
    let request = model.requests.last().expect("a request was sent");
    let answers: Vec<&str> = request
        .messages
        .iter()
        .filter(|message| message.role == Role::Assistant)
        .map(|message| message.content.as_str())
        .collect();
    assert_eq!(answers, ["b.", "c.", "d."]);
    assert_eq!(
        request.messages.last(),
        Some(&Message::new(Role::User, format!("TEXT:\n{RAW}")))
    );
    assert_eq!(request.template_context.get(prompt::ENABLE_THINKING), Some(&false));
}

#[test]
fn empty_raw_text_skips_generation() {
    let (executor, _) = executor(1.0, false);
    let cleaned = run(&executor, "  ", &options(CleanupLevel::Light), &mut never_asked());
    assert!(!cleaned.fell_back());
    assert_eq!(cleaned.text, "  ");
}

#[test]
fn level_none_returns_the_raw_text_without_the_model() {
    let (executor, _) = executor(1.0, false);
    let raw = "um so the the build is broken";
    let cleaned = run(&executor, raw, &options(CleanupLevel::None), &mut never_asked());
    assert_eq!(cleaned, CleanedText::without_the_model(raw.to_owned()));
}

#[test]
fn sinhala_skips_the_model_but_keeps_the_levels_rules() {
    let (executor, _) = executor(1.0, false);
    for text in ["ඒකෙ තියෙන magic වැඩ um", "um ඔන්න මගේ film එකතුවට"] {
        for level in [CleanupLevel::Light, CleanupLevel::Medium, CleanupLevel::High] {
            let cleaned = run(&executor, text, &options(level), &mut never_asked());
            assert_eq!(
                cleaned,
                CleanedText::without_the_model(deterministic_cleanup(text, level))
            );
        }
    }
}

#[test]
fn english_still_goes_to_the_model() {
    let (executor, _) = executor(1.0, false);
    let mut model = replying("The build is broken.");
    run(
        &executor,
        "the build is broken",
        &options(CleanupLevel::Medium),
        &mut model,
    );
    assert_eq!(model.requests.len(), 1);
}

#[test]
fn medium_removes_fillers_before_the_model_sees_the_text() {
    let (executor, _) = executor(1.0, false);
    let mut model = replying("So the build is broken.");
    let cleaned = run(
        &executor,
        "so um the build is uh broken",
        &options(CleanupLevel::Medium),
        &mut model,
    );
    assert_eq!(
        model.requests[0].messages.last(),
        Some(&Message::new(Role::User, "TEXT:\nso the build is broken"))
    );
    assert_eq!(cleaned.text, "So the build is broken.");
}

#[test]
fn light_keeps_fillers_for_the_model() {
    let (executor, _) = executor(1.0, false);
    let mut model = replying("So, um, the build is broken.");
    run(
        &executor,
        "so um the build is broken",
        &options(CleanupLevel::Light),
        &mut model,
    );
    assert_eq!(
        model.requests[0].messages.last(),
        Some(&Message::new(Role::User, "TEXT:\nso um the build is broken"))
    );
}

#[test]
fn a_fallback_keeps_the_fillers_removed() {
    let (executor, _) = executor(1.0, false);
    let cleaned = run(
        &executor,
        "so um the build is uh broken",
        &options(CleanupLevel::Medium),
        &mut replying("Here is the text: So the build is broken."),
    );
    assert!(cleaned.fell_back());
    assert_eq!(cleaned.text, "so the build is broken");
}

#[test]
fn only_fillers_leaves_nothing_to_clean() {
    let (executor, _) = executor(1.0, false);
    let cleaned = run(&executor, "um uh", &options(CleanupLevel::Medium), &mut never_asked());
    assert!(!cleaned.fell_back());
    assert!(cleaned.text.is_empty());
}

/// The model sees each placeholder as a word, listed in the prompt; the tokens come back before
/// the guard.
#[test]
fn options_shape_the_prompt() {
    let (executor, _) = executor(1.0, true);
    let options = CleanupOptions {
        vocabulary: vec!["Nerdstorm".to_owned()],
        placeholders: vec!["⟦S1⟧".to_owned()],
        ..options(CleanupLevel::High)
    };
    let mut model = replying("Email S1 to the Nerdstorm team.");
    let cleaned = run(&executor, "email ⟦S1⟧ to the nerd storm team", &options, &mut model);
    let shown = CleanupOptions {
        placeholders: vec!["S1".to_owned()],
        ..options.clone()
    };
    let request = &model.requests[0];
    assert_eq!(
        request.messages.first(),
        Some(&Message::new(
            Role::System,
            PromptBuilder::new(true).template(&shown).system
        ))
    );
    assert_eq!(
        request.messages.last(),
        Some(&Message::new(Role::User, "TEXT:\nemail S1 to the nerd storm team"))
    );
    assert_eq!(cleaned.text, "Email ⟦S1⟧ to the Nerdstorm team.");
}

#[test]
fn a_damaged_placeholder_falls_back_to_the_text_with_placeholders() {
    let (executor, _) = executor(1.0, false);
    let options = CleanupOptions {
        placeholders: vec!["⟦S1⟧".to_owned()],
        ..options(CleanupLevel::Medium)
    };
    let cleaned = run(
        &executor,
        "email ⟦S1⟧ to the team",
        &options,
        &mut replying("Email S 1 to the team."),
    );
    assert_eq!(reason(&cleaned).as_deref(), Some("changed a placeholder"));
    assert_eq!(cleaned.text, "email ⟦S1⟧ to the team");
}

#[test]
fn the_adapter_is_on_only_at_the_levels_that_resolve_self_corrections() {
    let (executor, _) = executor(1.0, true);
    for (level, expected) in [
        (CleanupLevel::Light, vec![false]),
        (CleanupLevel::Medium, vec![true]),
        (CleanupLevel::High, vec![true, true]),
    ] {
        let mut model = first_then(RESOLVED, "Let's meet on Wednesday at the office.");
        run(&executor, CORRECTED, &options(level), &mut model);
        let used: Vec<bool> = model.requests.iter().map(|request| request.use_adapter).collect();
        assert_eq!(used, expected, "{level:?}");
    }
}

// MARK: High with a self-correction

#[test]
fn high_resolves_a_correction_at_medium_then_rewords() {
    let (executor, _) = executor(1.0, true);
    let high = CleanupOptions {
        vocabulary: vec!["Acme".to_owned()],
        ..options(CleanupLevel::High)
    };
    let mut model = first_then(RESOLVED, "Let's meet on Wednesday at the office.");
    let cleaned = run(&executor, CORRECTED, &high, &mut model);
    let prompts = PromptBuilder::new(true);
    let systems: Vec<&str> = model
        .requests
        .iter()
        .map(|request| request.messages[0].content.as_str())
        .collect();
    let medium = CleanupOptions {
        level: CleanupLevel::Medium,
        ..high.clone()
    };
    assert_eq!(
        systems,
        [prompts.template(&medium).system, prompts.template(&high).system]
    );
    assert_eq!(
        model.requests[1].messages.last(),
        Some(&Message::new(Role::User, format!("TEXT:\n{RESOLVED}")))
    );
    assert_eq!(cleaned.text, "Let's meet on Wednesday at the office.");
    assert!(!cleaned.fell_back());
}

#[test]
fn a_rejected_rewording_keeps_the_resolved_text() {
    let (executor, _) = executor(1.0, true);
    let mut model = first_then(RESOLVED, "Here is the text: Let's meet on Wednesday.");
    let cleaned = run(&executor, CORRECTED, &options(CleanupLevel::High), &mut model);
    assert_eq!(cleaned.text, RESOLVED);
    assert!(!cleaned.fell_back(), "the resolved text passed Medium's review");
    assert_eq!(model.requests.len(), 2);
}

#[test]
fn a_rejected_resolution_falls_back_without_rewording() {
    let (executor, _) = executor(1.0, true);
    let mut model = replying("<think>hmm</think>");
    let cleaned = run(&executor, CORRECTED, &options(CleanupLevel::High), &mut model);
    assert!(cleaned.fell_back());
    assert_eq!(cleaned.text, CORRECTED);
    assert_eq!(model.requests.len(), 1);
}

#[test]
fn the_rewording_gets_only_the_time_left() {
    let (executor, clock) = executor(1.0, true);
    let model_clock = clock.clone();
    let mut given = Vec::new();
    let mut model = ScriptedModel::new(|index, _, deadline| {
        given.push(deadline.seconds());
        if index == 0 {
            model_clock.advance(Duration::from_millis(400));
            return Ok(RESOLVED.to_owned());
        }
        generate_until_stopped(&model_clock, deadline)
    });
    let cleaned = run(&executor, CORRECTED, &options(CleanupLevel::High), &mut model);
    assert_eq!(cleaned.text, RESOLVED);
    assert!(!cleaned.fell_back());
    assert_eq!(given, [1.0, 1.0 - 0.4]);
    assert_eq!(cleaned.latency_ms, 1_000, "both passes share one deadline");
}

#[test]
fn cancelling_the_rewording_keeps_the_resolved_text() {
    let (executor, _) = executor(1.0, true);
    let cancel = CancelFlag::new();
    let flag = cancel.clone();
    let mut model = ScriptedModel::new(move |index, _, _| {
        if index == 1 {
            flag.cancel();
        }
        Ok(RESOLVED.to_owned())
    });
    let cleaned = executor.run(CORRECTED, &[], &options(CleanupLevel::High), &mut model, &cancel);
    assert_eq!(cleaned.text, RESOLVED);
    assert!(!cleaned.fell_back());
}

/// Each reading of this clock takes a second, so the resolution finishes within its deadline but
/// leaves no time to reword.
#[test]
fn with_no_time_left_the_resolved_text_is_kept_without_rewording() {
    let clock = FakeClock::ticking(Duration::from_secs(1));
    let executor = CleanupExecutor::new(3, 1.5, OutputGuard::default(), PromptBuilder::new(true)).with_clock(clock);
    let mut model = replying(RESOLVED);
    let cleaned = run(&executor, CORRECTED, &options(CleanupLevel::High), &mut model);
    assert_eq!(cleaned.text, RESOLVED);
    assert!(!cleaned.fell_back());
    assert_eq!(model.requests.len(), 1);
}

#[test]
fn one_pass_without_a_correction_cue_at_high_and_at_medium_with_one() {
    let (executor, _) = executor(1.0, true);
    for (level, text) in [(CleanupLevel::High, RAW), (CleanupLevel::Medium, CORRECTED)] {
        let mut model = replying(text);
        run(&executor, text, &options(level), &mut model);
        assert_eq!(model.requests.len(), 1, "{level:?}");
    }
}

/// Dictation with the cleanup model off inserts this, so it must match what a level does without
/// the model: fillers go only from Medium up.
#[test]
fn deterministic_cleanup_removes_fillers_only_from_medium_up() {
    let raw = "so um the build is uh broken";
    assert_eq!(deterministic_cleanup(raw, CleanupLevel::None), raw);
    assert_eq!(deterministic_cleanup(raw, CleanupLevel::Light), raw);
    assert_eq!(
        deterministic_cleanup(raw, CleanupLevel::Medium),
        "so the build is broken"
    );
    assert_eq!(deterministic_cleanup(raw, CleanupLevel::High), "so the build is broken");
    assert_eq!(deterministic_cleanup(raw, CleanupLevel::Deep), "so the build is broken");
    assert_eq!(deterministic_cleanup("Um, hi", CleanupLevel::Medium), "Hi");
}
