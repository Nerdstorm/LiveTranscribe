import AppKit
@testable import DictationUI
import Testing

@Suite("SettingsTab")
struct SettingsTabTests {
    @Test func everyTabHasATitleAndAnIcon() {
        for tab in SettingsTab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(!tab.systemImage.isEmpty)
        }
    }

    @Test(arguments: SettingsTab.allCases)
    func everyIconIsASymbol(_ tab: SettingsTab) {
        // A misspelt symbol leaves the tab's toolbar button without an icon.
        #expect(NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: nil) != nil)
    }
}
