import SwiftUI

/// The menu bar icon: an SF Symbol for the dictation state (ready, listening, transcribing,
/// loading models, or needing attention), with a VoiceOver label that says the same.
///
/// The symbol is left unstyled so the menu bar draws it as a template image, matching the
/// system's icons in light and dark menu bars.
///
/// It is a `Label` shown icon-only, like the label `MenuBarExtra(_:systemImage:)` makes, whose
/// title the system uses for accessibility: the menu bar shows only the symbol and VoiceOver
/// reads the title.
public struct MenuBarLabel: View {
    let context: DictationUIContext

    public init(context: DictationUIContext) {
        self.context = context
    }

    public var body: some View {
        // Download progress changes the status line, not the icon, so the label leaves it out
        // rather than redrawing on every progress update.
        let indicator = MenuBarStatus.indicator(
            phase: context.controller.phase,
            hotkey: context.controller.hotkeyState,
            session: context.transcript.phase,
            modelProgress: [],
            microphone: context.microphonePermission.status()
        )
        Label(indicator.accessibilityLabel, systemImage: indicator.symbolName)
            .labelStyle(.iconOnly)
    }
}
