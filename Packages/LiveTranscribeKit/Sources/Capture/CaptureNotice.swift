import Foundation

/// Something the user should know about the microphone that capture kept running through.
///
/// Capture changes device on its own in a few cases (a chosen microphone disconnects, the system
/// default input changes while it is followed). Doing that silently would leave people talking
/// into a microphone they did not expect, so ``CaptureSessionSource`` reports each case. None of
/// these is an error: the stream keeps delivering audio.
public enum CaptureNotice: Sendable, Equatable {
    /// Capture moved to another microphone: the followed system default changed, or the device
    /// in use went away and the default replaced it.
    case switchedDevice(name: String)
    /// The chosen microphone is not connected, so capture uses the system default instead.
    /// `missing` is the chosen device's name when it is known (it is not at start, when only the
    /// saved UID is).
    case fellBackToDefault(missing: String?, using: String)
    /// The system default input changed to a virtual device; capture stayed where it was.
    case keptDevice(current: String, ignoredVirtual: String)
    /// The system default input is a virtual device, so capture opened a physical microphone.
    case skippedVirtualDefault(virtual: String, using: String)
    /// The chosen microphone is connected again and capture moved back to it from the fallback.
    case returnedToSelected(name: String)

    /// One or two plain sentences for a banner or the HUD. Contains device names, so log it
    /// only with `privacy: .private`.
    public var message: String {
        switch self {
        case .switchedDevice(let name):
            "Now using \(name)."
        case .fellBackToDefault(let missing?, let using):
            "\(missing) isn't connected. Using \(using) instead."
        case .fellBackToDefault(nil, let using):
            "The chosen microphone isn't connected. Using \(using) instead."
        case .keptDevice(let current, let ignoredVirtual):
            "Still using \(current). The new default input, \(ignoredVirtual), is a virtual device, "
                + "so it isn't used unless you choose it."
        case .skippedVirtualDefault(let virtual, let using):
            "Using \(using). The default input, \(virtual), is a virtual device, "
                + "so it isn't used unless you choose it."
        case .returnedToSelected(let name):
            "\(name) is connected again and in use."
        }
    }

    /// A stable name for the case, safe to log publicly because it carries no device names.
    var kind: String {
        switch self {
        case .switchedDevice: "switchedDevice"
        case .fellBackToDefault: "fellBackToDefault"
        case .keptDevice: "keptDevice"
        case .skippedVirtualDefault: "skippedVirtualDefault"
        case .returnedToSelected: "returnedToSelected"
        }
    }
}
