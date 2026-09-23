import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An app's icon and name, or a generic icon and its bundle identifier when it isn't installed.
struct AppOverrideAppLabel: View {
    let app: AppOverrideApp

    var body: some View {
        HStack(spacing: 8) {
            AppOverrideAppIcon(url: app.url)
                .frame(width: 20, height: 20)
            Text(app.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(app.bundleIdentifier)
    }
}

/// The icon of the app at `url`, or a generic app icon. Decorative: the name next to it says
/// which app it is.
private struct AppOverrideAppIcon: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Asks the user for an app bundle in a standard Open panel.
@MainActor
enum AppOverrideAppChooser {
    /// The chosen app's URL, or `nil` when the user cancels. The panel starts in Applications.
    static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }
}
