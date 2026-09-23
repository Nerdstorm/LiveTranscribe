import Capture
import Foundation
import Shared

/// Records one dictation from the microphone into memory.
///
/// By default capture opens when recording starts and closes when it stops, so the microphone
/// indicator is on only while the user dictates. With *keep ready* on, capture stays open
/// between dictations and the most recent `preRollMs` of audio is kept, so a recording starts
/// instantly and includes the moment before the key was pressed.
public actor DictationRecorder {
    public struct Configuration: Sendable, Equatable {
        /// Audio from before the key press kept while capture is ready. Unused otherwise.
        public var preRollMs: Int
        /// Recording stops growing at this length, so a stuck key cannot exhaust memory.
        public var maxDurationSeconds: Int
        /// The chosen microphone, `nil` for the system default. A change reopens capture that is
        /// kept ready, so the new choice is used without waiting for capture to close.
        public var inputDeviceUID: String?

        public init(preRollMs: Int, maxDurationSeconds: Int, inputDeviceUID: String? = nil) {
            self.preRollMs = preRollMs
            self.maxDurationSeconds = maxDurationSeconds
            self.inputDeviceUID = inputDeviceUID
        }
    }

    /// What a finished recording holds.
    public struct Recording: Sendable, Equatable {
        public let samples: [Float]
        /// The recording hit ``Configuration/maxDurationSeconds`` and the rest was dropped.
        public let truncated: Bool
        /// Why capture failed or ended during the recording; `samples` holds what arrived
        /// before it did.
        public let failure: String?

        public var durationMs: Int { AudioFormat.milliseconds(forSamples: samples.count) }
    }

    /// Something that happened to the recording in progress by itself, for the owner to act on.
    public enum Event: Sendable, Equatable {
        /// Capture ended during the recording, so nothing more arrives: the microphone failed,
        /// or went away and could not be recovered. ``stop()`` returns what arrived before, with
        /// the reason in ``Recording/failure``.
        case captureEnded
    }

    private let makeSource: @Sendable (_ inputDeviceUID: String?) -> any AudioSource
    private var configuration: Configuration
    private var source: (any AudioSource)?
    /// Counts the captures opened, so a pump that outlived its capture is recognised as stale.
    private var sourceGeneration = 0
    /// The microphone choice the open ``source`` was made for.
    private var sourceDeviceUID: String?
    private var pump: Task<Void, Never>?
    private var keepReady = false
    private var isOpening = false
    private var isRecording = false
    private var samples: [Float] = []
    private var preRoll: [Float] = []
    private var truncated = false
    private var failure: String?

    /// Input level (RMS of each buffer, 0...1) while recording, for the HUD's meter.
    public nonisolated let levels: AsyncStream<Float>
    private nonisolated let levelInput: AsyncStream<Float>.Continuation
    /// What happens to the recording in progress by itself; see ``Event``.
    public nonisolated let events: AsyncStream<Event>
    private nonisolated let eventInput: AsyncStream<Event>.Continuation

    /// Whether capture ended during the recording in progress, so it gets no more audio. An
    /// ``Event/captureEnded`` may be read late, after that recording stopped and another
    /// started; this says whether it still applies.
    public var hasLostCapture: Bool { isRecording && failure != nil }

    /// - Parameter makeSource: Makes capture for the chosen microphone (`nil`: system default).
    public init(makeSource: @escaping @Sendable (_ inputDeviceUID: String?) -> any AudioSource, configuration: Configuration) {
        self.makeSource = makeSource
        self.configuration = configuration
        (levels, levelInput) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
        (events, eventInput) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Applies new settings. A new microphone choice reopens capture that is kept ready and idle;
    /// during a recording it applies once the recording stops.
    public func update(_ configuration: Configuration) async {
        self.configuration = configuration
        guard !isRecording else { return }
        await reopenIfTheChoiceChanged()
    }

    /// Keeps capture open between dictations, or closes it once no recording needs it.
    public func setKeepReady(_ ready: Bool) async throws {
        guard ready != keepReady else { return }
        keepReady = ready
        if ready {
            try await openIfNeeded()
        } else if !isRecording {
            await close()
        }
    }

    /// Starts a recording. Throws when capture cannot start (no microphone, permission revoked).
    public func start() async throws {
        guard !isRecording else { return }
        let wasOpen = source != nil
        samples = wasOpen ? preRoll : []
        preRoll = []
        truncated = false
        failure = nil
        isRecording = true
        do {
            try await openIfNeeded()
        } catch {
            isRecording = false
            throw error
        }
        Log.dictation.debug("Recording started (\(wasOpen ? "from standby" : "opened capture", privacy: .public))")
    }

    /// Ends the recording and returns it. Capture closes unless it is kept ready.
    public func stop() async -> Recording {
        guard isRecording else { return Recording(samples: [], truncated: false, failure: nil) }
        isRecording = false
        let recording = Recording(samples: samples, truncated: truncated, failure: failure)
        samples = []
        if keepReady {
            await reopenIfTheChoiceChanged()
        } else {
            await close()
        }
        return recording
    }

    /// Discards the recording.
    public func cancel() async {
        _ = await stop()
    }

    // MARK: - Capture

    private func openIfNeeded() async throws {
        guard source == nil, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        let deviceUID = configuration.inputDeviceUID
        let source = makeSource(deviceUID)
        let stream: AsyncThrowingStream<[Float], Error>
        do {
            stream = try await source.start()
        } catch {
            if isRecording { failure = error.localizedDescription }
            throw error
        }
        // Cancelled, or keep-ready turned off, while capture was starting.
        guard isRecording || keepReady else {
            await source.stop()
            return
        }
        self.source = source
        sourceDeviceUID = deviceUID
        sourceGeneration += 1
        let generation = sourceGeneration
        pump = Task { [weak self] in
            do {
                for try await buffer in stream {
                    await self?.receive(buffer)
                }
                await self?.captureEnded(failure: nil, generation: generation)
            } catch {
                await self?.captureEnded(failure: error, generation: generation)
            }
        }
    }

    /// Capture kept ready for another microphone than the one now chosen is closed and opened
    /// again for the new one.
    private func reopenIfTheChoiceChanged() async {
        guard keepReady, source != nil, sourceDeviceUID != configuration.inputDeviceUID else { return }
        Log.dictation.info("Microphone choice changed; reopening the microphone kept ready")
        await close()
        do {
            try await openIfNeeded()
        } catch {
            Log.dictation.error("Could not reopen the microphone kept ready: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func close() async {
        let source = self.source
        self.source = nil
        pump?.cancel()
        pump = nil
        preRoll = []
        await source?.stop()
    }

    private func receive(_ buffer: [Float]) {
        if isRecording {
            let limit = AudioFormat.samples(forMilliseconds: configuration.maxDurationSeconds * 1_000)
            let room = max(0, limit - samples.count)
            if buffer.count > room {
                if !truncated {
                    Log.dictation.notice("Recording reached \(self.configuration.maxDurationSeconds) s; the rest is dropped")
                }
                truncated = true
            }
            samples.append(contentsOf: buffer.prefix(room))
            levelInput.yield(Self.rms(buffer))
        } else if keepReady {
            preRoll.append(contentsOf: buffer)
            let keep = AudioFormat.samples(forMilliseconds: configuration.preRollMs)
            if preRoll.count > keep {
                preRoll.removeFirst(preRoll.count - keep)
            }
        }
    }

    /// Capture ended on its own: a failure, or the device went away for good. A recording in
    /// progress keeps what arrived and is reported, so it can end now instead of listening on
    /// to nothing.
    private func captureEnded(failure error: Error?, generation: Int) {
        // Closed by us, or a capture already replaced by a newer one.
        guard source != nil, generation == sourceGeneration else { return }
        let reason = error?.localizedDescription ?? "Capture ended unexpectedly."
        if error != nil {
            Log.dictation.error("Capture failed: \(reason, privacy: .public)")
        } else {
            Log.dictation.notice("Capture ended by itself")
        }
        source = nil
        pump = nil
        preRoll = []
        guard isRecording else { return }
        failure = reason
        eventInput.yield(.captureEnded)
    }

    static func rms(_ buffer: [Float]) -> Float {
        guard !buffer.isEmpty else { return 0 }
        let sum = buffer.reduce(Float(0)) { $0 + $1 * $1 }
        return min(1, (sum / Float(buffer.count)).squareRoot())
    }
}
