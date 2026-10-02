//! Deep's repairs as the output guard judges them, as the Mac app's `SelfRepairTests`.

use lt_shared::CleanupLevel;

use crate::{CleanupOptions, FallbackReason, GenerationOutcome, GuardVerdict, OutputGuard};

const KIRK: &str = "I tried to speak with Kirk, but he didn't. I don't think he actually check whether the release is tomorrow. No, sorry, the after tomorrow.";

fn review(raw: &str, cleaned: &str) -> GuardVerdict {
    review_in(raw, cleaned, false)
}

fn review_in(raw: &str, cleaned: &str, multiline: bool) -> GuardVerdict {
    review_with(raw, cleaned, multiline, &[])
}

fn review_with(raw: &str, cleaned: &str, multiline: bool, placeholders: &[&str]) -> GuardVerdict {
    let options = CleanupOptions {
        multiline,
        placeholders: placeholders.iter().map(|&token| token.to_owned()).collect(),
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
        ("Bring two chairs. No, three.", "Bring three chairs.", "Bring three."),
    ] {
        assert_eq!(review(raw, kept), accepted(kept), "{raw:?}");
        assert_eq!(review(raw, dropped), INVALID, "{raw:?}");
    }
}

/// The Mac app's `resolvesACorrectionOfTheEndOfTheSentenceBefore`.
#[test]
fn a_cue_after_a_full_stop_corrects_the_end_of_the_sentence_before() {
    for (raw, cleaned) in [
        (
            "I left my charger in the garage. Actually, the lobby.",
            "I left my charger in the lobby.",
        ),
        (
            "The alert came from the billing service. Sorry, the database.",
            "The alert came from the database.",
        ),
        (
            "The team is replacing the laptop. No, the printer next week.",
            "The team is replacing the printer next week.",
        ),
        (
            "I'm making pasta. Actually, tacos for dinner.",
            "I'm making tacos for dinner.",
        ),
        ("Paint the door red. Actually, blue.", "Paint the door blue."),
    ] {
        assert_eq!(review(raw, cleaned), accepted(cleaned), "{raw:?}");
        let commas = raw.replace(". ", ", ");
        assert_eq!(
            review(&commas, cleaned),
            accepted(cleaned),
            "{commas:?}, as after a comma"
        );
    }
}

