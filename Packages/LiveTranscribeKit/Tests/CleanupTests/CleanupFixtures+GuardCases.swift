@testable import Cleanup
import Foundation
import Shared

/// The guard's cases: every input of the guard's unit tests (OutputGuard, SelfCorrection,
/// DroppedWords, ContentWords, SpokenNames and WordAlignment), then every fallback reason, the
/// policy's settings, the self-correction search's paths, text that tests how Swift compares,
/// cases and splits it, and Deep's repairs (CleanupFixtures+DeepGuardCases.swift).
extension CleanupFixtures.Guard {
    static var cases: [Case] {
        unitTestCases + outcomeCases + ratioCases + preambleCases + selfCorrectionCases + placeholderCases
            + wordCases + nameCases + policyCases + numberCases + unicodeCases + deepCases
    }

    static func completed(_ raw: String, _ output: String, placeholders: [String] = [], policy: Policy? = nil) -> Case {
        Case(raw: raw, outcome: .completed(output), placeholders: placeholders, policy: policy)
    }

    private static func words(_ count: Int) -> String {
        Array(repeating: "word", count: count).joined(separator: " ")
    }

    private static let letter = "Hi John thanks for the update I will review it tomorrow cheers Sam."
    static let twoTokens = ["⟦S1⟧", "⟦S2⟧"]

    // MARK: - The unit tests' inputs

