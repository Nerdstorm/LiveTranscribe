import ApplicationServices
import Foundation
import Insertion
import Testing

@Suite("InsertionTarget")
struct InsertionTargetTests {
    @Test func aPlainTextFieldIsNeitherSecureNorMultiline() {
        let target = InsertionTarget(app: Fixtures.textEdit, element: FakeElement(value: ""), secureEventInputEnabled: false)
        #expect(!target.isSecure)
        #expect(!target.isMultiline)
        #expect(target.app == Fixtures.textEdit)
    }

    @Test func aPasswordFieldIsSecure() {
        let field = FakeElement(value: "", subrole: kAXSecureTextFieldSubrole, caretBounds: CGRect(x: 1, y: 2, width: 1, height: 16))
        let target = InsertionTarget(app: Fixtures.textEdit, element: field, secureEventInputEnabled: false)
        #expect(target.isSecure)
        // Not looked up: nothing is inserted into a secure field.
        #expect(target.caretRect == nil)
    }

    @Test func secureEventInputMakesAnyTargetSecure() {
        #expect(InsertionTarget(app: nil, element: FakeElement(value: ""), secureEventInputEnabled: true).isSecure)
        #expect(InsertionTarget(app: nil, element: nil, secureEventInputEnabled: true).isSecure)
    }

    @Test func aTextAreaIsMultiline() {
        let target = InsertionTarget(
            app: nil, element: FakeElement(value: "", role: kAXTextAreaRole), secureEventInputEnabled: false
        )
        #expect(target.isMultiline)
    }

    @Test("The caret rectangle comes from the selection's bounds", arguments: [
        (CGRect(x: 100, y: 200, width: 0, height: 18) as CGRect?, CGRect(x: 100, y: 200, width: 0, height: 18) as CGRect?),
        (nil, nil),
        // Some apps answer with an empty rectangle instead of an error.
        (.zero, nil),
        (.null, nil),
    ])
    func caretRect(bounds: CGRect?, expected: CGRect?) {
        let field = FakeElement(value: "abc", caretBounds: bounds)
        #expect(InsertionTarget(app: nil, element: field, secureEventInputEnabled: false).caretRect == expected)
    }

    @Test func noCaretWhenTheSelectionIsUnreadable() {
        let field = FakeElement(value: "abc", caretBounds: CGRect(x: 1, y: 2, width: 1, height: 16))
        field.clearSelection()
        #expect(InsertionTarget(app: nil, element: field, secureEventInputEnabled: false).caretRect == nil)
    }

    @Test func noElementMeansNoFlagsAndNoCaret() {
        let target = InsertionTarget(app: Fixtures.textEdit, element: nil, secureEventInputEnabled: false)
        #expect(target.element == nil)
        #expect(!target.isSecure && !target.isMultiline)
        #expect(target.caretRect == nil)
    }
}
