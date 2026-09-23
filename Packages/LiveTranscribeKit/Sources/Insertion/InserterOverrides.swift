import Foundation
import Shared

/// Per-app choice of the first insertion method to try, keyed by bundle identifier.
///
/// Apps missing from the map try Accessibility first, then paste. An app mapped to
/// ``InsertionMethod/paste`` goes straight to paste; one mapped to
/// ``InsertionMethod/accessibility`` gets the default order, which lets a user entry undo a
/// bundled one.
public struct InserterOverrides: Codable, Sendable, Equatable {
    /// Bundle identifier to the first method to try.
    public var methods: [String: InsertionMethod]

    public init(methods: [String: InsertionMethod]) {
        self.methods = methods
    }

    private enum CodingKeys: String, CodingKey {
        case methods
    }

    /// Decodes `{"methods": {"<bundle id>": "paste"}}`.
    ///
    /// An entry whose method this version does not know (a typo in a hand edit, or a method added
    /// by a newer version) is skipped and logged, rather than failing the whole file and costing
    /// the user every other entry; the next save drops it. Method names are matched ignoring case.
    /// A file without a `methods` object, or with a value that is not a string, still fails.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decode([String: String].self, forKey: .methods)
        var methods: [String: InsertionMethod] = [:]
        for (bundleIdentifier, name) in stored {
            guard let method = InsertionMethod(rawValue: name.lowercased()) else {
                Log.insertion.error("""
                    Per-app insertion override for \(bundleIdentifier, privacy: .public) skipped: \
                    unknown method \(name, privacy: .private)
                    """)
                continue
            }
            methods[bundleIdentifier] = method
        }
        self.methods = methods
    }

    /// No overrides.
    public static let empty = InserterOverrides(methods: [:])

    /// Apps known to mishandle Accessibility writes, which go straight to paste.
    ///
    /// Terminals have no Accessibility-writable text; Electron and Chromium apps often accept the
    /// write and ignore it, or apply it after reporting the old value, which risks the text twice.
    public static let bundled = InserterOverrides(methods: Dictionary(
        uniqueKeysWithValues: (terminals + chromiumBased).map { ($0, InsertionMethod.paste) }
    ))

    static let terminals = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    static let chromiumBased = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "notion.id",
        "com.figma.Desktop",
        "com.google.Chrome",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
    ]

    /// These overrides with `user`'s entries on top: for an app in both, the user's choice wins.
    public func merged(with user: InserterOverrides) -> InserterOverrides {
        InserterOverrides(methods: methods.merging(user.methods) { _, userChoice in userChoice })
    }

    /// The first method to try for the app, if it has an override.
    ///
    /// Bundle identifiers are case-insensitive to Launch Services, so a hand-edited entry with
    /// different casing still applies. An exact match wins over a case-insensitive one, and among
    /// case-insensitive ones the lowest key wins, so the answer never depends on hash order.
    public func method(for bundleIdentifier: String?) -> InsertionMethod? {
        guard let bundleIdentifier else { return nil }
        if let exact = methods[bundleIdentifier] { return exact }
        return methods
            .filter { $0.key.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
            .min { $0.key < $1.key }?
            .value
    }
}
