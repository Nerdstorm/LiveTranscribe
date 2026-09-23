import Cleanup
import Foundation
import Persistence
import Segmentation
import Shared
import Transcription

/// One listening session: capture → segmentation → transcription → cleanup → storage.
///
/// Three loops run concurrently and hand work downstream through AsyncStreams. Raw transcripts
/// are never dropped: the transcription queue is unbounded, and when the bounded cleanup queue
/// overflows, the oldest pending segment is saved with its raw text instead of being cleaned.
actor SessionPipeline {
    struct Configuration: Sendable {
        let sessionID: UUID
        let contextSegments: Int
        let cleanupQueueCapacity: Int
        /// Read once at Start, so a session is cleaned at one level throughout.
        let cleanupOptions: CleanupOptions
    }

    private struct TranscriptionJob: Sendable {
        let audio: SpeechAudio
        let closedAt: ContinuousClock.Instant
    }

    private struct CleanupJob: Sendable {
        let segment: Segment
        let latency: StageLatencies
        let closedAt: ContinuousClock.Instant
    }

    private let configuration: Configuration
    private let segmenter: any SpeechSegmenter
    private let transcriber: any Transcriber
    /// `nil` runs the session raw-only.
    private let cleaner: (any Cleaner)?
    private let sink: any SessionSink
    private let emit: @Sendable (SessionEvent) -> Void

    private var finalizedSegments: Set<UUID> = []
    private var partialTask: Task<Void, Never>?
    private var cleanedContext: [String] = []

    init(
        configuration: Configuration,
        segmenter: any SpeechSegmenter,
        transcriber: any Transcriber,
        cleaner: (any Cleaner)?,
        sink: any SessionSink,
        emit: @escaping @Sendable (SessionEvent) -> Void
    ) {
        self.configuration = configuration
        self.segmenter = segmenter
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.sink = sink
        self.emit = emit
    }

    /// Runs until the audio stream ends and every queued segment is saved.
    /// - Returns: the error that ended capture early, or `nil` if capture was stopped normally.
    func run(audio: AsyncThrowingStream<[Float], Error>) async -> Error? {
        let (transcriptionJobs, transcriptionInput) = AsyncStream.makeStream(of: TranscriptionJob.self)
        let (cleanupJobs, cleanupInput) = AsyncStream.makeStream(
            of: CleanupJob.self,
            bufferingPolicy: .bufferingNewest(max(1, configuration.cleanupQueueCapacity))
        )

        return await withTaskGroup(of: Error?.self) { group in
            group.addTask { await self.runCapture(audio, into: transcriptionInput) }
            group.addTask {
                await self.runTranscription(transcriptionJobs, into: cleanupInput)
                return nil
            }
            group.addTask {
                await self.runCleanup(cleanupJobs)
                return nil
            }
            var failure: Error?
            for await result in group where result != nil {
                failure = result
            }
            return failure
        }
    }

    // MARK: - Capture and segmentation

    private func runCapture(
        _ audio: AsyncThrowingStream<[Float], Error>,
        into jobs: AsyncStream<TranscriptionJob>.Continuation
    ) async -> Error? {
        var failure: Error?
        do {
            for try await samples in audio {
                handle(try await segmenter.process(samples), jobs: jobs)
            }
        } catch {
            Log.session.error("Capture ended with an error: \(error.localizedDescription, privacy: .public)")
            failure = error
        }
        handle(await segmenter.flush(), jobs: jobs)
        // No partial may be emitted after the session's final segments.
        await partialTask?.value
        jobs.finish()
        return failure
    }

    private func handle(_ events: [SegmentationEvent], jobs: AsyncStream<TranscriptionJob>.Continuation) {
        for event in events {
            switch event {
            case .speechStarted(let id, let startMs):
                Log.segmentation.debug("Speech started \(id.uuidString, privacy: .public) at \(startMs) ms")
            case .partial(let audio):
                requestPartial(audio)
            case .closed(let audio, let reason):
                Log.segmentation.info(
                    "Segment closed (\(reason.rawValue, privacy: .public)): \(audio.endMs - audio.startMs) ms audio"
                )
                jobs.yield(TranscriptionJob(audio: audio, closedAt: .now))
            case .discarded(let id):
                finalizedSegments.insert(id)
                emit(.discarded(segmentID: id))
            }
        }
    }

    /// At most one partial transcription runs at a time; snapshots arriving meanwhile are
    /// skipped because the next one will contain their audio anyway.
    private func requestPartial(_ audio: SpeechAudio) {
        guard partialTask == nil else { return }
        let transcriber = self.transcriber
        partialTask = Task {
            let text = try? await transcriber.transcribe(audio.samples, sampleRate: AudioFormat.sampleRate)
            self.finishPartial(segmentID: audio.segmentID, text: text)
        }
    }

    private func finishPartial(segmentID: UUID, text: String?) {
        partialTask = nil
        guard let text, !text.isEmpty, !finalizedSegments.contains(segmentID) else { return }
        emit(.partial(segmentID: segmentID, text: text))
    }

    // MARK: - Transcription

    private func runTranscription(
        _ jobs: AsyncStream<TranscriptionJob>,
        into cleanupQueue: AsyncStream<CleanupJob>.Continuation
    ) async {
        for await job in jobs {
            let segmentID = job.audio.segmentID
            let started = ContinuousClock.now
            let text: String
            do {
                text = try await transcriber.transcribe(job.audio.samples, sampleRate: AudioFormat.sampleRate)
            } catch {
                Log.transcription.error("STT failed; skipping segment: \(error.localizedDescription, privacy: .public)")
                finalizedSegments.insert(segmentID)
                emit(.discarded(segmentID: segmentID))
                continue
            }
            finalizedSegments.insert(segmentID)
            guard !text.isEmpty else {
                emit(.discarded(segmentID: segmentID))
                continue
            }

            let segment = Segment(
                id: segmentID,
                sessionID: configuration.sessionID,
                startMs: job.audio.startMs,
                endMs: job.audio.endMs,
                rawText: text
            )
            let latency = StageLatencies(
                vadMs: job.audio.trailingSilenceMs,
                sttMs: started.duration(to: .now).wholeMilliseconds
            )
            Log.transcription.info("Transcribed \(segment.endMs - segment.startMs) ms: \(text, privacy: .private)")
            emit(.transcribed(segment))

            let pending = CleanupJob(segment: segment, latency: latency, closedAt: job.closedAt)
            guard cleaner != nil else {
                await complete(pending, cleaned: nil)
                continue
            }
            if case .dropped(let dropped) = cleanupQueue.yield(pending) {
                Log.cleanup.warning("Cleanup queue full; saving the oldest pending segment with its raw text")
                await complete(dropped, cleaned: .fallback(dropped.segment, reason: "cleanup queue full", latencyMs: 0))
            }
        }
        cleanupQueue.finish()
    }

    // MARK: - Cleanup

    private func runCleanup(_ jobs: AsyncStream<CleanupJob>) async {
        guard let cleaner else {
            for await _ in jobs {}
            return
        }
        for await job in jobs {
            let context = Array(cleanedContext.suffix(configuration.contextSegments))
            let cleaned = await cleaner.clean(job.segment, context: context, options: configuration.cleanupOptions)
            cleanedContext.append(cleaned.cleanedText)
            if cleanedContext.count > configuration.contextSegments {
                cleanedContext.removeFirst(cleanedContext.count - configuration.contextSegments)
            }
            await complete(job, cleaned: cleaned)
        }
    }

    // MARK: - Completion

    /// Saves the segment's record and publishes its final text.
    private func complete(_ job: CleanupJob, cleaned: CleanedSegment?) async {
        var latency = job.latency
        latency.llmMs = cleaned?.latencyMs
        latency.totalMs = latency.vadMs + job.closedAt.duration(to: .now).wholeMilliseconds

        let record = SegmentRecord(segment: job.segment, cleaned: cleaned, latency: latency, recordedAt: Date())
        do {
            try await sink.append(record)
        } catch {
            Log.persistence.error("Could not save segment: \(error.localizedDescription, privacy: .public)")
            emit(.warning("A segment could not be saved: \(error.localizedDescription)"))
        }
        if let cleaned {
            emit(.cleaned(cleaned))
        }
        Log.session.info(
            "Latency vad=\(latency.vadMs) stt=\(latency.sttMs) llm=\(latency.llmMs ?? -1) total=\(latency.totalMs ?? -1) ms"
        )
    }
}
