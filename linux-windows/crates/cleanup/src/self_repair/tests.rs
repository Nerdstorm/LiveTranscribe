//! Deep's repairs as the output guard judges them, as the Mac app's `SelfRepairTests`.

use lt_shared::CleanupLevel;

use crate::{CleanupOptions, FallbackReason, GenerationOutcome, GuardVerdict, OutputGuard};

const KIRK: &str = "I tried to speak with Kirk, but he didn't. I don't think he actually check whether the release is tomorrow. No, sorry, the after tomorrow.";

fn review(raw: &str, cleaned: &str) -> GuardVerdict {
    review_in(raw, cleaned, false)
}

fn review_in(raw: &str, cleaned: &str, multiline: bool) -> GuardVerdict {
    let options = CleanupOptions {
        multiline,
        ..CleanupOptions::new(CleanupLevel::Deep)
    };
    OutputGuard::default().review(raw, &GenerationOutcome::Completed(cleaned.to_owned()), &options)
}

fn accepted(text: &str) -> GuardVerdict {
    GuardVerdict::Accepted(text.to_owned())
}

const INVALID: GuardVerdict = GuardVerdict::Rejected(FallbackReason::InvalidRepair);

fn assert_accepted(cases: &[(&str, &str)]) {
    for &(raw, cleaned) in cases {
        assert_eq!(review(raw, cleaned), accepted(cleaned), "{raw:?} → {cleaned:?}");
    }
}

fn assert_rejected(cases: &[(&str, &str)]) {
    for &(raw, cleaned) in cases {
        assert_eq!(review(raw, cleaned), INVALID, "{raw:?} → {cleaned:?}");
    }
}

#[test]
fn repairs_a_correction_made_in_a_later_sentence_with_a_garbled_phrase() {
    assert_accepted(&[
        (
            KIRK,
            "I tried to speak with Kirk, but he didn't. I don't think he actually checked whether the release is the day after tomorrow.",
        ),
        (
            KIRK,
            "I tried to speak with Kirk, but he didn't. I don't think he actually check whether the release is the day after tomorrow.",
        ),
    ]);
}

#[test]
fn rejects_changing_anything_else() {
    let cases = [
        // Invents what Kirk did.
        "I tried to speak with Kirk, but he didn't answer. I don't think he actually checked whether the release is the day after tomorrow.",
        // Drops the negation.
        "I tried to speak with Kirk, but he didn't. I think he actually checked whether the release is the day after tomorrow.",
        // Reads the correction the wrong way.
        "I tried to speak with Kirk, but he didn't. I don't think he actually checked whether the release is the day before tomorrow.",
        // Keeps what was taken back.
        "I tried to speak with Kirk, but he didn't. I don't think he actually checked whether the release is tomorrow.",
        // Changes the name.
        "I tried to speak with Kurt, but he didn't. I don't think he actually checked whether the release is the day after tomorrow.",
    ];
    assert_rejected(&cases.map(|cleaned| (KIRK, cleaned)));
}

#[test]
fn resolves_a_correction_in_a_later_sentence() {
    assert_accepted(&[
        (
            "The meeting is on Tuesday. Sorry, Wednesday.",
            "The meeting is on Wednesday.",
        ),
        (
            "Send the invoice to Sarah. No wait, Priya.",
            "Send the invoice to Priya.",
        ),
        ("We need three servers. Sorry, I mean four.", "We need four servers."),
        (
            "Chloe will cover my shift. I mean, Peter.",
            "Peter will cover my shift.",
        ),
        (
            "Can you call me back at eleven am? No, sorry, at quarter past nine.",
            "Can you call me back at quarter past nine?",
        ),
        (
            "Our lease renews in May. Or rather, in March.",
            "Our lease renews in March.",
        ),
        (
            "Can you call me back at half past two? Sorry, four pm.",
            "Can you call me back at four pm?",
        ),
        (
            "Let's meet at the cafe on Monday. No, sorry, I mean the on Tuesday.",
            "Let's meet at the cafe on Tuesday.",
        ),
        (
            "The deadline is the fifth of June. Actually, the sixth.",
            "The deadline is the sixth of June.",
        ),
        (
            "Can you pick up the kids at three? Sorry, at four.",
            "Can you pick up the kids at four?",
        ),
        (
            "The budget is fifty thousand dollars. No, sorry, sixty thousand.",
            "The budget is sixty thousand dollars.",
        ),
        (
            "We're flying out next week. Sorry, no, the after next.",
            "We're flying out the week after next.",
        ),
    ]);
}

