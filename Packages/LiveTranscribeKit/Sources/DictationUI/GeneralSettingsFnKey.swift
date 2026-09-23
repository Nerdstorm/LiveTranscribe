import AppKit
import Hotkey
import Observation
import Shared
import SwiftUI

/// Whether macOS also acts on the fn (globe) key, which clashes with fn as the dictation
/// shortcut (docs/dictation.md, "Hotkey gestures"). Re-read whenever the app becomes active,
/// so the warning clears as soon as the user changes the setting in System Settings.
@MainActor
@Observable
final class GeneralSettingsFnKeyModel {
    /// System Settings › Keyboard, where "Press 🌐 key to" lives.
    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    private(set) var usage: FnKeyUsage
    /// Set when System Settings could not be opened.
    private(set) var errorMessage: String?

    @ObservationIgnored private let readUsage: @MainActor () -> FnKeyUsage
    @ObservationIgnored private let openURL: @MainActor (URL) -> Bool

    /// - Parameters:
    ///   - readUsage: Reads the current macOS setting; tests pass a fake.
    ///   - openURL: Opens a System Settings link and reports whether it worked.
    init(
        readUsage: @escaping @MainActor () -> FnKeyUsage = { FnKeyUsage.current() },
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.readUsage = readUsage
        self.openURL = openURL
        usage = readUsage()
    }

    /// Reads the macOS setting again.
    func refresh() {
        let latest = readUsage()
        if latest != usage {
            Log.ui.info("fn key setting is now \(latest.displayName, privacy: .public)")
        }
        usage = latest
    }

    /// Whether to warn for the stored dictation shortcut: it is fn, and macOS also uses fn.
    func showsWarning(forStoredHotkey storage: String) -> Bool {
        let binding = HotkeyRecorderModel.binding(storage: storage, fallback: .defaultDictation)
        return binding == .modifierKey(.fn) && usage.conflictsWithFnHotkey
    }

    /// The warning's text: what macOS does with fn now, and where to change it.
    var warningMessage: String {
        let action = switch usage {
        case .doNothing: "act on it"
        case .changeInputSource: "change the input source"
        case .showEmojiAndSymbols: "show emoji and symbols"
        case .startDictation: "start its own dictation"
        }
        return "Pressing fn also makes macOS \(action). To dictate with fn, set \(usage.fixHint)."
    }

    func openKeyboardSettings() {
        errorMessage = nil
        guard let url = Self.keyboardSettingsURL, openURL(url) else {
            Log.ui.error("Could not open Keyboard settings")
            errorMessage = "Couldn't open System Settings. Open it from the Apple menu, then choose Keyboard."
            return
        }
    }
}

/// The fn-key clash warning under the dictation shortcut, with a link to the fix.
struct GeneralSettingsFnKeyWarning: View {
    let model: GeneralSettingsFnKeyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(model.warningMessage)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Warning: \(model.warningMessage)")

            HStack {
                Spacer()
                Button("Open Keyboard Settings") { model.openKeyboardSettings() }
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
    }
}
