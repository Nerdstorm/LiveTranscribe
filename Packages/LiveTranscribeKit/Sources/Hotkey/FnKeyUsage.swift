import CoreFoundation
import Foundation
import Shared

/// What macOS does when fn (the globe key) is pressed on its own: System Settings › Keyboard ›
/// "Press (globe) key to".
///
/// macOS acts on the key as well as the app seeing it, so with any setting but Do Nothing,
/// holding fn to dictate also switches the input source, opens the emoji picker or starts
/// Apple's dictation. Settings uses this to warn and show the fix.
public enum FnKeyUsage: Int, Sendable, CaseIterable {
    case doNothing = 0
    case changeInputSource = 1
    case showEmojiAndSymbols = 2
    case startDictation = 3

    /// The preferences domain and key macOS stores the setting under.
    public static let preferencesDomain = "com.apple.HIToolbox"
    public static let preferenceKey = "AppleFnUsageType"

    /// Assumed when the setting has never been changed, so nothing is stored.
    ///
    /// Apple does not document the factory value. Out of the box the key opens the emoji
    /// picker or switches the input source, so it is assumed not to be Do Nothing, and that is
    /// all that matters here: a missing value counts as a conflict, and the warning shows until
    /// the user explicitly chooses Do Nothing. If the assumption is ever wrong, the cost is a
    /// warning the user can clear, not a hotkey that silently misbehaves.
    public static let unsetDefault = FnKeyUsage.showEmojiAndSymbols

    /// The current setting, read fresh from the system preferences.
    public static func current() -> FnKeyUsage {
        let domain = preferencesDomain as CFString
        // Drop any cached copy, so a change made in System Settings a moment ago is seen.
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue(preferenceKey as CFString, domain)
        return FnKeyUsage(preferenceValue: value)
    }

    /// Interprets a stored preference value. Missing or unreadable values mean
    /// ``unsetDefault``; so does an unknown number, which a later macOS may add for another
    /// action, and any action conflicts.
    public init(preferenceValue: Any?) {
        guard let preferenceValue else {
            self = Self.unsetDefault
            return
        }
        let number: Int? = switch preferenceValue {
        case let value as NSNumber: value.intValue
        case let value as String: Int(value)
        default: nil
        }
        guard let number, let usage = FnKeyUsage(rawValue: number) else {
            Log.hotkey.notice("Unrecognised fn key setting; assuming it conflicts with the fn hotkey")
            self = Self.unsetDefault
            return
        }
        self = usage
    }

    /// Whether pressing fn also triggers a macOS action, so fn as the dictation hotkey clashes.
    public var conflictsWithFnHotkey: Bool {
        self != .doNothing
    }

    /// The option's label in System Settings.
    public var displayName: String {
        switch self {
        case .doNothing: "Do Nothing"
        case .changeInputSource: "Change Input Source"
        case .showEmojiAndSymbols: "Show Emoji & Symbols"
        case .startDictation: "Start Dictation"
        }
    }

    /// Where to fix a conflict, for the warning in Settings.
    public var fixHint: String {
        "System Settings › Keyboard › Press \(ModifierKey.globeSymbol) key to: Do Nothing"
    }
}
