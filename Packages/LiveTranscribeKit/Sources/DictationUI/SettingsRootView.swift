import SwiftUI

/// The Settings window: one tab per ``SettingsTab``. (Placeholder, replaced by the UI slice.)
public struct SettingsRootView: View {
    let context: DictationUIContext

    public init(context: DictationUIContext, selection: SettingsTab = .general) {
        self.context = context
    }

    public var body: some View {
        Text("Settings")
    }
}
