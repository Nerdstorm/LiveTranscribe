import AppKit
import Dictation
import Hotkey
import SwiftUI

/// A shortcut field: shows the current shortcut, records a new one when clicked, and resets to
/// the default. The value is a ``HotkeyBinding/storageString`` binding, normally `@AppStorage`.
///
/// Only one recorder in a window records at a time: they share `activeRecorder`, and starting
/// one cancels the other. Recording also stops when its window loses focus or closes, when the
/// app loses focus, or when the view goes away, so the key monitor never outlives it.
///
/// While recording, the app's global shortcuts are paused through `suspendHotkeys`, and they
/// resume however recording ends (see ``HotkeyRecorderEventMonitor``).
struct HotkeyRecorderView: View {
    /// Names this recorder in `activeRecorder`; also its accessibility label ("Dictation shortcut").
    let title: String
    @Binding var storage: String
    let defaultBinding: HotkeyBinding
    /// Read when recording starts, so a change to the other shortcut is always taken into account.
    let configuration: HotkeyRecorderModel.Configuration
    @Binding var activeRecorder: String?
    /// Pauses the global shortcuts, normally ``DictationController/suspendHotkeys()``.
    let suspendHotkeys: @MainActor () -> HotkeySuspension

    @State private var model: HotkeyRecorderModel
    @State private var monitor = HotkeyRecorderEventMonitor()

    init(
        title: String,
        storage: Binding<String>,
        defaultBinding: HotkeyBinding,
        configuration: HotkeyRecorderModel.Configuration,
        activeRecorder: Binding<String?>,
        suspendHotkeys: @escaping @MainActor () -> HotkeySuspension
    ) {
        self.title = title
        _storage = storage
        self.defaultBinding = defaultBinding
        self.configuration = configuration
        _activeRecorder = activeRecorder
        self.suspendHotkeys = suspendHotkeys
        _model = State(initialValue: HotkeyRecorderModel(configuration: configuration))
    }

    private var current: HotkeyBinding {
        HotkeyRecorderModel.binding(storage: storage, fallback: defaultBinding)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    Text(buttonTitle)
                        .frame(minWidth: 150)
                        .foregroundStyle(model.isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .help(model.isRecording ? "Press the new shortcut, or esc to cancel" : "Click to record a new shortcut")
                .accessibilityLabel(title)
                .accessibilityValue(model.isRecording ? "Recording. Press the new shortcut, or escape to cancel" : current.displayName)

                Button("Reset") { reset() }
                    .disabled(current == defaultBinding && !model.isRecording)
                    .help("Use \(defaultBinding.displayName)")
                    .accessibilityLabel("Reset \(title.lowercased())")
            }
            if let problem = model.problem {
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: activeRecorder) { _, active in
            if active != title { stopRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
        .onDisappear { stopRecording() }
    }

    private var buttonTitle: String {
        guard model.isRecording else { return current.displayName }
        return model.heldModifiersDisplay.isEmpty ? "Type a shortcut…" : model.heldModifiersDisplay + "…"
    }

    // MARK: - Recording

    private func toggleRecording() {
        model.isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        model = HotkeyRecorderModel(configuration: configuration)
        model.start()
        activeRecorder = title
        // The window being clicked is key, so it is the recorder's own. The shortcuts are paused
        // before the first key can arrive, and the monitor resumes them when it stops.
        monitor.start(window: NSApp.keyWindow, suspension: suspendHotkeys()) { event in
            let swallow = model.swallows(event)
            let problemBefore = model.problem
            handle(model.handle(event), problemBefore: problemBefore)
            return swallow
        } onInterrupted: {
            // The window closed or another took focus: the monitor has already stopped.
            model.cancel()
            endRecording()
        }
        SettingsRootAnnouncer.announce("Recording \(title.lowercased()). Press the new shortcut, or escape to cancel.")
    }

    /// Stores a recorded shortcut, and tells VoiceOver users what happened. A problem is read
    /// once, not again for every modifier change while it stays the same.
    private func handle(_ outcome: HotkeyRecorderModel.Outcome, problemBefore: HotkeyRecorderModel.Problem?) {
        switch outcome {
        case .recorded(let binding):
            storage = binding.storageString
            endRecording()
            SettingsRootAnnouncer.announce("\(title) set to \(binding.displayName)")
        case .cancelled:
            endRecording()
            SettingsRootAnnouncer.announce("Recording cancelled")
        case .updated:
            if let problem = model.problem, problem != problemBefore {
                SettingsRootAnnouncer.announce(problem.message)
            }
        case .ignored:
            break
        }
    }

    /// Cancels a recording in progress, if any, and removes the key monitor.
    private func stopRecording() {
        model.cancel()
        endRecording()
    }

    /// Every way recording ends comes here or through the monitor's own interruption, both of
    /// which stop the monitor and so resume the global shortcuts.
    private func endRecording() {
        monitor.stop()
        if activeRecorder == title { activeRecorder = nil }
    }

    /// Restores the default, unless the other shortcut already uses it, which the model explains.
    private func reset() {
        endRecording()
        model = HotkeyRecorderModel(configuration: configuration)
        guard let binding = model.reset(to: defaultBinding) else {
            if let problem = model.problem { SettingsRootAnnouncer.announce(problem.message) }
            return
        }
        storage = binding.storageString
        SettingsRootAnnouncer.announce("\(title) set to \(binding.displayName)")
    }
}
