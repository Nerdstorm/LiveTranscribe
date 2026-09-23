import Foundation
import Shared

/// Microphone capture through an input-only `AVCaptureSession`, delivered as 16 kHz mono Float32.
///
/// Captures from the device with the given UID (an `AVCaptureDevice.uniqueID`, which on macOS is
/// the Core Audio device UID), or follows the system default input when it is `nil`. Which device
/// is opened, and when capture moves to another one, is decided by ``InputDevicePolicy``:
///
/// - **Following the default**: when macOS's default input changes mid-session, the session is
///   rebuilt on the new device without ending the stream. Virtual devices are not followed.
/// - **A chosen microphone that disconnects** (or is missing at start) falls back to the system
///   default, and capture returns to it when it reconnects.
///
/// Every such move is reported through `onNotice`. A session runtime error or a lost device
/// rebuilds the session per ``CaptureRestartPolicy``, rate-limited by ``RestartGovernor``.
/// Switches after default-input changes have their own governor, so a flapping default cannot
/// loop and cannot use up the recovery budget; a switch it refuses is retried once switching is
/// allowed again, so capture still ends up on the default the flapping settled on.
public actor CaptureSessionSource: AudioSource {
    /// The minute in ``CaptureRestartPolicy/maxRestartsPerMinute``.
    private static let rateWindow: Duration = .seconds(60)

    private let restartPolicy: CaptureRestartPolicy
    private let inputDeviceUID: String?
    private let onNotice: (@Sendable (CaptureNotice) -> Void)?
    private let catalog: any InputDeviceCatalog
    private let opener: any CaptureSessionOpening

    private var governor: RestartGovernor
    private var switchGovernor: RestartGovernor
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    private var running: (any RunningCapture)?
    /// The device of the last session that started; kept through a recovery for its notices.
    private var currentDevice: AudioInputDevice?
    /// The system default when devices were last reviewed; see ``InputDevicePolicy``.
    private var lastSeenDefaultUID: String?
    /// Increases with every session opened, so late failure reports from an earlier one are ignored.
    private var generation = 0
    private var recoveryTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    /// A review waiting for the switch governor to allow another switch.
    private var deferredReviewTask: Task<Void, Never>?

    /// Starting and stopping a capture session block until the session changes state, so the
    /// actor runs on its own serial queue instead of occupying a cooperative-pool thread.
    private let queue = DispatchSerialQueue(label: "LiveTranscribe.CaptureSession", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// - Parameter onNotice: told when capture moves to, or stays on, a device the user might not
    ///   expect (see ``CaptureNotice``). Called on capture's own queue; hop to the main actor to
    ///   show it.
    public init(
        restartPolicy: CaptureRestartPolicy,
        inputDeviceUID: String? = nil,
        onNotice: (@Sendable (CaptureNotice) -> Void)? = nil
    ) {
        self.init(
            restartPolicy: restartPolicy,
            inputDeviceUID: inputDeviceUID,
            onNotice: onNotice,
            catalog: SystemInputDeviceCatalog(),
            opener: AVCaptureSessionOpener(),
            rateWindow: Self.rateWindow
        )
    }

    /// Takes the device list and the session layer explicitly, so tests can run without hardware,
    /// and the rate-limit window, so they need not wait a minute for it to pass.
    init(
        restartPolicy: CaptureRestartPolicy,
        inputDeviceUID: String?,
        onNotice: (@Sendable (CaptureNotice) -> Void)?,
        catalog: any InputDeviceCatalog,
        opener: any CaptureSessionOpening,
        rateWindow: Duration
    ) {
        self.restartPolicy = restartPolicy
        self.inputDeviceUID = inputDeviceUID
        self.onNotice = onNotice
        self.catalog = catalog
        self.opener = opener
        self.governor = RestartGovernor(maxRestarts: restartPolicy.maxRestartsPerMinute, window: rateWindow)
        self.switchGovernor = RestartGovernor(maxRestarts: restartPolicy.maxRestartsPerMinute, window: rateWindow)
    }

    /// A source dropped without ``stop()`` must not keep observing the hardware: the observation
    /// task holds the Core Audio listeners, and it only holds this actor weakly.
    deinit {
        changesTask?.cancel()
        reviewTask?.cancel()
        deferredReviewTask?.cancel()
        recoveryTask?.cancel()
    }

    public func start() throws -> AsyncThrowingStream<[Float], Error> {
        guard continuation == nil else { throw CaptureError.alreadyRunning }
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.stop() }
        }
        // Observe before reading the hardware: opening a device can block for a second (a
        // Bluetooth headset changing profile), and a change in that time must not be missed.
        watchDeviceChanges()
        do {
            try openChosenDevice(yieldingTo: continuation)
        } catch {
            end()
            continuation.finish(throwing: error)
            throw error
        }
        self.continuation = continuation
        return stream
    }

    public func stop() {
        if continuation != nil {
            Log.capture.info("Capture stopped")
        }
        end()
        continuation?.finish()
        continuation = nil
    }

    /// The device capture is on, or `nil` while stopped or recovering. Tests also await it to
    /// know that work already running on the actor, such as a device review, has finished.
    var activeDevice: AudioInputDevice? {
        running == nil ? nil : currentDevice
    }

    // MARK: - Sessions

    /// Opens the device ``InputDevicePolicy`` picks, then reports its notice.
    private func openChosenDevice(yieldingTo continuation: AsyncThrowingStream<[Float], Error>.Continuation) throws {
        let snapshot = catalog.snapshot()
        let choice = try InputDevicePolicy.deviceToOpen(selectedUID: inputDeviceUID, previous: currentDevice, in: snapshot)
        try open(choice.device, yieldingTo: continuation)
        lastSeenDefaultUID = snapshot.systemDefault?.id
        if let notice = choice.notice { report(notice) }
    }

    private func open(_ device: AudioInputDevice, yieldingTo continuation: AsyncThrowingStream<[Float], Error>.Continuation) throws {
        generation += 1
        let sessionGeneration = generation
        running = try opener.open(device, yieldingTo: continuation) { [weak self] interruption in
            Task { await self?.handle(interruption, generation: sessionGeneration) }
        }
        currentDevice = device
        Log.capture.info("Capture started: \(device.name, privacy: .private) → 16 kHz mono")
    }

    private func tearDownSession() {
        running?.stop()
        running = nil
    }

    /// Stops everything except the stream itself.
    private func end() {
        recoveryTask?.cancel()
        recoveryTask = nil
        reviewTask?.cancel()
        reviewTask = nil
        deferredReviewTask?.cancel()
        deferredReviewTask = nil
        changesTask?.cancel()
        changesTask = nil
        tearDownSession()
        currentDevice = nil
        lastSeenDefaultUID = nil
    }

    private func report(_ notice: CaptureNotice) {
        Log.capture.notice("Microphone notice \(notice.kind, privacy: .public): \(notice.message, privacy: .private)")
        onNotice?(notice)
    }

    // MARK: - Following device changes

    private func watchDeviceChanges() {
        let changes = catalog.changes()
        changesTask = Task { [weak self] in
            for await _ in changes {
                await self?.devicesChanged()
            }
        }
    }

    /// Waits for the system to settle, then reviews once however many changes arrived meanwhile.
    private func devicesChanged() {
        guard continuation != nil, reviewTask == nil else { return }
        reviewTask = Task { await self.reviewDevicesAfterSettling() }
    }

    private func reviewDevicesAfterSettling() async {
        try? await Task.sleep(for: .seconds(restartPolicy.delaySeconds))
        guard !Task.isCancelled else { return }
        reviewTask = nil
        // A recovery re-resolves the device itself; a stopped source has nothing to review.
        guard let continuation, recoveryTask == nil, running != nil, let current = currentDevice else { return }

        let snapshot = catalog.snapshot()
        let previousDefaultUID = lastSeenDefaultUID
        lastSeenDefaultUID = snapshot.systemDefault?.id
        let decision = InputDevicePolicy.decisionAfterChange(
            selectedUID: inputDeviceUID,
            current: current,
            previousDefaultUID: previousDefaultUID,
            in: snapshot
        )
        switch decision {
        case .keep(let notice):
            if let notice { report(notice) }
        case .switchTo(let device, let notice):
            let now = ContinuousClock.now
            guard switchGovernor.allowRestart(at: now) else {
                // Not seen yet, so the review once switching is allowed still acts on it.
                lastSeenDefaultUID = previousDefaultUID
                deferReview(until: switchGovernor.nextAllowedRestart(after: now))
                return
            }
            Log.capture.info("Switching microphone to \(device.name, privacy: .private)")
            tearDownSession()
            do {
                try open(device, yieldingTo: continuation)
                report(notice)
            } catch {
                Log.capture.error("Could not switch microphone: \(error.localizedDescription, privacy: .public)")
                recover(from: .switchFailed(error.localizedDescription))
            }
        }
    }

    /// Reviews the devices again once the switch governor allows it. Without this, a default
    /// that stopped flapping on another device would not be followed until it changed again.
    private func deferReview(until instant: ContinuousClock.Instant) {
        guard deferredReviewTask == nil else { return }
        Log.capture.notice("The microphone changed too often; staying on the current one for now")
        deferredReviewTask = Task {
            try? await Task.sleep(until: instant, clock: .continuous)
            guard !Task.isCancelled else { return }
            self.deferredReviewTask = nil
            self.devicesChanged()
        }
    }

    // MARK: - Recovery

    private func handle(_ interruption: CaptureInterruption, generation: Int) {
        // A report from a session already replaced or torn down.
        guard generation == self.generation, running != nil else { return }
        recover(from: interruption)
    }

    private func recover(from interruption: CaptureInterruption) {
        guard let continuation, recoveryTask == nil else { return }
        tearDownSession()
        guard governor.allowRestart(at: .now) else {
            let limit = restartPolicy.maxRestartsPerMinute
            Log.capture.error("Capture failed more than \(limit) times in a minute; stopping capture")
            fail(continuation, with: .tooManyRestarts(restarts: limit))
            return
        }
        Log.capture.notice("Capture interrupted (\(interruption.description, privacy: .public)); restarting")
        recoveryTask = Task { await self.runRecovery(yieldingTo: continuation) }
    }

    private func runRecovery(yieldingTo continuation: AsyncThrowingStream<[Float], Error>.Continuation) async {
        var attempts = 0
        var lastError: (any Error)?
        while attempts < restartPolicy.maxAttempts {
            try? await Task.sleep(for: .seconds(restartPolicy.delaySeconds))
            attempts += 1
            // Stopped while waiting: nothing to recover.
            guard !Task.isCancelled, self.continuation != nil else { return }
            do {
                try openChosenDevice(yieldingTo: continuation)
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
        fail(continuation, with: .afterFailedRecovery(lastError: lastError, attempts: attempts))
    }

    private func fail(_ continuation: AsyncThrowingStream<[Float], Error>.Continuation, with error: CaptureError) {
        end()
        self.continuation = nil
        continuation.finish(throwing: error)
    }
}
