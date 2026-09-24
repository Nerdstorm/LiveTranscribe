import Capture
import Dictation
import Insertion
import Permissions
import Persistence
import Shared
import Snippets
import TranscriptUI
import Updates
import Vocabulary

/// The Settings tabs, in display order.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, snippets, vocabulary, apps, history, permissions, advanced

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .snippets: "Snippets"
        case .vocabulary: "Vocabulary"
        case .apps: "Apps"
        case .history: "History"
        case .permissions: "Permissions"
        case .advanced: "Advanced"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .snippets: "text.badge.plus"
        case .vocabulary: "character.book.closed"
        case .apps: "app.badge"
        case .history: "clock.arrow.circlepath"
        case .permissions: "lock.shield"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// Opens the app's windows. The app implements it with AppKit windows, so the menu bar app can
/// show a window and bring itself forward without a Dock icon of its own.
@MainActor
public protocol DictationWindowActions: AnyObject {
    func showTranscript()
    func showHistory()
    func showSettings(tab: SettingsTab?)
    func showOnboarding()
    /// The About panel, with the version and the licence notices.
    func showAbout()
}

/// Everything the dictation windows and the menu read and change, built once by the app.
///
/// Settings are edited through `UserDefaults` (``AppSettingsKey``); the app watches for changes
/// and applies them to the controller, so views never call ``DictationController/applySettings()``.
@MainActor
public final class DictationUIContext {
    public let controller: DictationController
    /// The live transcript's model: session state, and the microphone list and choice.
    public let transcript: TranscriptViewModel
    public let settingsStore: AppSettingsStore
    public let snippets: SnippetStore
    public let vocabulary: VocabularyStore
    public let overrides: AppOverridesStore
    public let history: any DictationHistory
    public let microphonePermission: any MicrophonePermissionProviding
    public let accessibility: any AccessibilityPermissionProviding
    /// The settings as read at launch. The models and the rest of Settings › Advanced keep
    /// these values until Live Transcribe restarts (dictation settings are read at each use), so
    /// Settings can tell what is in effect from a change still waiting for a restart.
    public let settingsAtLaunch: AppSettings
    /// New releases, in a release build; `nil` in a build from source, which never updates.
    public let updates: (any SoftwareUpdating)?
    public weak var windows: (any DictationWindowActions)?

    public init(
        controller: DictationController,
        transcript: TranscriptViewModel,
        settingsStore: AppSettingsStore,
        snippets: SnippetStore,
        vocabulary: VocabularyStore,
        overrides: AppOverridesStore,
        history: any DictationHistory,
        microphonePermission: any MicrophonePermissionProviding,
        accessibility: any AccessibilityPermissionProviding,
        settingsAtLaunch: AppSettings,
        updates: (any SoftwareUpdating)? = nil
    ) {
        self.controller = controller
        self.transcript = transcript
        self.settingsStore = settingsStore
        self.snippets = snippets
        self.vocabulary = vocabulary
        self.overrides = overrides
        self.history = history
        self.microphonePermission = microphonePermission
        self.accessibility = accessibility
        self.settingsAtLaunch = settingsAtLaunch
        self.updates = updates
    }
}