    private static var unitTestCases: [Case] {
        [
            // OutputGuardTests
            completed("i think we should meet on tuesday maybe at three", "I think we should meet on Tuesday, maybe at three."),
            completed("hello there", "\n  Hello there.  \n"),
            completed("hello there", ""),
            completed("hello there", "   "),
            completed("hello there", "\n\n"),
            completed("hello there", "<think>\nuser said hi\n</think>\nHello there."),
            completed("hello there", "Hello there.</think>"),
            completed("the report is due friday", "Here is the corrected text: The report is due Friday."),
            completed("sure, i can do that", "Sure, I can do that."),
            completed("sure so i was at a small startup for three years", "Sure. So I was at a small startup for three years."),
            completed("Of course we can ship it on Friday.", "Of course, we can ship it on Friday."),
            completed("certainly not before the review", "Certainly not before the review."),
            completed("Here's the plan for the launch", "Here's the plan for the launch."),
            completed("sure thing", "Sure, here's the corrected text: Sure thing."),
            completed("the meeting is on tuesday afternoon", "A banana smoothie needs frozen fruit."),
            completed("we should meet on tuesday sorry wednesday", "We should meet on Wednesday."),
            completed("we should meet on tuesday sorry wednesday", "We should meet on Tuesday, sorry, Wednesday."),
            completed("here's ⟦S1⟧ and the deck is at ⟦S2⟧", "Here's ⟦S1⟧, and the deck is at ⟦S2⟧.", placeholders: twoTokens),
            completed("here's ⟦S1⟧ and the deck is at ⟦S2⟧", "Here's the link, and the deck is at ⟦S2⟧.", placeholders: twoTokens),
            completed("here's ⟦S1⟧ and the deck is at ⟦S2⟧", "Here's ⟦S1⟧ ⟦S1⟧, and the deck is at ⟦S2⟧.", placeholders: twoTokens),
            completed("here's ⟦S1⟧ and the deck is at ⟦S2⟧", "Here's ⟦S 1⟧, and the deck is at ⟦S2⟧.", placeholders: twoTokens),
            completed("here's ⟦S1⟧ and the deck is at ⟦S2⟧", "Here's [S1], and the deck is at ⟦S2⟧.", placeholders: twoTokens),
            completed("here's ⟦S1⟧ and the deck is at ⟦S2⟧", "Here's ⟦S1⟧, and the deck is at ⟦S2⟧ and ⟦S3⟧.", placeholders: twoTokens),
            completed("here's ⟦S1⟧ and the deck is at ⟦S2⟧", "Here's ⟦S1, and the deck is at ⟦S2⟧.", placeholders: twoTokens),
            completed("send them ⟦S1⟧ sorry ⟦S2⟧", "Send them ⟦S2⟧.", placeholders: twoTokens),
            completed("see you soon", "See you ⟦S1⟧ soon."),

            // SelfCorrectionTests
            completed("I want to talk about fuel efficiency in cars sorry busses", "I want to talk about fuel efficiency in buses."),
            completed("let's meet on tuesday no wait wednesday at ten", "Let's meet on Wednesday at ten."),
            completed("send it to john i mean jane before friday", "Send it to Jane before Friday."),
            completed("we need three sorry four more servers for the launch", "We need four more servers for the launch."),
            completed("it's the login service or rather the auth service that times out", "It's the auth service that times out."),
            completed("the meeting is at two pm actually make that three pm", "The meeting is at three p.m."),
            completed("open the settings sorry the preferences window", "Open the preferences window."),
            completed("we should deploy on monday scratch that let's wait until tuesday", "Let's wait until Tuesday."),
            completed("so um we need to fix the the signup sorry login page", "So we need to fix the login page."),
            completed("we need three sorry four more servers for the launch", "We need three more servers for the launch."),
            completed("let's meet on tuesday sorry thursday", "Let's meet on Tuesday."),
            completed("send it to john i mean jane", "Send it to John."),
            completed("sorry i'm late the traffic was terrible", "I'm late, the traffic was terrible."),
            completed("i mean it this time we really need to ship", "It this time, we really need to ship."),
            completed("no i don't think that's right", "I don't think that's right."),
            completed("actually that works for me", "That works for me."),
            completed(
                "i returned the jacket to the shop on high street wait no to the shop in the shopping centre",
                "I returned the jacket to the shop in the shopping centre."
            ),
            completed(
                "i returned the jacket to the big shop on high street wait no to the shop in the centre",
                "I returned the jacket to the shop in the centre."
            ),
            completed("I want to talk about fuel efficiency in cars sorry busses", "Buses."),
            completed("send it to john i mean jane", "Send it to Jane in accounts."),
            completed("fuel efficiency in cars sorry busses", "Fuel efficiency in trains."),
            completed("sorry to interrupt but can i ask a question", "Sorry to interrupt, but can I ask a question?"),
            completed("sorry to interrupt but can i ask a question", "Sorry, a question?"),
            completed("Send it to John, I mean Jane, no wait, Jill.", "Send it to Jill."),
            completed("The build is green.", "The build is green."),
            completed("cars sorry buses", "Buses."),
            completed("sorry I'm late", "Sorry, I'm late."),
            completed("the meeting is in room four no not four five", "The meeting is in room five."),
            completed("book the flight for tuesday sorry not tuesday thursday morning", "Book the flight for Thursday morning."),
            completed("ask priya no not priya megan to review the draft", "Ask Megan to review the draft."),
            completed("we need three chairs sorry not three four chairs for the demo", "We need four chairs for the demo."),
            completed("i left the keys in the kitchen sorry not the kitchen the garage", "I left the keys in the garage."),
            completed("words like docker sorry not docker kubernetes never come out right", "Words like Kubernetes never come out right."),
            completed("we need three chairs sorry not four", "We need four chairs."),
            completed("send the blue file to sam sorry not blue red", "Send the blue file to red."),
            completed("words like docker sorry not docker kubernetes never come out right", "Words like Docker never come out right."),
            completed("the demo is on tuesday sorry thursday not friday", "The demo is on Thursday, not Friday."),

            // DroppedWordsTests
            completed(
                "Yeah he said someone will come by on Monday, maybe Tuesday at the latest.",
                "Yeah, he said someone will come by on Tuesday at the latest."
            ),
            completed("correction sunday morning i'm away on saturday", "Correction, I'm away on Saturday."),
            completed("we could meet at the cafe on the corner or at the office", "We could meet at the office."),
            completed("i do not agree with that plan", "I do agree with that plan."),
            completed("i can't make it on friday", "I can make it on Friday."),
            completed("we never ship on a friday", "We ship on a Friday."),
            completed("so the the numbers look good", "So the numbers look good."),
            completed("um i think its fine", "I think it's fine."),
            completed("i really think we should go", "I think we should go."),
            completed("i cannot make it", "I can't make it."),
            completed("we won't ship it before the review on friday", "We will not ship it before the review on Friday."),
            completed(
                "the demo of the new release for the sales team was really very good",
                "The demo of the new release for the sales team was good."
            ),
            completed("we need twenty five chairs", "We need 25 chairs."),
            completed("email the nerd storm team", "Email the Nerdstorm team."),
            completed("She wants few ex expenses paid back.", "She wants few expenses paid back."),
            completed("We should con consider the budget first.", "We should consider the budget first."),
            completed("can you send the rep report by friday", "Can you send the report by Friday?"),
            completed("there is not nothing left", "There is nothing left."),
            completed("bring ten tennis balls", "Bring tennis balls."),
            completed("we could stay for forty minutes", "We could forty minutes."),
            completed("We met the new rep. Reports are due on Monday.", "We met the new. Reports are due on Monday."),
            completed("can you send the rap report by friday", "Can you send the report by Friday?"),

            // ContentWordsTests
            completed("we need milk, eggs, and bread.", "We need eggs and bread."),
            completed("we could meet at the cafe on the corner or at the office", "We could meet at the cafe or the office."),
            completed("i need to cancel the order before friday", "I need the order before Friday."),
            completed(
                "Shopping list bullet point milk bullet point eggs bullet point bread.",
                "Shopping list bullet point: milk, eggs, bread."
            ),
            completed("thanks ⟦S1⟧ see you tomorrow", "Thanks ⟦S1⟧, see you.", placeholders: ["⟦S1⟧"]),
            completed("i got the tickets for friday", "I have the tickets for Friday."),
            completed("tomorrow i will send it to the team", "I will send it to the team tomorrow."),
            completed("the meating is at noon", "The meeting is at noon."),
            completed("it costs twenty five dollars", "It costs $25."),
            completed("we need 25 chairs", "We need twenty-five chairs."),
            completed("honestly the demo was really good", "The demo was good."),
            completed(
                "please send the final slides to the whole team tomorrow and i got the room booked for friday",
                "Tomorrow, please send the final slides to the whole team. I have the room booked for Friday."
            ),
            completed("send ⟦S1⟧ to the team", "Send ⟦S1⟧ to the team.", placeholders: ["⟦S1⟧"]),
            completed("tell yasmin or rather victor", "Tell Victor, or rather."),
            completed("we need milk milk and bread", "We need milk and bread."),
            completed("hi john thanks for the update cheers sam", "Hi Sam, thanks for the update. Cheers."),

            // SpokenNamesTests
            completed(letter, "Hi Sam, thanks for the update. I will review it tomorrow. Cheers."),
            completed(letter, "Hi Sam, thanks for the update. I will review it tomorrow. Cheers, John."),
            completed(letter, "Hi John and Sam, thanks for the update. I will review it tomorrow. Cheers."),
            completed("Send the report to Priya, Daniel and Ana", "Send the report to Priya and Ana."),
            completed("Tell Yasmin, or rather, Victor.", "Tell Victor, or rather."),
            completed(letter, "Hi John, thanks for the update. I will review it tomorrow. Cheers, Sam."),
            completed("Hi Jon see you on Friday", "Hi John, see you on Friday."),
            completed("Email the Nerd Storm team", "Email the Nerdstorm team."),
            completed("Hi John John thanks for coming", "Hi John, thanks for coming."),
            completed("Thanks, Sam. Talk soon. OK then, I will call.", "Thanks, Sam. Talk soon. OK then, I will call."),
            completed("Meet at the Café near Jean-Luc's flat", "Meet at the café near Jean-Luc's flat."),
            completed("Things to do today: Call the bank", "Things to do today: call the bank."),
            completed("Hi Sam\nThanks for coming", "Hi Sam, thanks for coming."),
            completed("Hi ⟦S1⟧ Thanks for coming, Sam", "Hi ⟦S1⟧ Thanks for coming, Sam.", placeholders: ["⟦S1⟧"]),

            // WordAlignmentTests
            completed("a b c d e", "a x d e f"),
            completed("tomorrow i will send it", "i will send it tomorrow"),
            completed("", ""),
            completed("", "a"),
            completed("a", ""),
        ]
    }

