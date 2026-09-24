import ApplicationServices
import Foundation
import Insertion
import Testing

/// ``AppOverrides/allowsLineBreaks(in:)``: the app's line setting, then whether the field
/// certainly takes a single line.
@Suite("AppOverrides: line breaks")
struct AppOverridesLineBreaksTests {
    private static let slack = AppInfo(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack", processIdentifier: 45)

    /// An element with `role`, inside ancestors with `ancestors`' roles, innermost first.
    private static func field(_ role: String?, in ancestors: [String]) -> FakeElement {
        let parent = ancestors.reversed().reduce(nil as FakeElement?) { outer, role in
            FakeElement(value: nil, role: role, parent: outer)
        }
        return FakeElement(value: "", role: role, parent: parent)
    }

    private static let native = ["AXGroup", kAXWindowRole, kAXApplicationRole]
    private static let webPage = ["AXGroup", "AXGroup", "AXWebArea", "AXScrollArea", kAXWindowRole]

    private func allows(_ element: FakeElement?, app: AppInfo? = Fixtures.notes, overrides: AppOverrides = .bundled) -> Bool {
        overrides.allowsLineBreaks(in: Fixtures.target(element, app: app))
    }

    @Test func aTextAreaTakesLineBreaks() {
        #expect(allows(Self.field(kAXTextAreaRole, in: Self.native)))
    }

    @Test("A text field or combo box of the app's own takes one line", arguments: [kAXTextFieldRole, kAXComboBoxRole])
    func aNativeSingleLineFieldTakesNone(role: String) {
        #expect(!allows(Self.field(role, in: Self.native)))
    }

    /// Browsers and Electron apps report a message box the page doesn't mark multi-line as a
    /// text field.
    @Test func aTextFieldInAWebPageIsNotCertainlySingleLine() {
        #expect(allows(Self.field(kAXTextFieldRole, in: Self.webPage), app: Self.slack))
    }

    @Test("Without a field to ask, or a role, a multi-line app gets line breaks", arguments: [
        nil as FakeElement?,
        FakeElement(value: "", role: nil),
        AppOverridesLineBreaksTests.field("AXGroup", in: native),
    ])
    func unknownFieldsTakeLineBreaks(element: FakeElement?) {
        #expect(allows(element))
    }

    @Test func aTextFieldWhoseAncestorsCantBeReadIsNotCertain() {
        #expect(allows(Self.field(kAXTextFieldRole, in: [])))
        #expect(allows(Self.field(kAXTextFieldRole, in: ["AXGroup"])), "the chain ends before a window")
    }

    @Test func aTextFieldTooDeepToCheckIsNotCertain() {
        let deep = Array(repeating: "AXGroup", count: 70) + [kAXWindowRole]
        #expect(allows(Self.field(kAXTextFieldRole, in: deep)))
    }

    @Test func aSingleLineAppTakesNoneWhateverTheField() {
        #expect(!allows(Self.field(kAXTextAreaRole, in: Self.native), app: Fixtures.terminal))
        #expect(!allows(nil, app: Fixtures.terminal))
        let user = AppOverrides(lines: ["com.apple.Notes": .singleLine])
        #expect(!allows(Self.field(kAXTextAreaRole, in: Self.native), overrides: .bundled.merged(with: user)))
    }

    @Test func aMultiLineSettingUndoesTheBuiltInOneButNotASingleLineField() {
        let overrides = AppOverrides.bundled.merged(with: AppOverrides(lines: ["com.apple.Terminal": .multiLine]))
        #expect(allows(Self.field(kAXTextAreaRole, in: Self.native), app: Fixtures.terminal, overrides: overrides))
        #expect(!allows(Self.field(kAXTextFieldRole, in: Self.native), app: Fixtures.terminal, overrides: overrides))
    }
}
