@testable import Cleanup
import Foundation
import Shared

/// Deep's repairs, as the guard judges them (``SelfRepair``): every input of SelfRepairTests, then
/// each kind of edit a repair may make and may not.
extension CleanupFixtures.Guard {
    private static let kirk = "I tried to speak with Kirk, but he didn't. I don't think he actually check whether the release is tomorrow. No, sorry, the after tomorrow."

    /// SelfRepairTests' cases, then each kind of edit a repair may make and may not: layout,
    /// numbers, contractions, names, cues, corrections across sentences and the search's limits.
    static var deepCases: [Case] {
        selfRepairTestCases + layoutCases + numberRepairCases + contractionCases + repairNameCases + cueCases
            + crossSentenceCases + repairEdgeCases
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
            // At most two corrections from later sentences.
            completed("Meet on Monday. Sorry, Tuesday. Bring two chairs. No, three. Invite Sam. Sorry, Priya.", "Meet on Tuesday. Bring three chairs. Invite Priya."),
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
}
