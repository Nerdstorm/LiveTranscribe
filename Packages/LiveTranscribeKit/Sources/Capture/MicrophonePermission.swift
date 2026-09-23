@preconcurrency import AVFoundation

public enum MicrophonePermissionStatus: Sendable, Equatable {
    case undetermined
    case denied
    case granted
}

public protocol MicrophonePermissionProviding: Sendable {
    func status() -> MicrophonePermissionStatus
    /// Prompts the user if the status is undetermined. Returns whether access is granted.
    func request() async -> Bool
}

/// The system (TCC) microphone permission.
public struct SystemMicrophonePermission: MicrophonePermissionProviding {
    public init() {}

    public func status() -> MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    public func request() async -> Bool {
        switch status() {
        case .granted: true
        case .denied: false
        case .undetermined: await AVCaptureDevice.requestAccess(for: .audio)
        }
    }
}