#[test]
fn keeps_the_rest_of_the_corrected_sentence() {
    for (raw, kept, dropped) in [
        (
            "The demo is on Tuesday at noon. Sorry, Wednesday.",
            "The demo is on Wednesday at noon.",
            "The demo is on Wednesday.",
        ),
        (
            "We need three servers for the launch. Sorry, four.",
            "We need four servers for the launch.",
            "We need four.",
        ),
        (
            "Chloe is presenting at the all hands. Sorry, no, Karen.",
            "Karen is presenting at the all hands.",
            "Karen is presenting.",
        ),
    ] {
        assert_eq!(review(raw, kept), accepted(kept), "{raw:?}");
        assert_eq!(review(raw, dropped), INVALID, "{raw:?}");
    }
}

#[test]
fn a_correction_takes_back_no_fact_it_does_not_replace() {
    let raw = "I'm not free on Tuesday. Sorry, Wednesday.";
    assert_accepted(&[
        (raw, "I'm not free on Wednesday."),
        (
            "we need three servers at noon sorry four",
            "We need four servers at noon.",
        ),
    ]);
    assert_rejected(&[
        (raw, "I'm free on Wednesday."),
        ("we need three servers at noon sorry four", "We need four."),
    ]);
}

#[test]
fn a_negation_is_taken_back_only_by_its_verb() {
    assert_accepted(&[("I don't sorry I do want it", "I do want it.")]);
    assert_rejected(&[(
        "I don't think he checked, sorry, the tests",
        "I think he checked the tests.",
    )]);
}

#[test]
fn resolves_two_corrections_in_later_sentences() {
    assert_accepted(&[(
        "The meeting is on Tuesday. Sorry, Wednesday. Bring three chairs. No, sorry, four.",
        "The meeting is on Wednesday. Bring four chairs.",
    )]);
}

#[test]
fn resolves_a_correction_within_a_sentence() {
    assert_accepted(&[
        (
            "I want to talk about fuel efficiency in cars sorry busses",
            "I want to talk about fuel efficiency in buses.",
        ),
        (
            "let's meet on tuesday no wait wednesday at ten",
            "Let's meet on Wednesday at ten.",
        ),
        (
            "we should deploy on monday scratch that let's wait until tuesday",
            "Let's wait until Tuesday.",
        ),
        (
            "Let's add caching to the frontend, no wait, the search index.",
            "Let's add caching to the search index.",
        ),
        (
            "The new jerseys are purple, actually, yellow.",
            "The new jerseys are yellow.",
        ),
        (
            "Dinner is at half past two, sorry, four pm tonight.",
            "Dinner is at four pm tonight.",
        ),
        (
            "i'm flying to paris on friday sorry i meant to madrid",
            "I'm flying to Madrid on Friday.",
        ),
        (
            "i'm flying to tokyo on friday wait no to denver",
            "I'm flying to Denver on Friday.",
        ),
        (
            "yasmin make that wendy left the keys at reception",
            "Wendy left the keys at reception.",
        ),
        ("the lease ends in april no wait may", "The lease ends in May."),
        (
            "the lease ends in february actually make that may",
            "The lease ends in May.",
        ),
        (
            "ship it to prague scratch that hold it until june",
            "Hold it until June.",
        ),
    ]);
}

