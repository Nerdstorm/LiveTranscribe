import Capture
import Dictation
import Observation
import Permissions
import Shared

/// The live state of the permissions dictation needs, for Settings › Permissions.
///
/// Accessibility is followed through ``AccessibilityPermissionProviding/changes()``; the
/// microphone has no change notification, so the view calls ``refreshMicrophone()`` whenever
/// the app becomes active (the user is back from System Settings).
@MainActor
@Observable
final class PermissionsSettingsModel {
    /// What a permission row's button does.
    enum Action: Equatable {
        /// Shows the system prompt (microphone), or the system alert that offers to open
        /// System Settings (Accessibility, which macOS shows at most once per launch).
        case request
        /// Opens the permission's pane in System Settings.
        case openSettings
    }

    private(set) var microphone: MicrophonePermissionStatus
    private(set) var accessibilityGranted: Bool
    /// Whether this launch already asked for Accessibility, here or in setup. After that the
    /// prompt shows nothing more, so the button opens System Settings instead. Read from the
    /// shared memory, so a prompt shown while this window is open counts too.
    var accessibilityPrompted: Bool { promptMemory.accessibilityPrompted }
    /// System Settings could not be opened; says where to go by hand. Cleared by the next action.
    private(set) var errorMessage: String?

    @ObservationIgnored private let microphonePermission: any MicrophonePermissionProviding
    @ObservationIgnored private let accessibility: any AccessibilityPermissionProviding
    @ObservationIgnored private let promptMemory: PermissionsSettingsPromptMemory
    @ObservationIgnored private let openSettings: @MainActor (RequiredPermission) -> Bool

    /// - Parameters:
    ///   - promptMemory: Remembers the Accessibility prompt for the whole launch, so a Settings
    ///     window opened again does not offer a prompt macOS will no longer show; tests pass
    ///     their own.
    ///   - openSettings: Opens a permission's System Settings pane and reports whether it
    ///     opened; tests pass a fake.
    init(
        microphonePermission: any MicrophonePermissionProviding,
        accessibility: any AccessibilityPermissionProviding,
        promptMemory: PermissionsSettingsPromptMemory = .shared,
        openSettings: @escaping @MainActor (RequiredPermission) -> Bool = { PrivacySettings.open($0) }
    ) {
        self.microphonePermission = microphonePermission
        self.accessibility = accessibility
        self.promptMemory = promptMemory
        self.openSettings = openSettings
        microphone = microphonePermission.status()
        accessibilityGranted = accessibility.isGranted()
    }

    // MARK: - Status

    func isGranted(_ permission: RequiredPermission) -> Bool {
        switch permission {
        case .microphone: microphone == .granted
        case .accessibility: accessibilityGranted
        }
    }

    /// The row's status in a few words.
    func statusText(_ permission: RequiredPermission) -> String {
        switch permission {
        case .microphone:
            switch microphone {
            case .granted: "Allowed"
            case .denied: "Not allowed"
            case .undetermined: "Not asked yet"
            }
        case .accessibility:
            accessibilityGranted ? "Allowed" : "Not allowed"
        }
    }

    /// The row's button, or `nil` once the permission is granted.
    func action(for permission: RequiredPermission) -> Action? {
        switch permission {
        case .microphone:
            switch microphone {
            case .granted: nil
            case .undetermined: .request
            case .denied: .openSettings
            }
        case .accessibility:
            if accessibilityGranted { nil } else if accessibilityPrompted { .openSettings } else { .request }
        }
    }

    // MARK: - Intents

    /// Runs the row's button.
    func perform(_ action: Action, for permission: RequiredPermission) async {
        errorMessage = nil
        switch (action, permission) {
        case (.request, .microphone):
            let granted = await microphonePermission.request()
            Log.ui.info("Microphone access requested from Settings; granted: \(granted)")
            refreshMicrophone()
        case (.request, .accessibility):
            promptMemory.prompt(accessibility)
            accessibilityGranted = accessibility.isGranted()
        case (.openSettings, _):
            if !openSettings(permission) {
                errorMessage = permission.settingsFailureMessage
            }
        }
    }

    func refreshMicrophone() {
        microphone = microphonePermission.status()
    }

    /// Follows Accessibility until the calling task is cancelled (the view disappears).
    func followAccessibility() async {
        for await granted in accessibility.changes() {
            accessibilityGranted = granted
        }
    }
}

/// Whether this launch of the app already showed the Accessibility prompt, which macOS shows
/// at most once per launch. Shared by every Settings window and by setup, which all prompt
/// through ``prompt(_:)``: whichever asks first, the others then open System Settings instead
/// of a prompt that would not appear.
@MainActor
@Observable
final class PermissionsSettingsPromptMemory {
    static let shared = PermissionsSettingsPromptMemory()

    var accessibilityPrompted = false

    /// Shows the Accessibility prompt and remembers that this launch has used it.
    func prompt(_ accessibility: any AccessibilityPermissionProviding) {
        accessibility.prompt()
        accessibilityPrompted = true
    }
}

/// The dictation shortcut's state in words, from ``DictationController/hotkeyState``.
struct PermissionsSettingsShortcutStatus: Equatable {
    let message: String
    /// Something stops the shortcut from working that the user should fix.
    let isProblem: Bool
    /// The fix is granting Accessibility.
    let needsAccessibility: Bool

    init(_ state: HotkeyState) {
        switch state {
        case .running(let hotkey):
            message = "On. Hold \(hotkey) to dictate."
            isProblem = false
            needsAccessibility = false
        case .disabled:
            message = "Off. Turn on dictation in General."
            isProblem = false
            needsAccessibility = false
        case .stopped:
            message = "Not started yet."
            isProblem = false
            needsAccessibility = false
        case .needsAccessibility:
            message = "Waiting for Accessibility access."
            isProblem = true
            needsAccessibility = true
        case .failed(let detail):
            // The detail is already a sentence that says the shortcut could not start.
            message = detail
            isProblem = true
            needsAccessibility = false
        }
    }
}
