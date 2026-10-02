@testable import Cleanup
import Foundation
import Shared

/// Deep's repairs, as the guard judges them (``SelfRepair``): every input of SelfRepairTests, then
/// each kind of edit a repair may make and may not.
extension CleanupFixtures.Guard {
    private static let kirk = "I tried to speak with Kirk, but he didn't. I don't think he actually check whether the release is tomorrow. No, sorry, the after tomorrow."

    /// SelfRepairTests' cases, then each kind of edit a repair may make and may not: layout,
    /// numbers, letters spelled out, contractions, names, cues, corrections across sentences and
    /// the search's limits.
    static var deepCases: [Case] {
        selfRepairTestCases + layoutCases + numberRepairCases + acronymCases + contractionCases + repairNameCases
            + cueCases + crossSentenceCases + repairEdgeCases + correctionMeaningCases
    }

    /// SelfRepairTests, every input.
    private static var selfRepairTestCases: [Case] {
        let kirkCleaned = [
            "I tried to speak with Kirk, but he didn't. I don't think he actually checked whether the release is the day after tomorrow.",
            "I tried to speak with Kirk, but he didn't. I don't think he actually check whether the release is the day after tomorrow.",
            "I tried to speak with Kirk, but he didn't answer. I don't think he actually checked whether the release is the day after tomorrow.",
            "I tried to speak with Kirk, but he didn't. I think he actually checked whether the release is the day after tomorrow.",
            "I tried to speak with Kirk, but he didn't. I don't think he actually checked whether the release is the day before tomorrow.",
            "I tried to speak with Kirk, but he didn't. I don't think he actually checked whether the release is tomorrow.",
            "I tried to speak with Kurt, but he didn't. I don't think he actually checked whether the release is the day after tomorrow.",
        ]
        let pairs: [(String, String)] = [
            // A correction in a later sentence.
            ("The meeting is on Tuesday. Sorry, Wednesday.", "The meeting is on Wednesday."),
            ("Send the invoice to Sarah. No wait, Priya.", "Send the invoice to Priya."),
            ("We need three servers. Sorry, I mean four.", "We need four servers."),
            ("Chloe will cover my shift. I mean, Peter.", "Peter will cover my shift."),
            ("Can you call me back at eleven am? No, sorry, at quarter past nine.", "Can you call me back at quarter past nine?"),
            ("Our lease renews in May. Or rather, in March.", "Our lease renews in March."),
            ("Can you call me back at half past two? Sorry, four pm.", "Can you call me back at four pm?"),
            ("Let's meet at the cafe on Monday. No, sorry, I mean the on Tuesday.", "Let's meet at the cafe on Tuesday."),
            ("The deadline is the fifth of June. Actually, the sixth.", "The deadline is the sixth of June."),
            ("Can you pick up the kids at three? Sorry, at four.", "Can you pick up the kids at four?"),
            ("The budget is fifty thousand dollars. No, sorry, sixty thousand.", "The budget is sixty thousand dollars."),
            ("We're flying out next week. Sorry, no, the after next.", "We're flying out the week after next."),
            // It keeps the rest of the sentence it corrects.
            ("The demo is on Tuesday at noon. Sorry, Wednesday.", "The demo is on Wednesday at noon."),
            ("The demo is on Tuesday at noon. Sorry, Wednesday.", "The demo is on Wednesday."),
            ("We need three servers for the launch. Sorry, four.", "We need four servers for the launch."),
            ("We need three servers for the launch. Sorry, four.", "We need four."),
            ("Chloe is presenting at the all hands. Sorry, no, Karen.", "Karen is presenting at the all hands."),
            ("Chloe is presenting at the all hands. Sorry, no, Karen.", "Karen is presenting."),
            // It can't be dropped with what it corrects kept.
            ("Meet me at the Old Town Hall. Actually no, the Town Hall.", "Meet me at the Town Hall."),
            ("Meet me at the Old Town Hall. Actually no, the Town Hall.", "Meet me at the Old Town Hall."),
            ("The parcel goes to the Melbourne office. Sorry, no, the Sydney office.", "The parcel goes to the Melbourne office."),
            // It takes back no fact it doesn't replace; a negation only with its verb.
            ("I'm not free on Tuesday. Sorry, Wednesday.", "I'm not free on Wednesday."),
            ("I'm not free on Tuesday. Sorry, Wednesday.", "I'm free on Wednesday."),
            ("we need three servers at noon sorry four", "We need four."),
            ("we need three servers at noon sorry four", "We need four servers at noon."),
            ("I don't sorry I do want it", "I do want it."),
            ("I don't think he checked, sorry, the tests", "I think he checked the tests."),
            ("The meeting is on Tuesday. Sorry, Wednesday. Bring three chairs. No, sorry, four.", "The meeting is on Wednesday. Bring four chairs."),
            // Within a sentence, as at Medium.
            ("I want to talk about fuel efficiency in cars sorry busses", "I want to talk about fuel efficiency in buses."),
            ("let's meet on tuesday no wait wednesday at ten", "Let's meet on Wednesday at ten."),
            ("we should deploy on monday scratch that let's wait until tuesday", "Let's wait until Tuesday."),
            ("Let's add caching to the frontend, no wait, the search index.", "Let's add caching to the search index."),
            ("The new jerseys are purple, actually, yellow.", "The new jerseys are yellow."),
            ("Dinner is at half past two, sorry, four pm tonight.", "Dinner is at four pm tonight."),
            ("i'm flying to paris on friday sorry i meant to madrid", "I'm flying to Madrid on Friday."),
            ("i'm flying to tokyo on friday wait no to denver", "I'm flying to Denver on Friday."),
            ("yasmin make that wendy left the keys at reception", "Wendy left the keys at reception."),
            ("the lease ends in april no wait may", "The lease ends in May."),
            ("the lease ends in february actually make that may", "The lease ends in May."),
            ("ship it to prague scratch that hold it until june", "Hold it until June."),
            // A cue followed by "not" and the corrected words said again goes with them, and only then.
            ("The meeting is in room four, no, not four, five.", "The meeting is in room five."),
            ("Book the flight for Tuesday, sorry, not Tuesday, Thursday morning.", "Book the flight for Thursday morning."),
            ("Send the report to the marketing team, sorry, not marketing, sales, by Friday.", "Send the report to the sales team by Friday."),
            ("Apps like Slack, sorry, not Slack, Teams keep dropping my calls.", "Apps like Teams keep dropping my calls."),
            ("Words like Docker, sorry, not Docker, Kubernetes never come out right.", "Words like Kubernetes never come out right."),
            ("I left the keys in the kitchen. Sorry, not the kitchen, the garage.", "I left the keys in the garage."),
            ("Send the blue file to Sam, sorry, not blue, red.", "Send the red file to Sam."),
            ("We need three chairs, sorry, not four.", "We need four chairs."),
            ("Send the blue file to Sam, sorry, not blue, red.", "Send the blue file to red."),
            ("Words like Docker, sorry, not Docker, Kubernetes never come out right.", "Words like Docker never come out right."),
            ("Words like Docker, sorry, not Docker, Kubernetes never come out right.", "Words like Docker, not Kubernetes, never come out right."),
            ("Is the demo on Tuesday? No, not Tuesday, Thursday.", "Is the demo on Thursday?"),
            // "Scratch that" takes back the end of the sentence before it.
            ("I'll call the plumber tomorrow. Scratch that, I'll fix the tap myself this weekend.", "I'll fix the tap myself this weekend."),
            ("Okay, pay off the credit card first. Scratch that, build the emergency fund first.", "Okay, build the emergency fund first."),
            // A cue goes only with its correction, and is never changed.
            ("ship it to prague scratch that hold it until june", "Ship it to Prague. Hold it until June."),
            ("ship it to prague sorry the parcel stays here", "Ship it to Prague. Parcel stays here."),
            ("I'll call the plumber tomorrow. Scratch that, I'll fix the tap myself.", "I'll call the plumber tomorrow. I'll fix the tap myself."),
            ("yasmin make that wendy left the keys at reception", "Yasmin made that. Wendy left the keys at reception."),
            ("tell zoe i meant delia the train is delayed", "Tell Zoe I mean Delia the train is delayed."),
            ("the scheduler make that the message queue ran out of memory", "The scheduler made that the message queue ran out of memory."),
            ("the lease ends in april no wait may", "The lease ends in April."),
            // A name is kept as said, and no word becomes one.
            ("I rang Uma twice, but they didn't answer.", "I rang Una twice, but they didn't answer."),
            ("i rang uma twice but they didn't answer", "I rang Una twice, but they didn't answer."),
            ("can you check the jura ticket", "Can you check the Jira ticket?"),
            ("uma hasn't replied to my message", "Una hasn't replied to my message."),
            ("delia i mean uma left the keys at reception", "Dela, I mean Uma, left the keys at reception."),
            ("remind xavier about the dentist no sorry uma", "Remind Xavier about the dentist. No, sorry, um..."),
            ("that is kirk car", "That is Kirk's car."),
            ("Uma will bring the cake.", "Una will bring the cake."),
            ("Can you ask Madge to review it?", "Can you ask Marge to review it?"),
            // A word speech-to-text took for a name, fixed where its capital says nothing.
            ("Can you Madge the PR before lunch?", "Can you merge the PR before lunch?"),
            ("Can you review the P R before lunch?", "Can you review the PR before lunch?"),
            ("The A P I is down again.", "The API is down again."),
            (
                "Plan for the release tomorrow. First, Madge, P R thirty one, Sam get the notes once the build has finished. Two follow up for the sign off. Three, the export screen needs a fix. Four, Ellis review should come last.",
                "Plan for the release tomorrow. First, merge PR 31, Sam get the notes once the build has finished. Two, follow up for the sign-off. Three, the export screen needs a fix. Four, Ellis review should come last."
            ),
            ("Two things for today. First, Madge the PR. Second, John updates the website.", "Two things for today:\n1. Merge the PR.\n2. John updates the website."),
            ("Two things for today. First, Madge the PR. Second, John updates the website.", "Two things for today:\n1. Merge the PR.\n2. Pete updates the website."),
            ("Can you review the P R before lunch?", "Can you review the RP before lunch?"),
            ("Can you review the P R before lunch?", "Can you review the PRs before lunch?"),
            ("Can you review the P R before lunch?", "Can you review the P before lunch?"),
            // A correction speech-to-text broke into sentences.
            ("My shift starts on Sunday. No, sorry, not Sunday. Thursday.", "My shift starts on Thursday."),
            ("My shift starts on Sunday. No, sorry, not Sunday. Thursday.", "My shift starts on Sunday. Thursday."),
            (
                "For the overnight trek, we'll need compasses. Sorry, not compasses. Stoves and plenty of water.",
                "For the overnight trek we'll need stoves and plenty of water."
            ),
            (
                "For the overnight trek, we'll need compasses. Sorry, not compasses. Stoves and plenty of water.",
                "For the overnight trek, we'll need compasses. Stoves and plenty of water."
            ),
            // A cue that starts a new thought stays.
            ("Is the release tomorrow? No, it's the day after.", "Is the release the day after?"),
            ("Is the release tomorrow? No, it's the day after.", "Is the release tomorrow? It's the day after."),
            ("Sorry I'm late, the train was delayed.", "I'm late, the train was delayed."),
            ("I finished the report. Sorry, I haven't had time to review yours yet.", "I haven't had time to review yours yet."),
            ("I finished the report. Sorry, I was late.", "I was late."),
            ("It works. Actually, it's quite fast.", "It's quite fast."),
            ("We shipped version two. Actually, we shipped it a week early.", "We shipped it a week early."),
            ("Is Sam coming tonight? No, he's working late.", "Is Sam coming? He's working late."),
            // Grammar and misheard words.
            ("She don't know if they was coming.", "She doesn't know if they were coming."),
            ("He go to the gym every day.", "He goes to the gym every day."),
            ("I need to by milk on the way home.", "I need to buy milk on the way home."),
            ("I going to the store later.", "I am going to the store later."),
            ("Their going to send it over tonight.", "They're going to send it over tonight."),
            ("We need twenty five chairs for the hall.", "We need 25 chairs for the hall."),
            ("The call is at two thirty.", "The call is at 2:30."),
            ("I do not think so.", "I don't think so."),
            ("Weather we go or not, we pay.", "Whether we go or not, we pay."),
            ("the busses are late again", "The buses are late again."),
            ("im going home", "I'm going home."),
            ("The build is green, and Priya will deploy it on Friday.", "The build is green, and Priya will deploy it on Friday."),
            // Facts may not change.
            ("We need fifteen chairs.", "We need fifty chairs."),
            ("See you Tuesday.", "See you Thursday."),
            ("I agree with the plan.", "I don't agree with the plan."),
            ("I don't agree with the plan.", "I agree with the plan."),
            ("Tell Kirk the build is green.", "Tell Kurt the build is green."),
            ("Call me before lunch.", "Call me after lunch."),
            ("The invoice is ready.", "The invoice is ready to send."),
            ("I tried to speak with Kirk.", "I tried to talk to Kirk."),
            // Layout, in a field that takes several lines and one that doesn't.
            ("I need to buy milk, eggs and bread.", "I need to buy:\n- Milk\n- Eggs\n- Bread"),
            ("Today first call the bank, second email Sarah, and third book the flights.", "Today:\n1. Call the bank.\n2. Email Sarah.\n3. Book the flights."),
            ("hi sam thanks for sending the report i'll review it tomorrow cheers priya", "Hi Sam,\n\nThanks for sending the report. I'll review it tomorrow.\n\nCheers,\nPriya"),
            ("Buy milk and eggs.", "Buy:\n- Milk\n- Eggs"),
            ("Buy three apples and two pears.", "Buy:\n- Apples\n- Pears"),
            ("Two things. Call the bank and email Sarah.", "Two things:\n- Call the bank\n- Email Sarah"),
            ("Two things, call the bank and email Sarah.", "Two things:\n- Call the bank\n- Email Sarah"),
            ("I've attached, the invoice and the signed agreement.", "I've attached:\n- The invoice\n- The signed agreement"),
            (
                "Reminder. I've attached the invoice and the signed agreement.",
                "Reminder. I've attached:\n- The invoice\n- The signed agreement"
            ),
        ]
        return kirkCleaned.map { completed(kirk, $0) } + pairs.map { completed($0.0, $0.1) }
    }

