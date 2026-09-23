@preconcurrency import AVFoundation
import Foundation
import Shared

/// Why a running capture stopped delivering audio.
enum CaptureInterruption: Sendable, CustomStringConvertible {
    case runtimeError(String)
    case deviceDisconnected
    /// Opening the next device, after a device change, failed.
    case switchFailed(String)

    var description: String {
        switch self {
        case .runtimeError(let message): "runtime error: \(message)"
        case .deviceDisconnected: "microphone disconnected"
        case .switchFailed(let message): "switching microphone failed: \(message)"
        }
    }
}

/// Capture running on one device. Stopping it is final.
protocol RunningCapture: AnyObject {
    /// Stops delivery and releases the device. Blocks until the device has stopped.
    func stop()
}

/// Opens capture on one device. ``CaptureSessionSource`` decides which device and when; this is
/// the thin OS layer underneath, replaced by a fake in tests.
protocol CaptureSessionOpening: Sendable {
    /// Starts delivering the device's audio, as 16 kHz mono Float32, to `continuation`.
    /// `onInterruption` may be called from any thread when the running capture fails.
    func open(
        _ device: AudioInputDevice,
        yieldingTo continuation: AsyncThrowingStream<[Float], Error>.Continuation,
        onInterruption: @escaping @Sendable (CaptureInterruption) -> Void
    ) throws -> any RunningCapture
}

/// Opens input-only `AVCaptureSession`s.
///
/// A capture session has no output side and keeps running while its input device reconfigures.
/// That matters for Bluetooth headsets: opening a headset's microphone switches it to its call
/// profile, and the resulting device reconfiguration stops an `AVAudioEngine` on every start.
struct AVCaptureSessionOpener: CaptureSessionOpening {
    /// Sample buffers arrive on their own queue, so a blocking start or stop never delays audio.
    private let sampleQueue = DispatchQueue(label: "LiveTranscribe.CaptureSamples", qos: .userInitiated)

    /// Blocks until the session is running: call it off the cooperative thread pool.
    func open(
        _ device: AudioInputDevice,
        yieldingTo continuation: AsyncThrowingStream<[Float], Error>.Continuation,
        onInterruption: @escaping @Sendable (CaptureInterruption) -> Void
    ) throws -> any RunningCapture {
        // The policy chose from a list read moments ago; the device can still vanish in between.
        guard let captureDevice = AVCaptureDevice(uniqueID: device.id),
              captureDevice.hasMediaType(.audio),
              captureDevice.isConnected
        else { throw CaptureError.startFailed("the microphone disconnected before capture could open it") }

        let session = AVCaptureSession()
        let forwarder = SampleForwarder(continuation: continuation)
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: captureDevice)
            guard session.canAddInput(input) else {
                throw CaptureError.startFailed("the microphone can't be added to a capture session")
            }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            output.audioSettings = Self.outputSettings()
            output.setSampleBufferDelegate(forwarder, queue: sampleQueue)
            guard session.canAddOutput(output) else {
                throw CaptureError.startFailed("the audio output can't be added to a capture session")
            }
            session.addOutput(output)
        } catch let error as CaptureError {
            session.commitConfiguration()
            throw error
        } catch {
            session.commitConfiguration()
            throw CaptureError.startFailed(error.localizedDescription)
        }
        session.commitConfiguration()

        // Observe before starting, so an error raised while starting is not missed.
        let running = AVRunningCapture(session: session, forwarder: forwarder)
        running.observe(device: captureDevice, onInterruption: onInterruption)
        session.startRunning()
        guard session.isRunning else {
            running.stop()
            throw CaptureError.startFailed("the capture session did not start")
        }
        return running
    }

    /// Asks the capture output for 16 kHz mono Float32, so a device format change (a headset
    /// switching profiles) is absorbed by AVFoundation's converter.
    private static func outputSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(AudioFormat.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }
}

/// One running `AVCaptureSession` and the observers that report its failures.
private final class AVRunningCapture: RunningCapture {
    private let session: AVCaptureSession
    /// Kept alive here: the capture output does not document that it retains its delegate.
    private let forwarder: SampleForwarder
    private var observers: [any NSObjectProtocol] = []

    init(session: AVCaptureSession, forwarder: SampleForwarder) {
        self.session = session
        self.forwarder = forwarder
    }

    func observe(device: AVCaptureDevice, onInterruption: @escaping @Sendable (CaptureInterruption) -> Void) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                onInterruption(.runtimeError(error?.localizedDescription ?? "unknown error"))
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
                onInterruption(.deviceDisconnected)
            },
        ]
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        session.stopRunning()
        for case let output as AVCaptureAudioDataOutput in session.outputs {
            output.setSampleBufferDelegate(nil, queue: nil)
        }
    }
}

/// Receives sample buffers from the capture output and yields them as 16 kHz mono Float32.
///
/// `@unchecked Sendable`: AVFoundation calls `captureOutput(_:didOutput:from:)` serially on the
/// one queue the delegate was registered with, and only that method touches `converter`.
private final class SampleForwarder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    private var converter = CaptureSampleConverter()

    init(continuation: AsyncThrowingStream<[Float], Error>.Continuation) {
        self.continuation = continuation
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let samples = converter.samples(from: sampleBuffer)
        if !samples.isEmpty {
            continuation.yield(samples)
        }
    }
}
