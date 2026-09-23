// Bench: runs fixture clips through the real pipeline and reports WER (raw vs cleaned) and
// per-stage latency. Build with xcodebuild (MLX needs its Metal library); see README.md.
//
//   Bench [--fixtures <dir>] [--no-cleanup] [--no-adapter] [--fast]

import Capture
import Cleanup
import Foundation
import MLXSupport
import Persistence
import Segmentation
import Session
import Shared
import Transcription

struct BenchOptions {
    var fixturesDirectory = URL(fileURLWithPath: "Tests/IntegrationTests/Fixtures/Audio", isDirectory: true)
    var cleanupEnabled = true
    var adapterEnabled = true
    var pacing = FileAudioSource.Pacing.realTime

    static func parse(_ arguments: [String]) throws -> BenchOptions {
        var options = BenchOptions()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--fixtures":
                guard let path = iterator.next() else { throw BenchError.usage("--fixtures needs a directory") }
                options.fixturesDirectory = URL(fileURLWithPath: path, isDirectory: true)
            case "--no-cleanup":
                options.cleanupEnabled = false
            case "--no-adapter":
                options.adapterEnabled = false
            case "--fast":
                options.pacing = .asFastAsPossible
            default:
                throw BenchError.usage("unknown argument \(argument)")
            }
        }
        return options
    }
}

enum BenchError: LocalizedError {
    case usage(String)
    case noFixtures(String)
    case sessionFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage(let detail): "\(detail)\nusage: Bench [--fixtures <dir>] [--no-cleanup] [--no-adapter] [--fast]"
        case .noFixtures(let path):
            "No .wav files with matching .txt references in \(path). Run scripts/generate-test-audio.sh first."
        case .sessionFailed(let detail): "Session failed: \(detail)"
        }
    }
}

struct AlwaysGrantedMicrophone: MicrophonePermissionProviding {
    func status() -> MicrophonePermissionStatus { .granted }
    func request() async -> Bool { true }
}

struct Fixture {
    let audio: URL
    let reference: String

    static func load(from directory: URL) throws -> [Fixture] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { audio in
                let referenceURL = audio.deletingPathExtension().appendingPathExtension("txt")
                guard FileManager.default.fileExists(atPath: referenceURL.path) else { return nil }
                return Fixture(audio: audio, reference: try String(contentsOf: referenceURL, encoding: .utf8))
            }
    }
}

let options = try BenchOptions.parse(Array(CommandLine.arguments.dropFirst()))
var settings = AppSettings.defaults
settings.cleanupEnabled = options.cleanupEnabled
settings.cleanupAdapterEnabled = options.adapterEnabled
MLXRuntime.configure(gpuCacheLimitMB: settings.gpuCacheLimitMB)

let fixtures = try Fixture.load(from: options.fixturesDirectory)
guard !fixtures.isEmpty else { throw BenchError.noFixtures(options.fixturesDirectory.path) }

// Models are shared across fixtures, so they load (and warm up) once.
let segmenter = SileroSegmenter(modelID: settings.vadModel, config: SegmentationConfig(settings: settings))
let transcriber = MLXTranscriber(modelID: settings.sttModel)
let cleaner = MLXCleaner(configuration: .init(settings: settings))

var results: [FixtureResult] = []
for fixture in fixtures {
    let sink = MemorySessionSink()
    let pacing = options.pacing
    let coordinator = SessionCoordinator(
        settings: settings,
        dependencies: .init(
            makeAudioSource: { FileAudioSource(url: fixture.audio, pacing: pacing) },
            segmenter: segmenter,
            transcriber: transcriber,
            cleaner: cleaner,
            makeSink: { _ in sink },
            microphonePermission: AlwaysGrantedMicrophone()
        )
    )
    let outcome = Task { await BenchSession.awaitCompletion(of: coordinator) }
    await coordinator.prepare()
    await coordinator.start()
    if let failure = await outcome.value {
        throw BenchError.sessionFailed("\(fixture.audio.lastPathComponent): \(failure)")
    }
    await coordinator.shutdown()

    let result = FixtureResult(name: fixture.audio.lastPathComponent, reference: fixture.reference, records: await sink.records)
    results.append(result)
    print(result.summaryLine)
}

BenchReport(results: results, cleanupEnabled: settings.cleanupEnabled).print()
