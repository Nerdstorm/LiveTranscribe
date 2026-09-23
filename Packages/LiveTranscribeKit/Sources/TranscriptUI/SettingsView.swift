import Shared
import SwiftUI

/// Edits ``AppSettings`` through UserDefaults. Values are read at launch, so changes apply on
/// the next launch.
public struct SettingsView: View {
    private static let d = AppSettings.defaults

    @AppStorage(AppSettingsKey.sttModel.rawValue) private var sttModel = d.sttModel
    @AppStorage(AppSettingsKey.llmModel.rawValue) private var llmModel = d.llmModel
    @AppStorage(AppSettingsKey.vadModel.rawValue) private var vadModel = d.vadModel
    @AppStorage(AppSettingsKey.cleanupEnabled.rawValue) private var cleanupEnabled = d.cleanupEnabled
    @AppStorage(AppSettingsKey.cleanupAdapterEnabled.rawValue) private var cleanupAdapterEnabled = d.cleanupAdapterEnabled
    @AppStorage(AppSettingsKey.vadSilenceMs.rawValue) private var vadSilenceMs = d.vadSilenceMs
    @AppStorage(AppSettingsKey.vadSpeechThreshold.rawValue) private var vadSpeechThreshold = d.vadSpeechThreshold
    @AppStorage(AppSettingsKey.vadPreRollMs.rawValue) private var vadPreRollMs = d.vadPreRollMs
    @AppStorage(AppSettingsKey.vadMinSpeechMs.rawValue) private var vadMinSpeechMs = d.vadMinSpeechMs
    @AppStorage(AppSettingsKey.maxSegmentSeconds.rawValue) private var maxSegmentSeconds = d.maxSegmentSeconds
    @AppStorage(AppSettingsKey.partialIntervalMs.rawValue) private var partialIntervalMs = d.partialIntervalMs
    @AppStorage(AppSettingsKey.contextSegments.rawValue) private var contextSegments = d.contextSegments
    @AppStorage(AppSettingsKey.cleanupTimeoutSeconds.rawValue) private var cleanupTimeoutSeconds = d.cleanupTimeoutSeconds
    @AppStorage(AppSettingsKey.cleanupQueueCapacity.rawValue) private var cleanupQueueCapacity = d.cleanupQueueCapacity
    @AppStorage(AppSettingsKey.gpuCacheLimitMB.rawValue) private var gpuCacheLimitMB = d.gpuCacheLimitMB
    @AppStorage(AppSettingsKey.captureRestartAttempts.rawValue) private var captureRestartAttempts = d.captureRestartAttempts
    @AppStorage(AppSettingsKey.captureRestartDelaySeconds.rawValue) private var captureRestartDelaySeconds = d.captureRestartDelaySeconds
    @AppStorage(AppSettingsKey.captureMaxRestartsPerMinute.rawValue) private var captureMaxRestartsPerMinute = d.captureMaxRestartsPerMinute

    public init() {}

    public var body: some View {
        Form {
            Section("Models (Hugging Face repositories)") {
                TextField("Speech-to-text", text: $sttModel)
                TextField("Cleanup LLM", text: $llmModel)
                TextField("Voice activity", text: $vadModel)
                Toggle("Clean up transcripts with the LLM", isOn: $cleanupEnabled)
            }
            Section("Segmentation") {
                Stepper("Silence that ends a segment: \(vadSilenceMs) ms", value: $vadSilenceMs, in: 100...5_000, step: 50)
                Stepper(
                    "Speech threshold: \(vadSpeechThreshold, format: .number.precision(.fractionLength(2)))",
                    value: $vadSpeechThreshold, in: 0.05...0.95, step: 0.05
                )
                Stepper("Pre-roll: \(vadPreRollMs) ms", value: $vadPreRollMs, in: 0...2_000, step: 50)
                Stepper("Minimum speech: \(vadMinSpeechMs) ms", value: $vadMinSpeechMs, in: 0...5_000, step: 50)
                Stepper("Maximum segment: \(maxSegmentSeconds) s", value: $maxSegmentSeconds, in: 2...60)
                Stepper(
                    partialIntervalMs == 0 ? "Live partials: off" : "Live partials every \(partialIntervalMs) ms",
                    value: $partialIntervalMs, in: 0...10_000, step: 250
                )
            }
            Section("Cleanup") {
                Toggle("Resolve spoken self-corrections (\"cars, sorry, buses\" → \"buses\")", isOn: $cleanupAdapterEnabled)
                    .disabled(!cleanupEnabled)
                    .help("Uses the bundled fine-tuned adapter. It applies only to the model it was trained on.")
                Stepper("Context segments: \(contextSegments)", value: $contextSegments, in: 0...20)
                Stepper(
                    "Timeout: \(cleanupTimeoutSeconds, format: .number.precision(.fractionLength(1))) s",
                    value: $cleanupTimeoutSeconds, in: 0.5...30, step: 0.5
                )
                Stepper("Queue capacity: \(cleanupQueueCapacity)", value: $cleanupQueueCapacity, in: 1...64)
            }
            Section("System") {
                Stepper("GPU buffer cache: \(gpuCacheLimitMB) MB", value: $gpuCacheLimitMB, in: 0...16_384, step: 128)
                Stepper("Capture restart attempts: \(captureRestartAttempts)", value: $captureRestartAttempts, in: 0...20)
                Stepper(
                    "Wait before each restart: \(captureRestartDelaySeconds, format: .number.precision(.fractionLength(1))) s",
                    value: $captureRestartDelaySeconds, in: 0...30, step: 0.5
                )
                Stepper(
                    "Capture restarts allowed per minute: \(captureMaxRestartsPerMinute)",
                    value: $captureMaxRestartsPerMinute, in: 1...60
                )
            }
            Section {
                HStack {
                    Text("Changes apply the next time Live Transcribe starts.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        AppSettingsStore().resetToDefaults()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}
