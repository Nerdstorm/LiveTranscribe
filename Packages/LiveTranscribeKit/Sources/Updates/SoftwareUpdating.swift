import Foundation

/// Checks for new releases of the app and installs them.
///
/// The app makes one (``SparkleUpdater``) only when its Info.plist names an update feed (see
/// ``UpdateFeed``), and the menu and Settings offer updates only then. A build from source names
/// none, so it never replaces itself with a release.
@MainActor
public protocol SoftwareUpdating: AnyObject {
    /// Whether a check can start now. It can't while one is running.
    var canCheckForUpdates: Bool { get }
    /// Whether the app checks for new releases by itself, about once a day.
    var automaticallyChecksForUpdates: Bool { get set }
    /// When the app last checked for a new release, or `nil` if it never has.
    var lastUpdateCheckDate: Date? { get }
    /// The version of a release that a scheduled check found and the user hasn't looked at yet.
    ///
    /// A menu bar app has no Dock icon to bounce, so the update's window may sit behind other
    /// apps; the menu shows this until the user opens it.
    var pendingUpdateVersion: String? { get }
    /// Checks for a new release now, or brings a pending one forward, and shows what it finds.
    func checkForUpdates()
}