    // MARK: - Outcomes other than text, and fallback reasons' descriptions

    private static var outcomeCases: [Case] {
        [3, 0.25, 0.35, 0.05, 0.15, 2.5, 0.1 + 0.2, 0, 60].map { Case(raw: "hello", outcome: .timedOut(seconds: $0)) }
            + [
                Case(raw: "hello", outcome: .cancelled),
                Case(raw: "hello", outcome: .failed("GPU error")),
                Case(raw: "hello", outcome: .failed("cleanup model not loaded")),
                Case(raw: "hello", outcome: .failed("")),
                completed("hello there", "<THINK>Hello there."),
                completed("hello there", "Hello < think > there."),
                completed("hello there", "Hello there.\u{2029}"),
                completed("hello there", "\u{00A0}\u{3000}\u{0085}"),
                completed("hello there", "\u{200B}"),
            ]
    }

    // MARK: - Word-count ratios

    /// The levels' bounds, and a policy's own, just inside and just outside, with the similarity
    /// check off; and ratios whose two decimals are a tie, which both apps must round alike.
    private static var ratioCases: [Case] {
        let similarityOff = Policy(minSimilarity: 0)
        let narrowLight = Policy(wordRatioBounds: [.light: 0.9...1.1], minSimilarity: 0)
        let emptyTable = Policy(wordRatioBounds: [:], minSimilarity: 0)
        return [39, 40, 49, 50, 79, 80, 120, 121, 130, 131].map { completed(words(100), words($0), policy: similarityOff) }
            + [85, 89, 90, 110, 111].map { completed(words(100), words($0), policy: narrowLight) }
            + [45, 125].map { completed(words(100), words($0), policy: emptyTable) }
            + [
                completed(words(8), words(1)),
                completed(words(8), words(3)),
                completed(words(8), words(11)),
                completed(words(16), words(21)),
                completed(words(3), words(1)),
                completed(words(3), words(4)),
                completed("abcdefgh", "abcdefgx", policy: Policy(minSimilarity: 0.9)),
                completed("abcdefgh", "abcdexyz", policy: Policy(minSimilarity: 0.9)),
                completed("abcdefgh", "abcdefgx", policy: Policy(minSimilarity: 0.875)),
                completed("the quick brown fox", "The quick brown fox jumps.", policy: Policy(minSimilarity: 0.95)),
            ]
    }

