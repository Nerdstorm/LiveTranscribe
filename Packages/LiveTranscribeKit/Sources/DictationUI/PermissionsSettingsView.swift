import AppKit
import Dictation
import Permissions
import SwiftUI

/// Settings › Permissions: Microphone and Accessibility with their live status and a way to
/// grant each, and whether the dictation shortcut is working.
struct PermissionsSettingsView: View {
    let context: DictationUIContext
    @State private var model: PermissionsSettingsModel

    init(context: DictationUIContext) {
        self.context = context
        _model = State(initialValue: PermissionsSettingsModel(
            microphonePermission: context.microphonePermission,
            accessibility: context.accessibility
        ))
    }

    var body: some View {
        Form {
            Section {
                ForEach(RequiredPermission.allCases) { permission in
                    PermissionsSettingsRow(permission: permission, model: model)
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("Accessibility is needed for the dictation shortcut and for typing into other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Dictation shortcut") {
                let status = PermissionsSettingsShortcutStatus(context.controller.hotkeyState)
                Label {
                    Text(status.message)
                } icon: {
                    Image(systemName: status.isProblem ? "exclamationmark.triangle.fill" : "keyboard")
                        .foregroundStyle(status.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Dictation shortcut: \(status.message)")
                .onChange(of: status) { _, new in SettingsRootAnnouncer.announce("Dictation shortcut: \(new.message)") }
            }
        }
        .formStyle(.grouped)
        .task { await model.followAccessibility() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshMicrophone()
        }
    }
}

/// One permission: its name, why it's needed, whether it's granted, and the button to grant it.
private struct PermissionsSettingsRow: View {
    let permission: RequiredPermission
    let model: PermissionsSettingsModel

    var body: some View {
        let granted = model.isGranted(permission)
        let status = model.statusText(permission)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.headline)
                    Text(status).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(permission.title): \(status)")
                Text(permission.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if permission == .accessibility, !granted {
                    Text("If Live Transcribe is already switched on there, remove it with −, then add it again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let action = model.action(for: permission) {
                Button(title(for: action)) {
                    Task { await model.perform(action, for: permission) }
                }
                .accessibilityLabel(accessibilityTitle(for: action))
            }
        }
        .onChange(of: granted) { _, nowGranted in
            SettingsRootAnnouncer.announce("\(permission.title) \(nowGranted ? "allowed" : "not allowed")")
        }
    }

    private func title(for action: PermissionsSettingsModel.Action) -> String {
        switch action {
        case .request: permission == .microphone ? "Allow…" : "Grant Access…"
        case .openSettings: "Open System Settings"
        }
    }

    private func accessibilityTitle(for action: PermissionsSettingsModel.Action) -> String {
        switch action {
        case .request: "Allow \(permission.title.lowercased()) access"
        case .openSettings: "Open System Settings for \(permission.title.lowercased())"
        }
    }
}
