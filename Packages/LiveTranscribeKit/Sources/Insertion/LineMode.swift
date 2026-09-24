import Foundation

/// Whether dictated text may break across lines in an app: spoken lists and letters laid out on
/// lines of their own, and "new line" typed as a line break.
///
/// Stored by raw value in the per-app settings file, so the raw values must not change.
public enum LineMode: String, Codable, Sendable, CaseIterable {
    /// Line breaks in every field except one that certainly takes a single line, such as a search
    /// box (see ``AppOverrides/allowsLineBreaks(in:)``). Every app's default.
    case multiLine = "multi-line"
    /// No line breaks anywhere in the app: lists and letters stay in the sentence, and "new line"
    /// types a space. For apps where a line break runs or sends something, such as terminals.
    case singleLine = "single-line"

    /// Name for the per-app picker in Settings.
    public var displayName: String {
        switch self {
        case .multiLine: "Multi-line"
        case .singleLine: "Single-line"
        }
    }
}