#[test]
fn scratch_that_takes_back_the_sentence_before() {
    assert_accepted(&[
        (
            "I'll call the plumber tomorrow. Scratch that, I'll fix the tap myself this weekend.",
            "I'll fix the tap myself this weekend.",
        ),
        (
            "Okay, pay off the credit card first. Scratch that, build the emergency fund first.",
            "Okay, build the emergency fund first.",
        ),
    ]);
}

#[test]
fn takes_a_cue_out_only_with_its_correction() {
    assert_rejected(&[
        // Keeps what "scratch that" took back and drops only the cue.
        (
            "ship it to prague scratch that hold it until june",
            "Ship it to Prague. Hold it until June.",
        ),
        (
            "ship it to prague sorry the parcel stays here",
            "Ship it to Prague. Parcel stays here.",
        ),
        (
            "I'll call the plumber tomorrow. Scratch that, I'll fix the tap myself.",
            "I'll call the plumber tomorrow. I'll fix the tap myself.",
        ),
        // Turns the cue into a claim.
        (
            "yasmin make that wendy left the keys at reception",
            "Yasmin made that. Wendy left the keys at reception.",
        ),
        (
            "tell zoe i meant delia the train is delayed",
            "Tell Zoe I mean Delia the train is delayed.",
        ),
        // Adds back what was corrected, and a form of the cue, as the phrase's repairs.
        (
            "the scheduler make that the message queue ran out of memory",
            "The scheduler made that the message queue ran out of memory.",
        ),
        // Keeps the month taken back.
        ("the lease ends in april no wait may", "The lease ends in April."),
    ]);
}

#[test]
fn keeps_names_as_said() {
    assert_rejected(&[
        (
            "I rang Uma twice, but they didn't answer.",
            "I rang Una twice, but they didn't answer.",
        ),
        (
            "i rang uma twice but they didn't answer",
            "I rang Una twice, but they didn't answer.",
        ),
        ("can you check the jura ticket", "Can you check the Jira ticket?"),
        ("uma hasn't replied to my message", "Una hasn't replied to my message."),
        (
            "delia i mean uma left the keys at reception",
            "Dela, I mean Uma, left the keys at reception.",
        ),
        (
            "remind xavier about the dentist no sorry uma",
            "Remind Xavier about the dentist. No, sorry, um...",
        ),
    ]);
}

#[test]
fn a_name_may_take_its_possessive() {
    assert_accepted(&[("that is kirk car", "That is Kirk's car.")]);
}

#[test]
fn keeps_a_cue_that_starts_a_new_thought() {
    assert_rejected(&[
        (
            "Is the release tomorrow? No, it's the day after.",
            "Is the release the day after?",
        ),
        (
            "Is the release tomorrow? No, it's the day after.",
            "Is the release tomorrow? It's the day after.",
        ),
        (
            "Sorry I'm late, the train was delayed.",
            "I'm late, the train was delayed.",
        ),
        (
            "I finished the report. Sorry, I haven't had time to review yours yet.",
            "I haven't had time to review yours yet.",
        ),
        ("I finished the report. Sorry, I was late.", "I was late."),
        ("It works. Actually, it's quite fast.", "It's quite fast."),
        (
            "We shipped version two. Actually, we shipped it a week early.",
            "We shipped it a week early.",
        ),
        (
            "Is Sam coming tonight? No, he's working late.",
            "Is Sam coming? He's working late.",
        ),
    ]);
}

#[test]
fn fixes_grammar_and_misheard_words() {
    assert_accepted(&[
        (
            "She don't know if they was coming.",
            "She doesn't know if they were coming.",
        ),
        ("He go to the gym every day.", "He goes to the gym every day."),
        (
            "I need to by milk on the way home.",
            "I need to buy milk on the way home.",
        ),
        ("I going to the store later.", "I am going to the store later."),
        (
            "Their going to send it over tonight.",
            "They're going to send it over tonight.",
        ),
        (
            "We need twenty five chairs for the hall.",
            "We need 25 chairs for the hall.",
        ),
        ("The call is at two thirty.", "The call is at 2:30."),
        ("I do not think so.", "I don't think so."),
        ("Weather we go or not, we pay.", "Whether we go or not, we pay."),
        ("the busses are late again", "The buses are late again."),
        ("im going home", "I'm going home."),
    ]);
}

