@testable import DictationUI
import Observation
import os
import Testing

@MainActor
@Suite("SettingsNavigation")
struct SettingsNavigationTests {
    @Test func opensOnGeneralUnlessATabIsGiven() {
        #expect(SettingsNavigation().selectedTab == .general)
        #expect(SettingsNavigation(selectedTab: .history).selectedTab == .history)
    }

    @Test func askingForATabSwitchesToIt() {
        let navigation = SettingsNavigation()
        navigation.show(.history)
        #expect(navigation.selectedTab == .history)
        navigation.show(.permissions)
        #expect(navigation.selectedTab == .permissions)
    }

    @Test func noTabKeepsTheOneShowing() {
        // The menu's Settings… reopens Settings where it was left.
        let navigation = SettingsNavigation(selectedTab: .snippets)
        navigation.show(nil)
        #expect(navigation.selectedTab == .snippets)
    }

    @Test func anOpenSheetKeepsItsTab() {
        // Switching away from the tab that opened an editor can close it and lose the draft.
        let navigation = SettingsNavigation(selectedTab: .snippets)
        navigation.show(.history, sheetIsOpen: true)
        #expect(navigation.selectedTab == .snippets)
        navigation.show(.history, sheetIsOpen: false)
        #expect(navigation.selectedTab == .history)
    }

    @Test func aSwitchIsSeenByTheToolbar() {
        // The Settings toolbar follows the selection through Observation, so a change must be observed.
        let navigation = SettingsNavigation()
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = navigation.selectedTab } onChange: { changed.withLock { $0 = true } }
        navigation.show(.vocabulary)
        #expect(changed.withLock { $0 })
    }
}
