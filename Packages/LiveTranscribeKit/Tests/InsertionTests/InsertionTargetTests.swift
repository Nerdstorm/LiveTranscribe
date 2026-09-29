import ApplicationServices
import Foundation
import Insertion
import Testing

@Suite("InsertionTarget")
struct InsertionTargetTests {
    @Test func aPlainTextFieldIsNotSecure() {
        let target = InsertionTarget(app: Fixtures.textEdit, element: FakeElement(value: ""), secureEventInputEnabled: false)
        #expect(!target.isSecure)
        #expect(target.app == Fixtures.textEdit)
    }

    @Test func aPasswordFieldIsSecure() {
        let field = FakeElement(value: "", subrole: kAXSecureTextFieldSubrole)
        let target = InsertionTarget(app: Fixtures.textEdit, element: field, secureEventInputEnabled: false)
        #expect(target.isSecure)
    }

    @Test func secureEventInputMakesAnyTargetSecure() {
        #expect(InsertionTarget(app: nil, element: FakeElement(value: ""), secureEventInputEnabled: true).isSecure)
        #expect(InsertionTarget(app: nil, element: nil, secureEventInputEnabled: true).isSecure)
    }

    @Test func noElementMeansNoFlags() {
        let target = InsertionTarget(app: Fixtures.textEdit, element: nil, secureEventInputEnabled: false)
        #expect(target.element == nil)
        #expect(!target.isSecure)
    }
}
