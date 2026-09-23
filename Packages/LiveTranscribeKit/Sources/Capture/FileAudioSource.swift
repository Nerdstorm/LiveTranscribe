@preconcurrency import AVFoundation
import Foundation
import Shared

/// Streams an audio file as if it were live capture. Used by the bench and integration tests.
public actor FileAudioSource: AudioSource {
    public enum Pacing: Sendable {
        /// Yield chunks at the rate they would arrive from a microphone.
        case realTime
        /// Yield chunks as fast as the consumer takes them.
        case asFastAsPossible
    }

    private let url: URL
    private let pacing: Pacing
    private let chunkMilliseconds: Int
    private let trailingSilenceMs: Int
    private var task: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?

    /// - Parameter trailingSilenceMs: silence appended after the file so the last utterance
    ///   ends the way it would live, by silence rather than by stopping capture.
    public init(url: URL, pacing: Pacing, chunkMilliseconds: Int = 100, trailingSilenceMs: Int = 1_000) {
        self.url = url
        self.pacing = pacing
        self.chunkMilliseconds = max(10, chunkMilliseconds)
        self.trailingSilenceMs = max(0, trailingSilenceMs)
    }

    public func start() throws -> AsyncThrowingStream<[Float], Error> {
        guard continuation == nil else { throw CaptureError.alreadyRunning }
        let samples = try Self.readSamples(from: url)
            + [Float](repeating: 0, count: AudioFormat.samples(forMilliseconds: trailingSilenceMs))
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        self.continuation = continuation

        let chunkSize = AudioFormat.samples(forMilliseconds: chunkMilliseconds)
        let delay = Duration.milliseconds(chunkMilliseconds)
        let pacing = pacing
        task = Task {
            var offset = 0
            while offset < samples.count, !Task.isCancelled {
                let end = min(offset + chunkSize, samples.count)
                continuation.yield(Array(samples[offset..<end]))
                offset = end
                if pacing == .realTime {
                    try? await Task.sleep(for: delay)
                }
            }
            continuation.finish()
        }
        return stream
    }

    public func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }

    /// Reads a whole file and converts it to 16 kHz mono Float32.
    public static func readSamples(from url: URL) throws -> [Float] {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let converter = try SampleRateConverter(inputFormat: format)
            let chunkFrames: AVAudioFrameCount = 16_384
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                throw CaptureError.unreadableFile("cannot allocate a read buffer")
            }

            // A single read may return fewer frames than requested, so read until end of file.
            var samples: [Float] = []
            var framesRead = 0
            while file.framePosition < file.length {
                try file.read(into: chunk, frameCount: chunkFrames)
                guard chunk.frameLength > 0 else { break }
                framesRead += Int(chunk.frameLength)
                samples += converter.convert(chunk)
            }

            // Silence pushes the resampler's delay line out; then trim to the exact length.
            samples += converter.convert(try silence(format: format, milliseconds: 100), isFinal: true)
            let expected = Int((Double(framesRead) * Double(AudioFormat.sampleRate) / format.sampleRate).rounded())
            return Array(samples.prefix(expected))
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.unreadableFile("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func silence(format: AVAudioFormat, milliseconds: Int) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * Double(milliseconds) / 1_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData
        else {
            throw CaptureError.unreadableFile("cannot allocate a silence buffer")
        }
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(frames))
        }
        buffer.frameLength = frames
        return buffer
    }
}
