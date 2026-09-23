import Cleanup
import Testing

@Suite("OutputGuard: self-corrections")
struct SelfCorrectionTests {
    private let outputGuard = OutputGuard()

    private func review(_ raw: String, _ cleaned: String) -> GuardVerdict {
        outputGuard.review(raw: raw, outcome: .completed(cleaned))
    }

    @Test("Keeping only the correction is accepted", arguments: [
        ("I want to talk about fuel efficiency in cars sorry busses", "I want to talk about fuel efficiency in buses."),
        ("let's meet on tuesday no wait wednesday at ten", "Let's meet on Wednesday at ten."),
        ("send it to john i mean jane before friday", "Send it to Jane before Friday."),
        ("we need three sorry four more servers for the launch", "We need four more servers for the launch."),
        ("it's the login service or rather the auth service that times out", "It's the auth service that times out."),
        ("the meeting is at two pm actually make that three pm", "The meeting is at three p.m."),
        ("open the settings sorry the preferences window", "Open the preferences window."),
        ("we should deploy on monday scratch that let's wait until tuesday", "Let's wait until Tuesday."),
    ])
    func acceptsASelfCorrection(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test func acceptsASelfCorrectionAlongsideOtherFixes() {
        let cleaned = "So we need to fix the login page."
        #expect(review("so um we need to fix the the signup sorry login page", cleaned) == .accepted(cleaned))
    }

    @Test("Keeping the retracted words instead of the correction is rejected", arguments: [
        ("we need three sorry four more servers for the launch", "We need three more servers for the launch."),
        ("let's meet on tuesday sorry thursday", "Let's meet on Tuesday."),
        ("send it to john i mean jane", "Send it to John."),
    ])
    func rejectsKeepingTheRetractedWords(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidSelfCorrection))
    }

    @Test("A cue with nothing before it to retract must stay", arguments: [
        ("sorry i'm late the traffic was terrible", "I'm late, the traffic was terrible."),
        ("i mean it this time we really need to ship", "It this time, we really need to ship."),
        ("no i don't think that's right", "I don't think that's right."),
        ("actually that works for me", "That works for me."),
    ])
    func rejectsDroppingACueThatCorrectsNothing(raw: String, cleaned: String) {
        #expect(review(raw, cleaned) == .rejected(.invalidSelfCorrection))
    }

    @Test func acceptsAFullRetractionEndingInBackToBackCues() {
        let cleaned = "I returned the jacket to the shop in the shopping centre."
        let raw = "i returned the jacket to the shop on high street wait no to the shop in the shopping centre"
        #expect(review(raw, cleaned) == .accepted(cleaned))
    }

    @Test func backToBackCuesStillLimitTheRetractedWords() {
        let raw = "i returned the jacket to the big shop on high street wait no to the shop in the centre"
        #expect(review(raw, "I returned the jacket to the shop in the centre.") == .rejected(.invalidSelfCorrection))
    }

    @Test func rejectsRetractingMoreThanTheLimit() {
        let verdict = review("I want to talk about fuel efficiency in cars sorry busses", "Buses.")
        #expect(verdict == .rejected(.invalidSelfCorrection))
    }

    @Test func rejectsAddingWordsWhileDroppingACue() {
        let verdict = review("send it to john i mean jane", "Send it to Jane in accounts.")
        #expect(verdict == .rejected(.invalidSelfCorrection))
    }

    @Test func rejectsReplacingTheCorrectionWithAnUnrelatedWord() {
        let verdict = review("fuel efficiency in cars sorry busses", "Fuel efficiency in trains.")
        #expect(verdict == .rejected(.invalidSelfCorrection))
    }

    @Test func keptCuesUseTheUsualLimits() {
        let cleaned = "Sorry to interrupt, but can I ask a question?"
        #expect(review("sorry to interrupt but can i ask a question", cleaned) == .accepted(cleaned))
        guard case .rejected(.wordRatio) = review("sorry to interrupt but can i ask a question", "Sorry, a question?") else {
            Issue.record("expected a word-ratio rejection")
            return
        }
    }

    @Test func countsCuesIncludingMultiWordOnes() {
        #expect(outputGuard.correctionCueCount(in: "Send it to John, I mean Jane, no wait, Jill.") == 3)
        #expect(outputGuard.correctionCueCount(in: "The build is green.") == 0)
    }

    @Test func dropsCorrectionCueComparesCueCounts() {
        #expect(outputGuard.dropsCorrectionCue(raw: "cars sorry buses", cleaned: "Buses."))
        #expect(!outputGuard.dropsCorrectionCue(raw: "sorry I'm late", cleaned: "Sorry, I'm late."))
    }

    @Test func invalidSelfCorrectionIsReadable() {
        #expect(FallbackReason.invalidSelfCorrection.description == "removed words that were not a self-correction")
    }
}
