import AppKit
import Shared
import SwiftUI

/// Dictation setup, for its own window: microphone and Accessibility access, the fn key's
/// system setting (while fn is the hotkey), and a place to try dictating.
///
/// The steps and their state live in ``OnboardingModel``. Every step can be skipped; the menu
/// offers *Set Up Dictation…* again while a permission is missing.
public struct OnboardingView: View {
    private static let d = AppSettings.defaults

    @AppStorage(AppSettingsKey.dictationHotkey.rawValue) private var hotkey = d.dictation.hotkey
    @AppStorage(AppSettingsKey.handsFreeEnabled.rawValue) private var handsFreeEnabled = d.dictation.handsFreeEnabled
    @State private var model: OnboardingModel

    private let context: DictationUIContext
    private let onFinish: @MainActor () -> Void

    /// - Parameter onFinish: called by *Done*; the app closes the window.
    public init(context: DictationUIContext, onFinish: @escaping @MainActor () -> Void) {
        self.context = context
        self.onFinish = onFinish
        _model = State(initialValue: OnboardingModel(
            microphonePermission: context.microphonePermission,
            accessibility: context.accessibility,
            system: .live
        ))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingHeader(model: model)
            Divider()
            page
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 520)
        .onAppear { model.setHotkey(storageString: hotkey) }
        .onChange(of: hotkey) { _, newValue in model.setHotkey(storageString: newValue) }
        .task { await model.observeAccessibility() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .microphone:
            OnboardingMicrophonePage(model: model)
        case .accessibility:
            OnboardingAccessibilityPage(model: model)
        case .fnKey:
            OnboardingFnKeyPage(model: model) {
                showWindow { $0.showSettings(tab: .general) }
            }
        case .tryIt:
            OnboardingTryItPage(
                hotkeyName: model.hotkey.displayName,
                handsFreeEnabled: handsFreeEnabled,
                note: OnboardingModel.tryItNote(
                    permissionsGranted: model.isComplete(.microphone) && model.isComplete(.accessibility),
                    hotkey: context.controller.hotkeyState,
                    session: context.transcript.phase
                )
            )
        }
    }

    private var footer: some View {
        HStack {
            Text("Step \((model.steps.firstIndex(of: model.step) ?? 0) + 1) of \(model.steps.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if !model.isFirstStep {
                Button("Back", action: model.goBack)
            }
            if model.isLastStep {
                // No Return shortcut here: Return in the practice text must add a line.
                Button("Done") { onFinish() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Continue", action: model.goForward)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Runs a window action, or logs that the app never connected the windows.
    private func showWindow(_ action: (any DictationWindowActions) -> Void) {
        guard let windows = context.windows else {
            Log.ui.error("Can't show Settings from setup: no window actions are connected")
            NSSound.beep()
            return
        }
        action(windows)
    }
}

/// The title, and the steps with a checkmark on each one that needs nothing more. A step can be
/// clicked to go straight to it.
private struct OnboardingHeader: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up dictation")
                .font(.title2.bold())
            Text("Hold a key, speak, and let go: your words appear wherever you're typing.")
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                ForEach(model.steps) { step in
                    stepButton(step)
                }
            }
        }
        .padding(20)
    }

    private func stepButton(_ step: OnboardingStep) -> some View {
        let isCurrent = step == model.step
        let isComplete = model.isComplete(step)
        return Button {
            model.show(step)
        } label: {
            Label(step.title, systemImage: isComplete ? "checkmark.circle.fill" : (isCurrent ? "circle.inset.filled" : "circle"))
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(step.title), \(isComplete ? "done" : "not done")")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
