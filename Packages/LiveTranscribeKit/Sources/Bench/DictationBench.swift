import Capture
import Cleanup
import Dictation
import Foundation
import Shared
import Transcription

/// `Bench --dictation`: runs every eval clip through the dictation processor at each cleanup
/// level and reports, per level and category, word error rate against what was said and against
/// what was meant, how often cleanup fell back, and latency (speech-to-text plus cleanup) against
/// the p95 target in docs/dictation.md. With `--multiline` the clips are dictated into a field
/// that takes several lines, and the report adds how many came out with the intended layout.
///
/// Clips come from Tests/IntegrationTests/Fixtures/Dictation/clips.tsv, synthesised to WAV by
/// scripts/generate-dictation-audio.sh.
enum DictationBench {
    struct Clip {
        let id: String
        let category: String
        /// What the voice says: the reference for levels that keep every word.
        let spoken: String
        /// What the writer meant: fillers dropped, self-corrections resolved, and laid out as in
        /// a field that takes several lines (written `\n` in the table).
        let intended: String
        let audio: URL

        /// Reads clips.tsv (id, category, spoken, intended) and pairs each line with its WAV.
        /// A `\n` in the intended column is a line break.
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
                let intended = columns[3].replacingOccurrences(of: "\\n", with: "\n")
                clips.append(Clip(id: columns[0], category: columns[1], spoken: columns[2], intended: intended, audio: audio))
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
        /// The output has the intended lines: the same blank lines, list items and lines of text.
        var hasIntendedLayout: Bool { Self.layout(of: output.text) == Self.layout(of: clip.intended) }

        /// Each line as blank, a numbered or bulleted list item, or text.
        static func layout(of text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let number = trimmed.prefix(while: \.isNumber)
                if trimmed.isEmpty { return "blank" }
                if trimmed.hasPrefix("- ") { return "bullet" }
                if !number.isEmpty, trimmed.dropFirst(number.count).hasPrefix(". ") { return "numbered" }
                return "text"
            }
        }
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
        // As in the app: with cleanup off, the levels apply only their rules that need no model.
        let processor = DictationProcessor(transcriber: transcriber, cleaner: settings.cleanupEnabled ? cleaner : nil)
        let samples = try clips.map { try FileAudioSource.readSamples(from: $0.audio) }

        // One untimed pass so the first timed clip does not pay for kernel compilation.
        _ = try await processor.process(samples[0], configuration: configuration(.medium, options: options, settings: settings))

        var results: [Result] = []
        for level in levels {
            for (clip, audio) in zip(clips, samples) {
                let output = try await processor.process(audio, configuration: configuration(level, options: options, settings: settings))
                let result = Result(clip: clip, level: level, output: output)
                results.append(result)
                if options.verbose {
                    let text = output.text.replacingOccurrences(of: "\n", with: "\\n")
                    print("\(level.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(clip.id): \(text)\(output.fellBack ? "  [fell back: \(output.fallbackReason ?? "?")]" : "")")
                }
            }
        }
        report(results, levels: levels, clips: clips.count, options: options)
    }

    private static func configuration(
        _ level: CleanupLevel,
        options: BenchOptions,
        settings: AppSettings
    ) -> DictationProcessor.Configuration {
        DictationProcessor.Configuration(
            level: level,
            snippets: [],
            vocabulary: [],
            vocabularyPromptLimit: settings.dictation.vocabularyPromptLimit,
            vocabularySimilarityThreshold: settings.dictation.vocabularySimilarityThreshold,
            multiline: options.multiline
        )
    }

    private static func report(_ results: [Result], levels: [CleanupLevel], clips: Int, options: BenchOptions) {
        print("\nDictation eval: \(clips) clips per level\(options.multiline ? ", multi-line field" : "")")
        print("level   category     clips  WER vs said  WER vs meant  fell back  p50 ms  p95 ms\(options.multiline ? "  layout" : "")")
        print(String(repeating: "-", count: options.multiline ? 88 : 80))
        for level in levels {
            let forLevel = results.filter { $0.level == level }
            let categories = Array(Set(forLevel.map(\.clip.category))).sorted()
            for category in categories {
                line(level: level, label: category, forLevel.filter { $0.clip.category == category }, layout: options.multiline)
            }
            line(level: level, label: "all", forLevel, layout: options.multiline)
            let p95 = percentile(forLevel.map(\.latencyMs), 0.95)
            print("  \(level.rawValue): p95 \(p95) ms, target < \(options.p95TargetMs) ms: \(p95 < options.p95TargetMs ? "PASS" : "FAIL")")
        }
    }

    /// - Parameter layout: Add how many results have the intended layout.
    private static func line(level: CleanupLevel, label: String, _ results: [Result], layout: Bool) {
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
        let laidOut = layout ? [pad("\(results.filter(\.hasIntendedLayout).count)/\(results.count)", 7, left: true)] : []
        print((columns + laidOut).joined(separator: " "))
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
