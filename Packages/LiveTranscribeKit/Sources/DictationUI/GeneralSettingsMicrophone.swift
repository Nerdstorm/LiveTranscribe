import Capture
import Shared
import SwiftUI
import TranscriptUI

/// Settings › General › Microphone: keeping the microphone ready, and which one to use.
///
/// The microphone choice is the live transcript's (``TranscriptViewModel``), shared by both
/// modes; it is stored by the input selection, not through `@AppStorage`. The picker lists the
/// same rows as the menu bar's and the transcript window's (``MicrophonePickerList``), grouped
/// the same way, so the three always agree.
struct GeneralSettingsMicrophoneSection: View {
    let transcript: TranscriptViewModel

    @AppStorage(AppSettingsKey.keepMicrophoneReady.rawValue)
    private var keepMicrophoneReady = AppSettings.defaults.dictation.keepMicrophoneReady
    @AppStorage(AppSettingsKey.showVirtualInputDevices.rawValue)
    private var showVirtualInputDevices = AppSettings.defaults.dictation.showVirtualInputDevices

    var body: some View {
        let list = transcript.microphoneList(showVirtualDevices: showVirtualInputDevices)
        Section("Microphone") {
            Picker("Microphone", selection: selection) {
                item(list.systemDefault)
                if !list.microphones.isEmpty {
                    Divider()
                    ForEach(list.microphones) { item($0) }
                }
                if !list.otherDevices.isEmpty {
                    Divider()
                    ForEach(list.otherDevices) { item($0) }
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

    private func item(_ row: MicrophonePickerList.Row) -> some View {
        Text(row.title).tag(row.uid)
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
