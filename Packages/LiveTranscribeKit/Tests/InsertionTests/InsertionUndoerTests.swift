import Foundation
import Insertion
import Testing

@Suite("InsertionUndoer")
struct InsertionUndoerTests {
    private static let cleaned = "Let's meet on Wednesday."
    private static let raw = "let's meet on um Tuesday no wait Wednesday"

    /// A field, a router over the real inserters, and keystrokes whose ⌘V and ⌘Z act on the field.
    private struct Harness {
        let field: FakeElement
        let pasteboard = FakePasteboard()
        let keystrokes: FakeKeystrokes
        /// Focus as the paste reads it just before ⌘V: in the app last dictated into.
        let focus = FakeFocus()
        let undoer: InsertionUndoer
        let router: InsertionRouter

        init(field: FakeElement, keystrokesSucceed: Bool = true, overrides: InserterOverrides = .bundled) {
            self.field = field
            keystrokes = keystrokesSucceed
                ? FakeKeystrokes.typing(into: field, from: pasteboard)
                : FakeKeystrokes(succeeds: false)
            router = InsertionRouter(
                accessibility: AXTextInserter(verificationDelayMs: 0),
                paste: PasteboardTextInserter(pasteboard: pasteboard, keystrokes: keystrokes, focus: focus, restoreDelayMs: 0),
                pasteboard: pasteboard,
                overrides: overrides
            )
            undoer = InsertionUndoer(router: router, keystrokes: keystrokes, settleDelayMs: 0)
        }

