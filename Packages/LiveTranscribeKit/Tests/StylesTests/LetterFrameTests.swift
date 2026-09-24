import Styles
import Testing

@Suite("LetterFrame")
struct LetterFrameTests {
    private let rule = LetterFrame()

    /// A formal letter as speech-to-text wrote it, mishearing "sir or madam".
    @Test func framesAFormalLetter() {
        let spoken = "Dear sir oh madam, I'm writing to you and mention about my passport is expiring and we need "
            + "to renew. It's expiring in January. No, in February, and need to be reapplied as soon as possible. "
            + "Kind regards Jordan Lee."
        #expect(rule.frame(in: spoken) == TextFrame(
            opening: "Dear Sir or Madam,\n\n",
            body: "I'm writing to you and mention about my passport is expiring and we need to renew. It's expiring "
                + "in January. No, in February, and need to be reapplied as soon as possible.",
            closing: "\n\nKind regards,\nJordan Lee"
        ))
    }

    @Test func framesAnUnpunctuatedNote() {
        #expect(rule.frame(in: "Hi John thanks for the update I will review it tomorrow cheers Sam.") == TextFrame(
            opening: "Hi John,\n\n",
            body: "thanks for the update I will review it tomorrow",
            closing: "\n\nCheers,\nSam"
        ))
    }

    @Test("Writes the salutation and the sign-off", arguments: [
        ("Hi team, the build is green. Thanks Sam", "Hi team,\n\n", "\n\nThanks,\nSam"),
        (
            "To whom it may concern, I am writing about my order. Yours faithfully, Jordan Lee",
            "To whom it may concern,\n\n", "\n\nYours faithfully,\nJordan Lee"
        ),
        ("Good morning everyone. Quick update: the release is out. Regards", "Good morning everyone,\n\n", "\n\nRegards,"),
        ("Hello, I hope you are well. Best regards", "Hello,\n\n", "\n\nBest regards,"),
        ("Hey Sam Lee can you check the invoice please. Love, Mum", "Hey Sam Lee,\n\n", "\n\nLove,\nMum"),
        (
            "Dear hiring manager I am applying for the role. Sincerely Jordan J. Lee",
            "Dear Hiring Manager,\n\n", "\n\nSincerely,\nJordan J. Lee"
        ),
    ])
    func writesTheEnds(text: String, opening: String, closing: String) {
        let frame = rule.frame(in: text)
        #expect(frame?.opening == opening)
        #expect(frame?.closing == closing)
    }

    @Test("Leaves text that is not a letter", arguments: [
        "Hi John, can you send the report?",
        "Hi John, can you send the report? Thanks",
        "Hi John thanks for the update cheers",
        "Dear diary, today was great.",
        "I said hi to John. Kind regards Sam",
        "Hi everyone thanks",
        "Kind regards Sam",
        "Hi John, thanks for the update. Regards to your family and see you soon",
    ])
    func leavesOtherText(text: String) {
        #expect(rule.frame(in: text) == nil)
    }

    @Test func aSignatureCanBeAPlaceholder() {
        #expect(rule.frame(in: "Dear team, the build is green. Kind regards ⟦S1⟧")?.closing == "\n\nKind regards,\n⟦S1⟧")
    }

    @Test func theAddresseeEndsAtAPlaceholder() {
        let frame = rule.frame(in: "Hi John ⟦S1⟧ thanks for the update. Cheers Sam")
        #expect(frame?.opening == "Hi John,\n\n")
        #expect(frame?.body == "⟦S1⟧ thanks for the update.")
    }
}
