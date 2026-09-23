@preconcurrency import AVFoundation
import Foundation
import Shared

/// How capture recovers when the capture session fails or the default microphone goes away.
public struct CaptureRestartPolicy: Sendable, Equatable {
    /// Consecutive failed start attempts per recovery before giving up.
    public let maxAttempts: Int
    /// Wait before each restart attempt, so the system can settle or pick a new default device.
    public let delaySeconds: Double
    /// Recoveries allowed in any 60 s window before capture stops with an error.
    public let maxRestartsPerMinute: Int

    public init(maxAttempts: Int, delaySeconds: Double, maxRestartsPerMinute: Int) {
        self.maxAttempts = max(0, maxAttempts)
        self.delaySeconds = max(0, delaySeconds)
        self.maxRestartsPerMinute = max(1, maxRestartsPerMinute)
    }

    public init(settings: AppSettings) {
        self.init(
            maxAttempts: settings.captureRestartAttempts,
            delaySeconds: settings.captureRestartDelaySeconds,
            maxRestartsPerMinute: settings.captureMaxRestartsPerMinute
        )
    }
}

/// Microphone capture through an input-only `AVCaptureSession`, delivered as 16 kHz mono Float32.
///
/// Captures from the device with the given UID (an `AVCaptureDevice.uniqueID`, which on macOS is
/// the Core Audio device UID), or from the system default input when it is `nil`.
///
/// A capture session has no output side and keeps running while its input device reconfigures.
/// That matters for Bluetooth headsets: opening a headset's microphone switches it to its call
/// profile, and the resulting device reconfiguration stops an `AVAudioEngine` on every start.
///
/// Recovery: a session runtime error, or the system default microphone disconnecting, rebuilds
/// the session per ``CaptureRestartPolicy``, rate-limited by ``RestartGovernor``. A microphone the
/// user chose that disconnects ends the stream with ``CaptureError/inputDeviceUnavailable``
/// rather than silently switching to another microphone.
public actor CaptureSessionSource: AudioSource {
    private let restartPolicy: CaptureRestartPolicy
    private let inputDeviceUID: String?
    private var governor: RestartGovernor
    private var session: AVCaptureSession?
    /// Kept alive here: the capture output does not document that it retains its delegate.
    private var forwarder: SampleForwarder?
    private var observers: [any NSObjectProtocol] = []
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    private var recoveryTask: Task<Void, Never>?

    /// `startRunning()` and `stopRunning()` block until the session changes state, so the actor
    /// runs on its own serial queue instead of occupying a cooperative-pool thread.
    private let queue = DispatchSerialQueue(label: "LiveTranscribe.CaptureSession", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Sample buffers arrive on their own queue, so a blocking start or stop never delays audio.
    private let sampleQueue = DispatchQueue(label: "LiveTranscribe.CaptureSamples", qos: .userInitiated)

    public init(restartPolicy: CaptureRestartPolicy, inputDeviceUID: String? = nil) {
        self.restartPolicy = restartPolicy
        self.inputDeviceUID = inputDeviceUID
        self.governor = RestartGovernor(maxRestarts: restartPolicy.maxRestartsPerMinute)
    }

    public func start() throws -> AsyncThrowingStream<[Float], Error> {
        guard continuation == nil else { throw CaptureError.alreadyRunning }
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.stop() }
        }
        do {
            try startSession(yieldingTo: continuation)
        } catch {
            continuation.finish(throwing: error)
            throw error
        }
        self.continuation = continuation
        return stream
    }

    public func stop() {
        recoveryTask?.cancel()
        recoveryTask = nil
        tearDownSession()
        if continuation != nil {
            Log.capture.info("Capture stopped")
        }
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Session lifecycle

    private func startSession(yieldingTo continuation: AsyncThrowingStream<[Float], Error>.Continuation) throws {
        let device = try resolveDevice()
        let session = AVCaptureSession()
        let forwarder = SampleForwarder(continuation: continuation)

        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
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
        observe(session, device: device)
        session.startRunning()
        guard session.isRunning else {
            removeObservers()
            throw CaptureError.startFailed("the capture session did not start")
        }
        self.session = session
        self.forwarder = forwarder
        Log.capture.info("Capture started: \(device.localizedName, privacy: .private) → 16 kHz mono")
    }

    private func resolveDevice() throws -> AVCaptureDevice {
        if let inputDeviceUID {
            guard let device = AVCaptureDevice(uniqueID: inputDeviceUID),
                  device.hasMediaType(.audio),
                  device.isConnected
            else { throw CaptureError.inputDeviceUnavailable }
            return device
        }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.noInputDevice
        }
        return device
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

    private func observe(_ session: AVCaptureSession, device: AVCaptureDevice) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                let failure = Failure.runtimeError(error?.localizedDescription ?? "unknown error")
                Task { await self?.handle(failure) }
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                Task { await self?.handle(.deviceDisconnected) }
            },
        ]
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    private func tearDownSession() {
        removeObservers()
        if let session {
            session.stopRunning()
            for case let output as AVCaptureAudioDataOutput in session.outputs {
                output.setSampleBufferDelegate(nil, queue: nil)
            }
        }
        session = nil
        forwarder = nil
    }

    // MARK: - Recovery

    private enum Failure: CustomStringConvertible {
        case runtimeError(String)
        case deviceDisconnected

        var description: String {
            switch self {
            case .runtimeError(let message): "runtime error: \(message)"
            case .deviceDisconnected: "microphone disconnected"
            }
        }
    }

    private func handle(_ failure: Failure) {
        guard let continuation, recoveryTask == nil else { return }
        tearDownSession()
        // A microphone the user chose is not swapped for another one behind their back.
        if case .deviceDisconnected = failure, inputDeviceUID != nil {
            Log.capture.error("The selected microphone disconnected; stopping capture")
            fail(continuation, with: .inputDeviceUnavailable)
            return
        }
        guard governor.allowRestart(at: .now) else {
            let limit = restartPolicy.maxRestartsPerMinute
            Log.capture.error("Capture failed more than \(limit) times in a minute; stopping capture")
            fail(continuation, with: .tooManyRestarts(restarts: limit))
            return
        }
        Log.capture.notice("Capture interrupted (\(failure.description, privacy: .public)); restarting")
        recoveryTask = Task { await self.recover(yieldingTo: continuation) }
    }

    private func recover(yieldingTo continuation: AsyncThrowingStream<[Float], Error>.Continuation) async {
        var attempts = 0
        var lastError: (any Error)?
        while attempts < restartPolicy.maxAttempts {
            try? await Task.sleep(for: .seconds(restartPolicy.delaySeconds))
            attempts += 1
            // Stopped while waiting: nothing to recover.
            guard !Task.isCancelled, self.continuation != nil else { return }
            do {
                try startSession(yieldingTo: continuation)
                Log.capture.info("Capture restarted after \(attempts) attempt(s)")
                recoveryTask = nil
                return
            } catch {
                lastError = error
                Log.capture.error("Capture restart attempt \(attempts) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        Log.capture.error("Capture could not restart after \(attempts) attempt(s)")
        recoveryTask = nil
        // A missing device says more than a generic restart failure.
        let failure = (lastError as? CaptureError) == .inputDeviceUnavailable
            ? CaptureError.inputDeviceUnavailable
            : CaptureError.restartFailed(attempts: attempts)
        fail(continuation, with: failure)
    }

    private func fail(_ continuation: AsyncThrowingStream<[Float], Error>.Continuation, with error: CaptureError) {
        self.continuation = nil
        continuation.finish(throwing: error)
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

/// Turns capture sample buffers into 16 kHz mono Float32.
///
/// The capture output is asked for exactly that format, so buffers normally pass straight
/// through. Any other format (an OS that ignores the request, or a mid-stream format change) goes
/// through a ``SampleRateConverter``, rebuilt whenever the incoming format changes.
struct CaptureSampleConverter {
    private var converter: SampleRateConverter?

    mutating func samples(from sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return [] }
        let format = buffer.format
        if format.commonFormat == .pcmFormatFloat32,
           format.sampleRate == Double(AudioFormat.sampleRate),
           format.channelCount == 1,
           let channel = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }
        if converter?.inputFormat != format {
            do {
                converter = try SampleRateConverter(inputFormat: format)
            } catch {
                converter = nil
                Log.capture.error("Unsupported capture format: \(format.description, privacy: .public)")
            }
        }
        return converter?.convert(buffer) ?? []
    }

    /// Copies a sample buffer's PCM data into an `AVAudioPCMBuffer` of the same format.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
