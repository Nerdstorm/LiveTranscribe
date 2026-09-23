import Foundation

/// The tag on every keyboard event the app posts itself (the ⌘V of a paste, the ⌘Z of *Undo AI
/// edit*), so the app's own hotkey tap can tell them from the user's typing.
///
/// Without it the tap cannot tell them apart: the ⌘Z that undo posts moments after ⌃⌥Z is pressed
/// arrives while the Z key is still held, and the tap would swallow it as that key's repeat.
///
/// Defined once here because two slices must agree on it: Insertion writes it into each event's
/// `eventSourceUserData` field, and Hotkey reads it back. The value spells "LTranscr" in ASCII;
/// any constant works as long as other apps are unlikely to post events with it.
public enum SyntheticEventMarker {
    public static let value: Int64 = 0x4C54_7261_6E73_6372
}
