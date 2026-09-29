use lt_shared::CleanupLevel;

use super::*;

fn review(raw: &str, output: &str, level: CleanupLevel, placeholders: &[&str]) -> GuardVerdict {
    review_outcome(
        raw,
        &GenerationOutcome::Completed(output.to_owned()),
        level,
        placeholders,
    )
}

fn review_outcome(raw: &str, outcome: &GenerationOutcome, level: CleanupLevel, placeholders: &[&str]) -> GuardVerdict {
    let options = CleanupOptions {
        placeholders: placeholders.iter().map(|&token| token.to_owned()).collect(),
        ..CleanupOptions::new(level)
    };
    OutputGuard::default().review(raw, outcome, &options)
}

fn medium(raw: &str, output: &str) -> GuardVerdict {
    review(raw, output, CleanupLevel::Medium, &[])
}

fn accepted(cleaned: &str) -> GuardVerdict {
    GuardVerdict::Accepted(cleaned.to_owned())
}

fn words(count: usize) -> String {
    vec!["word"; count].join(" ")
}

#[test]
fn accepts_a_correction() {
    let cleaned = "I think we should meet on Tuesday, maybe at three.";
    assert_eq!(
        medium("i think we should meet on tuesday maybe at three", cleaned),
        accepted(cleaned)
    );
}

#[test]
fn trims_surrounding_whitespace() {
    assert_eq!(medium("hello there", "\n  Hello there.  \n"), accepted("Hello there."));
}

#[test]
fn empty_or_blank_output_falls_back() {
    for output in ["", "   ", "\n\n"] {
        assert_eq!(
            medium("hello there", output),
            GuardVerdict::Rejected(FallbackReason::EmptyOutput)
        );
    }
}

#[test]
fn rejects_leaked_thinking() {
    let leaked = GuardVerdict::Rejected(FallbackReason::ThinkingLeaked);
    assert_eq!(
        medium("hello there", "<think>\nuser said hi\n</think>\nHello there."),
        leaked
    );
    assert_eq!(medium("hello there", "Hello there.</think>"), leaked);
}

#[test]
fn rejects_a_preamble() {
    assert_eq!(
        medium(
            "the report is due friday",
            "Here is the corrected text: The report is due Friday."
        ),
        GuardVerdict::Rejected(FallbackReason::Preamble("here is".to_owned()))
    );
}

#[test]
fn allows_an_opening_that_was_actually_spoken() {
    assert_eq!(
        medium("sure, i can do that", "Sure, I can do that."),
        accepted("Sure, I can do that.")
    );
}

#[test]
fn a_spoken_opening_is_kept_however_it_is_punctuated() {
    for (raw, cleaned) in [
        (
            "sure so i was at a small startup for three years",
            "Sure. So I was at a small startup for three years.",
        ),
        (
            "Of course we can ship it on Friday.",
            "Of course, we can ship it on Friday.",
        ),
        ("certainly not before the review", "Certainly not before the review."),
        ("Here's the plan for the launch", "Here's the plan for the launch."),
    ] {
        assert_eq!(medium(raw, cleaned), accepted(cleaned), "{raw}");
    }
}

#[test]
fn still_rejects_a_preamble_added_after_a_spoken_opening() {
    let cleaned = "Sure, here's the corrected text: Sure thing.";
    assert_ne!(medium("sure thing", cleaned), accepted(cleaned));
}

/// The default policy without the similarity check, which on its own rejects most large
/// changes in length, so the word-ratio bounds can be tested at their edges.
fn ratio_only_guard() -> OutputGuard {
    OutputGuard::new(GuardPolicy {
        min_similarity: 0.0,
        ..GuardPolicy::default()
    })
}

#[test]
fn each_level_accepts_output_at_its_word_ratio_bounds_and_rejects_it_just_outside() {
    let guard = ratio_only_guard();
    for level in [CleanupLevel::Light, CleanupLevel::Medium, CleanupLevel::High] {
        let options = CleanupOptions::new(level);
        let review = |count: usize| guard.review(&words(100), &GenerationOutcome::Completed(words(count)), &options);
        let bounds = level.word_ratio_bounds();
        let low = (bounds.start() * 100.0).round() as usize;
        let high = (bounds.end() * 100.0).round() as usize;
        for count in [low, high] {
            assert_eq!(review(count), accepted(&words(count)), "{level:?} at {count} words");
        }
        for count in [low - 1, high + 1] {
            let GuardVerdict::Rejected(FallbackReason::WordRatio(ratio)) = review(count) else {
                panic!("expected a word-ratio rejection at {count} words for {level:?}");
            };
            assert!((ratio - count as f64 / 100.0).abs() < 1e-9);
        }
    }
}

#[test]
fn a_policy_can_override_a_levels_bounds() {
    let mut policy = GuardPolicy {
        min_similarity: 0.0,
        ..GuardPolicy::default()
    };
    policy.word_ratio_bounds.insert(CleanupLevel::Light, 0.9..=1.1);
    let verdict = OutputGuard::new(policy.clone()).review(
        &words(100),
        &GenerationOutcome::Completed(words(85)),
        &CleanupOptions::new(CleanupLevel::Light),
    );
    assert_eq!(verdict, GuardVerdict::Rejected(FallbackReason::WordRatio(0.85)));
    assert_eq!(
        policy.word_ratio_bounds_for(CleanupLevel::Medium),
        CleanupLevel::Medium.word_ratio_bounds()
    );
    policy.word_ratio_bounds.clear();
    assert_eq!(policy.word_ratio_bounds_for(CleanupLevel::High), 0.4..=1.3);
}