    // MARK: - Preambles

    /// Each preamble added to the text, and each said by the speaker.
    private static var preambleCases: [Case] {
        let policy = OutputGuard.Policy.default
        return policy.preambles.map { completed("the build is broken", "\($0.capitalized) the build is broken.") }
            + policy.preambles.map { completed("\($0) the build is broken", "\($0.capitalized) the build is broken.") }
            + [
                completed("the build is broken", "  Here is the build: it is broken."),
                completed("here is the build log", "Here is the build log."),
                completed("here the build is", "Here is the build."),
                completed("sure the build is broken", "Sure! The build is broken."),
                completed("the build is broken", "HERE'S the build, broken."),
                completed("the build is broken", "Here\u{2019}s the build, broken."),
                completed("the build is broken", "Heres the build, broken."),
                completed("output the build", "Output: the build."),
                completed("the text is ready", "Text: the text is ready."),
                completed("of course", "Of course."),
                completed("the build is broken", "Of course the build is broken.", policy: Policy(preambles: ["", "Of course", "note:"])),
                completed("the build is broken", "Note: the build is broken.", policy: Policy(preambles: ["", "Of course", "note:"])),
            ]
    }

    // MARK: - Self-corrections

    /// The search's paths: spans of back-to-back cues, the retracted-word limit, fillers and
    /// repeats inside a correction, respellings, and cues at the edges.
    private static var selfCorrectionCases: [Case] {
        [
            completed("meet on tuesday sorry wednesday at two no three", "Meet on Wednesday at three."),
            completed("meet on tuesday sorry wednesday at two no three", "Meet on Wednesday at two."),
            completed("sorry wednesday", "Wednesday."),
            completed("wednesday sorry", "Wednesday."),
            completed("wednesday sorry", "Sorry."),
            completed("i want the red car sorry the blue car", "I want the blue car."),
            completed("i want the red car sorry the blue car", "I want the blue car.", policy: Policy(maxRetractedWords: 2)),
            completed("i want the red car sorry the blue car", "I want the blue car.", policy: Policy(maxRetractedWords: 0)),
            completed("fuel efficiency in cars sorry busses", "Fuel efficiency in buses.", policy: Policy(maxRetractedWords: 1)),
            completed("fuel efficiency in cars sorry busses", "Fuel efficiency in buses.", policy: Policy(minRespellingSimilarity: 0.95)),
            completed("so um cars sorry buses", "So buses."),
            completed("so um cars sorry buses", "So buses.", policy: Policy(fillers: [])),
            completed("the the cars sorry buses", "The buses."),
            completed("cars cars sorry buses", "Buses."),
            completed("cars sorry sorry buses", "Buses."),
            completed("cars sorry no wait i mean buses", "Buses."),
            completed("cars sorry no wait i mean buses", "Cars, I mean buses."),
            completed("tuesday sorry thursday", "Tuesday."),
            completed("tuesday sorry thursday", "Thursday."),
            completed("tuesday sorry thursday", "Thurs day."),
            completed("tuesday sorry thursday", "Thursdays."),
            completed("cars sorry buses", "Busses."),
            completed("cars sorry buses and trains", "Buses and trains."),
            completed("cars sorry buses and trains", "Buses, trains."),
            completed("one two three four five six seven sorry eight", "One eight."),
            completed("one two three four five six seven sorry eight", "Eight."),
            completed("i mean", "I mean."),
            completed("i mean", "Mean."),
            completed("make that make that three", "Three."),
            completed("send it to john i meant jane", "Send it to Jane."),
            completed("send it to john no-wait jane", "Send it to Jane."),
            completed("send it to john, I MEAN, jane", "Send it to Jane.", policy: Policy(correctionCues: ["", "…", "I MEAN,", "no-wait"])),
            completed("send it to john no wait jane", "Send it to Jane.", policy: Policy(correctionCues: ["", "…", "I MEAN,", "no-wait"])),
            completed("send it to john sorry jane", "Send it to Jane.", policy: Policy(correctionCues: ["", "…", "I MEAN,", "no-wait"])),
            completed("send it to john sorry jane", "Send it to Jane.", policy: Policy(correctionCues: [])),
            completed("the rather large dog", "The large dog."),
            completed("nowhere no where", "Nowhere where."),
            completed("i wanted to say sorry to jo", "I wanted to say it to Jo."),
        ]
    }

