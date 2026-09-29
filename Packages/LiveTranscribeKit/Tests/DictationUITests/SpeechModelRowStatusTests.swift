@testable import DictationUI
import Session
import Shared
import Testing
import Transcription

/// What each model's row in Settings › Models shows.
@Suite("Speech model row status")
struct SpeechModelRowStatusTests {
    private static let qwen = "Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit"
    private static let parakeet = "mlx-community/parakeet-tdt-0.6b-v2"

    private func status(
        of setting: String,
        chosen: String = qwen,
        loaded: String? = qwen,
        phase: SessionPhase = .ready,
        progress: [ModelLoadProgress] = [],
        download: SpeechModelLibrary.State? = .downloaded
    ) -> SpeechModelRowStatus {
        .of(setting: setting, chosen: chosen, loaded: loaded, phase: phase, progress: progress, download: download)
    }

    @Test func theChosenModelLoadedIsInUseWhateverTheSessionIsDoing() {
        for phase: SessionPhase in [.ready, .listening, .stopping, .failed(.microphonePermissionDenied)] {
            #expect(status(of: Self.qwen, phase: phase) == .inUse, "\(phase)")
        }
        #expect(status(of: Self.qwen.uppercased()) == .inUse, "Hugging Face ignores case")
    }

    @Test func theChosenModelShowsItsDownloadWhileItLoads() {
        let downloading = ModelLoadProgress(modelID: Self.parakeet, stage: .downloading, fractionCompleted: 0.25)
        let vad = ModelLoadProgress(modelID: "mlx-community/silero-vad", stage: .downloading, fractionCompleted: 0.9)
        #expect(status(of: Self.parakeet, chosen: Self.parakeet, phase: .loading, progress: [vad, downloading]) == .loading(fraction: 0.25))
        let loading = ModelLoadProgress(modelID: Self.parakeet, stage: .loading)
        #expect(status(of: Self.parakeet, chosen: Self.parakeet, phase: .loading, progress: [loading]) == .loading(fraction: nil))
    }

    @Test func theChosenModelSaysWhyItFailedToLoad() {
        let failed = SessionPhase.failed(.modelLoadFailed(model: Self.parakeet, message: "offline"))
        #expect(status(of: Self.parakeet, chosen: Self.parakeet, loaded: nil, phase: failed) == .failedToLoad("offline"))
        let vadFailed = SessionPhase.failed(.modelLoadFailed(model: "mlx-community/silero-vad", message: "offline"))
        #expect(status(of: Self.qwen, phase: vadFailed) == .inUse, "another model failed")
        #expect(status(of: Self.qwen, loaded: nil, phase: .notLoaded) == .notLoaded)
    }

    /// The live transcript keeps its model until it stops; the one chosen meanwhile waits.
    @Test func aModelChosenDuringTheLiveTranscriptWaitsForIt() {
        #expect(status(of: Self.parakeet, chosen: Self.parakeet, phase: .listening) == .waitingForLiveTranscript)
        #expect(status(of: Self.qwen, chosen: Self.parakeet, phase: .listening) == .inUse)
    }

    @Test func anyOtherModelShowsItsDownload() {
        #expect(status(of: Self.parakeet, download: .notDownloaded) == .notDownloaded)
        #expect(status(of: Self.parakeet, download: .downloading(fraction: 0.4)) == .downloading(fraction: 0.4))
        #expect(status(of: Self.parakeet, download: .downloaded) == .downloaded)
        #expect(status(of: Self.parakeet, download: .failed("disk full")) == .downloadFailed("disk full"))
        #expect(status(of: "owner/elsewhere", download: nil) == .notDownloaded)
    }
}