    /// Lists and letters laid out, with each kind of item marker, and what layout may not do.
    private static var layoutCases: [Case] {
        [
            completed("buy milk eggs and bread", "Buy:\n• Milk\n• Eggs\n• Bread"),
            completed("buy milk eggs and bread", "Buy:\n* Milk\n* Eggs\n* Bread"),
            completed("buy milk eggs and bread", "Buy:\n\u{2013} Milk\n\u{2014} Eggs\n\u{00B7} Bread"),
            completed("buy milk eggs and bread", "Buy:\n  - Milk\n\t- Eggs\n-Bread"),
            completed("buy milk eggs and bread", "Buy:\n- Milk\n- Eggs\n- Bread\n- Butter"),
            completed("buy milk eggs and bread", "Buy:\r\n- Milk\r\n- Eggs\r\n- Bread"),
            completed("buy milk eggs and bread", "Buy:\u{2028}- Milk\u{2029}- Eggs\u{85}- Bread"),
            completed("steps first open the app second sign in third pick a plan", "Steps:\n1) Open the app.\n2) Sign in.\n3) Pick a plan."),
            completed("steps firstly open the app secondly sign in finally pick a plan", "Steps:\n1. Open the app.\n2. Sign in.\n3. Pick a plan."),
            completed("number one call the bank number two email sarah", "1. Call the bank.\n2. Email Sarah."),
            completed("one call the bank two email sarah", "1. Call the bank.\n2. Email Sarah."),
            completed("the agenda is budget then hiring", "The agenda:\n1. Budget\n2. Hiring"),
            completed("room 1234 is free", "Room\n1234. is free"),
            completed("check items 1 2 and 3", "Check items:\n1. 1\n2. 2\n3. 3"),
            completed("dear priya thank you for the flowers best wishes sam", "Dear Priya,\n\nThank you for the flowers.\n\nBest wishes,\nSam"),
            completed("hi sam thanks for the report cheers priya", "Hi Sam,\n\nThanks for the report.\n\nCheers,\nJo"),
            completed("hi sam thanks for the report cheers priya", "Hi Priya,\n\nThanks for the report.\n\nCheers,\nSam"),
            completed("the first part is done. the second part is next.", "The first part is done.\n\nThe second part is next."),
            completed("the first part is done the second part is next", "The first part is done.\n\nThe second part is next."),
            completed("Hi team\nThe build is green\nThanks", "Hi team,\nThe build is green.\nThanks"),
            // Two things said in a sentence stay in it, unless they were counted or set off with a colon.
            completed(
                "few things we need to focus on: getting active feeds working and releasing the hot fix",
                "A few things we need to focus on:\n- Getting active feeds working\n- Releasing the hot fix"
            ),
            completed(
                "few things we need to focus on: getting active feeds working and releasing the hot fix",
                "A few things we need to focus on:\n\n- Getting active feeds working\n- Releasing the hot fix"
            ),
            completed(
                "few things we need to focus on getting active feeds working and releasing the hot fix",
                "A few things we need to focus on:\n- Getting active feeds working\n- Releasing the hot fix"
            ),
            completed(
                "reminder i've attached: the invoice and the signed agreement",
                "Reminder: I've attached:\n- The invoice\n- The signed agreement"
            ),
            completed(
                "reminder: i've attached the invoice and the signed agreement",
                "Reminder: I've attached:\n- The invoice\n- The signed agreement"
            ),
            completed("two things: call the bank and email sarah", "Two things:\n- Call the bank\n- Email Sarah"),
            completed("we need the cafe\u{301} menu: soup and bread", "We need the caf\u{E9} menu:\n- Soup\n- Bread"),
            completed("two things: call the bank and email sarah", "Two things:\n- Call the bank\n- Email Sarah\n\n- Phone Uma\n- Book the room"),
            completed("two things: call the bank and email sarah", "Two things:\n- Call the bank"),
            completed("two things: call the bank and email sarah", "Two things:\n- Phone the bank\n- Email Sarah"),
            completed("i've attached the invoice and the signed agreement", "I've attached:\n- The invoice\n- The signed agreement"),
            completed("i've attached the invoice and the signed agreement", "I've attached:\r\n- The invoice\r\n- The signed agreement\r\n"),
            completed("two things number one call the bank number two email sarah", "Two things:\n1. Call the bank.\n2. Email Sarah."),
            // Two things set off with the full stop speech-to-text writes for a pause, or counted
            // ahead of a comma.
            completed("two things. call the bank and email sarah", "Two things:\n- Call the bank\n- Email Sarah"),
            completed("two things! call the bank and email sarah", "Two things:\n- Call the bank\n- Email Sarah"),
            completed("two things, call the bank and email sarah", "Two things:\n- Call the bank\n- Email Sarah"),
            completed("a couple of things, call the bank and email sarah", "A couple of things:\n- Call the bank\n- Email Sarah"),
            completed("both of these, call the bank and email sarah", "Both of these:\n- Call the bank\n- Email Sarah"),
            completed("the plan, call the bank and email sarah", "The plan:\n- Call the bank\n- Email Sarah"),
            completed("two things today, call the bank and email sarah", "Two things today:\n- Call the bank\n- Email Sarah"),
            completed("reminder. i've attached the invoice and the signed agreement", "Reminder. I've attached:\n- The invoice\n- The signed agreement"),
            completed("we need to talk. two things. call the bank and email sarah", "We need to talk. Two things:\n- Call the bank\n- Email Sarah"),
            completed("buy milk\n- eggs\n- bread", "Buy milk:\n- Eggs\n- Bread"),
            // A placeholder alone on a line, and one in its sentence.
            completed("thanks so much ⟦E1⟧", "Thanks so much!\n\n⟦E1⟧", placeholders: ["⟦E1⟧"]),
            completed("thanks so much ⟦E1⟧", "Thanks so much! ⟦E1⟧", placeholders: ["⟦E1⟧"]),
            completed("thanks so much\n⟦E1⟧", "Thanks so much!\n⟦E1⟧", placeholders: ["⟦E1⟧"]),
            completed(
                "the links are ⟦A1⟧ ⟦A2⟧ and ⟦A3⟧", "The links are:\n- ⟦A1⟧\n- ⟦A2⟧\n- ⟦A3⟧.",
                placeholders: ["⟦A1⟧", "⟦A2⟧", "⟦A3⟧"]
            ),
        ]
    }

