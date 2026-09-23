import Hotkey
import Permissions
import SwiftUI

/// The layout every setup step shares: an icon, a title, why it matters, where it stands, and
/// what to do about it.
private struct OnboardingPage<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    /// Where the step stands; `nil` for a step with nothing to check.
    var status: (text: String, isDone: Bool)?
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status {
                    Label(status.text, systemImage: status.isDone ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(status.isDone ? .green : .orange)
                }
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Microphone access: the system prompt the first time, System Settings once refused.
struct OnboardingMicrophonePage: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingPage(
            systemImage: "mic",
            title: "Microphone",
            message: RequiredPermission.microphone.reason,
            status: status
        ) {
            switch model.microphone {
            case .granted:
                EmptyView()
            case .undetermined:
                Button("Allow Microphone Access") {
                    Task { await model.requestMicrophone() }
                }
                .disabled(model.isRequestingMicrophone)
            case .denied:
                Text("Turn on Live Transcribe in Privacy & Security › Microphone.")
                    .font(.callout)
                Button("Open System Settings", action: model.openMicrophoneSettings)
            }
            OnboardingErrorMessage(message: model.errorMessage)
        }
    }

    private var status: (text: String, isDone: Bool) {
        switch model.microphone {
        case .granted: ("Microphone access is on", true)
        case .undetermined: ("Not allowed yet", false)
        case .denied: ("Microphone access is off", false)
        }
    }
}

/// Accessibility access, which updates as soon as the user switches it on in System Settings.
struct OnboardingAccessibilityPage: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingPage(
            systemImage: "hand.raised",
            title: "Accessibility",
            message: RequiredPermission.accessibility.reason,
            status: status
        ) {
            if model.needsReopen {
                OnboardingReopenPrompt(reopen: model.reopen)
            } else if !model.accessibilityGranted {
                Button("Grant Access…", action: model.grantAccessibility)
                if model.hasAskedForAccessibility {
                    Text("Turn on Live Transcribe in the list. If it's already on, select it, remove it with −, then add it again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            OnboardingErrorMessage(message: model.errorMessage)
        }
    }

    private var status: (text: String, isDone: Bool) {
        if model.needsReopen {
            (OnboardingModel.reopenStatus, false)
        } else if model.accessibilityGranted {
            ("Accessibility access is on", true)
        } else {
            ("Not allowed yet", false)
        }
    }
}

/// Why the app must reopen before it can paste, and the button that reopens it.
private struct OnboardingReopenPrompt: View {
    let reopen: @MainActor () -> Void

    var body: some View {
        Text(PermissionsSettingsModel.reopenHint)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Button("Reopen Live Transcribe", action: reopen)
    }
}

/// The fn key: macOS must be set to do nothing with it, or holding it also switches the input
/// source, opens the emoji picker or starts Apple's dictation.
struct OnboardingFnKeyPage: View {
    let model: OnboardingModel
    let chooseAnotherShortcut: () -> Void

    var body: some View {
        let usage = model.fnUsage
        OnboardingPage(
            systemImage: "globe",
            title: "The fn key",
            message: usage.conflictsWithFnHotkey
                ? "macOS may also act on fn: holding it to dictate could switch the input source, show emoji or "
                    + "start Apple's dictation as well. To stop that, set \(usage.fixHint)."
                : "macOS leaves the fn key alone, so holding it only dictates.",
            status: usage.conflictsWithFnHotkey
                ? (OnboardingModel.fnKeyConflictStatus, false)
                : (OnboardingModel.fnKeyReadyStatus, true)
        ) {
            if usage.conflictsWithFnHotkey {
                HStack {
                    Button("Open Keyboard Settings", action: model.openKeyboardSettings)
                    Button("Check Again", action: model.checkFnKey)
                }
            }
            OnboardingErrorMessage(message: model.errorMessage)
            Button("Choose Another Shortcut…", action: chooseAnotherShortcut)
                .buttonStyle(.link)
        }
    }
}

/// Something the user asked for on this page failed, and what to do instead.
private struct OnboardingErrorMessage: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A place to dictate into, with the hotkey's instructions.
struct OnboardingTryItPage: View {
    let hotkeyName: String
    let handsFreeEnabled: Bool
    /// Why dictating might not work yet, from ``OnboardingModel/tryItNote(permissionsGranted:hotkey:session:)``.
    let note: String?
    /// Reopens the app while it can't paste into other apps (``OnboardingModel/needsReopen``);
    /// `nil` when it can.
    let reopen: (@MainActor () -> Void)?
    /// Reopening failed, and what to do instead.
    let errorMessage: String?
    @State private var practiceText = ""

    var body: some View {
        OnboardingPage(systemImage: "text.cursor", title: "Try it", message: instructions) {
            TextEditor(text: $practiceText)
                .font(.body)
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .accessibilityLabel("Practice text")
            if let note {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reopen {
                OnboardingReopenPrompt(reopen: reopen)
            }
            OnboardingErrorMessage(message: errorMessage)
        }
    }

    private var instructions: String {
        let hold = "Click in the box, hold \(hotkeyName), say a sentence, then let go."
        guard handsFreeEnabled else { return hold }
        return hold + " To talk without holding it, double-tap \(hotkeyName), then tap it once more to finish."
    }
}
