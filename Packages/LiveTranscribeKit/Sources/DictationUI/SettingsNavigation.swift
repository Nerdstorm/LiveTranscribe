import Observation
import Shared

/// Which Settings tab is showing.
///
/// The app keeps one for the Settings window, and the window's tab view is bound to it. Asking
/// for a tab from elsewhere (History's *History Settings…*, setup's *Choose Another Shortcut…*,
/// General's *Open Permissions*) changes only the selection. The window keeps its view, and with
/// it every tab's state, including an editor sheet and its unsaved draft.
@MainActor
@Observable
public final class SettingsNavigation {
    /// The tab the window shows. It outlives the window, so Settings reopens where it was left.
    public var selectedTab: SettingsTab

    public init(selectedTab: SettingsTab = .general) {
        self.selectedTab = selectedTab
    }

    /// Switches to `tab`; `nil` keeps the tab that is showing.
    ///
    /// - Parameter sheetIsOpen: the Settings window shows a sheet (an editor, or a confirmation).
    ///   The tab then stays as it is, because switching away from the tab that opened the sheet
    ///   can close it and lose what was typed. The window still comes forward, showing it.
    public func show(_ tab: SettingsTab?, sheetIsOpen: Bool = false) {
        guard let tab, tab != selectedTab else { return }
        guard !sheetIsOpen else {
            Log.ui.info(
                "Settings stays on \(self.selectedTab.rawValue, privacy: .public), not \(tab.rawValue, privacy: .public): a sheet is open"
            )
            return
        }
        selectedTab = tab
    }
}
