import Foundation

/// A device for capture to open, with a notice when it is not the one the user would expect.
public struct InputDeviceChoice: Sendable, Equatable {
    public let device: AudioInputDevice
    /// Shown once capture is running on `device`; `nil` when nothing needs saying.
    public let notice: CaptureNotice?

    public init(device: AudioInputDevice, notice: CaptureNotice?) {
        self.device = device
        self.notice = notice
    }
}

/// What to do after the connected devices or the system default input changed while capturing.
public enum DeviceChangeDecision: Sendable, Equatable {
    /// Keep capturing from the current device. A notice, if any, says why a change was ignored.
    case keep(notice: CaptureNotice?)
    /// Rebuild capture on this device, then show the notice.
    case switchTo(AudioInputDevice, notice: CaptureNotice)
}

/// Which microphone capture uses, and when it moves to another one.
///
/// Pure functions over an ``InputDeviceSnapshot``, so every rule is unit-tested and
/// ``CaptureSessionSource`` only applies the answers. The rules (docs/dictation.md, decision M1
/// and handoff F6):
///
/// - **A chosen microphone** (a selected UID) is used whenever it is connected, virtual or not,
///   and changes to the system default are ignored while it is in use.
/// - **A chosen microphone that is missing**, at start or because it disconnected, falls back to
///   the system default with a notice, and capture returns to it when it reconnects. While on
///   the fallback, capture follows the default like System Default does.
/// - **System Default** follows macOS's default input, including mid-session, with a notice on
///   each switch, so a newly connected microphone (which macOS usually makes the default) is
///   picked up without a restart.
/// - **Virtual devices are never moved to automatically.** A virtual default is skipped for a
///   physical microphone, preferring the one already in use. The single exception: at start,
///   following System Default, a virtual default is used when no physical microphone is
///   connected at all. It is then the only input and the user set it as the default, so failing
///   would be more surprising than using it. Mid-session it is not switched to, and a missing
///   chosen microphone never falls back to it.
public enum InputDevicePolicy {
    /// The device to open at start (`previous == nil`) or when recovering after the device in use
    /// failed or disconnected (`previous` is that device).
    ///
    /// - Throws: ``CaptureError/noInputDevice`` when nothing usable is connected, or
    ///   ``CaptureError/inputDeviceUnavailable`` when the chosen microphone is missing and only
    ///   virtual devices remain.
    public static func deviceToOpen(
        selectedUID: String?,
        previous: AudioInputDevice?,
        in snapshot: InputDeviceSnapshot
    ) throws(CaptureError) -> InputDeviceChoice {
        if let selectedUID {
            return try chosenOrFallback(selectedUID: selectedUID, previous: previous, in: snapshot)
        }
        return try followingDefault(previous: previous, in: snapshot)
    }

    /// What to do when the device list or the default input changed while `current` is capturing.
    ///
    /// - Parameter previousDefaultUID: the system default when this was last decided (or when
    ///   capture started). A default that has not changed since is not acted on again, so a
    ///   device connecting elsewhere does not repeat a notice about a virtual default.
    public static func decisionAfterChange(
        selectedUID: String?,
        current: AudioInputDevice,
        previousDefaultUID: String?,
        in snapshot: InputDeviceSnapshot
    ) -> DeviceChangeDecision {
        // A device that has gone is recovered through the session's own disconnect handling.
        guard snapshot.device(withID: current.id) != nil else { return .keep(notice: nil) }
        if let selectedUID {
            if current.id == selectedUID { return .keep(notice: nil) }
            if let selected = snapshot.device(withID: selectedUID) {
                return .switchTo(selected, notice: .returnedToSelected(name: selected.name))
            }
            // On the fallback while the chosen microphone is away: follow the default below.
        }
        guard let systemDefault = snapshot.systemDefault,
              systemDefault.id != previousDefaultUID,
              systemDefault.id != current.id
        else { return .keep(notice: nil) }
        if systemDefault.isVirtual {
            return .keep(notice: .keptDevice(current: current.name, ignoredVirtual: systemDefault.name))
        }
        return .switchTo(systemDefault, notice: .switchedDevice(name: systemDefault.name))
    }

    // MARK: - Rules

    private static func chosenOrFallback(
        selectedUID: String,
        previous: AudioInputDevice?,
        in snapshot: InputDeviceSnapshot
    ) throws(CaptureError) -> InputDeviceChoice {
        if let selected = snapshot.device(withID: selectedUID) {
            let isReturning = previous.map { $0.id != selected.id } ?? false
            return InputDeviceChoice(device: selected, notice: isReturning ? .returnedToSelected(name: selected.name) : nil)
        }
        guard let fallback = physicalFallback(previous: previous, in: snapshot) else {
            throw snapshot.connected.isEmpty ? .noInputDevice : .inputDeviceUnavailable
        }
        let notice: CaptureNotice?
        if fallback.id == previous?.id {
            // Recovering on the fallback already in use: nothing new to say.
            notice = nil
        } else if previous == nil || previous?.id == selectedUID {
            notice = .fellBackToDefault(missing: previous?.name, using: fallback.name)
        } else {
            // The fallback itself went away; the user already knows the chosen one is missing.
            notice = .switchedDevice(name: fallback.name)
        }
        return InputDeviceChoice(device: fallback, notice: notice)
    }

    private static func followingDefault(
        previous: AudioInputDevice?,
        in snapshot: InputDeviceSnapshot
    ) throws(CaptureError) -> InputDeviceChoice {
        if let systemDefault = snapshot.systemDefault, !systemDefault.isVirtual {
            return InputDeviceChoice(device: systemDefault, notice: switchNotice(to: systemDefault, from: previous))
        }
        if let physical = physicalFallback(previous: previous, in: snapshot) {
            let notice: CaptureNotice?
            if physical.id == previous?.id {
                notice = nil
            } else if let virtualDefault = snapshot.systemDefault {
                notice = .skippedVirtualDefault(virtual: virtualDefault.name, using: physical.name)
            } else {
                notice = switchNotice(to: physical, from: previous)
            }
            return InputDeviceChoice(device: physical, notice: notice)
        }
        // No physical microphone: a virtual default only at start, or if it is already in use.
        if let virtualDefault = snapshot.systemDefault, previous == nil || previous?.id == virtualDefault.id {
            return InputDeviceChoice(device: virtualDefault, notice: nil)
        }
        throw .noInputDevice
    }

    /// A physical microphone to use instead: the default if it is physical, else the one already
    /// in use if it is still connected (moving is only worth it for the default), else the first.
    private static func physicalFallback(previous: AudioInputDevice?, in snapshot: InputDeviceSnapshot) -> AudioInputDevice? {
        if let systemDefault = snapshot.systemDefault, !systemDefault.isVirtual {
            return systemDefault
        }
        if let previous, let stillConnected = snapshot.device(withID: previous.id), !stillConnected.isVirtual {
            return stillConnected
        }
        return snapshot.physicalDevices.first
    }

    private static func switchNotice(to device: AudioInputDevice, from previous: AudioInputDevice?) -> CaptureNotice? {
        guard let previous, previous.id != device.id else { return nil }
        return .switchedDevice(name: device.name)
    }
}
