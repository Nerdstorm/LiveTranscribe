@preconcurrency import AVFoundation
import Shared

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
