@preconcurrency import AVFoundation
import Shared

/// Converts audio buffers from the device format to 16 kHz mono Float32.
///
/// Marked `@unchecked Sendable` because `AVAudioConverter` is not `Sendable`. It is safe:
/// after `init`, the converter is only touched from `convert(_:)`, which is called serially from
/// the capture output's sample queue (or a single reader loop for files). Nothing else mutates it.
final class SampleRateConverter: @unchecked Sendable {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let ratio: Double

    init(inputFormat: AVAudioFormat) throws {
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(AudioFormat.sampleRate),
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw CaptureError.unsupportedFormat(inputFormat.description)
        }
        converter.downmix = true
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.ratio = outputFormat.sampleRate / inputFormat.sampleRate
    }

    /// Converts one buffer. The resampler keeps its filter state between calls, so a stream of
    /// buffers converts seamlessly. Returns an empty array if the converter produced nothing.
    ///
    /// - Parameter isFinal: signal end of stream after this buffer. The converter cannot be
    ///   reused afterwards. Note: for mono input AVAudioConverter does not emit its resampler
    ///   tail at end of stream; callers that need every sample pad the input with silence.
    func convert(_ buffer: AVAudioPCMBuffer, isFinal: Bool = false) -> [Float] {
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        let supplier = OneShotBufferSupplier(buffer, isFinal: isFinal)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            supplier.next(status: inputStatus)
        }
        guard status != .error, error == nil, let channel = output.floatChannelData else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

/// Hands the converter exactly one input buffer per `convert` call.
///
/// `@unchecked Sendable`: AVAudioConverter invokes the input block synchronously inside
/// `convert(to:error:withInputFrom:)`, on the calling thread, so there is no concurrent access.
private final class OneShotBufferSupplier: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private let isFinal: Bool

    init(_ buffer: AVAudioPCMBuffer, isFinal: Bool) {
        self.buffer = buffer
        self.isFinal = isFinal
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = isFinal ? .endOfStream : .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
