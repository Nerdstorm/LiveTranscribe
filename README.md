# Live Transcribe

On-device speech-to-text for Apple silicon Macs, in two modes:

- **Dictation, in any app.** Hold Fn (🌐), speak, release: the text, cleaned up by a local
  language model, is typed at the cursor of whatever app you are in.
- **Live transcript.** Speak into your microphone and the transcript appears in a small window,
  each line cleaned up and saved to a JSONL file.

Every model runs on your Mac with [MLX](https://github.com/ml-explore/mlx-swift): no audio or
text leaves it.

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

Live Transcribe runs in the menu bar; it has a Dock icon only while one of its windows is open.
On first launch it opens **Set Up Dictation**, which asks for microphone and Accessibility access
(Accessibility lets the dictation shortcut work in every app and type the text), and downloads
the models into the Hugging Face cache (`~/.cache/huggingface`, shared with the tests, the bench
and other Hugging Face tools). Dictation and **Start Transcribing** become available once the
models have loaded. If the cleanup model fails to load, the app transcribes without cleanup and
offers **Retry**.

Choose the microphone from the menu bar's **Microphone** menu or above the transcript. **System
Default** follows the input selected in macOS, including while you dictate or transcribe, so a
newly connected microphone is picked up. Virtual and aggregate devices (from Teams, Zoom, audio
routing tools) are hidden unless you turn on **Show Other Devices**, and are never switched to
automatically. If a microphone you chose disconnects, capture falls back to the system default,
tells you, and switches back when it reconnects.

**Settings** (⌘, or the menu bar) has tabs for dictation (shortcut, cleanup level, microphone),
snippets, vocabulary, per-app insertion, history and permissions. Dictation settings apply
immediately. **Advanced** holds the live transcript's tunables: models, voice-detection
thresholds and pre-roll, segment limits, partial text refresh, cleanup context, timeout and
queue size, GPU cache, and capture restarts. **Those apply the next time the app starts.**

### Dictation

- **Hold** the shortcut (Fn by default), speak, and release. Text is inserted where the cursor
  is, through Accessibility, or by pasting for apps that ignore it (your clipboard is put back
  afterwards). If neither works, the text is left on the clipboard and the floating panel says so.
- **Double-tap** the shortcut to dictate hands-free; press it again to finish.
- **Esc** cancels, while recording or while the text is being prepared.
- **Undo AI Edit** (⌃⌥Z, within 30 seconds) swaps the cleaned text for exactly what you said.
- **Cleanup level** (menu bar or Settings): *None* inserts the raw transcript; *Light* fixes
  punctuation, casing and recognition errors only; *Medium* (default) also removes fillers such
  as "um" and resolves spoken self-corrections ("Monday, no wait, Tuesday" → "Tuesday"); *High*
  may also reword lightly for grammar.
- **Snippets**: say a trigger phrase to insert saved text exactly as written.
- **Vocabulary**: names and jargon the cleanup should spell your way, with the ways you say them.
- Nothing is typed into password fields. With Fn as the shortcut, set System Settings ›
  Keyboard › *Press 🌐 key to* to **Do Nothing**, or macOS also acts on the key; Settings warns
  when it is not.

### Signing and Gatekeeper

The app is built for Developer ID distribution: it runs outside the App Sandbox (inserting text
into other apps needs the Accessibility permission, which sandboxed apps cannot use), with the
Hardened Runtime. That rules out the Mac App Store.

Builds from this repository are ad-hoc signed ("Sign to Run Locally") and not notarized, so they
run on the Mac that built them. Gatekeeper blocks a copy downloaded onto another Mac; build it
there instead, or allow it under System Settings › Privacy & Security. To distribute a build, sign
it with your Developer ID and notarize it. The ad-hoc signature changes with every build, so
macOS asks for microphone access again after a rebuild, and the Accessibility permission must be
granted again (remove the old entry and add the new build).

## Privacy

- Audio and transcripts never leave your Mac. There is no telemetry.
- The only network traffic is to Hugging Face (huggingface.co and the download servers it
  redirects to), to download the models on first launch, and on the next launch after you choose
  a different model in Settings. Downloaded models are reused without contacting Hugging Face
  again.
- **Dictation history is on by default.** Every dictation (what you said, the text inserted, the
  app, the cleanup level and timings) is kept in
  `~/Library/Application Support/org.nerdstorm.LiveTranscribe/History/` on this Mac only. It is
  never synced to iCloud or anywhere else. Turn it off, set how long it is kept, or clear it in
  Settings › History; **Dictation History** in the menu bar shows and searches it.
- Snippets, vocabulary and per-app insertion choices are JSON files in the same folder, readable
  only by your account.
- Every live transcript session is saved as an unencrypted JSONL file in
  `~/Library/Application Support/org.nerdstorm.LiveTranscribe/Sessions/`,
  which the **Sessions** button opens. Each line holds one segment: the raw and cleaned text,
  whether and why cleanup fell back to the raw text, start and end times, per-stage latencies,
  a timestamp and IDs. Files are kept until you delete them.
- Deleting the app does not delete its data. To remove it, delete
  `~/Library/Application Support/org.nerdstorm.LiveTranscribe` (sessions, dictation history,
  snippets, vocabulary and per-app insertion choices),
  `~/Library/Preferences/org.nerdstorm.LiveTranscribe.plist` (settings) and the models in
  `~/.cache/huggingface/hub` (folders named `models--mlx-community--…`, and `mlx-audio`).
- Earlier builds ran in the App Sandbox and kept their data in
  `~/Library/Containers/org.nerdstorm.LiveTranscribe`. The current app doesn't read it: move old
  sessions from its `Data/Library/Application Support/org.nerdstorm.LiveTranscribe/Sessions`
  folder if you want them, then delete the folder to free the models' space.

## Models and credits

The app downloads the models from Hugging Face. They are not part of this repository and not
covered by its licence. The cleanup adapter, a 10 MB LoRA adapter for Qwen3-1.7B, is part of
this repository.

| Role | Model used | Original model | Licence |
|---|---|---|---|
| Speech-to-text | [mlx-community/parakeet-tdt-0.6b-v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3) | [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Cleanup | [mlx-community/Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit) | [Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B) by the Qwen team, Alibaba Cloud | Apache-2.0 |
| Self-correction adapter | bundled (`Sources/Cleanup/Adapter`) | trained on synthetic data in this repository (`Training/`) | MIT |
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
App/                          menu bar app: menu, windows, composition root
LiveTranscribe.xcodeproj      app project (ad-hoc signed, hardened runtime, no App Sandbox)
docs/dictation.md             dictation: decisions, assumptions, settings and eval results
scripts/                      generate-test-audio.sh, generate-dictation-audio.sh
Packages/LiveTranscribeKit/   all feature code, as vertical slices
  Sources/
    Shared/          value types, AppSettings, logging, deadline, edit distance, atomic file writes
    Capture/         AVCaptureSession microphone capture → 16 kHz mono; microphone list and choice
    Segmentation/    Silero VAD + segmentation state machine (pre-roll, hysteresis, max length)
    Transcription/   Parakeet via mlx-audio-swift
    Cleanup/         Qwen3 via mlx-swift-lm, prompt, OutputGuard fallbacks, fine-tuned adapter
    Persistence/     JSONL session files and dictation history
    Session/         SessionCoordinator (lifecycle) + SessionPipeline (3 concurrent stages)
    TranscriptUI/    live transcript view model and views
    Hotkey/          global shortcut monitor (event tap), hold/double-tap gestures, bindings
    Permissions/     Accessibility and microphone permission, System Settings links
    Insertion/       typing at the cursor: Accessibility, paste with clipboard restore, per-app choice
    Styles/          rule-based filler removal and list formatting
    Snippets/        trigger phrases and the text they insert
    Vocabulary/      names and jargon, with how they are spoken
    Dictation/       DictationController: hotkey → record → transcribe → clean up → insert
    DictationUI/     menu bar menu, floating panel, setup, Settings tabs, history window
    MLXSupport/      MLX runtime configuration (GPU cache limit)
    Bench/           command-line tool: WER and latency over test clips, live transcript or dictation
    CleanupTraining/ dataset, LoRA training and evaluation for the cleanup adapter
    Train/           command-line tool: generate, validate, train and evaluate the adapter
  Tests/             Swift Testing; tests that need the models run only when enabled
  Training/          the adapter's dataset, and how it is trained (Training/README.md)
```

`App/AppComposition.swift` is the app's composition root: it constructs every concrete slice
implementation (the bench and the tests wire their own). The Settings window is the exception: it
reads and writes the settings in UserDefaults directly. Everything else depends on protocols
(`AudioSource`, `SpeechSegmenter`, `Transcriber`, `Cleaner`, `SessionSink`,
`MicrophonePermissionProviding`, for dictation `HotkeyMonitor`, `FocusedTargetProvider`,
`TextDelivery`, `DictationHistory` and `AccessibilityPermissionProviding`, and in the UI
`SessionControlling` and `InputDeviceSelecting`), which the unit tests replace with fakes or, for
`SessionSink`, the in-memory `MemorySessionSink`. Dictation and the live transcript share one
instance of each model; they never run at the same time.

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

The dictation eval's 44 clips (`Tests/IntegrationTests/Fixtures/Dictation/clips.tsv`) are
generated the same way:

```bash
scripts/generate-dictation-audio.sh
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
- `--no-adapter`: clean up without the fine-tuned self-correction adapter.
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

### Dictation eval

```bash
(cd Packages/LiveTranscribeKit && .build/xcode/Build/Products/Release/Bench --dictation)
```

Runs the 44 dictation clips (plain sentences, fillers, self-corrections, questions and longer
passages) through dictation's speech-to-text and cleanup at every cleanup level, and reports per
level and category the WER against what was *said* and against what was *meant* (fillers dropped,
self-corrections resolved), the fallbacks, and p50/p95 latency from release to text against the
target of p95 under 1.2 s. `--level <none|light|medium|high>` (repeatable) limits the levels,
`--clips <dir>` reads other clips, `--p95-target-ms <n>` changes the target and `--verbose`
prints every output.

Last run, on an M4 Pro:

| Level | WER vs said | WER vs meant | Fallbacks | p50 (ms) | p95 (ms) |
|---|---:|---:|---:|---:|---:|
| None | 1.9% | 24.2% | 0 | 32 | 59 |
| Light | 2.1% | 23.9% | 0 | 159 | 308 |
| Medium | 15.5% | 1.8% | 1 | 184 | 386 |
| High | 15.5% | 1.8% | 1 | 199 | 388 |

Medium resolved all 12 self-corrections and removed the fillers from all 10 filler clips. Every
level met the latency target. The one fallback (a plain sentence at Medium and High) is the
self-correction adapter changing a sentence that had nothing to correct; OutputGuard caught it
and the raw text was inserted.

## Design notes

- **A menu bar app.** Dictation has to be available in every app, so Live Transcribe lives in
  the menu bar (`LSUIElement`) and becomes a regular app with a Dock icon only while one of its
  windows (transcript, history, Settings, setup) is open.
- **Dictation reuses the live transcript's models and cleanup** rather than adding a second
  pipeline: one Parakeet and one Qwen3-1.7B instance serve both. The self-correction adapter is
  switched on per request, only at Medium and High, so Light never resolves corrections.
- **The shortcut is read with a `CGEventTap`**, which needs Accessibility. That is also the
  permission typing into other apps needs, so dictation asks for only two permissions.
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
- Spoken self-corrections ("fuel efficiency in cars, sorry, buses" → "fuel efficiency in buses")
  are resolved by a small fine-tuned adapter bundled with the app (Settings › *Resolve spoken
  self-corrections*). On 515 held-out examples it resolved 97% of self-corrections and kept 98%
  of look-alike sentences ("sorry I'm late", "I mean, honestly…") as spoken; without it,
  Qwen3-1.7B resolved under 1%. Its training data is synthetic, so expect lower accuracy on real
  speech. OutputGuard rejects any cleanup that drops a correction cue ("sorry", "I mean", "no",
  "wait", "actually", "scratch that", …) unless the only words it removed were up to six
  retracted words before that cue, the cue itself, fillers such as "um", and immediately repeated
  words; and cleanup that keeps every cue may not delete a run of spoken words or a negation.
  A correction that moves a word rather than deleting it ("Tell Yasmin, or rather, Victor" →
  "Tell Victor, or rather,") can still get through.
- **Dictation needs Accessibility, which macOS ties to the app's signature.** Each ad-hoc
  rebuild is a new app to macOS: remove Live Transcribe from Privacy & Security › Accessibility
  and add the new build, or the shortcut stops working.
- The self-correction adapter occasionally rewrites a plain sentence (1 of 44 eval clips);
  OutputGuard catches it and inserts the raw transcript instead of the cleaned text.
- Reserved system shortcuts (⌘Space, ⌘Tab, …) are recognised by key position on a US layout, so
  on other layouts Settings may accept a shortcut that macOS already uses.
- ⌃⌥Space is allowed as a shortcut but can clash with input-source switching on some Macs.
- If the app crashes, up to `cleanupQueueCapacity` + 1 segments (9 by default) that were
  transcribed but not yet cleaned are lost: their raw text was on screen but not yet saved.
- The models come from each repository's `main` branch at first launch and are then reused, so
  Macs that install at different times can end up with different model versions.
- mlx-audio-swift copies the speech-to-text weights into a second folder of the Hugging Face
  cache; on APFS the copy is a clone, so `du` counts it twice but it takes no extra space.

## License

[MIT](LICENSE) © 2026 Nerdstorm. The licence covers this repository's code only. The models
(see [Models and credits](#models-and-credits)) and the Swift package dependencies have their own
licences.