    /// Numbers said in words and written in digits, either way, and numbers that change.
    private static var numberRepairCases: [Case] {
        [
            completed("we need twenty one chairs", "We need 21 chairs."),
            completed("we need 21 chairs", "We need twenty one chairs."),
            completed("we need 21 chairs", "We need twenty-one chairs."),
            completed("the twenty first of june", "The 21st of June."),
            completed("the third of june", "The 3rd of June."),
            completed("the third of june", "The 4th of June."),
            completed("it costs one hundred twenty five dollars", "It costs $125."),
            completed("it costs one hundred and twenty five dollars", "It costs $125."),
            completed("it costs twenty five percent more", "It costs 25% more."),
            completed("it's two thousand twenty four", "It's 2024."),
            completed("one hundred twenty five thousand", "125000"),
            completed("one hundred twenty five thousand one", "125001"),
            completed("meet at nine oh five", "Meet at 9:05."),
            completed("meet at nine fifteen", "Meet at 9:15."),
            completed("meet at nine fifteen", "Meet at 9:50."),
            completed("meet at half past two", "Meet at 2:30."),
            completed("meet at seven pm", "Meet at 7 pm."),
            completed("meet at seven pm", "Meet at 7pm."),
            completed("meet at 7 pm", "Meet at seven pm."),
            completed("we need three", "We need 3."),
            completed("we need three", "We need 4."),
            completed("we need 3", "We need three."),
            completed("we need 3 more", "We need more."),
            completed("we need a dozen eggs", "We need 12 eggs."),
            completed("the score was five five", "The score was 55."),
            completed("the score was five five", "The score was 5-5."),
            completed("zero one two", "012"),
            completed("it's ٣ o'clock", "It's 3 o'clock."),
            completed("the first item", "The 1st item."),
            completed("the first item", "The first item."),
        ]
    }

