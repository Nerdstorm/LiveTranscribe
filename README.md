# Live Transcribe

On-device, realtime speech-to-text for Apple silicon Macs. Speak into your microphone and the
transcript appears in a small window, each line cleaned up by a local language model and saved
to a JSONL file. Every model runs on your Mac with [MLX](https://github.com/ml-explore/mlx-swift):
no audio or text leaves it.

The pipeline: microphone → Silero voice activity detection → Parakeet speech-to-text →
Qwen3-1.7B correction (recognition errors, punctuation, casing and grammar; it does not
rephrase) → window and file.

## Status

A working proof of concept, free and open source under the [MIT License](LICENSE).

- There are no prebuilt downloads: build it from source (below).
- Tested on an M4 Pro Mac with macOS 27 and Xcode 27. The app targets macOS 14 or later but has
  not been run on older systems.
- Tested with English speech. Parakeet v3 also recognises other European languages, but the
  cleanup step has not been tested with them.
- Issues and pull requests are welcome.

## Requirements

- An Apple silicon Mac. With the default models the app uses about 3 GB of memory. It has not
  been tested on 8 GB Macs.
- To build: Xcode 26.4 or later (Swift 6.3 or later), with its Metal Toolchain component
  (`xcodebuild -downloadComponent MetalToolchain`). MLX compiles Metal shaders, so build with
  `xcodebuild` or Xcode; `swift build` produces binaries without the Metal library.
- Disk space: about 3.5 GB for the models (Parakeet TDT 0.6B v3 is 2.5 GB, Qwen3-1.7B-4bit about
  1 GB) and about 2 GB for the build. The tests and the bench need roughly 7 GB more: their own
  copy of the models and their own build.

## Build and run

From the repository root:

```bash
xcodebuild build -project LiveTranscribe.xcodeproj -scheme LiveTranscribe -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-app -skipPackagePluginValidation
```

```bash
open .build/xcode-app/Build/Products/Release/LiveTranscribe.app
```

Or open `LiveTranscribe.xcodeproj` in Xcode and choose Run. The shared scheme runs the
**Release** configuration, because MLX inference in Debug is several times slower. On the first
build Xcode asks you to trust mlx-swift's `CudaBuild` build-tool plugin, which only does work in
CUDA builds; `-skipPackagePluginValidation` skips that prompt on the command line.

On first launch the app downloads the models into its sandbox container
(`~/Library/Containers/org.nerdstorm.LiveTranscribe/Data/Library/Caches/huggingface`) and shows
their progress. **Start Transcribing** becomes available once the models have loaded. If the
cleanup model fails to load, the app transcribes without cleanup and offers **Retry**. The first
Start asks for microphone access.

Choose the microphone from the menu above the transcript. **System Default** follows the input
selected in macOS. Your choice is saved and applies from the next Start; it cannot be changed
while a session is running. If the chosen microphone is disconnected, Start reports it until you
reconnect it or choose another.

**Settings** (⌘,) holds every tunable: models, cleanup on or off, voice-detection thresholds and
pre-roll, segment limits, how often the live partial text refreshes, cleanup context, timeout and
queue size, GPU cache, and how often capture may restart after an error. **Changes apply the next
time the app starts.** **Restore Defaults** resets these and keeps your microphone choice.

### Signing and Gatekeeper

Builds are ad-hoc signed ("Sign to Run Locally") and not notarized, so they run on the Mac that
built them. Gatekeeper blocks a copy downloaded onto another Mac; build it there instead, or allow
it under System Settings › Privacy & Security. The ad-hoc signature changes with every build, so
macOS may ask for microphone access again after a rebuild.

## Privacy

- Audio and transcripts never leave your Mac. There is no telemetry.
- The only network traffic is to Hugging Face (huggingface.co and the download servers it
  redirects to), to download the models on first launch, and on the next launch after you choose
  a different model in Settings. Downloaded models are reused without contacting Hugging Face
  again.
- Every session is saved as an unencrypted JSONL file in
  `~/Library/Containers/org.nerdstorm.LiveTranscribe/Data/Library/Application Support/org.nerdstorm.LiveTranscribe/Sessions/`,
  which the **Sessions** button opens. Each line holds one segment: the raw and cleaned text,
  whether and why cleanup fell back to the raw text, start and end times, per-stage latencies,
  a timestamp and IDs. Files are kept until you delete them.
- Deleting the app does not delete its data. To remove the models, sessions and settings, delete
  the `~/Library/Containers/org.nerdstorm.LiveTranscribe` folder.

## Models and credits

The app downloads the models from Hugging Face. They are not part of this repository and not
covered by its licence.

| Role | Model used | Original model | Licence |
|---|---|---|---|
| Speech-to-text | [mlx-community/parakeet-tdt-0.6b-v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3) | [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Cleanup | [mlx-community/Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit) | [Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B) by the Qwen team, Alibaba Cloud | Apache-2.0 |
| Voice activity detection | [mlx-community/silero-vad](https://huggingface.co/mlx-community/silero-vad) | [Silero VAD](https://github.com/snakers4/silero-vad) by the Silero team | MIT |

If you redistribute the Parakeet weights, for example bundled with a build, CC BY 4.0 requires
you to credit NVIDIA.

Built with [mlx-swift](https://github.com/ml-explore/mlx-swift),
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm),
[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift),
[swift-huggingface](https://github.com/huggingface/swift-huggingface) and
[swift-transformers](https://github.com/huggingface/swift-transformers). Every package
dependency, including indirect ones, is MIT or Apache-2.0 licensed. Some bundle third-party code
under other permissive licences (MLX includes the BSD-licensed PocketFFT, for example), so a
redistributed build must carry those notices too.

## Project layout

```
App/                          SwiftUI app target: window, settings, composition root
LiveTranscribe.xcodeproj      app project (ad-hoc signed, sandboxed, hardened runtime)
scripts/                      generate-test-audio.sh
Packages/LiveTranscribeKit/   all feature code, as vertical slices
  Sources/
    Shared/          value types, AppSettings, logging, deadline, edit distance
    Capture/         AVCaptureSession microphone capture → 16 kHz mono; microphone list and choice
    Segmentation/    Silero VAD + segmentation state machine (pre-roll, hysteresis, max length)
    Transcription/   Parakeet via mlx-audio-swift
    Cleanup/         Qwen3 via mlx-swift-lm, prompt, OutputGuard fallbacks
    Persistence/     JSONL session files
    Session/         SessionCoordinator (lifecycle) + SessionPipeline (3 concurrent stages)
    TranscriptUI/    view model and views
    MLXSupport/      MLX runtime configuration (GPU cache limit)
    Bench/           command-line tool: WER and per-stage latency over test clips
  Tests/             Swift Testing; tests that need the models run only when enabled
```

`App/AppComposition.swift` is the app's composition root: it constructs every concrete slice
implementation (the bench and the tests wire their own). The Settings window is the exception: it
reads and writes the settings in UserDefaults directly. Everything else depends on protocols
(`AudioSource`, `SpeechSegmenter`, `Transcriber`, `Cleaner`, `SessionSink`,
`MicrophonePermissionProviding`, and in the UI `SessionControlling` and `InputDeviceSelecting`),
which the unit tests replace with fakes or, for `SessionSink`, the in-memory `MemorySessionSink`.

## Tests

Unit tests need no models:

```bash
(cd Packages/LiveTranscribeKit && xcodebuild test -scheme LiveTranscribeKit-Package -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -skipPackagePluginValidation -skip-testing:IntegrationTests)
```

The end-to-end tests and the bench use short spoken clips. The clips are not in the repository,
because Apple's licence does not allow publishing recordings of its system voices. Generate them
with macOS text-to-speech before building the tests:

```bash
scripts/generate-test-audio.sh
```

The end-to-end tests run the real models, downloading them into `~/.cache/huggingface`.
xcodebuild passes environment variables to the test runner only with the `TEST_RUNNER_` prefix:

```bash
(cd Packages/LiveTranscribeKit && TEST_RUNNER_LT_RUN_MODEL_TESTS=1 xcodebuild test -scheme LiveTranscribeKit-Package -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -skipPackagePluginValidation -only-testing:IntegrationTests)
```

Set `TEST_RUNNER_LT_PROMPT_PROBE=1` instead to print the cleanup model's output for a set of
hard prompt cases, a development aid for prompt changes.

## Bench

```bash
(cd Packages/LiveTranscribeKit && xcodebuild build -scheme Bench -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -skipPackagePluginValidation)
```

```bash
(cd Packages/LiveTranscribeKit && .build/xcode/Build/Products/Release/Bench)
```

Options:

- `--fixtures <dir>`: a folder of `.wav` clips, each with a matching `.txt` transcript.
- `--no-cleanup`: speech-to-text only.
- `--fast`: feed audio as fast as possible instead of in real time. Latency numbers are then
  meaningless.

The bench prints the word error rate (WER) of the raw and cleaned text, p50 and p95 latency per
stage, and four checks:

- p95 from end of speech to text on screen is under 1.5 s;
- cleaned WER is no worse than raw WER;
- no clip's WER gets more than 2 points worse after cleanup;
- cleanup falls back to the raw text for fewer than 5% of segments.

Last run, on an M4 Pro with the four generated clips played in real time. **These numbers are
from Parakeet v2, the previous default; v3 has not been benchmarked yet.**

| Stage | p50 (ms) | p95 (ms) |
|---|---:|---:|
| Silence that ends a segment | 608 | 608 |
| Speech-to-text | 68 | 113 |
| Cleanup | 157 | 403 |
| End of speech → text | 837 | 1126 |

WER was 1.0% raw and 1.0% cleaned, with no fallbacks, and all four checks passed. The first row
is the configured 600 ms of silence that closes a segment; lower `vadSilenceMs` to trade it for
more segment splits. The clips are synthetic speech, so measure with real recordings on your own
hardware before relying on these numbers.

## Design notes

- **One window with a Start/Stop button**, rather than a menu-bar app, keeps the proof of concept
  simple.
- **Capture uses an input-only `AVCaptureSession`, not `AVAudioEngine`.** On macOS,
  `AVAudioEngine` stops whenever its audio device reconfigures, and a Bluetooth headset
  reconfigures every time its microphone opens, because it switches to its call profile.
  Restarting the engine reopened the microphone, so capture looped. A capture session has no
  output side and keeps running through the switch. It also delivers 16 kHz mono directly and
  opens the chosen microphone by its ID.
- **The cleanup prompt is multi-turn.** Each previous segment becomes a user `TEXT:` turn
  followed by an assistant turn holding its cleaned text, and the new segment is the last user
  turn. With the context inlined into a single message, the model sometimes echoed the context
  back and OutputGuard rejected the output for its word count. With multi-turn, fallbacks on a
  set of hard prompt cases went from 1 in 10 to none.
- **The Hugging Face downloader and tokenizer adapters are hand-written**
  (`Cleanup/HuggingFaceAdapters.swift`) instead of using mlx-swift-lm's `MLXHuggingFace` macros,
  which would need Xcode's macro-trust prompt. That makes `swift-huggingface` and
  `swift-transformers` direct dependencies; both were already indirect ones.
- **`mlx-audio-swift` is pinned by revision** (the commit of tag v0.1.3), not by version. It uses
  `unsafeFlags`, which SwiftPM accepts only from packages pinned by revision or by local path.

## Known limitations

- **A Bluetooth headset's microphone switches the headset into call mode.** macOS does this
  whenever any app opens a headset microphone: the headset drops to 16 kHz and its playback
  quality falls until capture stops. Transcription works, but for better playback use the
  built-in or a wired microphone while the headset plays audio.
- Correcting with a 1.7B model does not reliably fix homophones ("cash" → "cache"). That needs a
  larger model or a domain vocabulary. OutputGuard's similarity floor limits how far the model can
  change the text.
- Spoken self-corrections are normally kept as spoken. The cleanup prompt tells the model to
  remove nothing, so "fuel efficiency in cars, sorry, buses" usually stays as said rather than
  becoming "fuel efficiency in buses". Asked to resolve them, Qwen3-1.7B got at most 1 in 7 right
  and usually kept the words the speaker took back instead of the correction. OutputGuard
  therefore rejects any cleanup that drops a correction cue ("sorry", "I mean", "no", "wait",
  "actually", "scratch that", …) unless the only words it removed were up to six retracted words
  before that cue, the cue itself, fillers such as "um", and immediately repeated words.
- If the app crashes, up to `cleanupQueueCapacity` + 1 segments (9 by default) that were
  transcribed but not yet cleaned are lost: their raw text was on screen but not yet saved.
- The models come from each repository's `main` branch at first launch and are then reused, so
  Macs that install at different times can end up with different model versions.
- The sandboxed app keeps its own model copy in its container, separate from
  `~/.cache/huggingface`, which the tests and the bench use. mlx-audio-swift also copies the
  speech-to-text weights into a second folder; on APFS the copy is a clone, so `du` counts it
  twice but it takes no extra space.

## License

[MIT](LICENSE) © 2026 Nerdstorm. The licence covers this repository's code only. The models
(see [Models and credits](#models-and-credits)) and the Swift package dependencies have their own
licences.
