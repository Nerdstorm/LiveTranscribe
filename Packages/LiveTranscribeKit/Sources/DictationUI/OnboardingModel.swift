import AppKit
import Capture
import Dictation
import Foundation
import Hotkey
import Observation
import Permissions
import Session
import Shared

/// A step of dictation setup, in the order they are shown.
enum OnboardingStep: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case accessibility
    /// Only while the dictation hotkey is fn, which macOS may also act on.
    case fnKey
    case tryIt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .fnKey: "fn key"
        case .tryIt: "Try it"
        }
    }
}

/// State and actions for dictation setup: which step is showing, the permissions as they change,
/// and the fn key's system setting.
///
/// Permission and system calls come in through the initialiser, so tests drive every step with
/// fakes. The view only renders it.
@MainActor
@Observable
final class OnboardingModel {
    /// What setup asks of the system, replaced by fakes in tests.
    struct System {
        /// Reads macOS's *Press 🌐 key to* setting.
        var fnKeyUsage: @MainActor () -> FnKeyUsage
        var openPrivacySettings: @MainActor (RequiredPermission) -> Void
        /// Opens a URL; `false` if nothing could open it.
        var openURL: @MainActor (URL) -> Bool
        /// Reads a status change out to VoiceOver users.
        var announce: @MainActor (String) -> Void
    }

    /// System Settings › Keyboard, where *Press 🌐 key to* is.
    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    private(set) var step: OnboardingStep
    private(set) var microphone: MicrophonePermissionStatus
    /// The system microphone prompt is up.
    private(set) var isRequestingMicrophone = false
    private(set) var accessibilityGranted: Bool
    /// Accessibility was asked for during this setup, so a stale entry in the list is worth
    /// mentioning: an app rebuilt with a new signature shows as on but is refused.
    private(set) var hasAskedForAccessibility = false
    private(set) var fnUsage: FnKeyUsage
    /// The dictation hotkey, as the controller reads it from Settings.
    private(set) var hotkey: HotkeyBinding = .defaultDictation
    /// Something the user asked for failed; shown until they move on.
    private(set) var errorMessage: String?

    @ObservationIgnored private let microphonePermission: any MicrophonePermissionProviding
    @ObservationIgnored private let accessibility: any AccessibilityPermissionProviding
    @ObservationIgnored private let system: System

    init(
        microphonePermission: any MicrophonePermissionProviding,
        accessibility: any AccessibilityPermissionProviding,
        system: System
    ) {
        self.microphonePermission = microphonePermission
        self.accessibility = accessibility
        self.system = system
        microphone = microphonePermission.status()
        accessibilityGranted = accessibility.isGranted()
        fnUsage = system.fnKeyUsage()
        step = .microphone
        step = steps.first { !isComplete($0) } ?? .tryIt
    }

    // MARK: - Steps

    /// The steps for the current hotkey.
    var steps: [OnboardingStep] {
        OnboardingStep.allCases.filter { $0 != .fnKey || usesFnKey }
    }

    var usesFnKey: Bool { hotkey == .modifierKey(.fn) }

