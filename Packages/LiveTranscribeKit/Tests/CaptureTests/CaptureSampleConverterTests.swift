@preconcurrency import AVFoundation
@testable import Capture
import CoreMedia
import Testing

@Suite("Capture sample conversion")
struct CaptureSampleConverterTests {
    /// A 440 Hz sine in the given format, `seconds` long.
    private func sine(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                data[channel][frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        return buffer
    }

    /// Wraps PCM in a `CMSampleBuffer`, as the capture output delivers it.
    private func sampleBuffer(_ pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: pcm.format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        ) == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        #expect(CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: CMItemCount(pcm.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr)
        let buffer = try #require(sampleBuffer)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            bufferList: pcm.audioBufferList
        ) == noErr)
        return buffer
    }

    @Test func requestedFormatPassesThroughUnchanged() throws {
        let pcm = try sine(sampleRate: 16_000, channels: 1, seconds: 0.25)
        var converter = CaptureSampleConverter()
        let samples = converter.samples(from: try sampleBuffer(pcm))
        let original = Array(UnsafeBufferPointer(start: try #require(pcm.floatChannelData)[0], count: Int(pcm.frameLength)))
        #expect(samples == original)
    }

    @Test func otherFormatsAreResampledToSixteenKilohertzMono() throws {
        var converter = CaptureSampleConverter()
        var total = 0
        // Several consecutive buffers, as a device at 48 kHz stereo would deliver them.
        for _ in 0..<4 {
            total += converter.samples(from: try sampleBuffer(try sine(sampleRate: 48_000, channels: 2, seconds: 0.25))).count
        }
        // 1 s of 48 kHz input is 16 000 samples at 16 kHz, less the resampler's small priming delay.
        #expect((15_500...16_000).contains(total), "got \(total) samples")
    }

    @Test func aFormatChangeMidStreamIsHandled() throws {
        var converter = CaptureSampleConverter()
        let first = converter.samples(from: try sampleBuffer(try sine(sampleRate: 44_100, channels: 1, seconds: 0.5)))
        let second = converter.samples(from: try sampleBuffer(try sine(sampleRate: 16_000, channels: 1, seconds: 0.5)))
        #expect(!first.isEmpty)
        #expect(second.count == 8_000, "16 kHz mono after a device switch passes straight through")
    }
}