#[test]
fn low_similarity_falls_back() {
    let verdict = medium(
        "the meeting is on tuesday afternoon",
        "A banana smoothie needs frozen fruit.",
    );
    let GuardVerdict::Rejected(FallbackReason::LowSimilarity(similarity)) = verdict else {
        panic!("expected a similarity rejection, got {verdict:?}");
    };
    assert!(similarity < 0.6);
}

#[test]
fn a_generation_that_did_not_complete_falls_back() {
    let rejected = |outcome| review_outcome("hello", &outcome, CleanupLevel::Medium, &[]);
    assert_eq!(
        rejected(GenerationOutcome::TimedOut { seconds: 3.0 }),
        GuardVerdict::Rejected(FallbackReason::TimedOut { seconds: 3.0 })
    );
    assert_eq!(
        rejected(GenerationOutcome::Cancelled),
        GuardVerdict::Rejected(FallbackReason::Cancelled)
    );
    assert_eq!(
        rejected(GenerationOutcome::Failed("GPU error".to_owned())),
        GuardVerdict::Rejected(FallbackReason::GenerationFailed("GPU error".to_owned()))
    );
}

#[test]
fn fallback_reasons_are_readable() {
    assert_eq!(
        FallbackReason::TimedOut { seconds: 3.0 }.to_string(),
        "timed out after 3.0s"
    );
    assert_eq!(
        FallbackReason::WordRatio(1.31).to_string(),
        "word-count ratio 1.31 outside allowed range"
    );
    assert_eq!(
        FallbackReason::SelfCorrectionNotAllowed.to_string(),
        "resolved a self-correction at a level that keeps every word"
    );
    assert_eq!(FallbackReason::PlaceholderChanged.to_string(), "changed a placeholder");
    // Rounded as printf rounds the exact value: half to even.
    assert_eq!(
        FallbackReason::LowSimilarity(0.625).to_string(),
        "similarity 0.62 below threshold"
    );
    assert_eq!(
        FallbackReason::TimedOut { seconds: 0.25 }.to_string(),
        "timed out after 0.2s"
    );
}

#[test]
fn light_rejects_a_resolved_self_correction_that_medium_accepts() {
    let raw = "we should meet on tuesday sorry wednesday";
    let cleaned = "We should meet on Wednesday.";
    assert_eq!(
        review(raw, cleaned, CleanupLevel::Light, &[]),
        GuardVerdict::Rejected(FallbackReason::SelfCorrectionNotAllowed)
    );
    assert_eq!(review(raw, cleaned, CleanupLevel::Medium, &[]), accepted(cleaned));
    assert_eq!(review(raw, cleaned, CleanupLevel::High, &[]), accepted(cleaned));
}

#[test]
fn light_accepts_a_self_correction_kept_as_spoken() {
    let cleaned = "We should meet on Tuesday, sorry, Wednesday.";
    assert_eq!(
        review(
            "we should meet on tuesday sorry wednesday",
            cleaned,
            CleanupLevel::Light,
            &[]
        ),
        accepted(cleaned)
    );
}

const TOKENS: [&str; 2] = ["⟦S1⟧", "⟦S2⟧"];

#[test]
fn accepts_placeholders_that_come_back_intact() {
    let cleaned = "Here's ⟦S1⟧, and the deck is at ⟦S2⟧.";
    assert_eq!(
        review(
            "here's ⟦S1⟧ and the deck is at ⟦S2⟧",
            cleaned,
            CleanupLevel::Medium,
            &TOKENS
        ),
        accepted(cleaned)
    );
}

#[test]
fn rejects_a_dropped_repeated_altered_or_invented_placeholder() {
    for cleaned in [
        "Here's the link, and the deck is at ⟦S2⟧.",
        "Here's ⟦S1⟧ ⟦S1⟧, and the deck is at ⟦S2⟧.",
        "Here's ⟦S 1⟧, and the deck is at ⟦S2⟧.",
        "Here's [S1], and the deck is at ⟦S2⟧.",
        "Here's ⟦S1⟧, and the deck is at ⟦S2⟧ and ⟦S3⟧.",
        "Here's ⟦S1, and the deck is at ⟦S2⟧.",
    ] {
        assert_eq!(
            review(
                "here's ⟦S1⟧ and the deck is at ⟦S2⟧",
                cleaned,
                CleanupLevel::Medium,
                &TOKENS
            ),
            GuardVerdict::Rejected(FallbackReason::PlaceholderChanged),
            "{cleaned}"
        );
    }
}

#[test]
fn rejects_a_placeholder_retracted_by_a_self_correction() {
    assert_eq!(
        review(
            "send them ⟦S1⟧ sorry ⟦S2⟧",
            "Send them ⟦S2⟧.",
            CleanupLevel::Medium,
            &TOKENS
        ),
        GuardVerdict::Rejected(FallbackReason::PlaceholderChanged)
    );
}

#[test]
fn rejects_a_token_in_output_when_none_was_given() {
    assert_eq!(
        medium("see you soon", "See you ⟦S1⟧ soon."),
        GuardVerdict::Rejected(FallbackReason::PlaceholderChanged)
    );
}
