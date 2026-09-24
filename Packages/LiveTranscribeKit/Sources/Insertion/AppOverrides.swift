import Foundation
import Shared

/// Per-app settings, keyed by bundle identifier: the first insertion method to try, and whether
/// dictated text may break across lines.
///
/// Apps missing from ``methods`` try Accessibility first, then paste. An app mapped to
/// ``InsertionMethod/paste`` goes straight to paste; one mapped to
/// ``InsertionMethod/accessibility`` gets the default order, which lets a user entry undo a
/// bundled one. Apps missing from ``lines`` are ``LineMode/multiLine``, which likewise lets a
/// user entry undo a bundled ``LineMode/singleLine``.
public struct AppOverrides: Codable, Sendable, Equatable {
    /// Bundle identifier to the first method to try.
    public var methods: [String: InsertionMethod]
    /// Bundle identifier to whether the app's fields take line breaks.
    public var lines: [String: LineMode]

    public init(methods: [String: InsertionMethod] = [:], lines: [String: LineMode] = [:]) {
        self.methods = methods
        self.lines = lines
    }

    private enum CodingKeys: String, CodingKey {
        case methods, lines
    }

    /// Decodes `{"methods": {"<bundle id>": "paste"}, "lines": {"<bundle id>": "single-line"}}`.
    ///
    /// Either object may be missing, but not both: files from before line settings have only
    /// `methods`. An entry whose value this version does not know (a typo in a hand edit, or a
    /// value added by a newer version) is skipped and logged, rather than failing the whole file
    /// and costing the user every other entry; the next save drops it. Values are matched
    /// ignoring case. A file with neither object, or with a value that is not a string, still
    /// fails.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let methods = try container.decodeIfPresent([String: String].self, forKey: .methods)
        let lines = try container.decodeIfPresent([String: String].self, forKey: .lines)
        guard methods != nil || lines != nil else {
            throw DecodingError.keyNotFound(CodingKeys.methods, DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "Neither per-app methods nor lines"
            ))
        }
        self.methods = Self.entries(methods ?? [:], of: "insertion method")
        self.lines = Self.entries(lines ?? [:], of: "line setting")
    }

    /// Always writes `methods`, which versions before line settings require, and `lines` only
    /// when there are any, so a file without them stays as those versions wrote it.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(methods, forKey: .methods)
        if !lines.isEmpty {
            try container.encode(lines, forKey: .lines)
        }
    }

    /// The stored entries this version understands; see ``init(from:)``.
    private static func entries<Value: RawRepresentable>(
        _ stored: [String: String],
        of setting: String
    ) -> [String: Value] where Value.RawValue == String {
        var entries: [String: Value] = [:]
        for (bundleIdentifier, name) in stored {
            guard let value = Value(rawValue: name.lowercased()) else {
                Log.insertion.error("""
                    Per-app \(setting, privacy: .public) for \(bundleIdentifier, privacy: .public) skipped: \
                    unknown value \(name, privacy: .private)
                    """)
                continue
            }
            entries[bundleIdentifier] = value
        }
        return entries
    }

    /// No overrides.
    public static let empty = AppOverrides()

    /// Apps known to mishandle Accessibility writes, which go straight to paste, and terminals,
    /// which are also single-line.
    ///
    /// Terminals have no Accessibility-writable text, and a line break pasted into one can run
    /// the line as a command. Electron and Chromium apps often accept the write and ignore it, or
    /// apply it after reporting the old value, which risks the text twice.
    public static let bundled = AppOverrides(
        methods: Dictionary(uniqueKeysWithValues: (terminals + chromiumBased).map { ($0, InsertionMethod.paste) }),
        lines: Dictionary(uniqueKeysWithValues: terminals.map { ($0, LineMode.singleLine) })
    )

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
        "com.anthropic.claudefordesktop", // Claude
    ]

    /// These overrides with `user`'s entries on top: for an app in both, the user's choice wins,
    /// setting by setting.
    public func merged(with user: AppOverrides) -> AppOverrides {
        AppOverrides(
            methods: methods.merging(user.methods) { _, userChoice in userChoice },
            lines: lines.merging(user.lines) { _, userChoice in userChoice }
        )
    }

    /// The first method to try for the app, if it has an override.
    public func method(for bundleIdentifier: String?) -> InsertionMethod? {
        Self.value(in: methods, for: bundleIdentifier)
    }

    /// Whether the app's fields take line breaks, if it has an override.
    public func lineMode(for bundleIdentifier: String?) -> LineMode? {
        Self.value(in: lines, for: bundleIdentifier)
    }

    /// Whether the app has an override of either kind.
    public func hasOverride(for bundleIdentifier: String?) -> Bool {
        method(for: bundleIdentifier) != nil || lineMode(for: bundleIdentifier) != nil
    }

    /// Whether text dictated into `target` may contain line breaks: its app is multi-line, as
    /// every app is unless set otherwise, and the field doesn't certainly take a single line (see
    /// ``SingleLineField``). With no focused element to ask, a multi-line app gets them.
    ///
    /// Asks the field through Accessibility, so call it off the main actor.
    public func allowsLineBreaks(in target: InsertionTarget) -> Bool {
        let app = target.app?.bundleIdentifier
        let mode = lineMode(for: app) ?? .multiLine
        let singleLineField = mode == .multiLine && target.element.map(SingleLineField.isCertain) == true
        let allowed = mode == .multiLine && !singleLineField
        Log.insertion.info("""
            Line breaks \(allowed ? "allowed" : "not allowed", privacy: .public) in \(app ?? "an unknown app", privacy: .public): \
            \(mode.rawValue, privacy: .public) app\(singleLineField ? ", single-line field" : "", privacy: .public)
            """)
        return allowed
    }

    /// The entry for `bundleIdentifier` in `map`.
    ///
    /// Bundle identifiers are case-insensitive to Launch Services, so a hand-edited entry with
    /// different casing still applies. An exact match wins over a case-insensitive one, and among
    /// case-insensitive ones the lowest key wins, so the answer never depends on hash order.
    private static func value<Value>(in map: [String: Value], for bundleIdentifier: String?) -> Value? {
        guard let bundleIdentifier else { return nil }
        if let exact = map[bundleIdentifier] { return exact }
        return map
            .filter { $0.key.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
            .min { $0.key < $1.key }?
            .value
    }
}
