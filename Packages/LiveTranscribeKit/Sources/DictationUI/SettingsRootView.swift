import SwiftUI
import TranscriptUI

/// The Settings window: one tab per ``SettingsTab``, in display order.
///
/// Opens on `selection`. Passing a different `selection` to a window that is already open
/// (by replacing its root view) switches to that tab; tabs can also switch each other, such as
/// General's link to Permissions.
public struct SettingsRootView: View {
    /// Fixed width, so the window doesn't jump when switching tabs.
    private static let width: CGFloat = 560

    let context: DictationUIContext
    /// The tab the app asked for.
    private let requestedTab: SettingsTab
    @State private var selection: SettingsTab

    public init(context: DictationUIContext, selection: SettingsTab = .general) {
        self.context = context
        requestedTab = selection
        _selection = State(initialValue: selection)
    }

    public var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsTab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .frame(width: Self.width)
        .frame(minHeight: 460, idealHeight: 600)
        .onChange(of: requestedTab) { _, tab in selection = tab }
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView(context: context, showTab: { selection = $0 })
        case .snippets: SnippetsSettingsView(context: context)
        case .vocabulary: VocabularySettingsView(context: context)
        case .apps: AppOverridesSettingsView(context: context)
        case .history: HistorySettingsView(context: context)
        case .permissions: PermissionsSettingsView(context: context)
        case .advanced: SettingsView()
        }
    }
}
