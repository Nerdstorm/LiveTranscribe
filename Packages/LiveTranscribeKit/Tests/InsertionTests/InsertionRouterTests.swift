import ApplicationServices
import Foundation
import Insertion
import Testing

@Suite("InsertionRouter")
struct InsertionRouterTests {
    /// A router over the real inserters, a fake field and a fake pasteboard whose ⌘V types into
    /// the field, as the app would.
    private struct Harness {
        let field: FakeElement
        let pasteboard: FakePasteboard
        let keystrokes: FakeKeystrokes
        /// Focus as the paste reads it just before ⌘V; in TextEdit, like the targets, until moved.
        let focus = FakeFocus()
        let router: InsertionRouter

        init(
            field: FakeElement,
            clipboard: [PasteboardSnapshot.Item] = [],
            keystrokesSucceed: Bool = true,
            overrides: InserterOverrides = .bundled
        ) {
            let pasteboard = FakePasteboard(items: clipboard)
            let keystrokes = keystrokesSucceed
                ? FakeKeystrokes.typing(into: field, from: pasteboard)
                : FakeKeystrokes(succeeds: false)
            self.field = field
            self.pasteboard = pasteboard
            self.keystrokes = keystrokes
            self.router = InsertionRouter(
                accessibility: AXTextInserter(verificationDelayMs: 0),
                paste: PasteboardTextInserter(pasteboard: pasteboard, keystrokes: keystrokes, focus: focus, restoreDelayMs: 0),
                pasteboard: pasteboard,
                overrides: overrides
            )
        }
    }

    private static let clipboard = [FakePasteboard.plainItem("user's clipboard")]

    @Test func insertsThroughAccessibilityAndReportsTheRange() async {
        let harness = Harness(field: FakeElement(value: "Dear "), clipboard: Self.clipboard)

        let result = await harness.router.insert("Sam,", into: Fixtures.target(harness.field))

        #expect(result == .inserted(.accessibility, range: NSRange(location: 5, length: 4)))
        #expect(harness.field.value == "Dear Sam,")
        #expect(harness.keystrokes.pastes == 0)
        #expect(harness.pasteboard.items == Self.clipboard)
    }

    @Test("Falls back to paste when the Accessibility write leaves the field unchanged", arguments: [
        FakeElement.Behaviour.ignoresWrites,
        .rejectsWrites,
    ])
    func fallsBackToPaste(behaviour: FakeElement.Behaviour) async {
        let harness = Harness(field: FakeElement(value: "Dear ", behaviour: behaviour), clipboard: Self.clipboard)

        let result = await harness.router.insert("Sam,", into: Fixtures.target(harness.field))

        #expect(result == .inserted(.paste, range: nil))
        #expect(harness.field.value == "Dear Sam,")
        #expect(harness.pasteboard.items == Self.clipboard)
    }

    /// An app that shows the text only after first reporting the old value must not also get it
    /// pasted: that would type it twice.
    @Test func doesNotPasteAfterAWriteThatLandsLate() async {
        let harness = Harness(field: FakeElement(value: "Dear ", behaviour: .appliesLate), clipboard: Self.clipboard)

        let result = await harness.router.insert("Sam,", into: Fixtures.target(harness.field))

        #expect(result == .inserted(.accessibility, range: NSRange(location: 5, length: 4)))
        #expect(harness.field.value == "Dear Sam,")
        #expect(harness.keystrokes.pastes == 0)
        #expect(harness.pasteboard.items == Self.clipboard)
    }

    @Test func pastesWhenTheValueIsUnreadable() async {
        let field = FakeElement(value: nil)
        let paste = FakeInserter(.success(nil))
        let router = InsertionRouter(
            accessibility: AXTextInserter(verificationDelayMs: 0), paste: paste, pasteboard: FakePasteboard(), overrides: .empty
        )

        let result = await router.insert("hello", into: Fixtures.target(field))

        #expect(result == .inserted(.paste, range: nil))
        #expect(field.valueWrites == 0)
        #expect(paste.insertedTexts == ["hello"])
    }

