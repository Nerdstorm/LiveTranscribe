@testable import Cleanup
import Testing

@Suite("OutputGuard: Deep's repairs")
struct SelfRepairTests {
    private let outputGuard = OutputGuard()

    private func review(_ raw: String, _ cleaned: String, multiline: Bool = false, placeholders: [String] = []) -> GuardVerdict {
        outputGuard.review(
            raw: raw, outcome: .completed(cleaned),
            options: CleanupOptions(level: .deep, placeholders: placeholders, multiline: multiline)
        )
    }

    private static let kirk = "I tried to speak with Kirk, but he didn't. I don't think he actually check whether the release is tomorrow. No, sorry, the after tomorrow."

    @Test func repairsACorrectionMadeInALaterSentenceWithAGarbledPhrase() {
        let cleaned = "I tried to speak with Kirk, but he didn't. I don't think he actually checked whether the release is the day after tomorrow."
        #expect(review(Self.kirk, cleaned) == .accepted(cleaned))
        let unfixedGrammar = "I tried to speak with Kirk, but he didn't. I don't think he actually check whether the release is the day after tomorrow."
        #expect(review(Self.kirk, unfixedGrammar) == .accepted(unfixedGrammar))
    }

    @Test("A repair that changes anything else is rejected", arguments: [
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
    ])
    func rejectsChangingAnythingElse(cleaned: String) {
        #expect(review(Self.kirk, cleaned) == .rejected(.invalidRepair))
    }

    /// The prompt probe's policy lets no words be taken back: no correction is resolved then, and
    /// the check still runs.
    @Test func resolvesNothingWhenNoWordsMayBeTakenBack() {
        var policy = OutputGuard.Policy.default
        policy.maxRetractedWords = 0
        let strict = OutputGuard(policy: policy)
        let options = CleanupOptions(level: .deep)
        for raw in ["The meeting is on Tuesday. Sorry, Wednesday.", "we need three sorry four servers"] {
            #expect(strict.review(raw: raw, outcome: .completed(raw), options: options) == .accepted(raw))
        }
        let resolved = strict.review(raw: "The meeting is on Tuesday. Sorry, Wednesday.", outcome: .completed("The meeting is on Wednesday."), options: options)
        #expect(resolved == .rejected(.invalidRepair))
    }