    /// Letters spelled out and written as one word, and letters that change.
    private static var acronymCases: [Case] {
        [
            completed("review the p r today", "Review the PR today."),
            completed("review the P R today", "Review the PR today."),
            completed("review the P R today", "Review the pr today."),
            completed("the a p i is down", "The API is down."),
            completed("the A. P. I. is down", "The API is down."),
            completed("p r twenty two is merged", "PR 22 is merged."),
            completed("p r twenty two is merged", "PR22 is merged."),
            completed("the p r is merged", "The RP is merged."),
            completed("the p r is merged", "The PRs are merged."),
            completed("the p r is merged", "The P is merged."),
            completed("a b c d e f", "ABCDEF."),
            completed("a b c d e f g", "ABCDEFG."),
            completed("send it to p r sorry q a", "Send it to QA."),
            completed("send it to p r sorry q a", "Send it to PR."),
            completed("pick plan a. i think it's best", "Pick plan AI think it's best."),
            completed("the u r l is wrong", "The URL is wrong."),
            completed("the U R L is wrong", "The U.R.L. is wrong."),
        ]
    }

    /// Words merged and split, and negations kept through them.
    private static var contractionCases: [Case] {
        [
            completed("i am here", "I'm here."),
            completed("it is ready", "It's ready."),
            completed("it has been ready", "It's been ready."),
            completed("we will see", "We'll see."),
            completed("they are late", "They're late."),
            completed("i would go", "I'd go."),
            completed("let us go", "Let's go."),
            completed("you can not go", "You can't go."),
            completed("you cannot go", "You can't go."),
            completed("you cannot go", "You can go."),
            completed("we will not go", "We won't go."),
            completed("we won't go", "We will not go."),
            completed("i don't know", "I do not know."),
            completed("he don't know", "He doesn't know."),
            completed("he doesn't know", "He didn't know."),
            completed("he doesn't know", "He does know."),
            completed("it isn't ready", "It is not ready."),
            completed("it isn't ready", "It wasn't ready."),
            completed("it isn't ready", "It is ready."),
            completed("i ain't going", "I am not going."),
            completed("log in to the site", "Login to the site."),
            completed("the login page", "The log in page."),
            completed("every one came", "Everyone came."),
            completed("we're going", "We are going."),
        ]
    }