#[test]
fn accepts_text_that_was_already_right() {
    let text = "The build is green, and Priya will deploy it on Friday.";
    assert_accepted(&[(text, text)]);
}

#[test]
fn keeps_the_facts() {
    assert_rejected(&[
        ("We need fifteen chairs.", "We need fifty chairs."),
        ("See you Tuesday.", "See you Thursday."),
        ("I agree with the plan.", "I don't agree with the plan."),
        ("I don't agree with the plan.", "I agree with the plan."),
        ("Tell Kirk the build is green.", "Tell Kurt the build is green."),
        ("Call me before lunch.", "Call me after lunch."),
        ("The invoice is ready.", "The invoice is ready to send."),
        ("I tried to speak with Kirk.", "I tried to talk to Kirk."),
    ]);
}

#[test]
fn lays_out_a_list_in_a_field_that_takes_several_lines() {
    let cleaned = "I need to buy:\n- Milk\n- Eggs\n- Bread";
    assert_eq!(
        review_in("I need to buy milk, eggs and bread.", cleaned, true),
        accepted(cleaned)
    );
    let numbered = "Today:\n1. Call the bank.\n2. Email Sarah.\n3. Book the flights.";
    assert_eq!(
        review_in(
            "Today first call the bank, second email Sarah, and third book the flights.",
            numbered,
            true
        ),
        accepted(numbered)
    );
}

#[test]
fn lays_out_an_email() {
    let cleaned = "Hi Sam,\n\nThanks for sending the report. I'll review it tomorrow.\n\nCheers,\nPriya";
    assert_eq!(
        review_in(
            "hi sam thanks for sending the report i'll review it tomorrow cheers priya",
            cleaned,
            true
        ),
        accepted(cleaned)
    );
}

#[test]
fn rejects_lines_in_a_one_line_field() {
    assert_eq!(
        review("Buy milk and eggs.", "Buy:\n- Milk\n- Eggs"),
        GuardVerdict::Rejected(FallbackReason::LayoutNotAllowed)
    );
}

#[test]
fn rejects_a_list_that_drops_quantities() {
    assert_eq!(
        review_in("Buy three apples and two pears.", "Buy:\n- Apples\n- Pears", true),
        INVALID
    );
}

/// The prompt probe's policy lets no words be taken back: no correction is resolved then, and the
/// check still runs (the Mac app's `resolvesNothingWhenNoWordsMayBeTakenBack`).
#[test]
fn a_policy_that_retracts_nothing_resolves_no_correction() {
    let policy = crate::GuardPolicy {
        max_retracted_words: 0,
        ..crate::GuardPolicy::default()
    };
    let guard = OutputGuard::new(policy);
    let options = CleanupOptions::new(CleanupLevel::Deep);
    let review =
        |raw: &str, cleaned: &str| guard.review(raw, &GenerationOutcome::Completed(cleaned.to_owned()), &options);
    assert_eq!(
        review(
            "The meeting is on Tuesday. Sorry, Wednesday.",
            "The meeting is on Wednesday."
        ),
        INVALID
    );
    let kept = "The meeting is on Tuesday. Sorry, Wednesday.";
    assert_eq!(review(kept, kept), accepted(kept));
}

// MARK: - Beyond the Mac app's tests

/// Words are compared as Swift compares strings: an accent written as a combining mark is the
/// same word.
#[test]
fn words_are_canonically_equivalent() {
    assert_accepted(&[("We met at the caf\u{E9}.", "We met at the cafe\u{301}.")]);
}
