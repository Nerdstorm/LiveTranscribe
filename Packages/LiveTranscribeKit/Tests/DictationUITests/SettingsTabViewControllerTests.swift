import AppKit
@testable import DictationUI
import SwiftUI
import Testing

@MainActor
@Suite("SettingsTabViewController")
struct SettingsTabViewControllerTests {
    /// Each tab's pane is a different height, so the window's size tells which one it took.
    private static func size(of tab: SettingsTab) -> CGSize {
        CGSize(width: 680, height: 200 + 40 * CGFloat(index(of: tab)))
    }

    private static func index(of tab: SettingsTab) -> Int {
        SettingsTab.allCases.firstIndex(of: tab) ?? -1
    }

    private static func pane(for tab: SettingsTab) -> NSViewController {
        let size = size(of: tab)
        let pane = NSHostingController(rootView: Color.clear.frame(width: size.width, height: size.height))
        pane.sizingOptions = .preferredContentSize
        return pane
    }

    private func makeController(_ navigation: SettingsNavigation) -> SettingsTabViewController {
        SettingsTabViewController(navigation: navigation, makePane: Self.pane(for:))
    }

    /// Waits up to a second for `condition`, for changes the controller makes on a later turn.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func aToolbarButtonForEachTabInOrder() {
        let controller = makeController(SettingsNavigation())
        #expect(controller.tabStyle == .toolbar)
        #expect(controller.tabViewItems.map(\.label) == SettingsTab.allCases.map(\.title))
        #expect(controller.tabViewItems.map { $0.viewController?.title } == SettingsTab.allCases.map(\.title))
        #expect(controller.tabViewItems.allSatisfy { $0.image != nil })
    }

    @Test(arguments: SettingsTab.allCases)
    func opensOnTheNavigationsTab(_ tab: SettingsTab) {
        // Settings reopens where it was left, not on the first button.
        let navigation = SettingsNavigation(selectedTab: tab)
        let controller = makeController(navigation)
        let window = NSWindow(contentViewController: controller)
        defer { window.close() }
        #expect(controller.selectedTab == tab)
        #expect(navigation.selectedTab == tab)
        #expect(window.title == tab.title)
    }

    @Test func clickingAButtonChangesTheNavigation() throws {
        let navigation = SettingsNavigation()
        let window = NSWindow(contentViewController: makeController(navigation))
        defer { window.close() }
        let button = try #require(window.toolbar?.items.first { $0.label == SettingsTab.apps.title })
        let action = try #require(button.action)
        #expect(NSApplication.shared.sendAction(action, to: button.target, from: button))
        #expect(navigation.selectedTab == .apps)
    }

    @Test func aChangeFromElsewhereSelectsItsButton() async {
        let navigation = SettingsNavigation()
        let controller = makeController(navigation)
        navigation.show(.permissions)
        #expect(await eventually { controller.selectedTab == .permissions })
        // Every change is followed, not only the first.
        navigation.show(.history)
        #expect(await eventually { controller.selectedTab == .history })
    }

    @Test func eachPaneIsMadeOnceAndKept() {
        var made: [SettingsTab] = []
        let navigation = SettingsNavigation()
        let controller = SettingsTabViewController(navigation: navigation) { tab in
            made.append(tab)
            return Self.pane(for: tab)
        }
        let apps = controller.tabViewItems[Self.index(of: .apps)].viewController
        controller.selectedTabViewItemIndex = Self.index(of: .apps)
        controller.selectedTabViewItemIndex = Self.index(of: .general)
        controller.selectedTabViewItemIndex = Self.index(of: .apps)
        #expect(made == SettingsTab.allCases)
        #expect(controller.tabViewItems[Self.index(of: .apps)].viewController === apps)
    }

    @Test func theWindowTakesThePanesNameAndSize() async {
        let navigation = SettingsNavigation(selectedTab: .snippets)
        let window = NSWindow(contentViewController: makeController(navigation))
        window.styleMask = [.titled, .closable]
        defer { window.close() }
        #expect(window.title == SettingsTab.snippets.title)
        #expect(window.contentLayoutRect.size == Self.size(of: .snippets))

        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        navigation.show(.advanced)
        #expect(await eventually {
            window.title == SettingsTab.advanced.title && window.contentLayoutRect.size == Self.size(of: .advanced)
        })
        #expect(NSPoint(x: window.frame.minX, y: window.frame.maxY) == topLeft)
    }

    @Test func theToolbarHasIconsOverNamesLikeApplesSettings() {
        let window = NSWindow(contentViewController: makeController(SettingsNavigation()))
        window.styleMask = [.titled, .closable]
        window.orderBack(nil)
        defer { window.close() }
        #expect(window.toolbarStyle == .preference)
    }

    @Test func aSavedFrameKeepsItsPlaceButTakesThePanesSize() async {
        // The app restores the window's saved frame, which can be from before the pane's size
        // changed, such as the narrower window before the toolbar tabs.
        let window = NSWindow(contentViewController: makeController(SettingsNavigation(selectedTab: .history)))
        window.styleMask = [.titled, .closable]
        window.setFrame(NSRect(x: 100, y: 100, width: 560, height: 700), display: false)
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.orderBack(nil)
        defer { window.close() }
        #expect(await eventually { window.contentLayoutRect.size == Self.size(of: .history) })
        #expect(NSPoint(x: window.frame.minX, y: window.frame.maxY) == topLeft)
    }
}

@MainActor
@Suite("SettingsPaneFrame")
struct SettingsPaneFrameTests {
    private func preferredSize(of view: some View) -> CGSize {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        host.view.layoutSubtreeIfNeeded()
        return host.preferredContentSize
    }

    @Test func aShortFormIsAsTallAsItsContent() {
        let form = Form { Section { Text("One") } }.formStyle(.grouped)
        let size = preferredSize(of: form.modifier(SettingsPaneFrame(isList: false)))
        #expect(size.width == SettingsPaneFrame.width)
        #expect(size.height > 0)
        #expect(size.height < SettingsPaneFrame.maxHeight)
    }

    @Test func aLongFormStopsAtTheLimitAndScrolls() {
        let form = Form { Section { ForEach(0..<100) { Text("Row \($0)") } } }.formStyle(.grouped)
        let size = preferredSize(of: form.modifier(SettingsPaneFrame(isList: false)))
        #expect(size == CGSize(width: SettingsPaneFrame.width, height: SettingsPaneFrame.maxHeight))
    }

    @Test func aListGetsTheListHeight() {
        let list = List(0..<3, id: \.self) { Text("Row \($0)") }
        let size = preferredSize(of: list.modifier(SettingsPaneFrame(isList: true)))
        #expect(size == CGSize(width: SettingsPaneFrame.width, height: SettingsPaneFrame.listHeight))
    }
}
