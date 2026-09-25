/// The audio format shared by every stage after capture.
///
/// This is a model requirement rather than a tunable: Silero VAD and Qwen3-ASR both expect
/// 16 kHz mono Float32 samples.
public enum AudioFormat {
    public static let sampleRate = 16_000

    public static func milliseconds(forSamples count: Int) -> Int {
        count * 1_000 / sampleRate
    }

    public static func samples(forMilliseconds milliseconds: Int) -> Int {
        milliseconds * sampleRate / 1_000
    }
}
