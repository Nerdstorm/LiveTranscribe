import ApplicationServices
import Foundation
import Insertion
import Testing

@Suite("AXTextInserter")
struct AXTextInserterTests {
    private let inserter = AXTextInserter(verificationDelayMs: 0)

    @Test("Replaces the selection and returns the UTF-16 range of the text", arguments: [
        // Caret at the end.
        ("Hello", nil as NSRange?, " world", "Hello world", NSRange(location: 5, length: 6)),
        // Caret in the middle.
        ("Hello world", NSRange(location: 5, length: 0), ",", "Hello, world", NSRange(location: 5, length: 1)),
        // A selection is replaced.
        ("Ship it Tuesday", NSRange(location: 8, length: 7), "Wednesday", "Ship it Wednesday", NSRange(location: 8, length: 9)),
        // An emoji before the caret counts as two UTF-16 units.
        ("👋 ", nil, "héllo 🌍", "👋 héllo 🌍", NSRange(location: 3, length: 8)),
        // Into an empty field.
        ("", nil, "First line", "First line", NSRange(location: 0, length: 10)),
    ])
    func insertsAtTheSelection(
        value: String, selection: NSRange?, text: String, expected: String, range: NSRange
    ) async throws {
        let field = FakeElement(value: value, selection: selection)
        let inserted = try await inserter.insert(text, into: Fixtures.target(field))
        #expect(inserted == range)
        #expect(field.value == expected)
    }

    @Test func succeedsWhenTheAppAppliesTheTextButReportsFailure() async throws {
        let field = FakeElement(value: "a", behaviour: .appliesButReportsFailure)
        let inserted = try await inserter.insert("b", into: Fixtures.target(field))
        #expect(inserted == NSRange(location: 1, length: 1))
        #expect(field.value == "ab")
    }

    /// Chromium-style apps report the old value right after the write and apply it a moment
    /// later; judging that as ignored would paste the text a second time.
    @Test func aWriteAppliedLateIsReadAgainAndCountsAsSuccess() async throws {
        let field = FakeElement(value: "Hello", behaviour: .appliesLate)
        let inserted = try await inserter.insert(" world", into: Fixtures.target(field))
        #expect(inserted == NSRange(location: 5, length: 6))
        #expect(field.value == "Hello world")
        #expect(field.valueWrites == 1)
    }

    @Test func waitsBeforeTheSecondReadOnlyWhenTheFieldLooksUnchanged() async throws {
        let clock = ContinuousClock()

        // Applied at once: no wait, however long the delay.
        let applied = FakeElement(value: "a")
        var start = clock.now
        _ = try await AXTextInserter(verificationDelayMs: 60_000).insert("b", into: Fixtures.target(applied))
        #expect(clock.now - start < .seconds(10))

        // Unchanged: the second read comes after the delay.
        let ignored = FakeElement(value: "a", behaviour: .ignoresWrites)
        start = clock.now
        await #expect(throws: InsertionError.writeIgnored) {
            try await AXTextInserter(verificationDelayMs: 20).insert("b", into: Fixtures.target(ignored))
        }
        #expect(clock.now - start >= .milliseconds(20))
    }

    @Test("A write that leaves the field unchanged is a safe failure", arguments: [
        (FakeElement.Behaviour.ignoresWrites, InsertionError.writeIgnored),
        (.rejectsWrites, .writeRejected),
    ])
    func unchangedFieldIsSafeToRetry(behaviour: FakeElement.Behaviour, expected: InsertionError) async {
        let field = FakeElement(value: "Hello", behaviour: behaviour)
        await #expect(throws: expected) {
            try await inserter.insert(" world", into: Fixtures.target(field))
        }
        #expect(field.value == "Hello")
        #expect(!expected.mayHaveChangedField)
    }

    /// An empty caret insert of text that already follows the caret must not pass as success when
    /// the app ignored it: the length check catches it.
    @Test func ignoredWriteIsNotMistakenForSuccessWhenTheTextAlreadyFollowsTheCaret() async {
        let field = FakeElement(value: "hello world", selection: NSRange(location: 0, length: 0), behaviour: .ignoresWrites)
        await #expect(throws: InsertionError.writeIgnored) {
            try await inserter.insert("hello", into: Fixtures.target(field))
        }
    }

    @Test("A field that changed unexpectedly is reported as possibly changed", arguments: [
        FakeElement.Behaviour.truncatesWrites,
        .valueUnreadableAfterWrite,
    ])
    func unexpectedChangeIsNotRetried(behaviour: FakeElement.Behaviour) async {
        let field = FakeElement(value: "Note: ", behaviour: behaviour)
        await #expect(throws: InsertionError.verificationFailed) {
            try await inserter.insert("buy milk", into: Fixtures.target(field))
        }
        #expect(InsertionError.verificationFailed.mayHaveChangedField)
        #expect(field.valueWrites == 1)
    }

    @Test func unreadableValueIsNotWritten() async {
        let field = FakeElement(value: nil)
        await #expect(throws: InsertionError.valueUnreadable) {
            try await inserter.insert("text", into: Fixtures.target(field))
        }
        #expect(field.valueWrites == 0)
    }

    /// Ranges come from another process. The ones near `Int.max` used to overflow the end
    /// computation and crash the app.
    @Test("A missing or impossible selection is not written", arguments: [
        nil as NSRange?,
        NSRange(location: 4, length: 3),
        NSRange(location: 6, length: 0),
        NSRange(location: NSNotFound, length: 0),
        NSRange(location: 1, length: Int.max),
        NSRange(location: Int.max - 1, length: 5),
        NSRange(location: -1, length: 2),
        NSRange(location: 2, length: -1),
    ])
    func unusableSelectionIsNotWritten(selection: NSRange?) async {
        let field = FakeElement(value: "abcde", selection: selection)
        if selection == nil { field.clearSelection() }
        await #expect(throws: InsertionError.selectionUnreadable) {
            try await inserter.insert("x", into: Fixtures.target(field))
        }
        #expect(field.valueWrites == 0)
    }

    @Test func needsAFocusedElement() async {
        await #expect(throws: InsertionError.noFocusedElement) {
            try await inserter.insert("text", into: Fixtures.target(nil))
        }
    }
}