    /// Names kept, respelled, capitalised, dropped and made up.
    private static var repairNameCases: [Case] {
        [
            completed("that is james car", "That is James' car."),
            completed("that is james car", "That is James's car."),
            completed("that is kirk car", "That is Kirks' car."),
            completed("i met priya today", "I met Priya today."),
            completed("i met priya today", "I met Pria today."),
            completed("i met pria today", "I met Priya today."),
            completed("I met Priya today", "I met priya today."),
            completed("ask Priya and Sam", "Ask Sam and Priya."),
            completed("ask Priya and Sam", "Ask Priya."),
            completed("Chloe will cover my shift", "Chloe will cover my shift."),
            completed("Chloe will cover my shift", "Karen will cover my shift."),
            completed("i think the plan works", "I think The plan works."),
            completed("send it to the Acme team", "Send it to the ACME team."),
            completed("tell Jean-Luc about it", "Tell Jean-Luc about it."),
            completed("tell Jean-Luc about it", "Tell Jean Luc about it."),
            completed("José is here", "Jose\u{301} is here."),
            completed("i'll call mum", "I'll call Mum."),
            // A capital speech-to-text gave a word it took for a name.
            completed("can you Madge it", "Can you merge it?"),
            completed("can you Madge it", "Can you Merge it?"),
            completed("Madge the PR", "Merge the PR."),
            completed("ok so Madge the PR", "OK, so merge the PR."),
            completed("first, Madge the PR", "1. Merge the PR."),
            completed("first, Madge the PR. second, ship it", "1. Merge the PR.\n2. Ship it."),
            completed("first, John ships it. second, Sam tests it", "1. Joan ships it.\n2. Sam tests it."),
            completed("first, John ships it. second, Sam tests it", "1. Pete ships it.\n2. Sam tests it."),
            completed("i asked Uma. she said yes", "I asked uma. She said yes."),
            completed("i asked Uma. she said yes", "I asked um. She said yes."),
            completed("i asked uma. Una said yes", "I asked Una. Una said yes."),
            completed("we use Jura daily", "We use jira daily."),
            completed("we use jura daily", "We use Jira daily."),
        ]
    }