    /// Whether a step needs nothing more from the user. *Try it* never does, so it is never
    /// shown as done.
    func isComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .microphone: microphone == .granted
        case .accessibility: accessibilityGranted
        case .fnKey: !fnUsage.conflictsWithFnHotkey
        case .tryIt: false
        }
    }

    var isFirstStep: Bool { step == steps.first }
    var isLastStep: Bool { step == steps.last }

    func goForward() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        show(steps[index + 1])
    }

    func goBack() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        show(steps[index - 1])
    }

    func show(_ step: OnboardingStep) {
        guard steps.contains(step) else { return }
        errorMessage = nil
        self.step = step
    }

    /// Takes the dictation hotkey from Settings (its stored form). Unreadable values mean the
    /// default, as they do for the controller. Leaving fn drops the fn step, and the step
    /// after it shows if it was showing.
    func setHotkey(storageString: String) {
        let binding = HotkeyBinding(storageString: storageString) ?? .defaultDictation
        guard binding != hotkey else { return }
        hotkey = binding
        if usesFnKey { fnUsage = system.fnKeyUsage() }
        if !steps.contains(step) {
            let later = OnboardingStep.allCases.drop { $0 != step }
            show(later.first { steps.contains($0) } ?? .tryIt)
        }
    }

    // MARK: - Permissions

    /// Asks for the microphone with the system prompt; once refused, only System Settings can
    /// change it.
    func requestMicrophone() async {
        guard !isRequestingMicrophone else { return }
        isRequestingMicrophone = true
        let granted = await microphonePermission.request()
        isRequestingMicrophone = false
        if !granted {
            Log.ui.notice("Microphone access was not granted during setup")
        }
        updateMicrophone(microphonePermission.status())
    }

    func openMicrophoneSettings() {
        system.openPrivacySettings(.microphone)
    }

    /// Shows the system's Accessibility alert, which also adds the app to the list, and opens
    /// the list in System Settings.
    func grantAccessibility() {
        accessibility.prompt()
        system.openPrivacySettings(.accessibility)
        hasAskedForAccessibility = true
    }

    /// Follows Accessibility access until the task running it is cancelled, so the step updates
    /// as soon as the user switches it on.
    func observeAccessibility() async {
        for await granted in accessibility.changes() {
            updateAccessibility(granted)
        }
    }

    /// Checks everything again, for when the user comes back from System Settings.
    func refresh() {
        updateMicrophone(microphonePermission.status())
        updateAccessibility(accessibility.isGranted())
        if usesFnKey { fnUsage = system.fnKeyUsage() }
    }

    private func updateMicrophone(_ status: MicrophonePermissionStatus) {
        guard status != microphone else { return }
        microphone = status
        system.announce(status == .granted ? "Microphone access is on" : "Microphone access is off")
    }

    private func updateAccessibility(_ granted: Bool) {
        guard granted != accessibilityGranted else { return }
        accessibilityGranted = granted
        system.announce(granted ? "Accessibility access is on" : "Accessibility access is off")
    }

    // MARK: - fn key

    /// Reads the *Press 🌐 key to* setting again, and says what it found.
    ///
    /// It never names the current value: macOS stores nothing until the setting is changed, and
    /// ``FnKeyUsage`` then assumes one (``FnKeyUsage/unsetDefault``) that may not be what the
    /// Mac does. Only "Do Nothing or not" is certain.
    func checkFnKey() {
        fnUsage = system.fnKeyUsage()
        system.announce(fnUsage.conflictsWithFnHotkey ? Self.fnKeyConflictStatus : Self.fnKeyReadyStatus)
    }

    /// The fn step's status, and what *Check Again* says, while macOS may also act on the key.
    static let fnKeyConflictStatus = "Not set to Do Nothing yet"
    /// The fn step's status, and what *Check Again* says, once macOS leaves the key alone.
    static let fnKeyReadyStatus = "The fn key is ready"

    func openKeyboardSettings() {
        guard let url = Self.keyboardSettingsURL, system.openURL(url) else {
            Log.ui.error("Couldn't open Keyboard settings")
            errorMessage = "Couldn't open System Settings. Open it from the Apple menu, then choose Keyboard."
            return
        }
        errorMessage = nil
    }

    // MARK: - Try it

    /// Why dictating on the *Try it* step might not work yet; `nil` when it should.
    ///
    /// - Parameters:
    ///   - permissionsGranted: microphone and Accessibility access are both on.
    ///   - hotkey: the controller's hotkey state. Waiting for Accessibility is covered by
    ///     `permissionsGranted`, and the controller restarts the hotkey once access is on.
    ///   - session: the live transcript's phase, which owns the speech models.
    static func tryItNote(permissionsGranted: Bool, hotkey: HotkeyState, session: SessionPhase) -> String? {
        guard permissionsGranted else { return "Dictation works once microphone and Accessibility access are on." }
        switch hotkey {
        case .disabled:
            return "The dictation shortcut is off. Turn it on in Settings to try it."
        case .failed(let detail):
            return "The dictation shortcut couldn't start: \(detail)"
        case .running, .stopped, .needsAccessibility:
            break
        }
        switch session {
        case .notLoaded, .loading:
            return "The speech models are still loading. Try again once they're ready."
        case .failed(.modelLoadFailed):
            return "The speech models couldn't load. Open Live Transcript from the menu bar to try again."
        case .listening, .stopping:
            return "Stop the live transcript to dictate."
        case .ready, .failed:
            return nil
        }
    }
}

extension OnboardingModel.System {
    /// The real system: the fn key preference, System Settings, and VoiceOver.
    static var live: Self {
        Self(
            fnKeyUsage: { FnKeyUsage.current() },
            openPrivacySettings: { PrivacySettings.open($0) },
            openURL: { NSWorkspace.shared.open($0) },
            announce: { HUDAnnouncer.post($0) }
        )
    }
}
