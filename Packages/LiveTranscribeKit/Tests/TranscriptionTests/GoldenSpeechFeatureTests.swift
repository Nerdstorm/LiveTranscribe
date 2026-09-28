import Foundation
import MLX
import MLXAudioSTT
import Testing

/// Speech-to-text's audio front end as the Mac app runs Qwen3-ASR through mlx-audio-swift: the
/// log-mel features, how many audio placeholders the prompt gets, and how many rows the audio
/// encoder makes of them.
///
/// The Linux and Windows app (linux-windows/crates/transcription) computes these itself and must
/// match them exactly. They are not Qwen's own: mlx-audio-swift counts the placeholders in
/// float32, so a clip can get a few more than Qwen's processor gives it, and the encoder fills
/// only some of them. The Sinhala model was trained on these, so the port copies them rather than
/// Qwen's reference processor. After an mlx-audio-swift update changes them, regenerate the files,
/// review the diff, and evaluate the Sinhala model again (see Fixtures/golden/README.md):
///
///     make golden
@Suite("Golden speech features")
struct GoldenSpeechFeatureTests {
    /// The repository's Fixtures/golden, found from this file's path.
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TranscriptionTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // LiveTranscribeKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // the repository
        .appendingPathComponent("Fixtures/golden", isDirectory: true)

    /// How far a recorded feature may be from a recomputed one: GPU arithmetic differs slightly
    /// between Macs. The Rust port is held to the same tolerance.
    private static let tolerance: Float = 1e-4

    private static var updating: Bool {
        ProcessInfo.processInfo.environment["LT_UPDATE_GOLDEN"] == "1"
    }

    /// Qwen3-ASR with a tiny encoder and decoder. preprocessAudio reads only the mel settings, and
    /// the rows the encoder makes depend only on how it chunks the frames, not on its size or its
    /// (here random) weights, so no model has to be downloaded.
    private static func model() -> Qwen3ASRModel {
        Qwen3ASRModel(Qwen3ASRConfig(
            audioConfig: Qwen3AudioEncoderConfig(
                encoderLayers: 1, encoderAttentionHeads: 1, encoderFfnDim: 8, dModel: 8,
                outputDim: 8, downsampleHiddenSize: 2
            ),
            textConfig: Qwen3TextConfig(
                vocabSize: 8, hiddenSize: 8, intermediateSize: 8, numHiddenLayers: 1,
                numAttentionHeads: 1, numKeyValueHeads: 1, headDim: 8
            )
        ))
    }

    /// Each clip's log-mel frames, as preprocessAudio computes them for the clip padded the way
    /// generate pads it, in speech-features/<clip>.f32: 128 little-endian float32 values per frame,
    /// frame after frame.
    @Test func theLogMelFeaturesMatchTheGoldenFiles() throws {
        let model = Self.model()
        for clip in SyntheticClip.all {
            let (input, _, _) = model.preprocessAudio(MLXArray(clip.paddedSamples))
            // [1, 128, frames] to frames of 128, the order the Rust port computes them in.
            let features = input[0].transposed(1, 0).asType(.float32).asArray(Float.self)
            #expect(features.count == clip.frames * 128, "\(clip.name) has 1 + samples / 160 frames")
            try Self.check(features, file: "speech-features/\(clip.name).f32")
        }
    }

    /// For every clip length from one second to ten, as mel frames: the placeholders the prompt
    /// gets and the rows the encoder makes, which replace the placeholders from the first.
    @Test func thePlaceholderAndEncoderRowCountsMatchTheGoldenTable() throws {
        let model = Self.model()
        var lines = [
            "# For each clip length in mel frames (1 + samples / 160), the <|audio_pad|> placeholders",
            "# mlx-audio-swift's Qwen3-ASR prompt gets and the rows its audio encoder makes, which",
            "# replace the placeholders from the first. Columns: frames, placeholders, encoder rows.",
            "# Written by make golden; do not edit.",
        ]
        for frames in 101...1_000 {
            let (_, _, placeholders) = model.preprocessAudio(MLXArray.zeros([(frames - 1) * 160]))
            let rows = model.getAudioFeatures(
                MLXArray.zeros([1, 128, frames]),
                featureAttentionMask: MLXArray.ones([1, frames]).asType(.int32)
            ).dim(0)
            lines.append("\(frames)\t\(placeholders)\t\(rows)")
        }
        try Self.check(lines, file: "speech-layout.tsv")
    }

    /// Writes `produced` to `file` when updating, and otherwise expects the file to hold it within
    /// the tolerance.
    private static func check(_ produced: [Float], file name: String) throws {
        let file = directory.appendingPathComponent(name)
        if updating {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try produced.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: file)
            return
        }
        let data = try Data(contentsOf: file)
        let recorded = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(recorded.count == produced.count, "\(name) has as many frames as the clip")
        let worst = zip(recorded, produced).map { abs($0 - $1) }.max() ?? 0
        #expect(
            worst <= tolerance,
            "\(name) is up to \(worst) from the recorded features; if intended, run make golden and review the diff"
        )
    }

    /// Writes `produced` to `file` when updating, and otherwise expects the file to hold it.
    private static func check(_ produced: [String], file name: String) throws {
        let file = directory.appendingPathComponent(name)
        if updating {
            try (produced.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let recorded = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(recorded.count == produced.count, "\(name) has one line per clip length")
        let differing = zip(recorded, produced).filter { $0 != $1 }
        for (was, now) in differing.prefix(5) {
            Issue.record("\(name) changed:\n  recorded: \(was)\n  produced: \(now)")
        }
        #expect(differing.isEmpty, "\(differing.count) lines changed; if intended, run make golden and review the diff")
    }
}

/// A test signal made with integer arithmetic only, so the Swift and Rust tests make the same
/// samples bit for bit: a sawtooth sweeping from about 60 Hz to 7.6 kHz every two seconds, with
/// noise, and 0.25 s of silence every 1.5 s. The Rust port has the same generator
/// (linux-windows/crates/transcription/tests/golden_speech_features.rs).
private struct SyntheticClip {
    let name: String
    let seed: UInt32
    let samples: Int

    static let all = [
        SyntheticClip(name: "one-second", seed: 1, samples: 16_000),
        SyntheticClip(name: "short", seed: 2, samples: 9_920),
        SyntheticClip(name: "longer", seed: 3, samples: 37_920),
    ]

    /// The samples, padded with silence to one second as Qwen3ASRModel.generate pads a shorter clip.
    var paddedSamples: [Float] {
        var noise = seed
        var phase: UInt32 = 0
        var values: [Float] = []
        values.reserveCapacity(max(samples, 16_000))
        for n in 0..<samples {
            noise = noise &* 1_664_525 &+ 1_013_904_223
            phase &+= UInt32(16_000_000 + (n % 32_000) * 63_000)
            let saw = Int32(Int16(truncatingIfNeeded: phase >> 16))
            let hiss = Int32(Int16(truncatingIfNeeded: noise >> 16))
            let silent = n % 24_000 >= 20_000
            values.append(silent ? 0 : Float(saw / 4 + hiss / 16) / 32_768)
        }
        values += [Float](repeating: 0, count: max(0, 16_000 - samples))
        return values
    }

    var frames: Int { 1 + max(samples, 16_000) / 160 }
}
