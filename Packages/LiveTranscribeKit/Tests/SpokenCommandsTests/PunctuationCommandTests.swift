import Shared
import SpokenCommands
import Testing

@Suite("PunctuationCommand")
struct PunctuationCommandTests {
    private let protector = PhraseProtector(matchers: [PunctuationCommand()])

    @Test("Writes punctuation said by name", arguments: [
        ("Is it ready question mark?", "Is it ready?"),
        ("is it ready question mark yes it is", "is it ready? Yes it is"),
        ("That is amazing exclamation mark.", "That is amazing!"),
        ("That is amazing, exclamation point", "That is amazing!"),
        ("We need milk comma eggs comma and bread full stop", "We need milk, eggs, and bread."),
        ("What time is the meeting question mark I need to know?", "What time is the meeting? I need to know?"),
        ("really question mark exclamation mark", "really?!"),
        ("first semicolon second", "first; second"),
        ("He said open quote I will be late close quote and left.", "He said \"I will be late\" and left."),
        ("See the appendix open bracket page 4 close bracket for details.", "See the appendix (page 4) for details."),
        ("she called it quote finished unquote yesterday", "she called it \"finished\" yesterday"),
        ("He said open quote wait, close quote.", "He said \"wait,\"."),
    ])
    func writesPunctuation(spoken: String, expected: String) {
        let protected = protector.protect(spoken)
        #expect(protected.text == expected)
        #expect(protected.placeholders.isEmpty, "punctuation is written straight into the text")
    }

    @Test("Leaves marks that are talked about, and unpaired quotes and brackets", arguments: [
        "What does a question mark mean",
        "Put the full stop at the end",
        "question mark",
        "I like the Oxford comma",
        "He's a quote unquote expert",
        "That's the end quote of the book",
        "open bracket and nothing after",
        "close quote the door",
        "open quote close quote",
    ])
    func leavesMarksThatAreTalkedAbout(spoken: String) {
        #expect(protector.protect(spoken).text == spoken)
    }
}

@Suite("LineBreakCommand")
struct LineBreakCommandTests {
    private func rendered(_ spoken: String, multiline: Bool = true) -> String {
        let protected = PhraseProtector(matchers: [LineBreakCommand(multiline: multiline)]).protect(spoken)
        return SpokenCommands.tidyLineBreaks(protected.expanded)
    }

    @Test("Breaks lines where the field takes them", arguments: [
        ("first line new line second line", "first line\nSecond line"),
        ("Hi team new paragraph the build is green new paragraph thanks Sam.", "Hi team\n\nThe build is green\n\nThanks Sam."),
        ("Dear John, new paragraph. I'm writing", "Dear John,\n\nI'm writing"),
        ("milk newline eggs", "milk\nEggs"),
    ])
    func breaksLines(spoken: String, expected: String) {
        #expect(rendered(spoken) == expected)
    }

    @Test func singleLineFieldsGetASpaceWithNothingHidden() {
        let protected = PhraseProtector(matchers: [LineBreakCommand(multiline: false)])
            .protect("first line new line second line, new paragraph third")
        #expect(protected.text == "first line second line, third")
        #expect(protected.placeholders.isEmpty)
    }

    @Test("Leaves the words when they are a noun", arguments: [
        "Apple's new line of laptops",
        "we launched a new line today",
        "Write new line of code here",
        "The new paragraph reads well",
    ])
    func leavesNouns(spoken: String) {
        #expect(rendered(spoken) == spoken)
    }

    @Test func breaksAreHiddenFromTheModel() {
        let protected = PhraseProtector(matchers: [LineBreakCommand(multiline: true)]).protect("Thanks new paragraph bye")
        #expect(protected.text == "Thanks ⟦S1⟧ bye")
        #expect(protected.placeholders.first?.role == .lineBreak)
        #expect(protected.placeholders.first?.expansion == "\n\n")
    }
}

@Suite("Tidying line breaks")
struct TidyLineBreaksTests {
    @Test("Tidies around breaks the model punctuated", arguments: [
        ("Hi John \n\n , thanks for the update.", "Hi John,\n\nThanks for the update."),
        ("tomorrow \n\n. Cheers", "tomorrow.\n\nCheers"),
        ("done.\n\n, next", "done.\n\nNext"),
        ("a\n\n\n\nb", "a\n\nB"),
        ("Is it ready \n?", "Is it ready?\n"),
        ("one  two \n three", "one two\nThree"),
        ("\n\nstart", "\n\nStart"),
        ("Hello, world.", "Hello, world."),
        ("list:\n1. we\n- milk", "list:\n1. we\n- milk"),
    ])
    func tidies(input: String, expected: String) {
        #expect(SpokenCommands.tidyLineBreaks(input) == expected)
    }
}