    /// Cues kept as said, taken out with their correction, and taken out alone.
    private static var cueCases: [Case] {
        [
            completed("sorry i'm late", "Sorry, I'm late."),
            completed("sorry i'm late", "I'm late."),
            completed("no i don't think so", "No, I don't think so."),
            completed("is it ready? no", "Is it ready? No."),
            completed("is it ready? no", "Is it ready?"),
            completed("actually it works", "Actually, it works."),
            completed("actually it works", "It works."),
            completed("i mean it", "I mean it."),
            completed("wait for me", "Wait for me."),
            completed("wait for me", "For me."),
            completed("i would rather stay", "I'd rather stay."),
            completed("make that three coffees", "Make that three coffees."),
            completed("tell yasmin or rather victor", "Tell Victor."),
            completed("tell yasmin or rather victor", "Tell Yasmin, or rather, Victor."),
            completed("tell yasmin or rather victor", "Tell Yasmin or Victor."),
            completed("the correction is final", "The correction is final."),
            completed("cars sorry no wait i mean buses", "Buses."),
            completed("cars sorry no wait i mean buses", "Cars. Sorry, no, wait, I mean buses."),
            completed("Is it Tuesday? No. It's Wednesday.", "Is it Wednesday?"),
            completed("Is it Tuesday? No, sorry, Wednesday.", "Is it Wednesday?"),
            completed("Is it Tuesday? No.", "Is it Tuesday? No."),
            completed("It's Tuesday. No.", "It's Tuesday."),
        ]
    }

    /// Corrections from a later sentence: what they may correct, how many, and the months,
    /// joined numbers and names they are about.
    private static var crossSentenceCases: [Case] {
        [
            completed("The lease ends in April. No wait, May.", "The lease ends in May."),
            completed("The lease ends in april. No wait, may.", "The lease ends in May."),
            completed("We may go in April. Sorry, June.", "We may go in June."),
            completed("We may go in April. Sorry, June.", "We June go in April."),
            completed("It starts at half past two. Sorry, three.", "It starts at three."),
            completed("It starts at ten to five. Sorry, ten past five.", "It starts at ten past five."),
            completed("It costs two point five dollars. Sorry, three.", "It costs three dollars."),
            completed("Invite Sam to the launch. Sorry, Priya.", "Invite Priya to the launch."),
            completed("Invite Sam to the launch. Sorry, Priya.", "Invite Sam and Priya to the launch."),
            completed("Invite sam to the launch. Sorry, priya.", "Invite Priya to the launch."),
            completed("Paint the door red. Sorry, blue.", "Paint the door blue."),
            completed("Paint the door red. Actually, blue.", "Paint the door blue."),
            completed("Paint the door red. Sorry, the window.", "Paint the window red."),
            completed("Book the room for two hours. Sorry, three hours.", "Book the room for three hours."),
            completed("Book the room for two hours. Sorry, three.", "Book the room for three hours."),
            completed("The party is on Friday. The venue is the hall. Sorry, Saturday.", "The party is on Saturday. The venue is the hall."),
            completed("Meet me at the station at five. Sorry, the airport at six.", "Meet me at the airport at six."),
            completed("Meet me at the station at five. Sorry, the airport at six.", "Meet me at the airport at five."),
            completed("Call Ana on Monday. Sorry, Tuesday. And email Ben on Wednesday. No, sorry, Thursday.", "Call Ana on Tuesday. And email Ben on Thursday."),
            completed(
                "Meet on Monday. Sorry, Tuesday. Bring two chairs. No, three. Invite Sam. Sorry, Priya. Book room one. Sorry, room two. It starts at nine. Sorry, ten.",
                "Meet on Tuesday. Bring three chairs. Invite Priya. Book room two. It starts at ten."
            ),
            // At most two corrections whose phrase goes back into a sentence before; one that only
            // replaces the end of it is taken out where it is.
            completed("Meet on Monday. Sorry, Tuesday. Bring two chairs. No, three. Invite Sam. Sorry, Priya.", "Meet on Tuesday. Bring three chairs. Invite Priya."),
            completed(
                "Meet on Monday at noon. Sorry, Tuesday. Bring two chairs. No, three. Invite Sam to lunch. Sorry, Priya.",
                "Meet on Tuesday at noon. Bring three chairs. Invite Priya to lunch."
            ),
            // The end of the sentence before, corrected after a full stop speech-to-text wrote where
            // the speaker paused; not a whole sentence, a new thought or a number for more.
            completed("I left my charger in the garage. Actually, the lobby.", "I left my charger in the lobby."),
            completed("The alert came from the billing service. Sorry, the database.", "The alert came from the database."),
            completed("The team is replacing the laptop. No, the printer next week.", "The team is replacing the printer next week."),
            completed("Bring two chairs. No, three.", "Bring three."),
            completed("I finished the report. Sorry, I was late.", "I finished. I was late."),
            completed("It works. Actually, it's quite fast.", "It's quite fast."),
            completed("We shipped version two. Actually, we shipped it a week early.", "We shipped it a week early."),
            completed(
                "Meet on Monday. Sorry, Tuesday. Bring two chairs. No, three. Invite Sam. Sorry, Priya.",
                "Meet on Tuesday. Bring three chairs. Invite Sam. Sorry, Priya."
            ),
        ]
    }

