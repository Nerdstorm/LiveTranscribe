import Foundation
import Shared
import Snippets
import Testing

@Suite("SnippetExpander")
struct SnippetExpanderTests {
    private static let calendar = Snippet(trigger: "my calendar link", expansion: "https://cal.example.com/alex")
    private static let shortLink = Snippet(trigger: "my link", expansion: "https://example.com")
    private static let longLink = Snippet(trigger: "my link to the calendar", expansion: "https://example.com/calendar")
    private static let signature = Snippet(trigger: "sign off", expansion: "Best,\nAlex")
    private static let word = Snippet(trigger: "link", expansion: "LINK")

    private let expander = SnippetExpander(snippets: [calendar, shortLink, longLink, signature])

    @Test("Replaces a trigger with a token and keeps the punctuation around it", arguments: [
        ("Here's my calendar link.", "Here's ⟦S1⟧."),
        ("my calendar link", "⟦S1⟧"),
        ("MY CALENDAR LINK, please", "⟦S1⟧, please"),
        ("My Calendar Link?", "⟦S1⟧?"),
        ("(my calendar link)", "(⟦S1⟧)"),
        ("\u{201C}My calendar link,\u{201D} she said", "\u{201C}⟦S1⟧,\u{201D} she said"),
        ("It's my, calendar... link!", "It's ⟦S1⟧!"),
        ("Use my calendar-link.", "Use ⟦S1⟧."),
        ("my calendar — link", "⟦S1⟧"),
        ("Send it — my calendar link — today", "Send it — ⟦S1⟧ — today"),
        ("my calendar link\u{1F642} works", "⟦S1⟧\u{1F642} works"),
        ("Use my\ncalendar link now", "Use ⟦S1⟧ now"),
    ])
    func replacesTrigger(input: String, expected: String) {
        let protected = expander.protect(input)
        #expect(protected.text == expected)
        #expect(protected.tokens == ["⟦S1⟧"])
        #expect(protected.placeholders.map(\.trigger) == [Self.calendar.trigger])
        #expect(protected.placeholders.map(\.expansion) == [Self.calendar.expansion])
    }

    @Test func keepsWhitespaceOutsideTheMatchExactly() {
        #expect(expander.protect("a\n\n  my link\tb ").text == "a\n\n  ⟦S1⟧\tb ")
    }

    @Test("Returns text without triggers unchanged", arguments: [
        "",
        "   ",
        "Nothing to see here.",
        "  two  spaces\nand a newline\t",
        "my calendar",
        "calendar link",
    ])
    func leavesTextWithoutTriggers(input: String) {
        let protected = expander.protect(input)
        #expect(protected.text == input)
        #expect(protected.placeholders.isEmpty)
        #expect(protected.tokens.isEmpty)
        #expect(protected.expanded == input)
        #expect(expander.expand(input) == input)
    }

    @Test("Matches whole words only", arguments: [
        "The page is linked here.",
        "Check mylink now.",
        "A linkage problem.",
        "The calendar-link widget.",
        "Your link's broken.",
    ])
    func matchesWholeWordsOnly(input: String) {
        let expander = SnippetExpander(snippets: [Self.word])
        #expect(expander.protect(input).text == input)
    }

    @Test func prefersTheLongestOverlappingTrigger() {
        let protected = expander.protect("Send my link to the calendar today.")
        #expect(protected.text == "Send ⟦S1⟧ today.")
        #expect(protected.placeholders.map(\.expansion) == [Self.longLink.expansion])
    }

    @Test func fallsBackToTheShorterTriggerWhenTheLongerOneIsIncomplete() {
        let protected = expander.protect("Send my link to the team.")
        #expect(protected.text == "Send ⟦S1⟧ to the team.")
        #expect(protected.placeholders.map(\.expansion) == [Self.shortLink.expansion])
    }

    @Test func longestMatchDoesNotDependOnSnippetOrder() {
        let reversed = SnippetExpander(snippets: [Self.longLink, Self.shortLink])
        let forward = SnippetExpander(snippets: [Self.shortLink, Self.longLink])
        let text = "my link to the calendar and my link"
        #expect(reversed.protect(text) == forward.protect(text))
        #expect(forward.protect(text).placeholders.map(\.expansion) == [Self.longLink.expansion, Self.shortLink.expansion])
    }