        /// Inserts the cleaned text through the router, as dictation would with `app` focused, and
        /// records it. `seenByAccessibility: false` is an app that hid the field from Accessibility then.
        func insertCleaned(app: AppInfo = Fixtures.textEdit, seenByAccessibility: Bool = true) async throws -> InsertionRecord {
            focus.move(to: app)
            let target = Fixtures.target(seenByAccessibility ? field : nil, app: app)
            let result = await router.insert(InsertionUndoerTests.cleaned, into: target)
            return try #require(InsertionRecord(
                text: InsertionUndoerTests.cleaned, result: result, target: target, insertedAt: .now
            ))
        }
    }

    @Test func replacesAnAccessibilityInsertionInPlace() async throws {
        let harness = Harness(field: FakeElement(value: "Note: "))
        let record = try await harness.insertCleaned()
        #expect(record.method == .accessibility)
        harness.field.moveCaret(to: 0)

        let result = await harness.undoer.undo(record, replacingWith: Self.raw, in: Fixtures.target(harness.field))

        #expect(result == .replacedInPlace(range: NSRange(location: 6, length: Self.raw.utf16.count)))
        #expect(result.succeeded)
        #expect(harness.field.value == "Note: " + Self.raw)
        #expect(harness.keystrokes.undos == 0)
    }

    @Test func undoesAPasteWithTheUndoShortcutThenInsertsTheRawTranscript() async throws {
        let harness = Harness(field: FakeElement(value: "$ "))
        let record = try await harness.insertCleaned(app: Fixtures.terminal)
        #expect(record.method == .paste)
        #expect(harness.field.value == "$ " + Self.cleaned)

        let result = await harness.undoer.undo(
            record, replacingWith: Self.raw, in: Fixtures.target(harness.field, app: Fixtures.terminal)
        )

        #expect(result == .undoneAndInserted(.inserted(.paste, range: nil)))
        #expect(result.succeeded)
        #expect(harness.keystrokes.undos == 1)
        #expect(harness.field.value == "$ " + Self.raw)
    }

    @Test func fallsBackToTheUndoShortcutWhenTheAppWillNotSelectTheText() async throws {
        let harness = Harness(field: FakeElement(value: "Note: ", ignoresSelectionWrites: true))
        let record = try await harness.insertCleaned()

        let result = await harness.undoer.undo(record, replacingWith: Self.raw, in: Fixtures.target(harness.field))

        #expect(result == .undoneAndInserted(.inserted(.accessibility, range: NSRange(location: 6, length: Self.raw.utf16.count))))
        #expect(harness.keystrokes.undos == 1)
        #expect(harness.field.value == "Note: " + Self.raw)
    }

    @Test func fallsBackToTheUndoShortcutWhenTheAppIgnoresTheReplacement() async throws {
        let harness = Harness(field: FakeElement(value: "Note: "))
        let record = try await harness.insertCleaned()
        harness.field.setBehaviour(.ignoresWrites)

        let result = await harness.undoer.undo(record, replacingWith: Self.raw, in: Fixtures.target(harness.field))

        // ⌘Z removed the cleaned text; the raw transcript then went in by paste.
        #expect(result == .undoneAndInserted(.inserted(.paste, range: nil)))
        #expect(harness.field.value == "Note: " + Self.raw)
    }

    @Test func replacesInPlaceWhenTheAppAppliesTheReplacementLate() async throws {
        let harness = Harness(field: FakeElement(value: "Note: "))
        let record = try await harness.insertCleaned()
        harness.field.setBehaviour(.appliesLate)

        let result = await harness.undoer.undo(record, replacingWith: Self.raw, in: Fixtures.target(harness.field))

        #expect(result == .replacedInPlace(range: NSRange(location: 6, length: Self.raw.utf16.count)))
        #expect(harness.field.value == "Note: " + Self.raw)
        #expect(harness.keystrokes.undos == 0)
        #expect(harness.keystrokes.pastes == 0)
    }

    /// Accessibility can no longer see the focused field (it timed out, say): in place cannot be
    /// checked, so the spec's ⌘Z path runs, in the same app.
    @Test func usesTheUndoShortcutWhenTheFocusedFieldIsUnknown() async throws {
        let harness = Harness(field: FakeElement(value: "Note: "))
        let record = try await harness.insertCleaned()
        #expect(record.method == .accessibility)

        let result = await harness.undoer.undo(record, replacingWith: Self.raw, in: Fixtures.target(nil))

        #expect(result == .undoneAndInserted(.inserted(.paste, range: nil)))
        #expect(harness.keystrokes.undos == 1)
        #expect(harness.field.value == "Note: " + Self.raw)
    }

    /// A range near `Int.max` (a corrupt record) used to overflow the bounds check and crash.
    @Test("An impossible recorded range is refused without crashing", arguments: [
        NSRange(location: 1, length: Int.max),
        NSRange(location: Int.max - 1, length: 5),
        NSRange(location: NSNotFound, length: 0),
    ])
    func impossibleRangeIsRefused(range: NSRange) async {
        let field = FakeElement(value: "Note: " + Self.cleaned)
        let harness = Harness(field: field)
        let record = InsertionRecord(
            text: Self.cleaned, method: .accessibility, range: range, app: Fixtures.textEdit, element: field, insertedAt: .now
        )

        let result = await harness.undoer.undo(record, replacingWith: Self.raw, in: Fixtures.target(field))

        #expect(result == .refusedFieldChanged)
        #expect(harness.keystrokes.undos == 0)
        #expect(field.value == "Note: " + Self.cleaned)
    }

    @Test func failsWhenTheReplacementGoesWrongAndTheClipboardRefusesToo() async throws {
        let field = FakeElement(value: "Note: ")
        let pasteboard = FakePasteboard(refusesWrites: true)
        let keystrokes = FakeKeystrokes()
        let router = InsertionRouter(
            accessibility: AXTextInserter(verificationDelayMs: 0),
            paste: PasteboardTextInserter(pasteboard: pasteboard, keystrokes: keystrokes, focus: FakeFocus(), restoreDelayMs: 0),
            pasteboard: pasteboard,
            overrides: .empty
        )
        let target = Fixtures.target(field)
        let inserted = await router.insert(Self.cleaned, into: target)
        let record = try #require(InsertionRecord(text: Self.cleaned, result: inserted, target: target, insertedAt: .now))
        field.setBehaviour(.truncatesWrites)

        let result = await InsertionUndoer(router: router, keystrokes: keystrokes, settleDelayMs: 0)
            .undo(record, replacingWith: Self.raw, in: target)

        #expect(result == .failed)
        #expect(keystrokes.undos == 0)
    }

    @Test("Refuses when another app is in front", arguments: [
        Fixtures.notes as AppInfo?,
        // The same app, relaunched.
        AppInfo(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit", processIdentifier: 99),
        nil,
    ])
    func refusesInAnotherApp(current: AppInfo?) async throws {
        let harness = Harness(field: FakeElement(value: "Note: "))
        let record = try await harness.insertCleaned()
        let elsewhere = FakeElement(value: "other app's text")

        let result = await harness.undoer.undo(record, replacingWith: Self.raw, in: Fixtures.target(elsewhere, app: current))

        #expect(result == .refusedDifferentApp)
        #expect(!result.succeeded)
        #expect(harness.keystrokes.undos == 0)
        #expect(elsewhere.value == "other app's text")
        #expect(harness.field.value == "Note: " + Self.cleaned)
    }

    @Test func refusesWhenTheFieldWasEditedSince() async throws {
        let harness = Harness(field: FakeElement(value: "Note: "))
        let record = try await harness.insertCleaned()
        harness.field.moveCaret(to: 0)
        harness.field.typeText("Re: ")

        let result = await harness.undoer.undo(record, replacingWith: Self.raw, in: Fixtures.target(harness.field))

        #expect(result == .refusedFieldChanged)
        #expect(harness.keystrokes.undos == 0)
        #expect(harness.field.value == "Re: Note: " + Self.cleaned)
    }

    @Test func refusesWhenFocusMovedToAnotherField() async throws {
        let harness = Harness(field: FakeElement(value: "Note: "))
        let record = try await harness.insertCleaned()
        let otherField = FakeElement(value: "Subject")

        let result = await harness.undoer.undo(record, replacingWith: Self.raw, in: Fixtures.target(otherField))

        #expect(result == .refusedFocusMoved)
        #expect(!result.succeeded)
        #expect(harness.keystrokes.undos == 0)
        #expect(otherField.value == "Subject")
    }

    /// A paste leaves no range to check, but the field is still known: ⌘Z in another field of the
    /// same app (Gmail's Subject after dictating into the body) would undo the user's typing there,
    /// and the uncleaned text would follow it in.
    @Test func refusesAPasteWhenFocusMovedToAnotherField() async throws {
        let harness = Harness(field: FakeElement(value: "$ "))
        let record = try await harness.insertCleaned(app: Fixtures.terminal)
        #expect(record.method == .paste)
        let otherField = FakeElement(value: "Subject")
        otherField.typeText(": Q3 report")

        let result = await harness.undoer.undo(
            record, replacingWith: Self.raw, in: Fixtures.target(otherField, app: Fixtures.terminal)
        )

        #expect(result == .refusedFocusMoved)
        #expect(harness.keystrokes.undos == 0)
        #expect(harness.keystrokes.pastes == 1, "only the dictation's own paste")
        #expect(otherField.value == "Subject: Q3 report")
        #expect(harness.field.value == "$ " + Self.cleaned)
    }

    /// Back in the dictated field, the refused undo works: nothing was changed by the refusal.
    @Test func undoesAPasteOnceFocusIsBackInItsField() async throws {
        let harness = Harness(field: FakeElement(value: "$ "))
        let record = try await harness.insertCleaned(app: Fixtures.terminal)
        let otherField = FakeElement(value: "Subject")
        _ = await harness.undoer.undo(record, replacingWith: Self.raw, in: Fixtures.target(otherField, app: Fixtures.terminal))

        let result = await harness.undoer.undo(
            record, replacingWith: Self.raw, in: Fixtures.target(harness.field, app: Fixtures.terminal)
        )

        #expect(result == .undoneAndInserted(.inserted(.paste, range: nil)))
        #expect(harness.field.value == "$ " + Self.raw)
    }

    /// Accessibility could not see the field at the insertion or cannot now (Electron apps that
    /// hide their fields, a lookup that timed out): the fields cannot be compared, so the same-app
    /// check is all there is, and ⌘Z runs as before.
    @Test("A paste whose field is unknown on either side is still undone", arguments: [
        (true, false), (false, true), (false, false),
    ])
    func undoesAPasteWhoseFieldCannotBeCompared(seenAtInsertion: Bool, seenNow: Bool) async throws {
        let harness = Harness(field: FakeElement(value: "$ "))
        let record = try await harness.insertCleaned(app: Fixtures.terminal, seenByAccessibility: seenAtInsertion)
        #expect(record.method == .paste)

        let result = await harness.undoer.undo(
            record, replacingWith: Self.raw, in: Fixtures.target(seenNow ? harness.field : nil, app: Fixtures.terminal)
        )

        #expect(result == .undoneAndInserted(.inserted(.paste, range: nil)))
        #expect(harness.keystrokes.undos == 1)
        #expect(harness.field.value == "$ " + Self.raw)
    }

    @Test func refusesASecureField() async throws {
        let harness = Harness(field: FakeElement(value: "$ "))
        let record = try await harness.insertCleaned(app: Fixtures.terminal)

        let result = await harness.undoer.undo(
            record, replacingWith: Self.raw, in: Fixtures.target(harness.field, app: Fixtures.terminal, isSecure: true)
        )

        #expect(result == .refusedSecureField)
        #expect(harness.keystrokes.undos == 0)
    }

    @Test func failsWithoutChangesWhenTheUndoShortcutCannotBeSent() async throws {
        let field = FakeElement(value: "$ " + Self.cleaned)
        let harness = Harness(field: field, keystrokesSucceed: false)
        let record = InsertionRecord(
            text: Self.cleaned, method: .paste, range: nil, app: Fixtures.terminal, element: field, insertedAt: .now
        )

        let result = await harness.undoer.undo(
            record, replacingWith: Self.raw, in: Fixtures.target(field, app: Fixtures.terminal)
        )

        #expect(result == .failed)
        #expect(field.value == "$ " + Self.cleaned)
        #expect(harness.pasteboard.changeCount == 0)
    }

    /// A replacement that changed the field unexpectedly must not be followed by ⌘Z, which could
    /// undo the partial replacement or something else.
    @Test func copiesTheRawTranscriptWhenTheReplacementGoesWrong() async throws {
        let harness = Harness(field: FakeElement(value: "Note: "))
        let record = try await harness.insertCleaned()
        harness.field.setBehaviour(.truncatesWrites)

        let result = await harness.undoer.undo(record, replacingWith: Self.raw, in: Fixtures.target(harness.field))

        #expect(result == .copiedToClipboard)
        #expect(harness.keystrokes.undos == 0)
        #expect(harness.pasteboard.string == Self.raw)
    }

    @Test("Only an insertion into the field leaves a record", arguments: [
        InsertionResult.copiedToClipboard(.notAccepted), .refusedSecureField, .nothingToInsert, .failed,
    ])
    func onlyInsertionsAreRecorded(result: InsertionResult) {
        #expect(InsertionRecord(text: "x", result: result, target: Fixtures.target(nil), insertedAt: .now) == nil)
    }
}
