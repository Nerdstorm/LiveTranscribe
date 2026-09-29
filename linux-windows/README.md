# Live Transcribe for Linux and Windows

One Rust codebase for the Linux and Windows desktop app, which will run speech-to-text on the
computer's NPU. The Mac app stays in Swift (`Packages/LiveTranscribeKit`); the two share their
behaviour through the golden cases in [`Fixtures/golden`](../Fixtures/golden/README.md).

This is the start. The dictation text rules, ported from the Mac app, type the same text as the
Mac app for all 9,728 golden cases, and speech to text computes Qwen3-ASR's audio features,
prompt and decoding as the Mac app does, with the model running on OpenVINO. The app,
`livetranscribe`, dictates on Linux under Wayland as the Mac app does: hold a key and speak, and
a small circle by the mouse pointer shows the microphone's level while the text goes straight into
the focused field.
A tray menu starts, stops and cancels dictation, copies the last one, sets the cleanup level and
opens Settings, whose General, Models and Advanced tabs change dictation without a restart.
Settings › Models chooses the speech model from the catalog the Mac app reads too, and downloads
and removes them: by default the Mac app's Sinhala fine-tune of Qwen3-ASR, which runs on the NPU of
an Intel Core Ultra or on the CPU, and NVIDIA's Parakeet TDT 0.6B v2 (English) and v3 (25 European
languages) and Cohere Transcribe (the one of its 14 languages chosen on its row), which run on the
CPU with sherpa-onnx. Settings' other tabs, the history window, and Windows come later.

## Building and testing

```bash
packaging/fetch-sherpa-onnx.sh
```

```bash
cargo test
```

`rust-toolchain.toml` pins the Rust version, and rustup installs it on the first build. The tests
include the golden cases (`crates/dictation/tests/golden.rs`). CI runs formatting, clippy and the
tests on Linux and Windows (`.github/workflows/linux-windows.yml`).

The first command puts sherpa-onnx's speech-only libraries in `target/sherpa-onnx/lib`, checked
against their SHA-256: sherpa-onnx (k2-fsa, Apache-2.0) runs the catalog's other speech models,
with ONNX Runtime (Microsoft, MIT). `.cargo/config.toml` points the `sherpa-onnx` crate at them,
and without them the build stops rather than let the crate download sherpa-onnx's default
libraries, which link espeak-ng (GPL-3.0) for text to speech. The script runs on Linux x64, on
Windows x64 in Git Bash, and on Apple silicon Macs.

The workspace builds its own copy of the `openvino` crate, which can pass properties to a model's
compilation, as the NPU's LLM mode needs: see [`vendor/openvino/VENDORED.md`](vendor/openvino/VENDORED.md).

## Layout

One crate per slice of the Mac app's Swift package, with the same names, so a rule lives in the
same place in both apps:

| Crate | Swift module | What it holds |
|---|---|---|
| `lt-shared` | `Shared` | Text with Swift's semantics, the phrase protector and its placeholders, word normalisation, cleanup levels |
| `lt-styles` | `Styles` | Filler removal, and the layout of spoken lists and letters |
| `lt-spoken-commands` | `SpokenCommands` | Emoji, dictated punctuation, line breaks, email and web addresses |
| `lt-snippets` | `Snippets` | The user's snippets |
| `lt-vocabulary` | `Vocabulary` | The user's vocabulary |
| `lt-cleanup` | `Cleanup` | Cleanup at each level; for now the rules that need no language model |
| `lt-dictation` | `Dictation` | The dictation flow from hotkey to typed text, and a transcript to the text it types |
| `lt-transcription` | `Transcription`, and mlx-audio-swift's Qwen3-ASR | Speech to text: the log-mel features, the encoder's chunks and windows, the prompt, greedy decoding and its limits. The model's forward passes are behind the `SpeechModel` trait; `OpenVinoModel` runs them on OpenVINO. `sherpa` runs the catalog's other models through sherpa-onnx, on the CPU. `catalog` reads the speech model catalog and checks a model's files before it's opened; `speech_to_text` opens a model with its engine |
| `lt-hotkey` | `Hotkey` | The hold, tap and double-tap gesture; what each key means for it; on Linux, reading the keyboards (evdev) |
| `lt-capture` | `Capture` | Recording the microphone chosen in Settings, or the default one (cpal; on Linux, the sound server's), as 16 kHz mono, and its level for the meter |
| `lt-insertion` | `Insertion` | What is known about the focused field, what the clipboard holds while text is pasted, and what an insertion did |
| `lt-dictation-ui` | `DictationUI` | The panel shown while dictating (what it shows when, drawn to pixels, and where by the pointer) and what the tray says, with its icons |
| `lt-wayland` | `Insertion`'s typing and the HUD's window, for Wayland | One connection for the desktop: the input method (input-method-v2), which reads the focused field and types straight into it; pasting where no field takes one (ext-data-control and a virtual keyboard); the panel by the mouse pointer (wlr-layer-shell, with ext-image-copy-capture's cursor sessions saying where the pointer is), or at the bottom of the screen |
| `lt-app` | the app | The `livetranscribe` command: `run` (dictation, with the tray and the Settings window, Tauri's; `ui/` holds the window's page), `keys`, `transcribe`, `models`; the settings file; downloading the catalog's models (`speech_models`) |

## Packages

The release workflow (`.github/workflows/release.yml`) builds a deb, an rpm and an AppImage in
Ubuntu 22.04, whose glibc (2.35) sets the oldest distributions they run on: Ubuntu 22.04, Debian 12,
and any current Fedora, openSUSE or Arch: `live-transcribe_X.Y.Z_amd64.deb`,
`live-transcribe-X.Y.Z-1.x86_64.rpm` and `live-transcribe_X.Y.Z_amd64.AppImage`. Each release tag
`vX.Y.Z` puts them on the release with the Mac app, at the tag's version, which replaces the app
crate's 0.0.0 ([Releasing](../docs/releasing.md)). A pull request that changes how the packages
are made builds them too, to try from the run's artifacts. Each carries:

- the app, `/usr/bin/livetranscribe`, which runs dictation when started with no command, as the
  desktop's menu starts it;
- OpenVINO 2026.2.1's runtime in `/usr/lib/live-transcribe/openvino`: Intel's prebuilt libraries,
  unmodified, under Intel's licence, which allows redistributing them (`licenses/` beside them).
  `packaging/linux/fetch-openvino.sh` fetches them, one file each under its soname, since Tauri's
  bundler would copy each symlink as another whole file, and `packaging/linux/check-packages.sh`
  checks that each package has them byte for byte. The app loads them from there
  (`vendor/openvino`'s `load_from_folder`), since Intel's libraries don't say where to find each
  other. **The AppImage has them in `usr/share/live-transcribe/openvino`**: linuxdeploy, which
  makes it, sets the RUNPATH of every library in `usr/lib`, and the licence doesn't allow changing
  them;
- sherpa-onnx 1.13.8's C API and ONNX Runtime 1.28.2 in `/usr/lib/live-transcribe/sherpa-onnx`,
  which the app links and finds there through its RUNPATH (`crates/app/build.rs`), with their
  licences in `/usr/share/doc/live-transcribe/sherpa-onnx`. The AppImage has them in `usr/lib`,
  where linuxdeploy copies them, since they may be changed. `check-packages.sh` checks that each
  package has them and starts each package's app, as installed, to list the speech models;
- in the deb and rpm, a udev rule that lets whoever is logged in at the machine read the keyboards,
  which hold-to-talk needs. **Any program that user runs can then read what they type**, as any
  X11 program always could. The AppImage can't install it; `packaging/linux/README.Linux` says how.

The speech models aren't in the packages. The app downloads the one chosen the first time it's
needed, by default Nerdstorm/Qwen3-ASR-0.6B-Sinhala-OpenVINO (1.1 GB) from Hugging Face, and
Settings › Models downloads and removes the others, which sherpa-onnx publishes on GitHub as
`.tar.bz2` archives. The catalog,
[`speech-models.json`](../Packages/LiveTranscribeKit/Sources/Transcription/Resources/speech-models.json),
pins each model: a Hugging Face repository at a commit, or an archive, with each file's size and
SHA-256 (`scripts/pin-linux-windows-speech-model.sh` writes a model's entry). A model downloads
into a hidden folder beside the others, and moves into place only when every file matches
(`crates/app/src/speech_models/`); from an archive, only the catalog's files are unpacked, and the
archive is deleted. The app checks a model's files again before it opens it, since a damaged file
would crash ONNX Runtime rather than fail, and remembers what it checked (`.verified.json`), so
later starts hash only the files that changed. The tray and Settings show the progress. A download
that stops carries on where it stopped the next time; after that the app never goes online for the
model again. `livetranscribe models` lists the catalog, and
`livetranscribe transcribe --model parakeet-tdt-0.6b-v2 clip.wav` transcribes with one of its
models, downloading it first; `--language de` tells Cohere Transcribe which language to write. Intel's NPU driver isn't in the packages either: the rpm recommends
Fedora's `intel-npu-driver`, and without one the Qwen3-ASR models run on the CPU.

To build them by hand, in Ubuntu 22.04 with Tauri's build dependencies and the Tauri CLI 2.12:

```bash
packaging/linux/fetch-openvino.sh
```

```bash
packaging/fetch-sherpa-onnx.sh
```

```bash
cd crates/app && LD_LIBRARY_PATH=$(cd ../../target/sherpa-onnx/lib && pwd) cargo tauri build
```

`LD_LIBRARY_PATH` is how linuxdeploy finds the sherpa-onnx libraries for the AppImage.

## Running it from source

The app needs OpenVINO 2026.2 and the speech model converted for it. On the owner's Fedora
machine, the setup kit (not in the repository) installs both in an Ubuntu 24.04 toolbox. By hand:

1. Install OpenVINO's runtime and point `INTEL_OPENVINO_DIR` at it, with its `runtime/lib/intel64`
   and `runtime/3rdparty/tbb/lib` on `LD_LIBRARY_PATH`. The app loads it when it starts, so it
   builds without it.
2. Get the speech model, or let the app download it when it first starts. The app's default is
   the Mac app's,
   [Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit](https://huggingface.co/Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit):
   Qwen3-ASR-0.6B fine-tuned for Sinhala, which transcribes English nearly as well as the original.
   On the NPU of a Core Ultra 7 258V it gets 6.31% of characters wrong on OpenSLR 52's Sinhala test
   set, as the Mac app does (6.36%), and 5.18% of words on FLEURS English, where the original gets
   5.05%. It is on Hugging Face converted for OpenVINO,
   [Nerdstorm/Qwen3-ASR-0.6B-Sinhala-OpenVINO](https://huggingface.co/Nerdstorm/Qwen3-ASR-0.6B-Sinhala-OpenVINO):

   ```bash
   hf download Nerdstorm/Qwen3-ASR-0.6B-Sinhala-OpenVINO --revision 8298d9b2d532965800b2c0c64b81965ededb03a3 \
     --local-dir ~/.local/share/live-transcribe/models/qwen3-asr-0.6b-sinhala
   ```

   Or convert it yourself, in a Python environment with `openvino==2026.2.1`, `nncf==3.2.0`,
   `transformers==5.13.1` and CPU PyTorch:

   ```bash
   python tools/export-qwen3-asr.py --model /path/to/Qwen3-ASR-0.6B-Sinhala-8bit \
     --source Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit@c123d53a5057d10b1efbd0cd578d5d70bcde8509 \
     --out ~/.local/share/live-transcribe/models/qwen3-asr-0.6b-sinhala
   ```

   That checkpoint is mlx-audio's, with 8-bit weights, which the exporter turns back into floats
   first; it reads Qwen's own checkpoints, such as
   [Qwen/Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B), too. It writes the audio
   convolutions and encoder (fp16) and the language model (symmetric int8 weights, which the NPU
   runs 50 times faster than asymmetric ones; its KV cache kept as state), then checks each against
   PyTorch, and checks that OpenVINO's model cache gives them back unchanged: OpenVINO 2026.2.1's
   CPU plugin corrupts one way of writing RoPE in its cache, which made every start after the first
   transcribe gibberish. Settings › Models (**Another model**) chooses among the models converted
   into `~/.local/share/live-transcribe/models`, as `--model <folder>` does.
3. `cargo build --release -p lt-app` (the tray builds against WebKitGTK, libxdo and the app
   indicator library: Tauri's prerequisites), then:

   ```bash
   target/release/livetranscribe run
   ```

   The tray's *Settings…* sets the hotkey, hands-free, the cleanup level, the microphone, the
   timing, the speech model (Models) and where it runs (Advanced), each at once, and keeps them in
   `~/.config/live-transcribe/settings.json`. Options after `run` set one for that run only:
   `livetranscribe run --key KEY_RIGHTALT` holds Right Alt instead of Right Ctrl.
   `livetranscribe keys` names the keys you press.

The Qwen3-ASR models run on the NPU when OpenVINO sees one: the audio encoder at fixed shapes, and
the language model in the NPU's LLM mode, for prompts of up to 1,024 tokens (about 75 seconds of
speech). A longer prompt, a reply that outgrows the NPU's cache, and anything the NPU can't compile
go to the CPU. Settings › Advanced (or `--device CPU`) keeps it all on the CPU. The first start
compiles the model for the NPU, which takes a few seconds; OpenVINO keeps what it compiled in
`~/.cache/live-transcribe`, so later starts take under a second. sherpa-onnx's models run on the
CPU, on half its cores (at most 8), whatever the device setting says.

Dictation reads the keyboard from `/dev/input`, so the user needs read access to it; a udev rule
with `TAG+="uaccess"` gives it to whoever is logged in at the machine. The app registers as the
desktop's input method, so text goes straight into fields that take one (GTK, Qt, Firefox,
Chromium with Wayland IME, COSMIC's apps and most Wayland terminals). Those fields say what they
are: password fields are refused, as on the Mac; terminals and fields for one value (an address, a
number) keep dictated text on one line, and other fields take line breaks, as the Mac app decides
(most say nothing either way); and the character before the cursor decides the leading space.
Elsewhere it pastes: the text goes on the clipboard, a virtual keyboard types Ctrl+V, and the
clipboard is put back. COSMIC has everything this needs, as do wlroots desktops such as Sway and
Hyprland (untested). KDE Plasma has neither input-method-v2 nor a virtual keyboard, and GNOME has
none of it, so dictation doesn't start there yet, nor on X11 desktops: the app starts anyway, and
Settings says why (`desktop_blocker` in `crates/app/src/dictation.rs`). They get their own ways in
later versions. With IBus or Fcitx running, they hold the input method, and the app pastes.

While you dictate, a small circle below and to the right of the mouse pointer follows it: a red
disc that grows with the microphone's level, a ring round it when hands-free, and a spinning ring
while the speech is transcribed. It has no words and takes no clicks; Esc or the tray's menu
cancels. When something needs your attention (nothing was heard, the text was left on the
clipboard, the microphone stopped), a short message shows in a bubble beside it for a few seconds.
The desktop says where the pointer is through cursor sessions (ext-image-copy-capture-v1), which
report the pointer's position without capturing the screen, and only while the circle shows.
Where the desktop has none, the circle sits at the bottom of the screen.

## Speech models on Linux

Each catalog model, measured on 2026-09-29 through a test build's deb in Ubuntu 22.04, on the CPU
of an Intel Core i5-11500 (6 cores): FLEURS English's test set (647 recordings, 106 minutes),
scored as the Mac app's bench scores (NFKC, case folded, punctuation ignored, numbers left as
written), and the Mac app's 65 dictation clips and 4 bench clips, one at a time with the model
loaded, as dictation runs them. Memory is the peak over the FLEURS run.

| Model | FLEURS English WER | Time per second of speech | Dictation clips WER | Per clip, p50 / p95 | Memory |
|---|---:|---:|---:|---:|---:|
| Qwen3-ASR 0.6B Sinhala (OpenVINO) | 5.25% | 0.093 s | 3.2% | 388 / 950 ms | 5.3 GB |
| Parakeet TDT 0.6B v2 | 5.77% | 0.043 s | 2.3% | 163 / 373 ms | 1.3 GB |
| Parakeet TDT 0.6B v3 | 9.67% | 0.044 s | 2.5% | 236 / 514 ms | 1.3 GB |
| Cohere Transcribe (English) | 5.83% | 0.131 s | 3.9% | 430 / 1,123 ms | 3.8 GB |

Qwen3-ASR's 5.25% matches the Mac app's 5.24%. Parakeet v3 is for other European languages
(6.86% on FLEURS German's 862 recordings): in English it writes numbers as words ("eight zero two
point one one"), which this scoring counts as wrong, and it left 2 of the 647 recordings empty.
There, a first use downloaded, unpacked and checked a model in 30 to 40 s (Parakeet), 80 s
(Qwen3-ASR, 1.1 GB) or 2.5 minutes (Cohere Transcribe, 1.7 GB). Later starts check only the files
that changed, and load in 0.5 s (Qwen3-ASR, from OpenVINO's cache), 1.5 s (Parakeet) or 4 s
(Cohere Transcribe).

Cohere Transcribe can't tell which language it hears, so each clip is told the one chosen on its
row in Settings › Models (English at first, as above), and choosing another applies from the next
dictation without loading the model again. With a development build on a Mac: told their
languages, it wrote the sample clips sherpa-onnx publishes with it in Chinese, Korean, Vietnamese,
Arabic, French, Spanish and German, where told English it wrote made-up English for the Chinese
and Korean ones (5 and 7 s long). On longer recordings, English mostly follows the audio anyway: on
30 of FLEURS German's, 5.29% WER told English and 5.15% told German, and on 15 of FLEURS Mandarin's,
23.4% and 22.2% character error rate.

## Matching the Mac app

The rules are written against Swift's `String`, whose characters are grapheme clusters and whose
equality is canonical equivalence. `lt_shared::swift_string` gives the port the same semantics, so
the rules read like their Swift originals. It was checked against the Swift runtime scalar by
scalar; where Swift's character properties differ from Rust's, the scalars are listed in
`crates/shared/src/swift_string/tables.rs`, which `tools/swift-character-tables.swift` writes. Run
that tool on a Mac after a macOS or Xcode update:

```bash
swiftc -O tools/swift-character-tables.swift -o /tmp/swift-character-tables
```

```bash
/tmp/swift-character-tables > crates/shared/src/swift_string/tables.rs
```

Emoji names come from `Fixtures/golden/emoji-names.tsv`, which the Mac app's tests write, rather
than from a Rust Unicode names table: macOS resolves names exactly, while Rust's name lookup
accepts loose spellings ("fire works" for FIREWORKS).

To change a rule, change the Swift first, regenerate the golden cases with `make golden` at the
repository root, then port the change here until `cargo test` passes.

Speech to text follows mlx-audio-swift's Qwen3-ASR at the revision the Mac app pins, not Qwen's
own processor: mlx-audio-swift counts the prompt's audio placeholders in float32, so a clip can
get a few more than Qwen's count, and the encoder fills only some of them. The Sinhala model was
trained on exactly that, so the port copies it. `Fixtures/golden/speech-features/` holds the
Mac app's log-mel features for three test clips, and `speech-layout.tsv` its placeholder and
encoder row counts for every clip length from one to ten seconds; `make golden` records them, and
`crates/transcription/tests/golden_speech_features.rs` checks the port against them. The tests
that need a real model folder are ignored by default:

```bash
LT_QWEN3_ASR_DIR=/path/to/Qwen3-ASR-0.6B cargo test -p lt-transcription -- --ignored
```

CI runs the sherpa-onnx one with Parakeet TDT 0.6B v2, which it downloads from sherpa-onnx's
release once and keeps between runs; the test checks the folder against the catalog, as the app
does, before it opens it:

```bash
LT_SHERPA_PARAKEET_DIR=/path/to/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8 cargo test -p lt-transcription --test sherpa -- --ignored
```

Dictated text is never logged: log lines carry counts only.

## Credits

The default speech model, [Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit](https://huggingface.co/Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit),
is [Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) by the Qwen team, Alibaba Cloud
(Apache-2.0), fine-tuned for Sinhala by Nerdstorm on OpenSLR 52 (Google, CC BY-SA 4.0). The
fine-tune is licensed CC-BY-SA-4.0.

The catalog's other models for Linux and Windows are quantised to 8 bits for ONNX by the
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) project (k2-fsa), and keep their licences:
[Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) and
[v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA (CC-BY-4.0), and Cohere
Transcribe by Cohere Labs (Apache-2.0). Settings › Models credits each with its licence.

sherpa-onnx (k2-fsa, Apache-2.0) and ONNX Runtime (Microsoft, MIT) run them; the packages carry
their licences, and ONNX Runtime's third-party notices.