    // MARK: - Placeholders

    private static var placeholderCases: [Case] {
        [
            completed("send ⟦S1⟧", "Send ⟦S1⟧.", placeholders: ["⟦S1⟧", ""]),
            completed("send ⟦S1⟧", "Send ⟦S1⟧⟦S1⟧.", placeholders: ["⟦S1⟧"]),
            completed("send ⟦S1⟧ and ⟦S12⟧", "Send ⟦S1⟧ and ⟦S12⟧.", placeholders: ["⟦S1⟧", "⟦S12⟧"]),
            completed("send ⟦S1⟧ and ⟦S12⟧", "Send ⟦S12⟧ and ⟦S1⟧.", placeholders: ["⟦S1⟧", "⟦S12⟧"]),
            completed("send ⟦S1⟧", "Send ⟦S1⟧\u{301}.", placeholders: ["⟦S1⟧"]),
            completed("send ⟦S1⟧", "Send \u{301}⟦S1⟧.", placeholders: ["⟦S1⟧"]),
            completed("⟦ stray", "⟦ Stray."),
            completed("stray ⟧", "Stray."),
            completed("stray ⟧", "Stray ⟦."),
            completed("send ⟦S1⟧ now", "Send S1 now.", placeholders: ["⟦S1⟧"]),
            completed("send ⟦S1⟧ now", "Send S1 now.", placeholders: ["⟦S1⟧"], policy: Policy(requiresIntactPlaceholders: false)),
            completed("send ⟦S1⟧ now", "Send ⟦S1⟧ now.", placeholders: ["⟦S1⟧"], policy: Policy(requiresIntactPlaceholders: false)),
            completed("send it now", "Send it now.", placeholders: ["⟦S1⟧"]),
            completed("send ⟦S1⟧ ⟦S2⟧ ⟦S3⟧", "Send ⟦S3⟧ ⟦S2⟧ ⟦S1⟧.", placeholders: ["⟦S1⟧", "⟦S2⟧", "⟦S3⟧"]),
            completed("Call ⟦S1⟧ Bob now", "Call ⟦S1⟧ now.", placeholders: ["⟦S1⟧"]),
            completed("Call ⟦S1⟧ Bob now", "Call ⟦S1⟧ Bob now.", placeholders: ["⟦S1⟧"]),
            completed("meet ⟦S1⟧ tomorrow", "Meet tomorrow ⟦S1⟧.", placeholders: ["⟦S1⟧"]),
            completed("buy ⟦S1⟧ milk ⟦S2⟧ eggs", "Buy ⟦S1⟧ milk ⟦S2⟧ eggs.", placeholders: twoTokens),
            completed("buy ⟦S1⟧ milk ⟦S2⟧ eggs", "Buy milk ⟦S1⟧ ⟦S2⟧ eggs.", placeholders: twoTokens),
            completed("send ⟦S1⟧", "Send ⟦s1⟧.", placeholders: ["⟦S1⟧"]),
            completed("send x", "Send ⟦S1⟧.", placeholders: ["⟦S1⟧"]),
        ]
    }