    /// Pasting after a write that changed the field would type the text twice.
    @Test func doesNotPasteAfterAnUnexpectedChange() async {
        let harness = Harness(field: FakeElement(value: "", behaviour: .truncatesWrites), clipboard: Self.clipboard)

        let result = await harness.router.insert("buy milk", into: Fixtures.target(harness.field))

        #expect(result == .copiedToClipboard)
        #expect(harness.keystrokes.pastes == 0)
        #expect(harness.pasteboard.string == "buy milk")
    }

    @Test("Chooses the methods for each app", arguments: [
        (Fixtures.textEdit, InserterOverrides.empty, [InsertionMethod.accessibility, .paste]),
        (Fixtures.terminal, .bundled, [.paste]),
        (Fixtures.terminal, .bundled.merged(with: InserterOverrides(methods: ["com.apple.Terminal": .accessibility])),
         [.accessibility, .paste]),
        (Fixtures.notes, InserterOverrides(methods: ["COM.APPLE.NOTES": .paste]), [.paste]),
        (AppInfo(bundleIdentifier: nil, name: "tool", processIdentifier: 7), .bundled, [.accessibility, .paste]),
    ])
    func methodOrder(app: AppInfo, overrides: InserterOverrides, expected: [InsertionMethod]) {
        let router = InsertionRouter(
            accessibility: FakeInserter(.success(nil)),
            paste: FakeInserter(.success(nil)),
            pasteboard: FakePasteboard(),
            overrides: overrides
        )
        #expect(router.methods(for: Fixtures.target(FakeElement(value: ""), app: app)) == expected)
    }

    @Test func anOverriddenAppIsPastedIntoWithoutTryingAccessibility() async {
        let accessibility = FakeInserter(.success(NSRange(location: 0, length: 2)))
        let paste = FakeInserter(.success(nil))
        let router = InsertionRouter(
            accessibility: accessibility, paste: paste, pasteboard: FakePasteboard(), overrides: .bundled
        )

        let result = await router.insert("ls", into: Fixtures.target(FakeElement(value: ""), app: Fixtures.terminal))

        #expect(result == .inserted(.paste, range: nil))
        #expect(accessibility.insertedTexts.isEmpty)
    }

    @Test func pastesWhenNothingIsFocused() async {
        let accessibility = FakeInserter(.success(nil))
        let paste = FakeInserter(.success(nil))
        let router = InsertionRouter(
            accessibility: accessibility, paste: paste, pasteboard: FakePasteboard(), overrides: .empty
        )

        #expect(await router.insert("hi", into: Fixtures.target(nil)) == .inserted(.paste, range: nil))
        #expect(accessibility.insertedTexts.isEmpty)
    }

    @Test("Refuses secure targets without typing or copying", arguments: [
        // A password field.
        InsertionTarget(
            app: Fixtures.textEdit,
            element: FakeElement(value: "", subrole: kAXSecureTextFieldSubrole),
            secureEventInputEnabled: false
        ),
        // Secure event input is on, whatever the field.
        InsertionTarget(app: Fixtures.textEdit, element: FakeElement(value: ""), secureEventInputEnabled: true),
    ])
    func refusesSecureTargets(target: InsertionTarget) async {
        let accessibility = FakeInserter(.success(nil))
        let paste = FakeInserter(.success(nil))
        let pasteboard = FakePasteboard(items: Self.clipboard)
        let router = InsertionRouter(accessibility: accessibility, paste: paste, pasteboard: pasteboard, overrides: .empty)

        #expect(await router.insert("hunter2", into: target) == .refusedSecureField)
        #expect(accessibility.insertedTexts.isEmpty)
        #expect(paste.insertedTexts.isEmpty)
        #expect(pasteboard.items == Self.clipboard)
        #expect(router.methods(for: target).isEmpty)
    }

    // MARK: - Focus moved while the dictation was processed

