import Foundation
import Snippets
import Testing

@Suite("Snippet validation")
struct SnippetValidationTests {
    @Test("Rejects a trigger with no words", arguments: ["", "   ", "...", "\u{2014}", "?!", "'"])
    func rejectsEmptyTriggers(trigger: String) {
        let snippet = Snippet(trigger: trigger, expansion: "text")
        #expect(throws: SnippetError.emptyTrigger(id: snippet.id)) {
            try Snippet.validate([snippet])
        }
    }

    @Test func rejectsAnEmptyExpansion() {
        let snippet = Snippet(trigger: "my link", expansion: "")
        #expect(throws: SnippetError.emptyExpansion(id: snippet.id)) {
            try Snippet.validate([snippet])
        }
    }

    /// "New paragraph" expanding to two newlines is a reasonable snippet.
    @Test func allowsAWhitespaceExpansion() throws {
        try Snippet.validate([Snippet(trigger: "new paragraph", expansion: "\n\n")])
    }

    @Test("Rejects triggers that normalise to the same words", arguments: [
        ("my link", "My Link"),
        ("my link", "my, link!"),
        ("calendar link", "calendar-link"),
        ("don't forget", "Don\u{2019}t forget."),
    ])
    func rejectsDuplicateTriggers(first: String, second: String) {
        let later = Snippet(trigger: second, expansion: "b")
        #expect(throws: SnippetError.duplicateTrigger(id: later.id, trigger: second)) {
            try Snippet.validate([Snippet(trigger: first, expansion: "a"), later])
        }
    }

    /// Only a hand-edited file can repeat an id, and ``SnippetStore/upsert(_:)`` would then
    /// update the wrong one.
    @Test func rejectsARepeatedID() {
        let first = Snippet(trigger: "my link", expansion: "a")
        let copy = Snippet(id: first.id, trigger: "sign off", expansion: "b")
        #expect(throws: SnippetError.duplicateID(id: first.id)) {
            try Snippet.validate([first, copy])
        }
    }

    @Test func reportsTheFirstProblemInListOrder() {
        let valid = Snippet(trigger: "my link", expansion: "a")
        let noExpansion = Snippet(trigger: "sign off", expansion: "")
        let noTrigger = Snippet(trigger: "...", expansion: "b")
        #expect(throws: SnippetError.emptyExpansion(id: noExpansion.id)) {
            try Snippet.validate([valid, noExpansion, noTrigger])
        }
    }

    @Test func acceptsAnEmptyList() throws {
        try Snippet.validate([])
    }

    @Test func acceptsTriggersThatOnlyOverlap() throws {
        try Snippet.validate([
            Snippet(trigger: "my link", expansion: "a"),
            Snippet(trigger: "my link to the calendar", expansion: "b"),
            Snippet(trigger: "link", expansion: "c"),
        ])
    }

    @Test func triggerWordsAreNormalised() {
        #expect(Snippet(trigger: "  My Calendar-Link! ", expansion: "x").triggerWords == ["my", "calendar", "link"])
    }

    @Test("Every error has a message", arguments: [
        SnippetError.emptyTrigger(id: UUID()),
        .emptyExpansion(id: UUID()),
        .duplicateTrigger(id: UUID(), trigger: "my link"),
        .duplicateID(id: UUID()),
        .readFailed("Permission denied"),
        .writeFailed("Disk full"),
    ])
    func everyErrorHasAMessage(error: SnippetError) {
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test func theDuplicateMessageNamesTheTrigger() {
        let message = SnippetError.duplicateTrigger(id: UUID(), trigger: "my link").errorDescription
        #expect(message?.contains("my link") == true)
    }
}
