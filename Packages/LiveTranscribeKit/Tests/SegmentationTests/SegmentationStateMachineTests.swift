import Segmentation
import Shared
import Testing

/// 512-sample chunks (32 ms at 16 kHz), matching Silero's window.
private let chunkSize = 512

private func config(
    silenceMs: Int = 600,
    maxSegmentMs: Int = 15_000,
    preRollMs: Int = 200,
    minSpeechMs: Int = 250,
    partialIntervalMs: Int = 0
) -> SegmentationConfig {
    SegmentationConfig(
        speechThreshold: 0.5,
        silenceMs: silenceMs,
        maxSegmentMs: maxSegmentMs,
        preRollMs: preRollMs,
        minSpeechMs: minSpeechMs,
        partialIntervalMs: partialIntervalMs
    )
}

private extension SegmentationStateMachine {
    mutating func feed(chunks: Int, probability: Float, value: Float = 0.1) -> [SegmentationEvent] {
        (0..<chunks).flatMap { _ in
            ingest(chunk: [Float](repeating: value, count: chunkSize), speechProbability: probability)
        }
    }
}

private extension [SegmentationEvent] {
    var closed: [(SpeechAudio, SegmentCloseReason)] {
        compactMap { if case .closed(let audio, let reason) = $0 { (audio, reason) } else { nil } }
    }

    var partials: [SpeechAudio] {
        compactMap { if case .partial(let audio) = $0 { audio } else { nil } }
    }

    var discardedCount: Int {
        filter { if case .discarded = $0 { true } else { false } }.count
    }

    var startedCount: Int {
        filter { if case .speechStarted = $0 { true } else { false } }.count
    }
}

@Suite("Segmentation state machine")
struct SegmentationStateMachineTests {
    @Test func closesOnlyAfterTheSilenceThreshold() {
        var machine = SegmentationStateMachine(config: config(silenceMs: 600))
        #expect(machine.feed(chunks: 20, probability: 0.9).startedCount == 1)

        // 600 ms = 9600 samples = 18.75 chunks: 18 silent chunks are not enough, 19 are.
        #expect(machine.feed(chunks: 18, probability: 0.0).closed.isEmpty)
        let closed = machine.feed(chunks: 1, probability: 0.0).closed
        #expect(closed.count == 1)
        #expect(closed.first?.1 == .silence)
        #expect(closed.first?.0.trailingSilenceMs == 19 * chunkSize * 1_000 / 16_000)
        #expect(!machine.isInSpeech)
    }

    @Test func prependsPreRollAudio() throws {
        var machine = SegmentationStateMachine(config: config(preRollMs: 200))
        // Ten silent chunks whose samples carry the chunk index, then speech valued 100.
        for index in 0..<10 {
            _ = machine.ingest(chunk: [Float](repeating: Float(index), count: chunkSize), speechProbability: 0)
        }
        let started = machine.feed(chunks: 20, probability: 0.9, value: 100)
        #expect(started.startedCount == 1)
        let audio = try #require(machine.feed(chunks: 19, probability: 0).closed.first?.0)

        // 200 ms = 3200 samples of pre-roll: samples 1920..<5120, starting inside chunk 3.
        let preRollSamples = 3_200
        #expect(audio.samples.first == 3)
        #expect(audio.samples[preRollSamples - 1] == 9)
        #expect(audio.samples[preRollSamples] == 100)
        #expect(audio.startMs == (10 * chunkSize - preRollSamples) * 1_000 / 16_000)
    }

    @Test func trimsTrailingSilenceToThePreRollLength() throws {
        var machine = SegmentationStateMachine(config: config(preRollMs: 200))
        _ = machine.feed(chunks: 20, probability: 0.9)
        let audio = try #require(machine.feed(chunks: 19, probability: 0).closed.first?.0)
        // No audio preceded speech, so: 20 speech chunks + 200 ms (3200 samples) of tail.
        #expect(audio.samples.count == 20 * chunkSize + 3_200)
        #expect(audio.startMs == 0)
        #expect(audio.endMs == (20 * chunkSize + 3_200) * 1_000 / 16_000)
    }