    @Test("A correction in a later sentence is resolved", arguments: [
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
    ])
    func resolvesACorrectionInALaterSentence(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test("A correction in a later sentence keeps the rest of the sentence it corrects", arguments: [
        ("The demo is on Tuesday at noon. Sorry, Wednesday.", "The demo is on Wednesday at noon.", "The demo is on Wednesday."),
        ("We need three servers for the launch. Sorry, four.", "We need four servers for the launch.", "We need four."),
        ("Chloe is presenting at the all hands. Sorry, no, Karen.", "Karen is presenting at the all hands.", "Karen is presenting."),
        ("Bring two chairs. No, three.", "Bring three chairs.", "Bring three."),
    ])
    func keepsTheRestOfTheCorrectedSentence(raw: String, kept: String, dropped: String) {
        #expect(review(raw, kept) == .accepted(kept))
        #expect(review(raw, dropped) == .rejected(.invalidRepair))
    }

    @Test("A cue after a full stop corrects the end of the sentence before, as after a comma", arguments: [
        ("I left my charger in the garage. Actually, the lobby.", "I left my charger in the lobby."),
        ("The alert came from the billing service. Sorry, the database.", "The alert came from the database."),
        ("The team is replacing the laptop. No, the printer next week.", "The team is replacing the printer next week."),
        ("I'm making pasta. Actually, tacos for dinner.", "I'm making tacos for dinner."),
        ("Paint the door red. Actually, blue.", "Paint the door blue."),
    ])
    func resolvesACorrectionOfTheEndOfTheSentenceBefore(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
        #expect(review(raw.replacingOccurrences(of: ". ", with: ", "), cleaned) == .accepted(cleaned), "as after a comma")
    }

    /// Dropping a correction made in a later sentence leaves what it took back as said, however the
    /// check could read its phrase: re-using the words it corrects, a repaired phrase can come out
    /// as those words.
    @Test("A correction in a later sentence can't be dropped with what it corrects kept", arguments: [
        ("Meet me at the Old Town Hall. Actually no, the Town Hall.", "Meet me at the Town Hall."),
        ("The parcel goes to the Melbourne office. Sorry, no, the Sydney office.", "The parcel goes to the Sydney office."),
        ("The demo is on Tuesday at noon. Sorry, Wednesday.", "The demo is on Wednesday at noon."),
        ("We need three servers for the launch. Sorry, four.", "We need four servers for the launch."),
    ])
    func keepsACorrectionInALaterSentence(raw: String, resolved: String) {
        #expect(review(raw, resolved) == .accepted(resolved))
        let sentences = raw.split(separator: ". ", maxSplits: 1)
        let dropped = String(sentences[0]) + "."
        #expect(review(raw, dropped) == .rejected(.invalidRepair), "\(dropped)")
    }

    @Test func aCorrectionTakesBackNoFactItDoesNotReplace() {
        let raw = "I'm not free on Tuesday. Sorry, Wednesday."
        #expect(review(raw, "I'm not free on Wednesday.") == .accepted("I'm not free on Wednesday."))
        #expect(review(raw, "I'm free on Wednesday.") == .rejected(.invalidRepair))
        #expect(review("we need three servers at noon sorry four", "We need four.") == .rejected(.invalidRepair))
        #expect(review("we need three servers at noon sorry four", "We need four servers at noon.") == .accepted("We need four servers at noon."))
    }

    @Test func aNegationIsTakenBackOnlyByItsVerb() {
        #expect(review("I don't sorry I do want it", "I do want it.") == .accepted("I do want it."))
        #expect(review("I don't think he checked, sorry, the tests", "I think he checked the tests.") == .rejected(.invalidRepair))
    }

    @Test func resolvesTwoCorrectionsInLaterSentences() {
        let raw = "The meeting is on Tuesday. Sorry, Wednesday. Bring three chairs. No, sorry, four."
        let cleaned = "The meeting is on Wednesday. Bring four chairs."
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test("A correction within a sentence is resolved, as at Medium", arguments: [
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
    ])
    func resolvesACorrectionWithinASentence(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test("A cue followed by \"not\" and the corrected words said again goes with them", arguments: [
        ("The meeting is in room four, no, not four, five.", "The meeting is in room five."),
        ("Book the flight for Tuesday, sorry, not Tuesday, Thursday morning.", "Book the flight for Thursday morning."),
        ("Send the report to the marketing team, sorry, not marketing, sales, by Friday.", "Send the report to the sales team by Friday."),
        ("Apps like Slack, sorry, not Slack, Teams keep dropping my calls.", "Apps like Teams keep dropping my calls."),
        ("Words like Docker, sorry, not Docker, Kubernetes never come out right.", "Words like Kubernetes never come out right."),
        ("I left the keys in the kitchen. Sorry, not the kitchen, the garage.", "I left the keys in the garage."),
        ("Send the blue file to Sam, sorry, not blue, red.", "Send the red file to Sam."),
    ])
    func resolvesARestatedCorrection(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test("A correction speech-to-text broke into sentences is resolved", arguments: [
        ("My shift starts on Sunday. No, sorry, not Sunday. Thursday.", "My shift starts on Thursday."),
        (
            "For the overnight trek, we'll need compasses. Sorry, not compasses. Stoves and plenty of water.",
            "For the overnight trek we'll need stoves and plenty of water."
        ),
    ])
    func resolvesACorrectionBrokenIntoSentences(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
        #expect(
            review(raw, raw.replacingOccurrences(of: "No, sorry, not Sunday. ", with: "").replacingOccurrences(of: "Sorry, not compasses. ", with: ""))
                == .rejected(.invalidRepair),
            "the cue and the words said again go only with the correction"
        )
    }

    @Test("A \"not\" goes with a correction only when it says corrected words again", arguments: [
        // Drops the contrast the speaker made.
        ("We need three chairs, sorry, not four.", "We need four chairs."),
        // Says again a word the correction doesn't take back.
        ("Send the blue file to Sam, sorry, not blue, red.", "Send the blue file to red."),
        // Keeps the corrected word, or reads the correction the wrong way.
        ("Words like Docker, sorry, not Docker, Kubernetes never come out right.", "Words like Docker never come out right."),
        ("Words like Docker, sorry, not Docker, Kubernetes never come out right.", "Words like Docker, not Kubernetes, never come out right."),
        // Answers the question.
        ("Is the demo on Tuesday? No, not Tuesday, Thursday.", "Is the demo on Thursday?"),
    ])
    func keepsANotThatSaysNothingCorrectedAgain(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidRepair))
    }

    @Test("Scratch that takes back the end of the sentence before it", arguments: [
        ("I'll call the plumber tomorrow. Scratch that, I'll fix the tap myself this weekend.", "I'll fix the tap myself this weekend."),
        ("Okay, pay off the credit card first. Scratch that, build the emergency fund first.", "Okay, build the emergency fund first."),
    ])
    func scratchThatTakesBackTheSentenceBefore(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test("A cue goes only with its correction, and is never changed", arguments: [
        // Keeps what "scratch that" took back and drops only the cue.
        ("ship it to prague scratch that hold it until june", "Ship it to Prague. Hold it until June."),
        ("ship it to prague sorry the parcel stays here", "Ship it to Prague. Parcel stays here."),
        ("I'll call the plumber tomorrow. Scratch that, I'll fix the tap myself.", "I'll call the plumber tomorrow. I'll fix the tap myself."),
        // Turns the cue into a claim.
        ("yasmin make that wendy left the keys at reception", "Yasmin made that. Wendy left the keys at reception."),
        ("tell zoe i meant delia the train is delayed", "Tell Zoe I mean Delia the train is delayed."),
        // Adds back what was corrected, and a form of the cue, as the phrase's repairs.
        ("the scheduler make that the message queue ran out of memory", "The scheduler made that the message queue ran out of memory."),
        // Keeps the month taken back.
        ("the lease ends in april no wait may", "The lease ends in April."),
    ])
    func takesACueOutOnlyWithItsCorrection(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidRepair))
    }

