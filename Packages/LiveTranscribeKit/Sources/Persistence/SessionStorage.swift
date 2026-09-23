import Foundation

/// Locations of persisted sessions.
public enum SessionStorage {
    /// `Application Support/<bundle id>/Sessions`. Inside the app sandbox this resolves to the
    /// app's container.
    public static func sessionsDirectory(bundleIdentifier: String) throws -> URL {
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return applicationSupport
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("Sessions", isDirectory: true)
        } catch {
            throw PersistenceError.directoryUnavailable(error.localizedDescription)
        }
    }
}