    @Test func forceClosesAtMaximumLengthAndContinues() {
        var machine = SegmentationStateMachine(config: config(maxSegmentMs: 2_000, preRollMs: 0))
        // 2 s = 32000 samples: the 63rd chunk (32256 samples) crosses the limit.
        let first = machine.feed(chunks: 63, probability: 0.9)
        #expect(first.closed.count == 1)
        #expect(first.closed.first?.1 == .maxLength)
        #expect(first.closed.first?.0.samples.count == 63 * chunkSize)
        #expect(first.closed.first?.0.trailingSilenceMs == 0)
        #expect(first.startedCount == 2, "a new segment starts right after the forced close")
        #expect(machine.isInSpeech)

        _ = machine.feed(chunks: 20, probability: 0.9)
        let second = machine.feed(chunks: 19, probability: 0).closed
        #expect(second.count == 1)
        #expect(second.first?.1 == .silence)
        #expect(second.first?.0.startMs == 63 * chunkSize * 1_000 / 16_000)
    }

    @Test func discardsSegmentsWithTooLittleSpeech() {
        var machine = SegmentationStateMachine(config: config(minSpeechMs: 250))
        _ = machine.feed(chunks: 5, probability: 0.9) // 160 ms
        let events = machine.feed(chunks: 19, probability: 0)
        #expect(events.closed.isEmpty)
        #expect(events.discardedCount == 1)
    }

    @Test func probabilitiesBetweenThresholdsKeepSpeechGoing() {
        var machine = SegmentationStateMachine(config: config(silenceMs: 600))
        _ = machine.feed(chunks: 10, probability: 0.9)
        // 0.4 is below the 0.5 start threshold but above the 0.35 silence threshold.
        #expect(machine.feed(chunks: 30, probability: 0.4).closed.isEmpty)
        #expect(machine.feed(chunks: 19, probability: 0.1).closed.count == 1)
    }

    @Test func weakSpeechDoesNotStartASegment() {
        var machine = SegmentationStateMachine(config: config())
        #expect(machine.feed(chunks: 40, probability: 0.45).isEmpty)
        #expect(!machine.isInSpeech)
    }

    @Test func emitsPartialSnapshotsAtTheConfiguredInterval() {
        var machine = SegmentationStateMachine(config: config(preRollMs: 0, partialIntervalMs: 500))
        // 500 ms = 8000 samples: first snapshot after 16 chunks, the next after 32.
        let events = machine.feed(chunks: 20, probability: 0.9)
        #expect(events.partials.count == 1)
        #expect(events.partials.first?.samples.count == 16 * chunkSize)
        #expect(machine.feed(chunks: 12, probability: 0.9).partials.count == 1)
    }

    @Test func noPartialsWhenDisabled() {
        var machine = SegmentationStateMachine(config: config(partialIntervalMs: 0))
        #expect(machine.feed(chunks: 100, probability: 0.9).partials.isEmpty)
    }

    @Test func flushClosesAnOpenSegment() {
        var machine = SegmentationStateMachine(config: config())
        _ = machine.feed(chunks: 20, probability: 0.9)
        let events = machine.flush()
        #expect(events.closed.first?.1 == .endOfStream)
        #expect(machine.flush().isEmpty)
    }

    @Test func flushWithoutSpeechDoesNothing() {
        var machine = SegmentationStateMachine(config: config())
        _ = machine.feed(chunks: 10, probability: 0)
        #expect(machine.flush().isEmpty)
    }

    @Test func segmentIdentityIsSharedByStartPartialAndClose() throws {
        var machine = SegmentationStateMachine(config: config(partialIntervalMs: 250))
        let started = machine.feed(chunks: 20, probability: 0.9)
        guard case .speechStarted(let id, _)? = started.first else {
            Issue.record("expected speechStarted first")
            return
        }
        #expect(started.partials.allSatisfy { $0.segmentID == id })
        let closed = try #require(machine.feed(chunks: 19, probability: 0).closed.first)
        #expect(closed.0.segmentID == id)
    }
}

@Suite("ChunkAccumulator")
struct ChunkAccumulatorTests {
    @Test func regroupsBuffersIntoFixedChunks() {
        var accumulator = ChunkAccumulator(chunkSize: 512)
        #expect(accumulator.append([Float](repeating: 1, count: 300)).isEmpty)
        let chunks = accumulator.append([Float](repeating: 2, count: 800))
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.count == 512 })
        #expect(chunks[0].prefix(300).allSatisfy { $0 == 1 })
        #expect(chunks[0][300] == 2)
        #expect(accumulator.pendingCount == 1_100 - 1_024)
    }

    @Test func resetDropsPendingSamples() {
        var accumulator = ChunkAccumulator(chunkSize: 4)
        _ = accumulator.append([1, 2, 3])
        accumulator.reset()
        #expect(accumulator.pendingCount == 0)
        #expect(accumulator.append([4, 5, 6, 7]) == [[4, 5, 6, 7]])
    }
}
