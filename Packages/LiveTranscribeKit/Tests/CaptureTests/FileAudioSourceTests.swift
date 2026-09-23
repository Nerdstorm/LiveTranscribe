import AVFoundation
import Capture
import Foundation
import Testing

@Suite("Audio conversion")
struct FileAudioSourceTests {
    /// Writes a 1 s, 440 Hz stereo sine at `sampleRate` and returns its URL.
    private func makeSineFile(sampleRate: Double, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sine-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let frames = AVAudioFrameCount(sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(frames) {
                data[frame] = 0.5 * sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test("Converts to 16 kHz mono", arguments: [44_100.0, 48_000.0, 16_000.0])
    func resamplesToSixteenKilohertz(sampleRate: Double) throws {
        let url = try makeSineFile(sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try FileAudioSource.readSamples(from: url)
        // One second of audio: 16000 samples, allowing a few for resampler edges.
        #expect(abs(samples.count - 16_000) <= 32)
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0.4 && peak < 0.6, "downmixing two identical channels keeps the amplitude")
    }

    @Test func streamsAllSamplesThenTrailingSilence() async throws {
        let url = try makeSineFile(sampleRate: 48_000, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = FileAudioSource(url: url, pacing: .asFastAsPossible, chunkMilliseconds: 100, trailingSilenceMs: 500)
        var total: [Float] = []
        for try await chunk in try await source.start() {
            #expect(chunk.count <= 1_600)
            total += chunk
        }
        #expect(abs(total.count - (16_000 + 8_000)) <= 32, "got \(total.count) samples")
        #expect(total.suffix(8_000).allSatisfy { $0 == 0 })
    }

    @Test func unreadableFileThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wav")
        #expect(throws: CaptureError.self) {
            try FileAudioSource.readSamples(from: missing)
        }
    }

    @Test func stopEndsTheStream() async throws {
        let url = try makeSineFile(sampleRate: 16_000, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = FileAudioSource(url: url, pacing: .realTime, chunkMilliseconds: 100, trailingSilenceMs: 0)
        let stream = try await source.start()
        var received = 0
        for try await _ in stream {
            received += 1
            if received == 2 { await source.stop() }
        }
        #expect(received < 10)
    }
}
