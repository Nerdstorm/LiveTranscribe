import Cleanup
import Testing

@Suite("OutputGuard: Deep's repairs")
struct SelfRepairTests {
    private let outputGuard = OutputGuard()

    private func review(_ raw: String, _ cleaned: String, multiline: Bool = false) -> GuardVerdict {
        outputGuard.review(raw: raw, outcome: .completed(cleaned), options: CleanupOptions(level: .deep, multiline: multiline))
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
    ])
    func keepsTheRestOfTheCorrectedSentence(raw: String, kept: String, dropped: String) {
        #expect(review(raw, kept) == .accepted(kept))
        #expect(review(raw, dropped) == .rejected(.invalidRepair))
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
    ])
    func keepsNamesAsSaid(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidRepair))
    }

    @Test func aNameMayTakeItsPossessive() {
        #expect(review("that is kirk car", "That is Kirk's car.") == .accepted("That is Kirk's car."))
    }

    @Test("A cue that starts a new thought stays", arguments: [
        ("Is the release tomorrow? No, it's the day after.", "Is the release the day after?"),
        ("Is the release tomorrow? No, it's the day after.", "Is the release tomorrow? It's the day after."),
        ("Sorry I'm late, the train was delayed.", "I'm late, the train was delayed."),
        ("I finished the report. Sorry, I haven't had time to review yours yet.", "I haven't had time to review yours yet."),
        ("I finished the report. Sorry, I was late.", "I was late."),
        ("It works. Actually, it's quite fast.", "It's quite fast."),
        ("We shipped version two. Actually, we shipped it a week early.", "We shipped it a week early."),
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
        let cleaned = "Buy:\n- Apples\n- Pears"
        #expect(review("Buy three apples and two pears.", cleaned, multiline: true) == .rejected(.invalidRepair))
    }
}
