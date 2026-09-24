import SwiftUI
import TranscriptUI

/// One tab's pane in the Settings window (see ``SettingsTabViewController``).
struct SettingsPane: View {
    let tab: SettingsTab
    let context: DictationUIContext
    let navigation: SettingsNavigation

    var body: some View {
        content.modifier(SettingsPaneFrame(isList: tab.showsList))
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: GeneralSettingsView(context: context, showTab: { navigation.show($0) })
        case .snippets: SnippetsSettingsView(context: context)
        case .vocabulary: VocabularySettingsView(context: context)
        case .apps: AppOverridesSettingsView(context: context)
        case .history: HistorySettingsView(context: context)
        case .permissions: PermissionsSettingsView(context: context)
        case .advanced: SettingsView()
        }
    }
}

/// The size of a Settings pane, which the window takes while the pane is showing.
///
/// Every pane is as wide as the window. A pane is as tall as its content, up to ``maxHeight``,
/// and scrolls beyond it. A list has no natural height, so a list pane gets ``listHeight``.
struct SettingsPaneFrame: ViewModifier {
    static let width: CGFloat = 680
    /// Keeps the window, with its toolbar, clear of the Dock on a 13-inch display.
    static let maxHeight: CGFloat = 640
    /// Room for about a dozen rows under the list's explanation.
    static let listHeight: CGFloat = 540

    let isList: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: Self.width, height: isList ? Self.listHeight : nil)
            .frame(maxHeight: Self.maxHeight)
    }
}

private extension SettingsTab {
    /// Whether the tab's pane is an editable list.
    var showsList: Bool {
        switch self {
        case .snippets, .vocabulary, .apps: true
        case .general, .history, .permissions, .advanced: false
        }
    }
}
