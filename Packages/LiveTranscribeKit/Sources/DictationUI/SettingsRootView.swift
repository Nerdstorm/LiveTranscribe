import SwiftUI
import TranscriptUI

/// The Settings window: one tab per ``SettingsTab``, in display order.
///
/// The selected tab is ``SettingsNavigation/selectedTab``, so the app switches the tab of a
/// window that is already open by changing the navigation, never by replacing this view; tabs can
/// also switch each other, such as General's link to Permissions.
public struct SettingsRootView: View {
    /// Fixed width, so the window doesn't jump when switching tabs.
    private static let width: CGFloat = 560

    let context: DictationUIContext
    @Bindable private var navigation: SettingsNavigation

    public init(context: DictationUIContext, navigation: SettingsNavigation) {
        self.context = context
        self.navigation = navigation
    }

    public var body: some View {
        TabView(selection: $navigation.selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .frame(width: Self.width)
        .frame(minHeight: 460, idealHeight: 600)
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
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