    // MARK: - Dropped words, negations and content

    private static var wordCases: [Case] {
        [
            completed("i can't go", "I cannot go."),
            completed("i won\u{2019}t go", "I will go."),
            completed("i won\u{2019}t go", "I won't go."),
            completed("nothing to see here", "Something to see here."),
            completed("it is not bad", "It is not not bad."),
            completed("neither this nor that", "This or that."),
            completed("go without me", "Go with me."),
            completed("we could meet at the cafe on the corner or at the office", "We could meet at the office.", policy: Policy(maxDroppedRun: 3)),
            completed("we could meet at the cafe on the corner or at the office", "We could meet at the office.", policy: Policy(maxDroppedRun: 10)),
            completed("we need milk, eggs, and bread.", "We need eggs and bread.", policy: Policy(maxDroppedContent: 1)),
            completed("we need the milk", "We need milk."),
            completed("we need the milk", "We need milk.", policy: Policy(functionWords: [])),
            completed("i do not agree", "I do agree.", policy: Policy(negations: [])),
            completed("i don't agree", "I do agree.", policy: Policy(negations: [])),
            completed("go without me", "Go with me.", policy: Policy(negations: ["WITHOUT"])),
            completed("so um like the the build is is broken", "The build is broken."),
            completed("the build is broken broken", "The build is broken."),
            completed("we need milk and bread", "We need bread and milk."),
            completed("we need milk and bread", "We need bread and more milk."),
            completed("we need milk and bread", "We need bread and mlik."),
            completed("we need milk and bread", "We need bread."),
            completed("we need milk and bread", "We need bread and a pint."),
            completed("buy milk bread eggs", "Buy bread."),
            completed("the new release date", "The release date."),
            completed("room 101 is free", "Room is free."),
            completed("room a is free", "Room is free."),
            completed("i got two tickets", "I got 2 tickets."),
            completed("i got 2 tickets", "I got two tickets."),
            completed("i got 2 tickets", "I got tickets."),
            completed("it costs seven dollars", "It costs seven."),
            completed("it costs seven dollars", "It costs $7."),
            completed("it costs seven dollars", "It costs 7 bucks."),
            completed("the log in page", "The login page."),
            completed("the log in page", "The logging page."),
            completed("email the nerd storm team today", "Email the Nerdstorm team."),
        ]
    }

