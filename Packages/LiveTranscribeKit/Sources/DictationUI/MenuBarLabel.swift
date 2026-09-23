import SwiftUI

/// The menu bar icon, reflecting dictation state. (Placeholder, replaced by the UI slice.)
public struct MenuBarLabel: View {
    let context: DictationUIContext

    public init(context: DictationUIContext) { self.context = context }

    public var body: some View {
        Image(systemName: "waveform")
    }
}
