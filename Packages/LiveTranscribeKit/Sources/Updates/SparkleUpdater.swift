import Foundation
import Observation
import Shared
import Sparkle

/// ``SoftwareUpdating`` with Sparkle's standard updater and its windows.
///
/// Sparkle keeps its settings in the app's user defaults: whether to check automatically, and
/// when it last checked. They are read and written there, not copied into `AppSettings`, so
/// Settings and Sparkle's own prompt can't disagree. Until the user chooses, Sparkle asks on the
/// second launch whether to check automatically.
@MainActor
@Observable
public final class SparkleUpdater: SoftwareUpdating {
    public private(set) var canCheckForUpdates = false
    public private(set) var lastUpdateCheckDate: Date?
    public private(set) var pendingUpdateVersion: String?

    public var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    /// Sparkle holds its user driver's delegate weakly, so this keeps it.
    @ObservationIgnored private let reminders = GentleReminders()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Starts Sparkle, which then checks on its own schedule.
    ///
    /// - Throws: Sparkle's error when it can't start, such as when it refuses the feed or the key.
    public init() throws {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: reminders
        )
        reminders.onPendingUpdateChange = { [weak self] version in
            self?.pendingUpdateVersion = version
        }
        try controller.updater.start()
        observeUpdater()
        Log.updates.info(
            "Updates start; automatic checks \(self.controller.updater.automaticallyChecksForUpdates ? "on" : "off", privacy: .public)"
        )
    }

    public func checkForUpdates() {
        Log.updates.info("Checking for updates at the user's request")
        controller.checkForUpdates(nil)
    }

    /// Follows Sparkle's state, which it changes on the main thread.
    private func observeUpdater() {
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            // Sparkle's second-launch prompt changes it too.
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.withMutation(keyPath: \.automaticallyChecksForUpdates) {} }
            },
        ]
    }

    /// A check ending makes checking possible again, so this also picks up its date, which Sparkle
    /// doesn't report on its own.
    private func refresh() {
        let updater = controller.updater
        if canCheckForUpdates != updater.canCheckForUpdates {
            canCheckForUpdates = updater.canCheckForUpdates
        }
        if lastUpdateCheckDate != updater.lastUpdateCheckDate {
            lastUpdateCheckDate = updater.lastUpdateCheckDate
        }
    }
}

/// Keeps a scheduled update from taking focus from the app the user is in, as Sparkle asks of
/// menu bar apps. Sparkle still shows the update's window, behind other apps; until the user looks
/// at it, the menu offers it too (``SoftwareUpdating/pendingUpdateVersion``).
///
/// Sparkle's standard user driver lives on the main thread and calls its delegate there, but its
/// protocol doesn't say so; the `@preconcurrency` conformance checks it at run time.
@MainActor
private final class GentleReminders: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    /// Called with the version waiting for the user, and with `nil` once they have seen it.
    var onPendingUpdateChange: ((String?) -> Void)?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // A check the user asked for comes to the front anyway.
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        onPendingUpdateChange?(version)
        Log.updates.info("Update \(version, privacy: .public) found by a scheduled check")
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onPendingUpdateChange?(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        onPendingUpdateChange?(nil)
    }
}