    @Test func leftmostMatchWinsOverALaterOverlappingOne() {
        let expander = SnippetExpander(snippets: [
            Snippet(trigger: "beta gamma delta", expansion: "second"),
            Snippet(trigger: "alpha beta", expansion: "first"),
        ])
        let protected = expander.protect("alpha beta gamma delta")
        #expect(protected.text == "⟦S1⟧ gamma delta")
        #expect(protected.placeholders.map(\.expansion) == ["first"])
    }

    @Test func numbersEveryOccurrenceInOrderOfAppearance() {
        let protected = expander.protect("Sign off. My link, then my link again, and sign off")
        #expect(protected.text == "⟦S1⟧. ⟦S2⟧, then ⟦S3⟧ again, and ⟦S4⟧")
        #expect(protected.tokens == ["⟦S1⟧", "⟦S2⟧", "⟦S3⟧", "⟦S4⟧"])
        #expect(protected.placeholders.map(\.trigger) == ["sign off", "my link", "my link", "sign off"])
    }

    @Test func expandsTriggersDirectly() {
        #expect(expander.expand("Here's my calendar link.") == "Here's https://cal.example.com/alex.")
        #expect(expander.expand("Thanks. Sign off") == "Thanks. Best,\nAlex")
    }

    @Test func punctuationThatBelongsToTheTriggerIsReplacedWithIt() {
        let expander = SnippetExpander(snippets: [
            Snippet(trigger: "docs c++", expansion: "https://cppreference.com"),
            Snippet(trigger: "@home address", expansion: "1 Main St"),
        ])
        #expect(expander.protect("Read the docs C++.").text == "Read the ⟦S1⟧.")
        #expect(expander.protect("Ship to (@home address).").text == "Ship to (⟦S1⟧).")
        // Without the trigger's own punctuation, whatever surrounds the words stays.
        #expect(expander.protect("the docs c!").text == "the ⟦S1⟧!")
    }

    @Test func ignoresTriggersWithoutWordsAndRepeatedTriggers() {
        let expander = SnippetExpander(snippets: [
            Snippet(trigger: "...", expansion: "never"),
            Snippet(trigger: "my link", expansion: "first"),
            Snippet(trigger: "My, link!", expansion: "second"),
        ])
        let protected = expander.protect("... my link")
        #expect(protected.text == "... ⟦S1⟧")
        #expect(protected.placeholders.map(\.expansion) == ["first"])
    }

    /// Validation rejects an empty expansion; a hand-edited file that has one must not make the
    /// trigger vanish from the dictation, and a later snippet with the same trigger takes over.
    @Test func ignoresSnippetsWithAnEmptyExpansion() {
        let expander = SnippetExpander(snippets: [
            Snippet(trigger: "my link", expansion: ""),
            Snippet(trigger: "My link!", expansion: "second"),
            Snippet(trigger: "gone", expansion: ""),
        ])
        let protected = expander.protect("my link is gone")
        #expect(protected.text == "⟦S1⟧ is gone")
        #expect(protected.placeholders.map(\.expansion) == ["second"])
    }

    @Test func matchesACurlyApostropheAgainstAStraightOne() {
        let expander = SnippetExpander(snippets: [Snippet(trigger: "don't forget", expansion: "Reminder:")])
        #expect(expander.protect("Don\u{2019}t forget the milk").text == "⟦S1⟧ the milk")
        #expect(expander.protect("Dont forget the milk").text == "Dont forget the milk")
    }

    /// Sentence punctuation typed into a trigger belongs to it like any other: a trigger ending in
    /// a full stop takes the spoken full stop with it, so a URL is not followed by one.
    @Test func sentencePunctuationInTheTriggerIsReplacedWithIt() {
        let expander = SnippetExpander(snippets: [Snippet(trigger: "my link.", expansion: "https://example.com")])
        #expect(expander.protect("Here's my link.").text == "Here's ⟦S1⟧")
        #expect(expander.protect("Here's my link, thanks").text == "Here's ⟦S1⟧, thanks")
        #expect(expander.expand("Here's my link.") == "Here's https://example.com")
    }

    @Test func anExpanderWithoutSnippetsChangesNothing() {
        let expander = SnippetExpander(snippets: [])
        #expect(expander.protect("my link").text == "my link")
    }
}
