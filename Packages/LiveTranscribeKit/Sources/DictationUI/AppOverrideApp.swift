import AppKit
import Foundation

/// An app a per-app setting can name: its bundle identifier, and how to show it.
struct AppOverrideApp: Identifiable, Equatable, Sendable {
    /// The identifier the setting is stored under.
    let bundleIdentifier: String
    /// The app's name; its bundle identifier when the app isn't installed on this Mac.
    let name: String
    /// Where the app is installed, for its icon; `nil` when this Mac doesn't know the app.
    let url: URL?

    var id: String { bundleIdentifier }

    /// Whether the app was found on this Mac, so ``name`` is its real name.
    var isInstalled: Bool { url != nil }

    /// An app known only by its bundle identifier, shown as that identifier.
    static func unresolved(_ bundleIdentifier: String) -> AppOverrideApp {
        AppOverrideApp(bundleIdentifier: bundleIdentifier, name: bundleIdentifier, url: nil)
    }
}

/// Finds apps for Settings › Apps. The system implementation asks Launch Services and
/// `NSWorkspace`; tests pass a fixed list.
@MainActor
protocol AppOverrideAppCatalog {
    /// The installed app with this bundle identifier, or `nil` when there is none.
    func app(bundleIdentifier: String) -> AppOverrideApp?
    /// The app bundle at `url`, or `nil` when it isn't an app with a bundle identifier.
    func app(at url: URL) -> AppOverrideApp?
    /// The regular apps (those with a Dock icon) running now that have a bundle identifier.
    func runningApps() -> [AppOverrideApp]
}

/// ``AppOverrideAppCatalog`` backed by Launch Services, `NSWorkspace` and each app's Info.plist.
@MainActor
struct SystemAppOverrideAppCatalog: AppOverrideAppCatalog {
    func app(bundleIdentifier: String) -> AppOverrideApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let name = Bundle(url: url).map { Self.name(of: $0, at: url) } ?? Self.fileName(of: url)
        return AppOverrideApp(bundleIdentifier: bundleIdentifier, name: name, url: url)
    }

    func app(at url: URL) -> AppOverrideApp? {
        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty
        else { return nil }
        return AppOverrideApp(bundleIdentifier: bundleIdentifier, name: Self.name(of: bundle, at: url), url: url)
    }

    func runningApps() -> [AppOverrideApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { running in
                guard let bundleIdentifier = running.bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
                let name = running.localizedName ?? running.bundleURL.map(Self.fileName(of:)) ?? bundleIdentifier
                return AppOverrideApp(bundleIdentifier: bundleIdentifier, name: name, url: running.bundleURL)
            }
    }

    /// The name the app shows in Finder and the Dock: its localised display name, then its
    /// bundle name, then its file name without `.app`.
    static func name(of bundle: Bundle, at url: URL) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            let value = bundle.localizedInfoDictionary?[key] ?? bundle.infoDictionary?[key]
            if let name = value as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                return name
            }
        }
        return fileName(of: url)
    }

    private static func fileName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