    /// Placeholders, text without words, how Swift compares and splits text, and the policy's
    /// settings as Deep's check reads them.
    private static var repairEdgeCases: [Case] {
        let one = ["⟦S1⟧"]
        return [
            completed("send ⟦S1⟧ to john sorry jane", "Send ⟦S1⟧ to Jane.", placeholders: one),
            completed("send ⟦S1⟧ to the team", "Send it to the team ⟦S1⟧.", placeholders: one),
            completed("Send ⟦S1⟧. Sorry, ⟦S2⟧.", "Send ⟦S2⟧.", placeholders: twoTokens),
            completed("hi ⟦S1⟧ see you ⟦S2⟧", "Hi ⟦S1⟧\nSee you ⟦S2⟧", placeholders: twoTokens),
            completed("…", "…"),
            completed("hello", "…"),
            completed("…", "Hello."),
            completed("caf\u{E9} at noon", "Cafe\u{301} at noon."),
            completed("is it tomorrow… no, the day after", "Is it the day after?"),
            completed("well-known issue", "Well known issue."),
            completed("state-of-the-art tools", "State of the art tools."),
            completed("the build—it's green", "The build: it's green."),
            completed("we ship on friday", "We ship on Friday!!"),
            completed("we ship on friday", "We ship on Friday?"),
            completed("we ship on friday", "we ship on friday"),
            completed("Um, we ship on Friday.", "We ship on Friday."),
            completed("we ship on friday", "Um, we ship on Friday."),
            completed("we ship on friday", "We ship on Friday, I think."),
            completed("ship it tomorrow ship it tomorrow", "Ship it tomorrow."),
            completed("i want the red car sorry the blue car", "I want the blue car.", policy: Policy(maxRetractedWords: 1)),
            completed("Chloe will cover my shift. I mean, Peter.", "Peter will cover my shift.", policy: Policy(functionWords: [])),
            completed("The meeting is on Tuesday. Sorry, Wednesday.", "The meeting is on Wednesday.", policy: Policy(correctionCues: ["pardon"])),
            completed("The meeting is on Tuesday. Pardon, Wednesday.", "The meeting is on Wednesday.", policy: Policy(correctionCues: ["pardon"])),
            completed("I'm not free on Tuesday. Sorry, Wednesday.", "I'm free on Wednesday.", policy: Policy(negations: [])),
            completed("The busses are late.", "The buses are late.", policy: Policy(minRespellingSimilarity: 0.95)),
            completed("So um the bus is late.", "So the bus is late.", policy: Policy(fillers: ["So"])),
        ]
    }