/// The Mac app's `keepsACorrectionInALaterSentence`: dropping a correction made in a later
/// sentence leaves what it took back as said, however the check could read its phrase.
#[test]
fn a_correction_in_a_later_sentence_cant_be_dropped_with_what_it_corrects_kept() {
    for (raw, resolved) in [
        (
            "Meet me at the Old Town Hall. Actually no, the Town Hall.",
            "Meet me at the Town Hall.",
        ),
        (
            "The parcel goes to the Melbourne office. Sorry, no, the Sydney office.",
            "The parcel goes to the Sydney office.",
        ),
        (
            "The demo is on Tuesday at noon. Sorry, Wednesday.",
            "The demo is on Wednesday at noon.",
        ),
        (
            "We need three servers for the launch. Sorry, four.",
            "We need four servers for the launch.",
        ),
    ] {
        assert_eq!(review(raw, resolved), accepted(resolved), "{raw:?}");
        let dropped = format!("{}.", raw.split(". ").next().expect("two sentences"));
        assert_eq!(review(raw, &dropped), INVALID, "{dropped:?}");
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
fn a_cue_followed_by_not_and_the_corrected_words_said_again_goes_with_them() {
    assert_accepted(&[
        (
            "The meeting is in room four, no, not four, five.",
            "The meeting is in room five.",
        ),
        (
            "Book the flight for Tuesday, sorry, not Tuesday, Thursday morning.",
            "Book the flight for Thursday morning.",
        ),
        (
            "Send the report to the marketing team, sorry, not marketing, sales, by Friday.",
            "Send the report to the sales team by Friday.",
        ),
        (
            "Apps like Slack, sorry, not Slack, Teams keep dropping my calls.",
            "Apps like Teams keep dropping my calls.",
        ),
        (
            "Words like Docker, sorry, not Docker, Kubernetes never come out right.",
            "Words like Kubernetes never come out right.",
        ),
        (
            "I left the keys in the kitchen. Sorry, not the kitchen, the garage.",
            "I left the keys in the garage.",
        ),
        (
            "Send the blue file to Sam, sorry, not blue, red.",
            "Send the red file to Sam.",
        ),
    ]);
}

#[test]
fn resolves_a_correction_broken_into_sentences() {
    let cases = [
        (
            "My shift starts on Sunday. No, sorry, not Sunday. Thursday.",
            "My shift starts on Thursday.",
            "My shift starts on Sunday. Thursday.",
        ),
        (
            "For the overnight trek, we'll need compasses. Sorry, not compasses. Stoves and plenty of water.",
            "For the overnight trek we'll need stoves and plenty of water.",
            "For the overnight trek, we'll need compasses. Stoves and plenty of water.",
        ),
    ];
    for (raw, cleaned, cue_dropped) in cases {
        assert_eq!(review(raw, cleaned), accepted(cleaned), "{raw:?}");
        assert_eq!(
            review(raw, cue_dropped),
            INVALID,
            "the cue and the words said again go only with the correction"
        );
    }
}

#[test]
fn a_not_goes_with_a_correction_only_when_it_says_corrected_words_again() {
    assert_rejected(&[
        // Drops the contrast the speaker made.
        ("We need three chairs, sorry, not four.", "We need four chairs."),
        // Says again a word the correction doesn't take back.
        (
            "Send the blue file to Sam, sorry, not blue, red.",
            "Send the blue file to red.",
        ),
        // Keeps the corrected word, or reads the correction the wrong way.
        (
            "Words like Docker, sorry, not Docker, Kubernetes never come out right.",
            "Words like Docker never come out right.",
        ),
        (
            "Words like Docker, sorry, not Docker, Kubernetes never come out right.",
            "Words like Docker, not Kubernetes, never come out right.",
        ),
        // Answers the question.
        (
            "Is the demo on Tuesday? No, not Tuesday, Thursday.",
            "Is the demo on Thursday?",
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
        // A name that started the sentence as said, where either capital may be a name's.
        ("Uma will bring the cake.", "Una will bring the cake."),
        // Another name where no sentence starts.
        ("Can you ask Madge to review it?", "Can you ask Marge to review it?"),
    ]);
}

#[test]
fn a_name_may_take_its_possessive() {
    assert_accepted(&[("that is kirk car", "That is Kirk's car.")]);
}

#[test]
fn fixes_a_word_taken_for_a_name() {
    assert_accepted(&[
        (
            "Can you Madge the PR before lunch?",
            "Can you merge the PR before lunch?",
        ),
        (
            "Can you review the P R before lunch?",
            "Can you review the PR before lunch?",
        ),
        ("The A P I is down again.", "The API is down again."),
        (
            "Action summary to get done tomorrow. First, Madge, P R twenty two, Max get the update once the website has deployed. Two follow up for the go ahead. Three, emoji parsing needs a revisit. Four, Russell cleanup should work best.",
            "Action summary to get done tomorrow. First, merge PR 22, Max get the update once the website has deployed. Two, follow up for the go-ahead. Three, emoji parsing needs a revisit. Four, Russell cleanup should work best.",
        ),
    ]);
}

#[test]
fn fixes_a_word_taken_for_a_name_that_starts_a_list_item() {
    let raw = "Two things for today. First, Madge the PR. Second, John updates the website.";
    let cleaned = "Two things for today:\n1. Merge the PR.\n2. John updates the website.";
    assert_eq!(review_in(raw, cleaned, true), accepted(cleaned));
    let renamed = "Two things for today:\n1. Merge the PR.\n2. Pete updates the website.";
    assert_eq!(
        review_in(raw, renamed, true),
        INVALID,
        "a name isn't swapped for another"
    );
}

#[test]
fn keeps_the_letters_spelled_out() {
    let raw = "Can you review the P R before lunch?";
    for cleaned in [
        "Can you review the RP before lunch?",
        "Can you review the PRs before lunch?",
        "Can you review the P before lunch?",
    ] {
        assert_eq!(review(raw, cleaned), INVALID, "{cleaned:?}");
    }
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
        ("I finished the report. Sorry, I was late.", "I finished. I was late."),
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
        review_in(
            "Buy three apples, two pears and a melon.",
            "Buy:\n- Apples\n- Pears\n- A melon",
            true
        ),
        INVALID
    );
}

#[test]
fn rejects_a_bulleted_list_of_two_things_said_in_a_sentence() {
    assert_eq!(
        review_in(
            "I've attached the invoice and the signed agreement.",
            "I've attached:\n- The invoice\n- The signed agreement",
            true
        ),
        GuardVerdict::Rejected(FallbackReason::ShortList)
    );
    let numbered = "Two things:\n1. Call the bank.\n2. Email Sarah.";
    assert_eq!(
        review_in(
            "Two things: number one, call the bank. Number two, email Sarah.",
            numbered,
            true
        ),
        accepted(numbered),
        "a numbered list may have two items, as when they were counted"
    );
}

#[test]
fn allows_two_things_set_off_with_a_full_stop_or_counted_before_a_comma() {
    let cleaned = "Two things:\n- Call the bank\n- Email Sarah";
    for raw in [
        "Two things. Call the bank and email Sarah.",
        "Two things, call the bank and email Sarah.",
    ] {
        assert_eq!(review_in(raw, cleaned, true), accepted(cleaned), "{raw:?}");
    }
    assert_eq!(
        review_in(
            "I've attached, the invoice and the signed agreement.",
            "I've attached:\n- The invoice\n- The signed agreement",
            true
        ),
        GuardVerdict::Rejected(FallbackReason::ShortList),
        "a comma sets them off only after words that count them"
    );
    assert_eq!(
        review_in(
            "Reminder. I've attached the invoice and the signed agreement.",
            "Reminder. I've attached:\n- The invoice\n- The signed agreement",
            true
        ),
        GuardVerdict::Rejected(FallbackReason::ShortList),
        "a full stop elsewhere doesn't set them off"
    );
}

#[test]
fn each_bulleted_list_has_the_line_before_it() {
    let lists = super::bulleted_lists("Two things:\n- a\n- b\n\n- c\n- d\nAnd also:\n- e");
    let leads: Vec<Option<&str>> = lists.iter().map(|list| list.lead.as_deref()).collect();
    assert_eq!(leads, [Some("Two things:"), Some("- b"), Some("And also:")]);
    let items: Vec<&[String]> = lists.iter().map(|list| list.items.as_slice()).collect();
    assert_eq!(items, [&["a", "b"][..], &["c", "d"][..], &["e"][..]]);
    assert_eq!(super::bulleted_lists("- a\n- b")[0].lead, None);
}

#[test]
fn a_list_set_off_by_a_colon_is_matched_as_text_not_as_bytes() {
    let said = "we need the cafe\u{301} menu: soup and bread";
    let cleaned = "We need the caf\u{E9} menu:\n- Soup\n- Bread";
    assert_eq!(
        review_in(said, cleaned, true),
        accepted(cleaned),
        "an accent written either way is the same word"
    );
}

#[test]
fn rejects_a_placeholder_on_a_line_of_its_own() {
    let emoji = ["⟦E1⟧"];
    assert_eq!(
        review_with("Thanks so much! ⟦E1⟧", "Thanks so much!\n\n⟦E1⟧", true, &emoji),
        GuardVerdict::Rejected(FallbackReason::PlaceholderOnItsOwnLine)
    );
    assert_eq!(
        review_with("Thanks so much! ⟦E1⟧", "Thanks so much! ⟦E1⟧", true, &emoji),
        accepted("Thanks so much! ⟦E1⟧")
    );
    assert_eq!(
        review_with(
            "The links are ⟦A1⟧, ⟦A2⟧ and ⟦A3⟧.",
            "The links are:\n- ⟦A1⟧\n- ⟦A2⟧\n- ⟦A3⟧",
            true,
            &["⟦A1⟧", "⟦A2⟧", "⟦A3⟧"]
        ),
        GuardVerdict::Rejected(FallbackReason::PlaceholderOnItsOwnLine),
        "a list of placeholders alone is turned down too, and Medium's sentence shown"
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

/// A correction keeps its meaning: the word it says instead stays, as itself or a word like it,
/// and what it takes back isn't written again, however a repair could otherwise line them up.
#[test]
fn a_correction_keeps_its_meaning() {
    let green = "book the blue room sorry the green room for friday";
    assert_rejected(&[
        (green, "Book the blue room for Friday."),
        (green, "Book the room for Friday."),
        (green, "Book the blue green room for Friday."),
        (
            "Book the blue room, sorry, the green room for Friday.",
            "Book the blue room for Friday.",
        ),
        (
            "send it to the finance team make that the legal team today",
            "Send it to the finance team today.",
        ),
        (
            "ask the designer i mean the developer to check it",
            "Ask the designer to check it.",
        ),
        (
            "we're migrating the load balancer make that the scheduler next week",
            "We're migrating the load balancer next week.",
        ),
        ("paint the fence red no wait blue", "Paint the fence red."),
        ("we need three servers sorry four", "We need four three servers."),
        ("send it to sam sorry to priya", "Send it to Priya Sam."),
        (
            "I left my charger in the garage. Actually, the lobby.",
            "I left my charger in the garage lobby.",
        ),
        (
            "The demo is on Tuesday at noon. Sorry, Wednesday.",
            "The demo is on Tuesday Wednesday at noon.",
        ),
        (
            "Invite Sam to the launch. Sorry, Priya.",
            "Invite Sam and Priya to the launch.",
        ),
        ("fuel efficiency in cars sorry busses", "Fuel efficiency in trains."),
        ("i wanted to say sorry to jo", "I wanted to say it to Jo."),
    ]);
    assert_accepted(&[
        (green, "Book the green room for Friday."),
        (
            "send it to the finance team make that the legal team today",
            "Send it to the legal team today.",
        ),
        (
            "ask the designer i mean the developer to check it",
            "Ask the developer to check it.",
        ),
        (
            "we're migrating the load balancer make that the scheduler next week",
            "We're migrating the scheduler next week.",
        ),
        ("paint the fence red no wait blue", "Paint the fence blue."),
        ("we need three servers sorry four", "We need four servers."),
        ("send it to sam sorry to priya", "Send it to Priya."),
        (
            "the demo is next week sorry the after next",
            "The demo is the week after next.",
        ),
        (
            "i'm meeting divya at the station actually nikhil",
            "I'm meeting Nikhil at the station.",
        ),
        (
            "The billing service goes live next Tuesday. Sorry, I mean the login service.",
            "The login service goes live next Tuesday.",
        ),
        ("fuel efficiency in cars sorry busses", "Fuel efficiency in buses."),
    ]);
}

/// A fact or a name a correction says instead takes back one of its own sort, so no reading of it
/// keeps that one beside it: one that takes back only the words after it is no reading at all.
#[test]
fn a_correction_never_keeps_what_it_takes_back_beside_it() {
    let servers = "we need three servers sorry four";
    let launch = "Invite Sam to the launch. Sorry, Priya.";
    let station = "I am meeting Divya at the station. Actually, Nikhil.";
    assert_rejected(&[
        (servers, "We need three four servers."),
        (servers, "We need three or four servers."),
        (
            "we need three of the servers sorry four",
            "We need three of the four servers.",
        ),
        (launch, "Invite Sam and Priya to the launch."),
        (launch, "Invite Sam, Priya to the launch."),
        (
            "Invite Sam to the launch, sorry, Priya.",
            "Invite Sam and Priya to the launch.",
        ),
        (station, "I am meeting Divya and Nikhil at the station."),
        (station, "I am meeting Divya Nikhil at the station."),
        ("Call me on Tuesday, no, Wednesday.", "Call me on Tuesday or Wednesday."),
        (
            "We have two weeks left. Sorry, three.",
            "We have two or three weeks left.",
        ),
    ]);
    assert_accepted(&[
        (servers, "We need four servers."),
        (
            "two people said we need servers sorry four",
            "Two people said we need four servers.",
        ),
        (
            "we need three of the servers sorry four",
            "We need four of the servers.",
        ),
        (launch, "Invite Priya to the launch."),
        ("Invite Sam to the launch, sorry, Priya.", "Invite Priya to the launch."),
        (station, "I am meeting Nikhil at the station."),
        ("meet me at the station sorry at six", "Meet me at six."),
        ("Ask Sam to email Ana, sorry, Priya.", "Ask Sam to email Priya."),
        ("Ask Sam to email Ana, sorry, Priya.", "Ask Priya to email Ana."),
        ("We have two weeks left. Sorry, three.", "We have three weeks left."),
    ]);
}

/// A cue speech-to-text misheard just after one it heard goes with it, and a misheard word that only
/// holds the grammar together says nothing a correction says instead.
#[test]
fn misheard_cues_and_small_words_say_nothing_a_correction_says() {
    assert_accepted(&[
        (
            "Can you bring the monitor, wait node, the router to the meeting?",
            "Can you bring the router to the meeting?",
        ),
        (
            "The city is buying more electric buses, no weight vans.",
            "The city is buying more electric vans.",
        ),
        (
            "Dinner is on Saturday. Sorry, no theon Tuesday.",
            "Dinner is on Tuesday.",
        ),
        (
            "The product review is on the 12th of October. No sorry thee of November.",
            "The product review is on the 12th of November.",
        ),
    ]);
}

/// "No" in "no one" is a cue too, so one correction can take words out of the phrase another moved
/// back, and that phrase then ends where its words do.
#[test]
fn a_phrase_a_later_correction_cuts_ends_where_its_words_do() {
    let raw = "I'll call no one now. Scratch that. I'll email no one instead.";
    assert_accepted(&[(raw, "I'll email no one instead.")]);
    assert_rejected(&[(raw, "I'll email Noah instead.")]);
}

/// An abbreviation's full stop ends a sentence only before a capital, so "at 3 p.m. today" is one
/// sentence and its time can be corrected.
#[test]
fn an_abbreviation_ends_a_sentence_only_before_a_capital() {
    assert_accepted(&[(
        "The shop closes at 3 p.m. today. Sorry, I meant at 10 a.m.",
        "The shop closes at 10 a.m. today.",
    )]);
}

#[test]
fn a_phrase_that_opens_the_way_its_sentence_did_starts_it_again() {
    let prague = "Ship it to Prague, scratch that, hold it until September.";
    let june = "ship it to prague scratch that hold it until june";
    let lisbon = "Ship it to Lisbon, scratch that, hold it until November.";
    assert_rejected(&[
        (prague, "Ship it to hold it until September."),
        (june, "Ship it to hold it until June."),
        (lisbon, "Ship it to Hold it until November."),
    ]);
    assert_accepted(&[
        (prague, "Hold it until September."),
        (june, "Hold it until June."),
        (lisbon, "Hold it until November."),
        ("Ship it to Prague, scratch that, Vienna.", "Ship it to Vienna."),
        (
            "Book the early flight. Scratch that. Book the afternoon one.",
            "Book the afternoon one.",
        ),
        (
            "Put the box on the table, sorry, under the table.",
            "Put the box under the table.",
        ),
        (
            "We need to restart the off service. Actually, the database.",
            "We need to restart the database.",
        ),
        (
            "The leak is under the sink, rather, behind the dishwasher.",
            "The leak is behind the dishwasher.",
        ),
    ]);
}

#[test]
fn a_correction_takes_back_no_more_than_the_corrected_words_said_again() {
    let physio = "the physio team sorry not physio nursing will join the call at noon";
    let kofi = "Kofi's brother, no wait, not brother, cousin, is hosting the barbecue.";
    let nikhil = "nikhil's team sorry not nikhil's siobhan's owns the billing service";
    assert_rejected(&[
        (physio, "The nursing will join the call at noon."),
        (kofi, "Cousin is hosting the barbecue."),
        (nikhil, "Siobhan's owns the billing service."),
    ]);
    assert_accepted(&[
        (physio, "The nursing team will join the call at noon."),
        (kofi, "Kofi's cousin is hosting the barbecue."),
        (nikhil, "Siobhan's team owns the billing service."),
    ]);
}

/// In text written with capitals and punctuation, a correction takes back its whole sentence so
/// far only when its phrase shows it says all of it again.
#[test]
fn a_correction_takes_back_its_whole_sentence_only_when_its_phrase_says_it_again() {
    let ferries = "Insurance for ferries, no wait, boats went up again.";
    assert_rejected(&[
        (ferries, "Boats went up again."),
        (
            "Insurance for ferries, wait, no, planes went up again.",
            "Planes went up again.",
        ),
        (
            "I emailed Adrian, actually, I'll call them as well.",
            "I'll call them as well.",
        ),
    ]);
    assert_accepted(&[
        (ferries, "Insurance for boats went up again."),
        // A name for a name, the same word, a fact of the same kind, a word said again.
        (
            "Alice knows, sorry, Tara will lead the design review.",
            "Tara will lead the design review.",
        ),
        ("My laptop battery, no wait, my phone is dead.", "My phone is dead."),
        (
            "On Monday at noon, sorry, Tuesday at two works better.",
            "Tuesday at two works better.",
        ),
        (
            "The red car, sorry, a blue car is parked outside.",
            "A blue car is parked outside.",
        ),
    ]);
}

/// Without capitals or punctuation, nothing tells a name from another word, so the ferries read
/// like a false start ("alice knows sorry tara will lead the design review") and stay accepted. A
/// weekday, an acronym or a vocabulary term in text written without capitals doesn't make it text
/// written with them.
#[test]
fn only_capitals_and_punctuation_tell_a_correction_from_a_false_start() {
    assert_accepted(&[
        (
            "insurance for ferries no wait boats went up again",
            "Boats went up again.",
        ),
        (
            "insurance for ferries, no wait, boats went up again.",
            "Boats went up again.",
        ),
        (
            "Insurance for ferries no wait boats went up again",
            "Boats went up again.",
        ),
        (
            "alice knows sorry tara will lead the design review",
            "Tara will lead the design review.",
        ),
        (
            "alice knows, sorry, tara will lead the design review on Monday.",
            "Tara will lead the design review on Monday.",
        ),
        (
            "alice knows, sorry, tara will review the PR.",
            "Tara will review the PR.",
        ),
        (
            "insurance for ferries, no wait, boats went up again on Monday.",
            "Boats went up again on Monday.",
        ),
    ]);
}

/// A reading turned down for taking back too much still names the words its phrase may correct,
/// so a repair can't add them to the phrase as new words and drop the one between.
#[test]
fn a_reading_turned_down_lets_no_other_through() {
    let raw = "The garden Cleaner comes on Tuesday, or rather on Friday.";
    assert_rejected(&[(raw, "The cleaner comes on Friday.")]);
    assert_accepted(&[(raw, "The garden Cleaner comes on Friday.")]);
}

#[test]
fn the_start_of_a_word_broken_off_and_said_again_in_full_may_go() {
    assert_accepted(&[
        (
            "She wants few ex expenses paid back.",
            "She wants few expenses paid back.",
        ),
        (
            "We should con consider the budget first.",
            "We should consider the budget first.",
        ),
        (
            "can you send the rep report by friday",
            "Can you send the report by Friday?",
        ),
        (
            "We should con- consider the budget first.",
            "We should consider the budget first.",
        ),
    ]);
}

#[test]
fn a_word_that_only_starts_the_next_by_chance_stays() {
    assert_rejected(&[
        // A negation, a number, a function word.
        ("there is not nothing left", "There is nothing left."),
        ("Bring ten tennis balls.", "Bring tennis balls."),
        ("Can he help us move?", "Can help us move?"),
        // Across the end of a sentence.
        (
            "We met the new rep. Reports are due on Monday.",
            "We met the new. Reports are due on Monday.",
        ),
        // Not the start of the next word.
        (
            "can you send the rap report by friday",
            "Can you send the report by Friday?",
        ),
        // Not written as a word broken off: part of a word, or set off by a comma.
        (
            "please re-read the contract before signing",
            "Please read the contract before signing.",
        ),
        ("Bring a pen, pencil and paper.", "Bring a pencil and paper."),
        // A single letter, and a name's first part where it starts a sentence.
        (
            "vitamin d deficiency is common in winter",
            "Vitamin deficiency is common in winter.",
        ),
        ("Ed Edwards will lead.", "Edwards will lead."),
    ]);
}
