import Shared
import SwiftUI

struct LoadingView: View {
    let progress: [ModelLoadProgress]
    let isLoading: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(isLoading ? "Preparing on-device models" : "Models are not loaded")
                .font(.headline)
            Text("The first launch downloads the models (about 3.5 GB with the defaults). Everything runs locally after that.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ForEach(progress, id: \.modelID) { item in
                ModelProgressRow(progress: item)
            }
            if isLoading {
                Button("Cancel", action: onCancel)
            }
        }
        .padding(24)
        .frame(maxWidth: 400)
    }
}

private struct ModelProgressRow: View {
    let progress: ModelLoadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(progress.modelID.split(separator: "/").last.map(String.init) ?? progress.modelID)
                    .font(.callout.monospaced())
                Spacer()
                Text(stageLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let fraction = progress.fractionCompleted, progress.stage == .downloading {
                ProgressView(value: fraction)
            } else if progress.stage == .ready {
                ProgressView(value: 1)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
    }

    private var stageLabel: String {
        switch progress.stage {
        case .downloading:
            progress.fractionCompleted.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading"
        case .loading: "Loading"
        case .warmingUp: "Warming up"
        case .ready: "Ready"
        }
    }
}

struct PermissionDeniedView: View {
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Microphone access is off", systemImage: "mic.slash")
        } description: {
            Text("Live Transcribe needs the microphone to transcribe your speech. Audio never leaves this Mac.")
        } actions: {
            Button("Open System Settings", action: SystemActions.openMicrophoneSettings)
                .buttonStyle(.borderedProminent)
            Button("Try Again", action: onRetry)
        }
    }
}

struct ModelErrorView: View {
    let modelID: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load \(modelID)", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
    }
}

struct Banner: View {
    let systemImage: String
    let text: String
    let tint: Color
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1))
    }
}