    // MARK: - Names

    private static var nameCases: [Case] {
        [
            completed(letter, "Hi Sam, thanks for the update. I will review it tomorrow. Cheers.", policy: Policy(requiresNamesInPlace: false)),
            completed("yes I will come", "Yes, I will come.", policy: Policy(functionWords: [])),
            completed("then I left", "Then left.", policy: Policy(functionWords: [])),
            completed("then I left", "Then left."),
            completed("Hi José thanks for coming", "Hi Jose\u{301}, thanks for coming."),
            completed("Hi Zoë, see you at Café Nero", "Hi Zoe, see you at Cafe Nero."),
            completed("Meet Ana at the ÉCOLE", "Meet Ana at the école."),
            completed("Tell Jean-Luc — and Marie – about it", "Tell Jean-Luc and Marie about it."),
            completed("Tell Jean-Luc — and Marie – about it", "Tell Luc and Marie about it."),
            completed("I met Sam: Alex was there too", "I met Sam. Alex was there too."),
            completed("I met Sam: Alex was there too", "I met Sam. He was there too."),
            completed("Wait… Sam said no", "Wait, Sam said no."),
            completed("He said \"Sam!\" Then left", "He said, \"Sam!\" Then he left."),
            completed("He said \"Sam!\" Then left", "He said, \"Sam!\" He left."),
            completed("Ask Priya about it. Priya knows", "Ask Priya about it. She knows."),
            completed("Ask Priya about it and Priya will know", "Ask Priya about it and she will know."),
            completed("Meet me in Paris on Tuesday", "Meet me on Tuesday in Paris."),
            completed("Meet me in Paris on Tuesday", "Meet me in Rome on Tuesday."),
            completed("Meet me in Paris on Tuesday", "Meet me in Pariss on Tuesday."),
            completed("Hi team\nPlease review\nThanks Sam", "Hi team,\nPlease review.\nThanks, Sam."),
            completed("Hi team\r\nPlease review\r\nThanks Sam", "Hi team, please review. Thanks."),
            completed("Hi team\u{2028}Please review Sam", "Hi team, please review."),
            completed("the NASA launch", "The launch."),
            completed("the NASA launch", "The Nasa launch."),
            completed("on iPhone and macOS", "On the phone and Mac."),
            completed("Meet ǅemal and Ⅻ today", "Meet today."),
            completed("Visit İstanbul in May", "Visit Istanbul in May."),
            completed("Visit Straße Nord", "Visit Strasse Nord."),
            completed("Hi Sam-", "Hi."),
            completed("Hi -Sam- and Jo", "Hi and Jo."),
        ]
    }

    // MARK: - Policy settings

    private static var policyCases: [Case] {
        [
            completed("Hi John and Sam", "Hi John.", policy: Policy(requiresNamesInPlace: false)),
            completed("we need milk eggs and bread", "We need bread.", policy: Policy(maxDroppedRun: 5, maxDroppedContent: 2)),
            completed("we need milk eggs and bread", "We need bread.", policy: Policy(maxDroppedRun: 5, maxDroppedContent: 1)),
            completed("the cat sat", "A dog stood.", policy: Policy(minSimilarity: 0)),
            completed("the cat sat", "The cat sat.", policy: Policy(minSimilarity: 1.5)),
            completed("we need a new plan", "We need a plan.", policy: Policy(wordRatioBounds: [CleanupLevel.none: 1...1, .light: 1...1, .medium: 1...1, .high: 1...1])),
            completed("we need a new plan", "We need a plan.", policy: Policy(functionWords: ["NEW", "  a  "])),
            completed("the plan is new", "The plan.", policy: Policy(fillers: ["Is", "new"])),
            completed("cars sorry buses", "Buses.", policy: Policy(fillers: ["sorry"])),
            completed("cars, er, sorry, buses", "Buses.", policy: Policy(fillers: ["er"])),
            completed("cars, er, sorry, buses", "Buses.", policy: Policy(fillers: [])),
        ]
    }

