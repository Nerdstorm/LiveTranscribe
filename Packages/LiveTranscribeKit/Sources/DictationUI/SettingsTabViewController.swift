import AppKit
import Observation
import Shared
import SwiftUI

/// The Settings window's content: a toolbar button for each ``SettingsTab``, as in the Settings
/// of Apple's apps, above the chosen tab's pane.
///
/// The window takes the pane's name as its title and the pane's size (see ``SettingsPaneFrame``),
/// keeping its top-left corner in place. The chosen tab is the app's ``SettingsNavigation``, both
/// ways: clicking a button changes it, and a change from elsewhere, such as General's *Open
/// Permissions*, selects the button. Each pane is made once and kept, so switching tabs keeps its
/// state, including an open editor and its unsaved draft.
public final class SettingsTabViewController: NSTabViewController {
    private let navigation: SettingsNavigation

    /// Settings for `context`, open on `navigation`'s tab.
    public convenience init(context: DictationUIContext, navigation: SettingsNavigation) {
        self.init(navigation: navigation) { tab in
            let pane = NSHostingController(rootView: SettingsPane(tab: tab, context: context, navigation: navigation))
            // The window follows the pane's size as its content changes, such as a warning appearing.
            pane.sizingOptions = .preferredContentSize
            return pane
        }
    }

    /// - Parameter makePane: Makes the view controller for a tab's pane, once for each tab.
    init(navigation: SettingsNavigation, makePane: (SettingsTab) -> NSViewController) {
        self.navigation = navigation
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            addTabViewItem(Self.item(for: tab, pane: makePane(tab)))
        }
        select(navigation.selectedTab)
        followNavigation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsTabViewController is made in code")
    }

    /// The tab whose pane is showing.
    var selectedTab: SettingsTab? {
        selectedItem.flatMap(Self.tab(of:))
    }

    private var selectedItem: NSTabViewItem? {
        tabViewItems.indices.contains(selectedTabViewItemIndex) ? tabViewItems[selectedTabViewItemIndex] : nil
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        // The window takes this size when it is made, so it is placed at the size it shows.
        if let pane = selectedItem?.viewController {
            view.setFrameSize(pane.preferredContentSize)
        }
    }

    override public func viewWillAppear() {
        super.viewWillAppear()
        // Icons over names, centered: the toolbar of the Settings windows of Apple's apps.
        view.window?.toolbarStyle = .preference
    }

    override public func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let tab = tabViewItem.flatMap(Self.tab(of:)), tab != navigation.selectedTab else { return }
        navigation.selectedTab = tab
    }

    // MARK: - Selection

    private func select(_ tab: SettingsTab) {
        guard let index = tabViewItems.firstIndex(where: { Self.tab(of: $0) == tab }),
              index != selectedTabViewItemIndex
        else { return }
        selectedTabViewItemIndex = index
    }

    /// Selects the navigation's tab each time it changes, for as long as this controller lives.
    private func followNavigation() {
        withObservationTracking {
            _ = navigation.selectedTab
        } onChange: { [weak self] in
            // Called as the change starts; the new tab can be read once it is done.
            Task { @MainActor [weak self] in
                guard let self else { return }
                select(navigation.selectedTab)
                followNavigation()
            }
        }
    }

    // MARK: - Tabs

    private static func item(for tab: SettingsTab, pane: NSViewController) -> NSTabViewItem {
        pane.title = tab.title
        let item = NSTabViewItem(viewController: pane)
        item.identifier = tab.rawValue
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
        if item.image == nil {
            Log.ui.error("Settings tab \(tab.rawValue, privacy: .public) has no icon: no symbol \(tab.systemImage, privacy: .public)")
        }
        return item
    }

    private static func tab(of item: NSTabViewItem) -> SettingsTab? {
        (item.identifier as? String).flatMap(SettingsTab.init(rawValue:))
    }
}
