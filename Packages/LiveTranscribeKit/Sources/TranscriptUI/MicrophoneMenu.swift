import Capture
import Shared
import SwiftUI

/// The items of a microphone menu: System Default, the microphones, other devices, and
/// *Show Other Devices*.
///
/// The menu bar's *Microphone* submenu and the live transcript window's microphone menu both
/// show these, so they list the same rows (``MicrophonePickerList``) the same way. Each row is a
/// checkable item; choosing the one already checked keeps it, like a radio group.
public struct MicrophoneMenuItems: View {
    let model: TranscriptViewModel
    /// The `showVirtualInputDevices` setting.
    @Binding var showOtherDevices: Bool

    public init(model: TranscriptViewModel, showOtherDevices: Binding<Bool>) {
        self.model = model
        _showOtherDevices = showOtherDevices
    }

    public var body: some View {
        let list = model.microphoneList(showVirtualDevices: showOtherDevices)
        item(list.systemDefault)
        if !list.microphones.isEmpty {
            Divider()
            ForEach(list.microphones) { item($0) }
        }
        if !list.otherDevices.isEmpty {
            Divider()
            ForEach(list.otherDevices) { item($0) }
        }
        Divider()
        Toggle("Show Other Devices", isOn: $showOtherDevices)
    }

    private func item(_ row: MicrophonePickerList.Row) -> some View {
        Toggle(row.title, isOn: Binding(
            get: { row.isSelected },
            set: { _ in model.selectInputDevice(row.uid) }
        ))
    }
}

/// The transcript window's microphone menu. It shows the chosen row and opens the same items as
/// the menu bar's *Microphone* submenu, reading *Show Other Devices* the same way.
///
/// Locked while transcribing, because the microphone is fixed for a session.
struct MicrophonePicker: View {
    let model: TranscriptViewModel

    @AppStorage(AppSettingsKey.showVirtualInputDevices.rawValue)
    private var showOtherDevices = AppSettings.defaults.dictation.showVirtualInputDevices

    var body: some View {
        let selected = model.microphoneList(showVirtualDevices: showOtherDevices).selectedRow
        HStack(spacing: 8) {
            Image(systemName: "mic")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Menu {
                MicrophoneMenuItems(model: model, showOtherDevices: $showOtherDevices)
            } label: {
                Text(selected.title)
            }
            .accessibilityLabel("Microphone")
            .accessibilityValue(selected.title)
            .disabled(!model.canChangeInputDevice)
            .help(model.canChangeInputDevice ? "Microphone to transcribe from" : "Stop transcribing to change the microphone")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
