import Foundation
import Hotkey
import Testing

@Suite("FnKeyUsage")
struct FnKeyUsageTests {
    @Test("Reads stored numbers", arguments: [
        (0, FnKeyUsage.doNothing), (1, .changeInputSource), (2, .showEmojiAndSymbols), (3, .startDictation),
    ])
    func readsStoredNumbers(stored: Int, expected: FnKeyUsage) {
        #expect(FnKeyUsage(preferenceValue: NSNumber(value: stored)) == expected)
        #expect(FnKeyUsage(preferenceValue: String(stored)) == expected)
    }

    @Test func aMissingValueIsTheUnsetDefault() {
        #expect(FnKeyUsage(preferenceValue: nil) == FnKeyUsage.unsetDefault)
    }

    @Test("Unreadable or unknown values count as a conflict", arguments: [
        NSNumber(value: 9), NSNumber(value: -1), "emoji", Date(), [1, 2],
    ] as [any Sendable])
    func unknownValuesConflict(value: any Sendable) {
        let usage = FnKeyUsage(preferenceValue: value)
        #expect(usage == FnKeyUsage.unsetDefault)
        #expect(usage.conflictsWithFnHotkey)
    }

    @Test func onlyDoNothingLeavesFnFree() {
        #expect(FnKeyUsage.allCases.filter { !$0.conflictsWithFnHotkey } == [.doNothing])
        #expect(FnKeyUsage.unsetDefault.conflictsWithFnHotkey, "an unchanged Mac gets the warning")
    }

    @Test func fixHintNamesTheSetting() {
        #expect(FnKeyUsage.startDictation.fixHint == "System Settings › Keyboard › Press \u{1F310} key to: Do Nothing")
    }

    @Test func displayNamesMatchSystemSettings() {
        #expect(FnKeyUsage.allCases.map(\.displayName) == [
            "Do Nothing", "Change Input Source", "Show Emoji & Symbols", "Start Dictation",
        ])
    }

    @Test func currentReadsWithoutFailing() {
        // The value depends on this Mac; reading it must simply produce one of the cases.
        #expect(FnKeyUsage.allCases.contains(FnKeyUsage.current()))
    }
}