    /// The target was read before processing; since then the user tabbed into a password field.
    /// Paste goes to the current focus, so it is refused, and nothing is copied either.
    @Test func refusesAPasteWhenFocusBecameSecure() async {
        let harness = Harness(field: FakeElement(value: "user@"), clipboard: Self.clipboard)
        harness.focus.move(to: Fixtures.textEdit, secure: true)

        let result = await harness.router.insert("example.com", into: Fixtures.target(nil))

        #expect(result == .refusedSecureField)
        #expect(harness.keystrokes.pastes == 0)
        #expect(harness.pasteboard.changeCount == 0, "the pasteboard is untouched")
        #expect(harness.pasteboard.items == Self.clipboard)
        #expect(harness.field.value == "user@")
    }

    /// Accessibility writes to the field it was given, wherever the focus is now, so it is not
    /// affected; its fallback to paste is.
    @Test func refusesTheFallbackPasteWhenFocusBecameSecure() async {
        let harness = Harness(field: FakeElement(value: "user@", behaviour: .ignoresWrites), clipboard: Self.clipboard)
        harness.focus.move(to: Fixtures.textEdit, secure: true)

        let result = await harness.router.insert("example.com", into: Fixtures.target(harness.field))

        #expect(result == .refusedSecureField)
        #expect(harness.field.valueWrites == 1, "Accessibility was tried on the original field")
        #expect(harness.keystrokes.pastes == 0)
        #expect(harness.pasteboard.items == Self.clipboard)
    }

    @Test func accessibilityStillInsertsIntoTheOriginalFieldWhenFocusMoved() async {
        let harness = Harness(field: FakeElement(value: "Dear "), clipboard: Self.clipboard)
        harness.focus.move(to: Fixtures.textEdit, secure: true)

        let result = await harness.router.insert("Sam,", into: Fixtures.target(harness.field))

        #expect(result == .inserted(.accessibility, range: NSRange(location: 5, length: 4)))
        #expect(harness.field.value == "Dear Sam,")
        #expect(harness.focus.readCount == 0, "no paste, so no need to check the focus")
    }

    /// ⌘V would land in the other app; the text goes on the clipboard instead, as when nothing
    /// could insert it.
    @Test func leavesTheTextOnTheClipboardWhenFocusMovedToAnotherApp() async {
        let harness = Harness(field: FakeElement(value: "$ "), clipboard: Self.clipboard)
        harness.focus.move(to: Fixtures.notes)

        let result = await harness.router.insert("ls", into: Fixtures.target(harness.field, app: Fixtures.terminal))

        #expect(result == .copiedToClipboard)
        #expect(harness.keystrokes.pastes == 0)
        #expect(harness.pasteboard.items == [FakePasteboard.plainItem("ls")])
        #expect(harness.field.value == "$ ")
    }

    @Test func leavesTheTextOnTheClipboardWhenEveryMethodFails() async {
        let harness = Harness(
            field: FakeElement(value: "", behaviour: .ignoresWrites),
            clipboard: Self.clipboard,
            keystrokesSucceed: false
        )

        let result = await harness.router.insert("dictated", into: Fixtures.target(harness.field))

        #expect(result == .copiedToClipboard)
        #expect(harness.pasteboard.string == "dictated")
        // An ordinary copy: no transient markers, so clipboard managers keep it.
        #expect(harness.pasteboard.items == [FakePasteboard.plainItem("dictated")])
    }

    @Test func reportsFailureWhenEvenTheClipboardRefuses() async {
        let router = InsertionRouter(
            accessibility: FakeInserter(.failure(.writeIgnored)),
            paste: FakeInserter(.failure(.keystrokeFailed)),
            pasteboard: FakePasteboard(refusesWrites: true),
            overrides: .empty
        )
        #expect(await router.insert("dictated", into: Fixtures.target(FakeElement(value: ""))) == .failed)
    }

    @Test func emptyTextDoesNothing() async {
        let accessibility = FakeInserter(.success(nil))
        let paste = FakeInserter(.success(nil))
        let pasteboard = FakePasteboard(items: Self.clipboard)
        let router = InsertionRouter(accessibility: accessibility, paste: paste, pasteboard: pasteboard, overrides: .empty)

        #expect(await router.insert("", into: Fixtures.target(FakeElement(value: "x"))) == .nothingToInsert)
        #expect(accessibility.insertedTexts.isEmpty && paste.insertedTexts.isEmpty)
        #expect(pasteboard.changeCount == 0)
    }
}