    @Test("A name is kept as said, and no word becomes one", arguments: [
        ("I rang Uma twice, but they didn't answer.", "I rang Una twice, but they didn't answer."),
        ("i rang uma twice but they didn't answer", "I rang Una twice, but they didn't answer."),
        ("can you check the jura ticket", "Can you check the Jira ticket?"),
        ("uma hasn't replied to my message", "Una hasn't replied to my message."),
        ("delia i mean uma left the keys at reception", "Dela, I mean Uma, left the keys at reception."),
        ("remind xavier about the dentist no sorry uma", "Remind Xavier about the dentist. No, sorry, um..."),
        // A name that started the sentence as said, where either capital may be a name's.
        ("Uma will bring the cake.", "Una will bring the cake."),
        // Another name where no sentence starts.
        ("Can you ask Madge to review it?", "Can you ask Marge to review it?"),
    ])
    func keepsNamesAsSaid(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidRepair))
    }

    @Test func aNameMayTakeItsPossessive() {
        #expect(review("that is kirk car", "That is Kirk's car.") == .accepted("That is Kirk's car."))
    }

    @Test("A word speech-to-text took for a name is fixed where its capital says nothing", arguments: [
        ("Can you Madge the PR before lunch?", "Can you merge the PR before lunch?"),
        ("Can you review the P R before lunch?", "Can you review the PR before lunch?"),
        ("The A P I is down again.", "The API is down again."),
        (
            "Plan for the release tomorrow. First, Madge, P R thirty one, Sam get the notes once the build has finished. Two follow up for the sign off. Three, the export screen needs a fix. Four, Ellis review should come last.",
            "Plan for the release tomorrow. First, merge PR 31, Sam get the notes once the build has finished. Two, follow up for the sign-off. Three, the export screen needs a fix. Four, Ellis review should come last."
        ),
    ])
    func fixesAWordTakenForAName(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test func fixesAWordTakenForANameThatStartsAListItem() {
        let raw = "Two things for today. First, Madge the PR. Second, John updates the website."
        let cleaned = "Two things for today:\n1. Merge the PR.\n2. John updates the website."
        #expect(review(raw, cleaned, multiline: true) == .accepted(cleaned))
        let renamed = "Two things for today:\n1. Merge the PR.\n2. Pete updates the website."
        #expect(review(raw, renamed, multiline: true) == .rejected(.invalidRepair), "a name isn't swapped for another")
    }

    @Test("Letters spelled out keep their order and number", arguments: [
        "Can you review the RP before lunch?",
        "Can you review the PRs before lunch?",
        "Can you review the P before lunch?",
    ])
    func keepsTheLettersSpelledOut(cleaned: String) {
        #expect(review("Can you review the P R before lunch?", cleaned) == .rejected(.invalidRepair))
    }

    @Test("A cue that starts a new thought stays", arguments: [
        ("Is the release tomorrow? No, it's the day after.", "Is the release the day after?"),
        ("Is the release tomorrow? No, it's the day after.", "Is the release tomorrow? It's the day after."),
        ("Sorry I'm late, the train was delayed.", "I'm late, the train was delayed."),
        ("I finished the report. Sorry, I haven't had time to review yours yet.", "I haven't had time to review yours yet."),
        ("I finished the report. Sorry, I was late.", "I was late."),
        ("It works. Actually, it's quite fast.", "It's quite fast."),
        ("We shipped version two. Actually, we shipped it a week early.", "We shipped it a week early."),
        ("I finished the report. Sorry, I was late.", "I finished. I was late."),
        ("Is Sam coming tonight? No, he's working late.", "Is Sam coming? He's working late."),
    ])
    func keepsACueThatStartsANewThought(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidRepair))
    }

    @Test("Grammar and misheard words are fixed", arguments: [
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
    ])
    func fixesGrammarAndMisheardWords(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test func acceptsTextThatWasAlreadyRight() {
        let text = "The build is green, and Priya will deploy it on Friday."
        #expect(review(text, text) == .accepted(text))
    }

    @Test("Facts may not change", arguments: [
        ("We need fifteen chairs.", "We need fifty chairs."),
        ("See you Tuesday.", "See you Thursday."),
        ("I agree with the plan.", "I don't agree with the plan."),
        ("I don't agree with the plan.", "I agree with the plan."),
        ("Tell Kirk the build is green.", "Tell Kurt the build is green."),
        ("Call me before lunch.", "Call me after lunch."),
        ("The invoice is ready.", "The invoice is ready to send."),
        ("I tried to speak with Kirk.", "I tried to talk to Kirk."),
    ])
    func keepsTheFacts(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidRepair))
    }

    @Test func laysOutAListInAFieldThatTakesSeveralLines() {
        let cleaned = "I need to buy:\n- Milk\n- Eggs\n- Bread"
        #expect(review("I need to buy milk, eggs and bread.", cleaned, multiline: true) == .accepted(cleaned))
        let numbered = "Today:\n1. Call the bank.\n2. Email Sarah.\n3. Book the flights."
        #expect(review("Today first call the bank, second email Sarah, and third book the flights.", numbered, multiline: true) == .accepted(numbered))
    }

    @Test func laysOutAnEmail() {
        let cleaned = "Hi Sam,\n\nThanks for sending the report. I'll review it tomorrow.\n\nCheers,\nPriya"
        #expect(review("hi sam thanks for sending the report i'll review it tomorrow cheers priya", cleaned, multiline: true) == .accepted(cleaned))
    }

    @Test func rejectsLinesInAOneLineField() {
        #expect(review("Buy milk and eggs.", "Buy:\n- Milk\n- Eggs") == .rejected(.layoutNotAllowed))
    }

    @Test func rejectsAListThatDropsQuantities() {
        let cleaned = "Buy:\n- Apples\n- Pears\n- A melon"
        #expect(review("Buy three apples, two pears and a melon.", cleaned, multiline: true) == .rejected(.invalidRepair))
    }

    @Test func rejectsABulletedListOfTwoThingsSaidInASentence() {
        let bulleted = "I've attached:\n- The invoice\n- The signed agreement"
        #expect(review("I've attached the invoice and the signed agreement.", bulleted, multiline: true) == .rejected(.shortList))
        let numbered = "Two things:\n1. Call the bank.\n2. Email Sarah."
        #expect(
            review("Two things: number one, call the bank. Number two, email Sarah.", numbered, multiline: true) == .accepted(numbered),
            "a numbered list may have two items, as when they were counted"
        )
    }

    @Test func allowsABulletedListOfTwoThingsTheSpeakerSetOffWithAColon() {
        let said = "few things we need to focus on: getting active feeds working and releasing the hot fix before end of the week"
        let cleaned = "A few things we need to focus on:\n- Getting active feeds working\n- Releasing the hot fix before end of the week"
        #expect(review(said, cleaned, multiline: true) == .accepted(cleaned))
        let spaced = cleaned.replacingOccurrences(of: "on:\n", with: "on:\n\n")
        #expect(review(said, spaced, multiline: true) == .accepted(spaced), "a blank line between the lead and the list is fine")
        #expect(
            review(said.replacingOccurrences(of: "on:", with: "on"), cleaned, multiline: true) == .rejected(.shortList),
            "with no colon said, they stay in the sentence"
        )
        #expect(
            review("reminder: i've attached the invoice and the signed agreement", "Reminder: I've attached:\n- The invoice\n- The signed agreement", multiline: true)
                == .rejected(.shortList),
            "a colon elsewhere in the text doesn't set the list off"
        )
        #expect(
            review("two things: call the bank and email sarah", "Two things:\n- Call the bank", multiline: true) == .rejected(.shortList),
            "one item is never a list"
        )
    }

    @Test func allowsTwoThingsSetOffWithAFullStopOrCountedBeforeAComma() {
        let cleaned = "Two things:\n- Call the bank\n- Email Sarah"
        #expect(review("Two things. Call the bank and email Sarah.", cleaned, multiline: true) == .accepted(cleaned))
        #expect(review("Two things, call the bank and email Sarah.", cleaned, multiline: true) == .accepted(cleaned))
        let attached = "I've attached:\n- The invoice\n- The signed agreement"
        #expect(
            review("I've attached, the invoice and the signed agreement.", attached, multiline: true) == .rejected(.shortList),
            "a comma sets them off only after words that count them"
        )
        #expect(
            review("Reminder. I've attached the invoice and the signed agreement.", "Reminder. I've attached:\n- The invoice\n- The signed agreement", multiline: true)
                == .rejected(.shortList),
            "a full stop elsewhere doesn't set them off"
        )
    }

    @Test func eachBulletedListHasTheLineBeforeIt() {
        let lists = SelfRepair.bulletedLists(in: "Two things:\n- a\n- b\n\n- c\n- d\nAnd also:\n- e")
        #expect(lists.map(\.lead) == ["Two things:", "- b", "And also:"], "a second list doesn't take the first one's lead")
        #expect(lists.map(\.items) == [["a", "b"], ["c", "d"], ["e"]])
        #expect(SelfRepair.bulletedLists(in: "- a\n- b").map(\.lead) == [nil])
    }

    @Test func aListSetOffByAColonIsMatchedAsTextNotAsBytes() {
        let said = "we need the cafe\u{301} menu: soup and bread"
        let cleaned = "We need the caf\u{E9} menu:\n- Soup\n- Bread"
        #expect(review(said, cleaned, multiline: true) == .accepted(cleaned), "an accent written either way is the same word")
    }

    @Test func rejectsAPlaceholderOnALineOfItsOwn() {
        let emoji = ["⟦E1⟧"]
        #expect(review("Thanks so much! ⟦E1⟧", "Thanks so much!\n\n⟦E1⟧", multiline: true, placeholders: emoji) == .rejected(.placeholderOnItsOwnLine))
        #expect(review("Thanks so much! ⟦E1⟧", "Thanks so much! ⟦E1⟧", multiline: true, placeholders: emoji) == .accepted("Thanks so much! ⟦E1⟧"))
        let addresses = ["⟦A1⟧", "⟦A2⟧", "⟦A3⟧"]
        #expect(
            review("The links are ⟦A1⟧, ⟦A2⟧ and ⟦A3⟧.", "The links are:\n- ⟦A1⟧\n- ⟦A2⟧\n- ⟦A3⟧", multiline: true, placeholders: addresses)
                == .rejected(.placeholderOnItsOwnLine),
            "a list of placeholders alone is turned down too, and Medium's sentence shown"
        )
    }
}
