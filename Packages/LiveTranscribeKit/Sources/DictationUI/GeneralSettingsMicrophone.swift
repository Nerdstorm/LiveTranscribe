import Capture
import Shared
import SwiftUI
import TranscriptUI

/// The entries of the microphone picker in Settings › General.
///
/// *System Default* comes first (decision M1: it follows macOS's default input). Physical
/// microphones follow; virtual and aggregate devices only with *Show other devices* on, because
/// they often carry other apps' audio or silence. The chosen device is always listed, even when
/// it is virtual or disconnected, so the picker never shows a blank selection.
struct GeneralSettingsMicrophoneChoice: Identifiable, Equatable {
    /// The device UID, or `nil` for System Default.
    let uid: String?
    let name: String

    var id: String { uid ?? "" }

    static func choices(
        devices: [AudioInputDevice],
        selectedUID: String?,
        showVirtualDevices: Bool,
        systemDefaultName: String?
    ) -> [GeneralSettingsMicrophoneChoice] {
        var choices = [GeneralSettingsMicrophoneChoice(
            uid: nil,
            name: systemDefaultName.map { "System Default (\($0))" } ?? "System Default"
        )]
        for device in devices where !device.isVirtual || showVirtualDevices || device.id == selectedUID {
            choices.append(GeneralSettingsMicrophoneChoice(uid: device.id, name: device.name))
        }
        if let selectedUID, !devices.contains(where: { $0.id == selectedUID }) {
            choices.append(GeneralSettingsMicrophoneChoice(uid: selectedUID, name: "Disconnected microphone"))
        }
        return choices
    }
}

/// Settings › General › Microphone: keeping the microphone ready, and which one to use.
///
/// The microphone choice is the live transcript's (``TranscriptViewModel``), shared by both
/// modes; it is stored by the input selection, not through `@AppStorage`.
struct GeneralSettingsMicrophoneSection: View {
    let transcript: TranscriptViewModel

    @AppStorage(AppSettingsKey.keepMicrophoneReady.rawValue)
    private var keepMicrophoneReady = AppSettings.defaults.dictation.keepMicrophoneReady
    @AppStorage(AppSettingsKey.showVirtualInputDevices.rawValue)
    private var showVirtualInputDevices = AppSettings.defaults.dictation.showVirtualInputDevices

    var body: some View {
        Section("Microphone") {
            Picker("Microphone", selection: selection) {
                ForEach(choices) { choice in
                    Text(choice.name).tag(choice.uid)
                }
            }
            .disabled(!transcript.canChangeInputDevice)
            if let reason = disabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Show other devices", isOn: $showVirtualInputDevices)
                .help("List virtual and combined devices, such as meeting apps' audio drivers.")

            Toggle(isOn: $keepMicrophoneReady) {
                Text("Keep the microphone ready")
                Text("Dictation starts faster and keeps the moment before you press the key. The microphone indicator stays on while Live Transcribe runs.")
            }
        }
    }

    private var choices: [GeneralSettingsMicrophoneChoice] {
        GeneralSettingsMicrophoneChoice.choices(
            devices: transcript.inputDevices,
            selectedUID: transcript.selectedInputDeviceUID,
            showVirtualDevices: showVirtualInputDevices,
            systemDefaultName: transcript.systemDefaultInputName
        )
    }

    private var selection: Binding<String?> {
        Binding(get: { transcript.selectedInputDeviceUID }, set: { transcript.selectInputDevice($0) })
    }

    /// Why the picker can't be changed right now, if it can't.
    private var disabledReason: String? {
        guard !transcript.canChangeInputDevice else { return nil }
        return transcript.supportsInputSelection
            ? "Stop the live transcript to change the microphone."
            : "The microphone can't be changed in this build."
    }
}
