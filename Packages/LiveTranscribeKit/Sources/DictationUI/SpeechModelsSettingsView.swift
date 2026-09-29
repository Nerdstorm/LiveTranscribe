import Session
import Shared
import SwiftUI
import Transcription
import TranscriptUI

/// Settings › Models: the speech-to-text models to download and choose from
/// (``SpeechModelCatalog``), and any other model by its repository or folder.
///
/// Choosing a model stores the Speech-to-text setting, and the app loads it in place of the one
/// in use: straight away, or once the live transcript stops. Dictation waits while it loads.
struct SpeechModelsSettingsView: View {
    let context: DictationUIContext

    @AppStorage(AppSettingsKey.sttModel.rawValue) private var chosen = AppSettings.defaults.sttModel
    @AppStorage(AppSettingsKey.sttLanguage.rawValue) private var language: String?
    @State private var otherModel = ""
    @State private var confirmingRemoval: SpeechModelCatalog.Model?

    private var library: SpeechModelLibrary { context.speechModels }
    private var isChosenInCatalog: Bool { library.catalog.model(forSetting: chosen) != nil }

    var body: some View {
        Form {
            Section {
                ForEach(library.catalog.models) { model in
                    SpeechModelRow(
                        model: model,
                        isDefault: SpeechModelRowStatus.same(model.mac.repository.rawValue, AppSettings.defaults.sttModel),
                        status: status(of: model.mac.repository.rawValue, download: library.state(of: model)),
                        canRemove: canRemove(model),
                        language: languageChoice(for: model),
                        actions: actions(for: model)
                    )
                }
                if let error = library.removalError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Speech-to-text")
            } footer: {
                Text("Models are downloaded from Hugging Face into ~/.cache/huggingface. A model you choose loads straight away, or when the live transcript stops; dictation waits for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                if !isChosenInCatalog {
                    HStack(alignment: .firstTextBaseline) {
                        Text(chosen)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        SpeechModelStatusView(status: status(of: chosen, download: nil), modelName: chosen, actions: statusActions)
                    }
                }
                HStack {
                    TextField("Model", text: $otherModel, prompt: Text("Hugging Face repository, or a folder starting with / or ~"))
                        .labelsHidden()
                        .onSubmit(useOtherModel)
                    Button("Use", action: useOtherModel)
                        .disabled((try? SpeechModelLocation(setting: otherModel)) == nil)
                }
            } header: {
                Text("Another model")
            } footer: {
                Text("Any model mlx-audio-swift runs: Qwen3-ASR, Parakeet, Whisper and more. A repository is downloaded at its latest version, and kept at that version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { library.refresh() }
        .onChange(of: context.transcript.speechModel) { library.refresh() }
        .confirmationDialog(
            confirmingRemoval.map { "Remove \($0.name)?" } ?? "",
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            presenting: confirmingRemoval
        ) { model in
            Button("Remove", role: .destructive) { library.remove(model) }
        } message: { model in
            Text("Its files are deleted from ~/.cache/huggingface. You can download it again.")
                .accessibilityLabel("\(model.name)'s files are deleted from the Hugging Face cache. You can download it again.")
        }
    }

    private func status(of setting: String, download: SpeechModelLibrary.State?) -> SpeechModelRowStatus {
        SpeechModelRowStatus.of(
            setting: setting,
            chosen: chosen,
            loaded: context.transcript.speechModel,
            phase: context.transcript.phase,
            progress: context.transcript.modelProgress,
            download: download
        )
    }

    private func canRemove(_ model: SpeechModelCatalog.Model) -> Bool {
        let setting = model.mac.repository.rawValue
        return library.canRemove(model)
            && !SpeechModelRowStatus.same(setting, chosen)
            && !SpeechModelRowStatus.same(setting, context.transcript.speechModel)
    }

    private func actions(for model: SpeechModelCatalog.Model) -> SpeechModelStatusView.Actions {
        SpeechModelStatusView.Actions(
            download: { library.download(model) },
            cancelDownload: { library.cancelDownload(model) },
            use: { choose(model.mac.repository.rawValue) },
            remove: { confirmingRemoval = model },
            load: statusActions.load
        )
    }

    /// The language a model that is told one writes: the Language setting's, if the model has
    /// it, and otherwise its first. `nil` for a model that finds the language itself.
    private func languageChoice(for model: SpeechModelCatalog.Model) -> Binding<String>? {
        guard let first = model.languageChoices.first else { return nil }
        return Binding(
            get: { model.language(forSetting: language)?.code ?? first.code },
            set: { code in
                context.settingsStore.setSpeechLanguage(code)
                Log.ui.info("Speech language chosen in Settings: \(code, privacy: .public)")
            }
        )
    }

    /// For the chosen model outside the catalog: loading it again is all there is to do.
    private var statusActions: SpeechModelStatusView.Actions {
        SpeechModelStatusView.Actions(load: { context.transcript.retryLoading() })
    }

    private func useOtherModel() {
        guard (try? SpeechModelLocation(setting: otherModel)) != nil else { return }
        choose(otherModel.trimmingCharacters(in: .whitespacesAndNewlines))
        otherModel = ""
    }

    private func choose(_ setting: String) {
        context.settingsStore.setText(setting, for: .sttModel)
        Log.ui.info("Speech model chosen in Settings: \(setting, privacy: .public)")
    }
}

/// One catalog model: what it is for, the language it writes if it's told one, and its status or
/// what can be done with it.
private struct SpeechModelRow: View {
    let model: SpeechModelCatalog.Model
    let isDefault: Bool
    let status: SpeechModelRowStatus
    let canRemove: Bool
    /// The Language setting, for a model that is told one.
    let language: Binding<String>?
    let actions: SpeechModelStatusView.Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.name).fontWeight(.medium)
                        if isDefault {
                            Text("Default")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(model.summary)
                        .foregroundStyle(.secondary)
                    Text("\(model.languages) · \(ByteCountFormatter.string(fromByteCount: model.mac.bytes, countStyle: .file)) · \(model.licence)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.credit)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                if let language {
                    Picker("Language", selection: language) {
                        ForEach(model.languageChoices) { choice in
                            Text(choice.name).tag(choice.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("\(model.name)'s language")
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                SpeechModelStatusView(status: status, modelName: model.name, actions: actions)
                if canRemove {
                    Button { actions.remove() } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove its files")
                    .accessibilityLabel("Remove \(model.name)")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A model's status, or the button for what comes next.
struct SpeechModelStatusView: View {
    struct Actions {
        var download: () -> Void = {}
        var cancelDownload: () -> Void = {}
        var use: () -> Void = {}
        var remove: () -> Void = {}
        /// Loads the chosen model again, after it failed to load or loading was cancelled.
        var load: () -> Void = {}
    }

    let status: SpeechModelRowStatus
    let modelName: String
    let actions: Actions

    var body: some View {
        switch status {
        case .inUse:
            Label("In use", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("\(modelName) is in use")
        case .loading(let fraction):
            VStack(alignment: .trailing, spacing: 2) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 110)
                    Text("Downloading \(fraction, format: .percent.precision(.fractionLength(0)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(modelName) is loading")
        case .waitingForLiveTranscript:
            Text("Loads when the live transcript stops")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 150, alignment: .trailing)
        case .failedToLoad(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Label("Couldn't load", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
                Button("Try Again", action: actions.load)
                    .accessibilityLabel("Load \(modelName) again")
            }
        case .notLoaded:
            Button("Load", action: actions.load)
                .accessibilityLabel("Load \(modelName)")
        case .notDownloaded:
            Button("Download", action: actions.download)
                .accessibilityLabel("Download \(modelName)")
        case .downloading(let fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction).frame(width: 90)
                    .accessibilityLabel("Downloading \(modelName)")
                Button("Cancel", action: actions.cancelDownload)
                    .accessibilityLabel("Cancel downloading \(modelName)")
            }
        case .downloadFailed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
                Button("Try Again", action: actions.download)
                    .accessibilityLabel("Download \(modelName) again")
            }
        case .downloaded:
            Button("Use", action: actions.use)
                .accessibilityLabel("Use \(modelName)")
        }
    }
}

/// What a model's row in Settings › Models shows: for the model chosen, how its loading goes;
/// for any other, its download.
enum SpeechModelRowStatus: Equatable {
    /// Loaded, and transcribing.
    case inUse
    /// Chosen, and loading: downloading first, when `fraction` is known.
    case loading(fraction: Double?)
    /// Chosen while the live transcript uses the model before it, which stays until it stops.
    case waitingForLiveTranscript
    /// Chosen, and it failed to load.
    case failedToLoad(String)
    /// Chosen, and loading it was cancelled.
    case notLoaded
    case notDownloaded
    case downloading(fraction: Double)
    case downloadFailed(String)
    /// Downloaded, and not chosen.
    case downloaded

    /// - Parameters:
    ///   - setting: the model's Speech-to-text setting: its repository, or a folder.
    ///   - chosen: the Speech-to-text setting now.
    ///   - loaded: the setting of the speech model loaded (``TranscriptViewModel/speechModel``).
    ///   - download: the library's state for a catalog model; `nil` for any other.
    static func of(
        setting: String,
        chosen: String,
        loaded: String?,
        phase: SessionPhase,
        progress: [ModelLoadProgress],
        download: SpeechModelLibrary.State?
    ) -> Self {
        if same(setting, chosen) {
            switch phase {
            case .loading:
                let downloading = progress.first { same($0.modelID, setting) && $0.stage == .downloading }
                return .loading(fraction: downloading?.fractionCompleted)
            case .failed(.modelLoadFailed(let model, let message)) where same(model, setting):
                return .failedToLoad(message)
            case .notLoaded:
                return .notLoaded
            default:
                break
            }
            if same(loaded, setting) { return .inUse }
            return phase == .listening || phase == .stopping ? .waitingForLiveTranscript : .loading(fraction: nil)
        }
        // A model chosen during the live transcript waits for it, and this one is still in use.
        if same(loaded, setting) { return .inUse }
        switch download {
        case .none, .notDownloaded: return .notDownloaded
        case .downloading(let fraction): return .downloading(fraction: fraction)
        case .downloaded: return .downloaded
        case .failed(let message): return .downloadFailed(message)
        }
    }

    /// Two Speech-to-text settings for the same model: Hugging Face ignores case.
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
