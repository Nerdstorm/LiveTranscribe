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
}
