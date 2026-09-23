import AppKit
import SwiftUI

/// The frame every editable Settings list shares: an explanation, notices about the file, and
/// the list itself once its file has been read.
///
/// While the file is being read for the first time it shows a spinner; when it can't be read it
/// shows the store's message with Retry instead of the list, so nothing can be changed.
struct EditableListPane<Content: View>: View {
    private let explanation: String
    private let status: EditableListStatus
    private let retry: () async -> Void
    private let content: Content

    /// - Parameters:
    ///   - explanation: What the list is for, shown above it.
    ///   - status: The list's file state and errors.
    ///   - retry: Reads the file again, for the Retry button.
    ///   - content: The list and its buttons, shown once the file has been read.
    init(
        explanation: String,
        status: EditableListStatus,
        retry: @escaping () async -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.explanation = explanation
        self.status = status
        self.retry = retry
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = status.recoveryMessage, let backup = status.recoveredBackup {
                EditableListBanner(message: message, systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([backup])
                    }
                    EditableListDismissButton(action: status.dismissRecoveryNotice)
                }
            }
            if let message = status.errorMessage {
                EditableListBanner(message: message, systemImage: "xmark.octagon.fill", tint: .red) {
                    EditableListDismissButton(action: status.dismissError)
                }
            }

            switch status.loadState {
            case .loading:
                ProgressView("Loading\u{2026}")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { Task { await retry() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                content
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: status.errorMessage) { _, message in
            if let message { EditableListAnnouncer.announce(message) }
        }
        .onChange(of: status.recoveryMessage) { _, message in
            if let message { EditableListAnnouncer.announce(message) }
        }
        .onChange(of: status.loadState) { _, state in
            if case .failed(let message) = state { EditableListAnnouncer.announce(message) }
        }
    }
}

/// A one-line notice above a list: a damaged file set aside, or a change that wasn't saved.
struct EditableListBanner<Actions: View>: View {
    let message: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            actions()
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

/// The small close button on an ``EditableListBanner``.
struct EditableListDismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}

/// Reads a status change aloud for VoiceOver users, who would otherwise not notice a notice
/// appearing above the list they are working in.
@MainActor
enum EditableListAnnouncer {
    static func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}
