import Session
import SwiftUI

/// The app's single window: status, a start/stop button and the live transcript.
public struct TranscriptWindow: View {
    let model: TranscriptViewModel

    public init(model: TranscriptViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            StatusHeader(model: model)
            Divider()
            if model.supportsInputSelection {
                MicrophonePicker(model: model)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            banners
            Divider()
            ControlBar(model: model)
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 320, idealHeight: 520)
        .onAppear { model.attach() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .notLoaded, .loading:
            LoadingView(progress: model.modelProgress, isLoading: model.phase == .loading, onCancel: model.cancelLoading)
        case .failed(.microphonePermissionDenied):
            PermissionDeniedView(onRetry: model.toggleListening)
        case .failed(.modelLoadFailed(let modelID, let message)):
            ModelErrorView(modelID: modelID, message: message, onRetry: model.retryLoading)
        default:
            TranscriptList(lines: model.lines, isListening: model.isListening)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if case .failed(.audioCaptureFailed(let message)) = model.phase {
            Banner(systemImage: "mic.badge.xmark", text: "Audio capture stopped: \(message)", tint: .red)
        }
        if case .failed(.persistenceFailed(let message)) = model.phase {
            Banner(systemImage: "externaldrive.badge.xmark", text: "Can't save the transcript: \(message)", tint: .red)
        }
        if case .unavailable(let modelID, let message) = model.cleanup {
            Banner(
                systemImage: "wand.and.stars.inverse",
                text: "Cleanup unavailable (\(modelID)): \(message). Showing raw text.",
                tint: .orange,
                actionTitle: model.phase == .ready ? "Retry" : nil,
                action: model.retryCleanup
            )
        }
        if let warning = model.warning {
            Banner(systemImage: "exclamationmark.triangle", text: warning, tint: .orange, actionTitle: "Dismiss", action: model.dismissWarning)
        }
    }
}

private struct StatusHeader: View {
    let model: TranscriptViewModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Spacer()
            Text(cleanupLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var title: String {
        switch model.phase {
        case .notLoaded: "Not loaded"
        case .loading: "Loading models…"
        case .ready: "Ready"
        case .listening: "Listening"
        case .stopping: "Finishing…"
        case .failed(.microphonePermissionDenied): "Microphone access needed"
        case .failed(.modelLoadFailed): "Model failed to load"
        case .failed(.audioCaptureFailed): "Audio capture stopped"
        case .failed(.persistenceFailed): "Can't save transcript"
        }
    }

    private var color: Color {
        switch model.phase {
        case .listening: .red
        case .ready: .green
        case .loading, .stopping: .orange
        case .notLoaded: .gray
        case .failed: .yellow
        }
    }

    private var cleanupLabel: String {
        switch model.cleanup {
        case .available: "LLM cleanup on"
        case .pending: "LLM cleanup loading"
        case .disabled: "Raw transcript only"
        case .unavailable: "Raw only (cleanup failed)"
        }
    }
}

private struct MicrophonePicker: View {
    let model: TranscriptViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Picker("Microphone", selection: selection) {
                Text(defaultLabel).tag(String?.none)
                if model.selectedInputDeviceIsMissing, let uid = model.selectedInputDeviceUID {
                    Text("Disconnected microphone").tag(String?.some(uid))
                }
                Divider()
                ForEach(model.inputDevices) { device in
                    Text(device.name).tag(String?.some(device.id))
                }
            }
            .labelsHidden()
            .disabled(!model.canChangeInputDevice)
            .help(model.canChangeInputDevice ? "Microphone to transcribe from" : "Stop transcribing to change the microphone")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var selection: Binding<String?> {
        Binding(get: { model.selectedInputDeviceUID }, set: { model.selectInputDevice($0) })
    }

    private var defaultLabel: String {
        model.systemDefaultInputName.map { "System Default (\($0))" } ?? "System Default"
    }
}

private struct ControlBar: View {
    let model: TranscriptViewModel

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.toggleListening) {
                Label(
                    model.isListening ? "Stop" : "Start Transcribing",
                    systemImage: model.isListening ? "stop.fill" : "mic.fill"
                )
                .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isListening ? .red : .accentColor)
            .controlSize(.large)
            .disabled(!model.canToggleListening)
            .keyboardShortcut("r", modifiers: .command)

            Spacer()

            Button {
                SystemActions.copyToPasteboard(model.transcriptText)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(model.transcriptText.isEmpty)
            .help("Copy the transcript")

            if let directory = model.sessionsDirectory {
                Button {
                    SystemActions.openFolder(directory)
                } label: {
                    Label("Sessions", systemImage: "folder")
                }
                .help("Open the folder with saved sessions (JSONL)")
            }
        }
        .padding(12)
    }
}
