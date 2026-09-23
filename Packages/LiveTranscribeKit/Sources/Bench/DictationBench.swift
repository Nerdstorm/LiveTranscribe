import Capture
import Cleanup
import Dictation
import Foundation
import Shared
import Transcription

/// `Bench --dictation`: runs every eval clip through the dictation processor at each cleanup
/// level and reports, per level and category, word error rate against what was said and against
/// what was meant, how often cleanup fell back, and latency (speech-to-text plus cleanup) against
/// the p95 target in docs/dictation.md.
///
/// Clips come from Tests/IntegrationTests/Fixtures/Dictation/clips.tsv, synthesised to WAV by
/// scripts/generate-dictation-audio.sh.
enum DictationBench {
    struct Clip {
        let id: String
        let category: String
        /// What the voice says: the reference for levels that keep every word.
        let spoken: String
        /// What the writer meant: fillers dropped and self-corrections resolved.
        let intended: String
        let audio: URL

        /// Reads clips.tsv (id, category, spoken, intended) and pairs each line with its WAV.
        static func load(from directory: URL) throws -> [Clip] {
            let table = directory.appending(path: "clips.tsv")
            let text = try String(contentsOf: table, encoding: .utf8)
            var clips: [Clip] = []
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard columns.count == 4 else { throw BenchError.usage("malformed line in \(table.path): \(line)") }
                let audio = directory.appending(path: "\(columns[0]).wav")
                guard FileManager.default.fileExists(atPath: audio.path) else {
                    throw BenchError.noFixtures("\(audio.path) (run scripts/generate-dictation-audio.sh)")
                }
                clips.append(Clip(id: columns[0], category: columns[1], spoken: columns[2], intended: columns[3], audio: audio))
            }
            return clips
        }
    }

    struct Result {
        let clip: Clip
        let level: CleanupLevel
        let output: DictationProcessor.Output

        var spokenWER: Double { EditDistance.wordErrorRate(reference: clip.spoken, hypothesis: output.text) }
        var intendedWER: Double { EditDistance.wordErrorRate(reference: clip.intended, hypothesis: output.text) }
        var latencyMs: Int { output.transcriptionMs + output.cleanupMs }
    }

    static func run(options: BenchOptions, settings: AppSettings) async throws {
        let clips = try Clip.load(from: options.clipsDirectory)
        guard !clips.isEmpty else { throw BenchError.noFixtures(options.clipsDirectory.path) }
        let levels = options.levels ?? CleanupLevel.allCases

        let transcriber = MLXTranscriber(modelID: settings.sttModel)
        let cleaner = MLXCleaner(configuration: .init(settings: settings))
        print("Loading \(settings.sttModel) and \(settings.llmModel)")
        try await transcriber.load { _ in }
        if settings.cleanupEnabled {
            try await cleaner.load { _ in }
        }
        let processor = DictationProcessor(transcriber: transcriber, cleaner: cleaner)
        let samples = try clips.map { try FileAudioSource.readSamples(from: $0.audio) }

        // One untimed pass so the first timed clip does not pay for kernel compilation.
        _ = try await processor.process(samples[0], configuration: configuration(.medium, settings: settings))

        var results: [Result] = []
        for level in levels {
            for (clip, audio) in zip(clips, samples) {
                let output = try await processor.process(audio, configuration: configuration(level, settings: settings))
                let result = Result(clip: clip, level: level, output: output)
                results.append(result)
                if options.verbose {
                    print("\(level.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(clip.id): \(output.text)\(output.fellBack ? "  [fell back: \(output.fallbackReason ?? "?")]" : "")")
                }
            }
        }
        report(results, levels: levels, clips: clips.count, p95TargetMs: options.p95TargetMs)
    }

    private static func configuration(_ level: CleanupLevel, settings: AppSettings) -> DictationProcessor.Configuration {
        DictationProcessor.Configuration(
            level: level,
            snippets: [],
            vocabulary: [],
            vocabularyPromptLimit: settings.dictation.vocabularyPromptLimit,
            vocabularySimilarityThreshold: settings.dictation.vocabularySimilarityThreshold,
            multiline: false
        )
    }

    private static func report(_ results: [Result], levels: [CleanupLevel], clips: Int, p95TargetMs: Int) {
        print("\nDictation eval: \(clips) clips per level")
        print("level   category     clips  WER vs said  WER vs meant  fell back  p50 ms  p95 ms")
        print(String(repeating: "-", count: 80))
        for level in levels {
            let forLevel = results.filter { $0.level == level }
            let categories = Array(Set(forLevel.map(\.clip.category))).sorted()
            for category in categories {
                line(level: level, label: category, forLevel.filter { $0.clip.category == category })
            }
            line(level: level, label: "all", forLevel)
            let p95 = percentile(forLevel.map(\.latencyMs), 0.95)
            print("  \(level.rawValue): p95 \(p95) ms, target < \(p95TargetMs) ms: \(p95 < p95TargetMs ? "PASS" : "FAIL")")
        }
    }

    private static func line(level: CleanupLevel, label: String, _ results: [Result]) {
        guard !results.isEmpty else { return }
        let said = mean(results.map(\.spokenWER))
        let meant = mean(results.map(\.intendedWER))
        let fellBack = results.filter(\.output.fellBack).count
        let latencies = results.map(\.latencyMs)
        let columns = [
            pad(level.rawValue, 7), pad(label, 12), pad("\(results.count)", 5, left: true),
            pad(percent(said), 12, left: true), pad(percent(meant), 13, left: true),
            pad("\(fellBack)", 10, left: true),
            pad("\(percentile(latencies, 0.5))", 7, left: true), pad("\(percentile(latencies, 0.95))", 7, left: true),
        ]
        print(columns.joined(separator: " "))
    }

    private static func percent(_ value: Double) -> String {
        "\((value * 1_000).rounded() / 10)%"
    }

    private static func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let padding = String(repeating: " ", count: max(0, width - text.count))
        return left ? padding + text : text + padding
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// Nearest-rank percentile.
    private static func percentile(_ values: [Int], _ fraction: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
