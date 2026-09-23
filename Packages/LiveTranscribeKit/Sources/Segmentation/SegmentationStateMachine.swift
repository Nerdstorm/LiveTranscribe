import Foundation
import Shared

/// Turns per-chunk speech probabilities into segment events. Pure and deterministic.
///
/// - A segment opens on the first chunk at or above `speechThreshold`, with up to
///   `preRollMs` of the preceding audio prepended.
/// - It closes after `silenceMs` of chunks below `silenceThreshold`, keeping at most
///   `preRollMs` of the trailing silence.
/// - It is force-closed at `maxSegmentMs`; a new segment continues seamlessly.
/// - Segments with less than `minSpeechMs` of speech are discarded instead of closed.
public struct SegmentationStateMachine: Sendable {
    public let config: SegmentationConfig
    private let makeID: @Sendable () -> UUID

    /// Samples ingested since the last reset; the session timeline.
    public private(set) var processedSamples = 0
    private var preRoll: [Float] = []
    private var open: OpenSegment?

    private let preRollSamples: Int
    private let silenceSamples: Int
    private let maxSegmentSamples: Int
    private let minSpeechSamples: Int
    private let partialIntervalSamples: Int

    private struct OpenSegment {
        let id: UUID
        let startSample: Int
        var samples: [Float]
        /// Absolute sample index just after the last chunk classified as speech.
        var lastSpeechEndSample: Int
        var silenceRunSamples: Int
        var speechSamples: Int
        var samplesAtLastPartial: Int
    }

    public init(config: SegmentationConfig, makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.config = config
        self.makeID = makeID
        preRollSamples = AudioFormat.samples(forMilliseconds: max(0, config.preRollMs))
        silenceSamples = max(1, AudioFormat.samples(forMilliseconds: config.silenceMs))
        maxSegmentSamples = max(1, AudioFormat.samples(forMilliseconds: config.maxSegmentMs))
        minSpeechSamples = AudioFormat.samples(forMilliseconds: max(0, config.minSpeechMs))
        partialIntervalSamples = AudioFormat.samples(forMilliseconds: max(0, config.partialIntervalMs))
    }

    public var isInSpeech: Bool { open != nil }

    public mutating func ingest(chunk: [Float], speechProbability probability: Float) -> [SegmentationEvent] {
        let chunkStart = processedSamples
        processedSamples += chunk.count

        guard var segment = open else {
            if probability >= config.speechThreshold {
                return [openSegment(startingWith: chunk, at: chunkStart)]
            }
            appendToPreRoll(chunk)
            return []
        }

        segment.samples.append(contentsOf: chunk)
        if probability >= config.silenceThreshold {
            segment.silenceRunSamples = 0
            segment.lastSpeechEndSample = processedSamples
            segment.speechSamples += chunk.count
        } else {
            segment.silenceRunSamples += chunk.count
        }

        if segment.silenceRunSamples >= silenceSamples {
            open = nil
            return [close(segment, reason: .silence)]
        }

        if segment.samples.count >= maxSegmentSamples {
            // Speech is still running: close what we have and continue in a new segment. No
            // pre-roll, since the new segment's audio is contiguous with the closed one.
            let closed = close(segment, reason: .maxLength)
            let next = OpenSegment(
                id: makeID(),
                startSample: processedSamples,
                samples: [],
                lastSpeechEndSample: processedSamples,
                silenceRunSamples: segment.silenceRunSamples,
                speechSamples: 0,
                samplesAtLastPartial: 0
            )
            open = next
            return [closed, .speechStarted(segmentID: next.id, startMs: milliseconds(next.startSample))]
        }

        var events: [SegmentationEvent] = []
        if partialIntervalSamples > 0,
           segment.silenceRunSamples == 0,
           segment.samples.count - segment.samplesAtLastPartial >= partialIntervalSamples {
            segment.samplesAtLastPartial = segment.samples.count
            events.append(.partial(snapshot(of: segment)))
        }
        open = segment
        return events
    }

    /// Closes the open segment, if any, because capture is ending.
    public mutating func flush() -> [SegmentationEvent] {
        defer { preRoll.removeAll(keepingCapacity: true) }
        guard let segment = open else { return [] }
        open = nil
        return [close(segment, reason: .endOfStream)]
    }

    // MARK: - Private

    private mutating func openSegment(startingWith chunk: [Float], at chunkStart: Int) -> SegmentationEvent {
        let segment = OpenSegment(
            id: makeID(),
            startSample: chunkStart - preRoll.count,
            samples: preRoll + chunk,
            lastSpeechEndSample: processedSamples,
            silenceRunSamples: 0,
            speechSamples: chunk.count,
            samplesAtLastPartial: 0
        )
        preRoll.removeAll(keepingCapacity: true)
        open = segment
        return .speechStarted(segmentID: segment.id, startMs: milliseconds(segment.startSample))
    }

    private mutating func close(_ segment: OpenSegment, reason: SegmentCloseReason) -> SegmentationEvent {
        if reason == .silence {
            // The trailing silence doubles as pre-roll for whatever comes next.
            preRoll = Array(segment.samples.suffix(preRollSamples))
        }
        guard segment.speechSamples >= minSpeechSamples, segment.speechSamples > 0 else {
            return .discarded(segmentID: segment.id)
        }

        let kept: [Float]
        let trailingSilence: Int
        if reason == .maxLength {
            kept = segment.samples
            trailingSilence = 0
        } else {
            let speechEnd = segment.lastSpeechEndSample - segment.startSample
            let tail = min(preRollSamples, segment.samples.count - speechEnd)
            kept = Array(segment.samples[0..<(speechEnd + tail)])
            trailingSilence = processedSamples - segment.lastSpeechEndSample
        }

        let audio = SpeechAudio(
            segmentID: segment.id,
            startMs: milliseconds(segment.startSample),
            endMs: milliseconds(segment.startSample + kept.count),
            samples: kept,
            trailingSilenceMs: milliseconds(trailingSilence)
        )
        return .closed(audio, reason: reason)
    }

    private func snapshot(of segment: OpenSegment) -> SpeechAudio {
        SpeechAudio(
            segmentID: segment.id,
            startMs: milliseconds(segment.startSample),
            endMs: milliseconds(segment.startSample + segment.samples.count),
            samples: segment.samples,
            trailingSilenceMs: 0
        )
    }

    private mutating func appendToPreRoll(_ chunk: [Float]) {
        guard preRollSamples > 0 else { return }
        preRoll.append(contentsOf: chunk)
        if preRoll.count > preRollSamples {
            preRoll.removeFirst(preRoll.count - preRollSamples)
        }
    }

    private func milliseconds(_ samples: Int) -> Int {
        AudioFormat.milliseconds(forSamples: samples)
    }
}