    /// SelfRepairTests' corrections read for their meaning: what each takes back, the key word
    /// its phrase says instead, the corrected words said again, and a sentence started again.
    private static var correctionMeaningCases: [Case] {
        [
            completed("book the blue room sorry the green room for friday", "Book the green room for Friday."),
            completed("send it to the finance team make that the legal team today", "Send it to the legal team today."),
            completed("ask the designer i mean the developer to check it", "Ask the developer to check it."),
            completed("we're migrating the load balancer make that the scheduler next week", "We're migrating the scheduler next week."),
            completed("paint the fence red no wait blue", "Paint the fence blue."),
            completed("we need three servers sorry four", "We need four servers."),
            completed("send it to sam sorry to priya", "Send it to Priya."),
            completed("the demo is next week sorry the after next", "The demo is the week after next."),
            completed("i'm meeting divya at the station actually nikhil", "I'm meeting Nikhil at the station."),
            completed("The billing service goes live next Tuesday. Sorry, I mean the login service.", "The login service goes live next Tuesday."),
            completed("fuel efficiency in cars sorry busses", "Fuel efficiency in buses."),
            completed("book the blue room sorry the green room for friday", "Book the blue room for Friday."),
            completed("book the blue room sorry the green room for friday", "Book the room for Friday."),
            completed("book the blue room sorry the green room for friday", "Book the blue green room for Friday."),
            completed("Book the blue room, sorry, the green room for Friday.", "Book the blue room for Friday."),
            completed("send it to the finance team make that the legal team today", "Send it to the finance team today."),
            completed("ask the designer i mean the developer to check it", "Ask the designer to check it."),
            completed("we're migrating the load balancer make that the scheduler next week", "We're migrating the load balancer next week."),
            completed("paint the fence red no wait blue", "Paint the fence red."),
            completed("we need three servers sorry four", "We need four three servers."),
            completed("send it to sam sorry to priya", "Send it to Priya Sam."),
            completed("I left my charger in the garage. Actually, the lobby.", "I left my charger in the garage lobby."),
            completed("The demo is on Tuesday at noon. Sorry, Wednesday.", "The demo is on Tuesday Wednesday at noon."),
            completed("Invite Sam to the launch. Sorry, Priya.", "Invite Sam and Priya to the launch."),
            completed("fuel efficiency in cars sorry busses", "Fuel efficiency in trains."),
            completed("i wanted to say sorry to jo", "I wanted to say it to Jo."),
            completed("we need three servers sorry four", "We need three four servers."),
            completed("we need three servers sorry four", "We need three or four servers."),
            completed("we need three of the servers sorry four", "We need three of the four servers."),
            completed("Invite Sam to the launch. Sorry, Priya.", "Invite Sam, Priya to the launch."),
            completed("Invite Sam to the launch, sorry, Priya.", "Invite Sam and Priya to the launch."),
            completed("I am meeting Divya at the station. Actually, Nikhil.", "I am meeting Divya and Nikhil at the station."),
            completed("I am meeting Divya at the station. Actually, Nikhil.", "I am meeting Divya Nikhil at the station."),
            completed("Call me on Tuesday, no, Wednesday.", "Call me on Tuesday or Wednesday."),
            completed("We have two weeks left. Sorry, three.", "We have two or three weeks left."),
            completed("two people said we need servers sorry four", "Two people said we need four servers."),
            completed("we need three of the servers sorry four", "We need four of the servers."),
            completed("Invite Sam to the launch. Sorry, Priya.", "Invite Priya to the launch."),
            completed("Invite Sam to the launch, sorry, Priya.", "Invite Priya to the launch."),
            completed("I am meeting Divya at the station. Actually, Nikhil.", "I am meeting Nikhil at the station."),
            completed("meet me at the station sorry at six", "Meet me at six."),
            completed("Ask Sam to email Ana, sorry, Priya.", "Ask Sam to email Priya."),
            completed("Ask Sam to email Ana, sorry, Priya.", "Ask Priya to email Ana."),
            completed("We have two weeks left. Sorry, three.", "We have three weeks left."),
            completed("Can you bring the monitor, wait node, the router to the meeting?", "Can you bring the router to the meeting?"),
            completed("The city is buying more electric buses, no weight vans.", "The city is buying more electric vans."),
            completed("Dinner is on Saturday. Sorry, no theon Tuesday.", "Dinner is on Tuesday."),
            completed("The product review is on the 12th of October. No sorry thee of November.", "The product review is on the 12th of November."),
            completed("Ship it to Prague, scratch that, hold it until September.", "Hold it until September."),
            completed("ship it to prague scratch that hold it until june", "Hold it until June."),
            completed("Ship it to Lisbon, scratch that, hold it until November.", "Hold it until November."),
            completed("Ship it to Prague, scratch that, Vienna.", "Ship it to Vienna."),
            completed("Book the early flight. Scratch that. Book the afternoon one.", "Book the afternoon one."),
            completed("Put the box on the table, sorry, under the table.", "Put the box under the table."),
            completed("We need to restart the off service. Actually, the database.", "We need to restart the database."),
            completed("The leak is under the sink, rather, behind the dishwasher.", "The leak is behind the dishwasher."),
            completed("Ship it to Prague, scratch that, hold it until September.", "Ship it to hold it until September."),
            completed("ship it to prague scratch that hold it until june", "Ship it to hold it until June."),
            completed("Ship it to Lisbon, scratch that, hold it until November.", "Ship it to Hold it until November."),
            completed("the physio team sorry not physio nursing will join the call at noon", "The nursing team will join the call at noon."),
            completed("Kofi's brother, no wait, not brother, cousin, is hosting the barbecue.", "Kofi's cousin is hosting the barbecue."),
            completed("nikhil's team sorry not nikhil's siobhan's owns the billing service", "Siobhan's team owns the billing service."),
            completed("the physio team sorry not physio nursing will join the call at noon", "The nursing will join the call at noon."),
            completed("Kofi's brother, no wait, not brother, cousin, is hosting the barbecue.", "Cousin is hosting the barbecue."),
            completed("nikhil's team sorry not nikhil's siobhan's owns the billing service", "Siobhan's owns the billing service."),
            completed("I'll call no one now. Scratch that. I'll email no one instead.", "I'll email no one instead."),
            completed("I'll call no one now. Scratch that. I'll email no one instead.", "I'll email Noah instead."),
            completed("The shop closes at 3 p.m. today. Sorry, I meant at 10 a.m.", "The shop closes at 10 a.m. today."),
        ]
    }
}
