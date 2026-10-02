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

    /// A correction keeps its meaning: the word it says instead stays, as itself or a word like it,
    /// and what it takes back isn't written again.
    @Test("A correction is resolved with its meaning kept", arguments: [
        ("book the blue room sorry the green room for friday", "Book the green room for Friday."),
        ("send it to the finance team make that the legal team today", "Send it to the legal team today."),
        ("ask the designer i mean the developer to check it", "Ask the developer to check it."),
        ("we're migrating the load balancer make that the scheduler next week", "We're migrating the scheduler next week."),
        ("paint the fence red no wait blue", "Paint the fence blue."),
        ("we need three servers sorry four", "We need four servers."),
        ("send it to sam sorry to priya", "Send it to Priya."),
        ("the demo is next week sorry the after next", "The demo is the week after next."),
        ("i'm meeting divya at the station actually nikhil", "I'm meeting Nikhil at the station."),
        ("The billing service goes live next Tuesday. Sorry, I mean the login service.", "The login service goes live next Tuesday."),
        ("fuel efficiency in cars sorry busses", "Fuel efficiency in buses."),
    ])
    func keepsTheMeaningOfACorrection(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    /// However a repair could otherwise line the words up, an answer may not lose what a correction
    /// says instead or write what it takes back.
    @Test("A correction whose meaning is lost is rejected", arguments: [
        ("book the blue room sorry the green room for friday", "Book the blue room for Friday."),
        ("book the blue room sorry the green room for friday", "Book the room for Friday."),
        ("book the blue room sorry the green room for friday", "Book the blue green room for Friday."),
        ("Book the blue room, sorry, the green room for Friday.", "Book the blue room for Friday."),
        ("send it to the finance team make that the legal team today", "Send it to the finance team today."),
        ("ask the designer i mean the developer to check it", "Ask the designer to check it."),
        ("we're migrating the load balancer make that the scheduler next week", "We're migrating the load balancer next week."),
        ("paint the fence red no wait blue", "Paint the fence red."),
        ("we need three servers sorry four", "We need four three servers."),
        ("send it to sam sorry to priya", "Send it to Priya Sam."),
        ("I left my charger in the garage. Actually, the lobby.", "I left my charger in the garage lobby."),
        ("The demo is on Tuesday at noon. Sorry, Wednesday.", "The demo is on Tuesday Wednesday at noon."),
        ("Invite Sam to the launch. Sorry, Priya.", "Invite Sam and Priya to the launch."),
        ("fuel efficiency in cars sorry busses", "Fuel efficiency in trains."),
        ("i wanted to say sorry to jo", "I wanted to say it to Jo."),
    ])
    func rejectsLosingTheMeaningOfACorrection(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidRepair))
    }

    /// A fact or a name a correction says instead takes back one of its own sort, so no reading of
    /// it keeps that one beside it: one that takes back only the words after it is no reading at
    /// all.
    @Test("A correction never keeps what it takes back beside it", arguments: [
        ("we need three servers sorry four", "We need three four servers."),
        ("we need three servers sorry four", "We need three or four servers."),
        ("we need three of the servers sorry four", "We need three of the four servers."),
        ("Invite Sam to the launch. Sorry, Priya.", "Invite Sam and Priya to the launch."),
        ("Invite Sam to the launch. Sorry, Priya.", "Invite Sam, Priya to the launch."),
        ("Invite Sam to the launch, sorry, Priya.", "Invite Sam and Priya to the launch."),
        ("I am meeting Divya at the station. Actually, Nikhil.", "I am meeting Divya and Nikhil at the station."),
        ("I am meeting Divya at the station. Actually, Nikhil.", "I am meeting Divya Nikhil at the station."),
        ("Call me on Tuesday, no, Wednesday.", "Call me on Tuesday or Wednesday."),
        ("We have two weeks left. Sorry, three.", "We have two or three weeks left."),
    ])
    func rejectsKeepingWhatACorrectionTakesBack(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidRepair))
    }

    @Test("A correction of a fact or a name is resolved however far back it reaches", arguments: [
        ("we need three servers sorry four", "We need four servers."),
        ("two people said we need servers sorry four", "Two people said we need four servers."),
        ("we need three of the servers sorry four", "We need four of the servers."),
        ("Invite Sam to the launch. Sorry, Priya.", "Invite Priya to the launch."),
        ("Invite Sam to the launch, sorry, Priya.", "Invite Priya to the launch."),
        ("I am meeting Divya at the station. Actually, Nikhil.", "I am meeting Nikhil at the station."),
        ("meet me at the station sorry at six", "Meet me at six."),
        ("Ask Sam to email Ana, sorry, Priya.", "Ask Sam to email Priya."),
        ("Ask Sam to email Ana, sorry, Priya.", "Ask Priya to email Ana."),
        ("We have two weeks left. Sorry, three.", "We have three weeks left."),
    ])
    func resolvesACorrectionOfAFactOrAName(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    /// A cue speech-to-text misheard just after one it heard goes with it, and a misheard word that
    /// only holds the grammar together says nothing a correction says instead.
    @Test("Misheard cues and small words say nothing a correction says", arguments: [
        ("Can you bring the monitor, wait node, the router to the meeting?", "Can you bring the router to the meeting?"),
        ("The city is buying more electric buses, no weight vans.", "The city is buying more electric vans."),
        ("Dinner is on Saturday. Sorry, no theon Tuesday.", "Dinner is on Tuesday."),
        ("The product review is on the 12th of October. No sorry thee of November.", "The product review is on the 12th of November."),
    ])
    func resolvesACorrectionWithMisheardWords(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    /// "No" in "no one" is a cue too, so one correction can take words out of the phrase another
    /// moved back, and that phrase then ends where its words do.
    @Test func aPhraseALaterCorrectionCutsEndsWhereItsWordsDo() {
        let raw = "I'll call no one now. Scratch that. I'll email no one instead."
        #expect(review(raw, "I'll email no one instead.") == .accepted("I'll email no one instead."))
        #expect(review(raw, "I'll email Noah instead.") == .rejected(.invalidRepair))
    }

    /// An abbreviation's full stop ends a sentence only before a capital, so "at 3 p.m. today" is
    /// one sentence and its time can be corrected.
    @Test func anAbbreviationEndsASentenceOnlyBeforeACapital() {
        let cleaned = "The shop closes at 10 a.m. today."
        #expect(review("The shop closes at 3 p.m. today. Sorry, I meant at 10 a.m.", cleaned) == .accepted(cleaned))
    }

    /// A phrase that opens the way its sentence did starts it again ("Ship it" → "hold it"), so
    /// it takes back from where the sentence opened, and never leaves its start in front.
    @Test("A phrase that opens the way its sentence did starts it again", arguments: [
        ("Ship it to Prague, scratch that, hold it until September.", "Hold it until September."),
        ("ship it to prague scratch that hold it until june", "Hold it until June."),
        ("Ship it to Lisbon, scratch that, hold it until November.", "Hold it until November."),
        ("Ship it to Prague, scratch that, Vienna.", "Ship it to Vienna."),
        ("Book the early flight. Scratch that. Book the afternoon one.", "Book the afternoon one."),
        ("Put the box on the table, sorry, under the table.", "Put the box under the table."),
        ("We need to restart the off service. Actually, the database.", "We need to restart the database."),
        ("The leak is under the sink, rather, behind the dishwasher.", "The leak is behind the dishwasher."),
    ])
    func startsASentenceAgain(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test("A sentence started again never keeps its start in front", arguments: [
        ("Ship it to Prague, scratch that, hold it until September.", "Ship it to hold it until September."),
        ("ship it to prague scratch that hold it until june", "Ship it to hold it until June."),
        ("Ship it to Lisbon, scratch that, hold it until November.", "Ship it to Hold it until November."),
    ])
    func rejectsKeepingTheStartOfASentenceStartedAgain(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidRepair))
    }

    /// The corrected words said again after "not" are what a correction takes back, and the
    /// words beside them stay.
    @Test("A correction takes back the corrected words said again", arguments: [
        ("the physio team sorry not physio nursing will join the call at noon", "The nursing team will join the call at noon."),
        ("Kofi's brother, no wait, not brother, cousin, is hosting the barbecue.", "Kofi's cousin is hosting the barbecue."),
        ("nikhil's team sorry not nikhil's siobhan's owns the billing service", "Siobhan's team owns the billing service."),
    ])
    func takesBackTheWordsSaidAgain(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test("A correction takes back no more than the corrected words said again", arguments: [
        ("the physio team sorry not physio nursing will join the call at noon", "The nursing will join the call at noon."),
        ("Kofi's brother, no wait, not brother, cousin, is hosting the barbecue.", "Cousin is hosting the barbecue."),
        ("nikhil's team sorry not nikhil's siobhan's owns the billing service", "Siobhan's owns the billing service."),
    ])
    func rejectsTakingBackMoreThanTheWordsSaidAgain(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidRepair))
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
            "Action summary to get done tomorrow. First, Madge, P R twenty two, Max get the update once the website has deployed. Two follow up for the go ahead. Three, emoji parsing needs a revisit. Four, Russell cleanup should work best.",
            "Action summary to get done tomorrow. First, merge PR 22, Max get the update once the website has deployed. Two, follow up for the go-ahead. Three, emoji parsing needs a revisit. Four, Russell cleanup should work best."
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

    @Test("The start of a word broken off and said again in full may go", arguments: [
        ("She wants few ex expenses paid back.", "She wants few expenses paid back."),
        ("We should con consider the budget first.", "We should consider the budget first."),
        ("can you send the rep report by friday", "Can you send the report by Friday?"),
        ("We should con- consider the budget first.", "We should consider the budget first."),
    ])
    func dropsAWordFragment(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test("A word that only starts the next by chance stays", arguments: [
        // A negation, a number, a function word.
        ("there is not nothing left", "There is nothing left."),
        ("Bring ten tennis balls.", "Bring tennis balls."),
        ("Can he help us move?", "Can help us move?"),
        // Across the end of a sentence.
        ("We met the new rep. Reports are due on Monday.", "We met the new. Reports are due on Monday."),
        // Not the start of the next word.
        ("can you send the rap report by friday", "Can you send the report by Friday?"),
        // Not written as a word broken off: part of a word, or set off by a comma.
        ("please re-read the contract before signing", "Please read the contract before signing."),
        ("Bring a pen, pencil and paper.", "Bring a pencil and paper."),
        // A single letter, and a name's first part where it starts a sentence.
        ("vitamin d deficiency is common in winter", "Vitamin deficiency is common in winter."),
        ("Ed Edwards will lead.", "Edwards will lead."),
    ])
    func keepsAWordThatIsNoFragment(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidRepair))
    }
}