    // MARK: - Numbers

    /// Every number word the content check knows, and words it doesn't: "seven" and the word
    /// replaced by one number in digits. A number word shares the digits; any other word was
    /// dropped. Then which characters count as digits.
    private static var numberCases: [Case] {
        let numberWords = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
            "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
            "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
            "trillion", "dozen", "half", "quarter", "point",
            "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh",
            "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth",
            "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth",
            "hundredth", "thousandth", "millionth",
            "o'clock", "am", "pm", "percent", "degree", "degrees", "dollar", "dollars", "cent", "cents", "buck", "bucks",
            "pound", "pounds", "pence", "euro", "euros", "yen", "rupee", "rupees",
        ]
        let otherWords = [
            "fourty", "ninty", "hundreds", "thousands", "millions", "dozens", "halves", "quarters", "points", "tens",
            "oclock", "percentage", "p.m.", "a.m.", "quid", "grand", "nil", "nought", "zeroes", "yens", "apples",
            "minutes", "Seven", "SEVEN", "o\u{2019}clock", "euro's",
        ]
        let digits = ["7", "٧", "７", "½", "五", "²", "Ⅶ", "𝟕", "7th", "$7", "#", "VII", "seven", "7️⃣", "①"]
        return (numberWords + otherWords).map { completed("it costs seven \($0)", "It costs 7.") }
            + digits.map { completed("it costs seven dollars", "It costs \($0).") }
    }

    // MARK: - How Swift compares, cases and splits text

    private static var unicodeCases: [Case] {
        [
            completed("caf\u{E9} au lait", "Cafe\u{301} au lait."),
            completed("cafe\u{301} au lait", "Caf\u{E9} au lait."),
            completed("i\u{2019}m fine", "I'm fine."),
            completed("Η ΟΔΟΣ ΕΙΝΑΙ ΚΛΕΙΣΤΗ", "Η οδός είναι κλειστή."),
            completed("ΟΔΟΣ", "οδοσ"),
            completed("die straße ist gross", "Die Strasse ist groß."),
            completed("ship it 👍🏽 today", "Ship it today. 👍🏽"),
            completed("family 👨‍👩‍👧 photo", "Family photo."),
            completed("family 👨‍👩‍👧 photo", "Family 👨‍👩‍👦 photo."),
            completed("ශ්‍රී ලංකාව ලස්සනයි", "ශ්‍රී ලංකාව ලස්සනයි."),
            completed("ශ්‍රී ලංකාව ලස්සනයි", "ශර ලකව ලසසනය."),
            completed("东京 很 好", "东京很好。"),
            completed("C++ and C# rock", "C and C rock."),
            completed("well-known — and\u{2013}so on", "Well known, and so on."),
            completed("tab\tseparated\u{00A0}words\u{3000}here", "Tab separated words here."),
            completed("line one\nline two", "Line one. Line two."),
            completed("line one\r\nline two", "Line one\r\nline two."),
            completed("x\u{0301}\u{0301} marks", "X marks."),
            completed("'quoted' words", "Quoted words."),
            completed("it's John's", "Its Johns."),
            completed("ﬁne ﬂow", "Fine flow."),
            completed("Ⓐ ⓑ", "A b."),
            completed("İ", "i̇"),
            completed("ǈ ǉ", "Lj lj."),
        ]
    }
}
