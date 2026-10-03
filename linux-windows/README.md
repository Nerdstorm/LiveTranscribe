# Live Transcribe for Linux and Windows

One Rust codebase (a Cargo workspace) for the Linux and Windows app, `livetranscribe`. It dictates
as the Mac app does: hold a key and speak, and the text goes into the focused field, cleaned at the
level you chose. Speech-to-text is Qwen3-ASR on OpenVINO (an Intel NPU when the computer has one,
otherwise the CPU), or Parakeet and Cohere Transcribe on sherpa-onnx (CPU). Cleanup is Qwen3-1.7B on
OpenVINO (CPU). Using the app is in [Using Live Transcribe](../docs/using.md#linux-and-windows), and
how it works in [Architecture](../docs/architecture.md). This page is for building, packaging and
changing it.

The Mac app stays in Swift (`Packages/LiveTranscribeKit`). The two share their behaviour through
fixtures the Mac app's tests write and this workspace's tests replay: the dictation text rules
type the same text as the Mac app for all 12,160 golden cases
([`Fixtures/golden`](../Fixtures/golden/README.md)), and cleanup's prompts, checks and executor
match ([`Fixtures/cleanup`](../Fixtures/cleanup/README.md)).

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

Building the app needs Tauri's prerequisites. On Linux: WebKitGTK, libxdo, the app indicator
library, librsvg and OpenSSL headers, plus pkg-config and ALSA's headers (`libasound2-dev`). On
Windows: Visual Studio's C++ build tools. The workspace builds its own copy of the `openvino`
crate, which can pass properties to a model's compilation, as the NPU's LLM mode needs: see
[`vendor/openvino/VENDORED.md`](vendor/openvino/VENDORED.md).

## Layout

One crate per slice of the Mac app's Swift package, with the same names, so a rule lives in the
same place in both apps:

| Crate | Swift module | What it holds |
|---|---|---|
| `lt-shared` | `Shared` | Text with Swift's semantics, the phrase protector and its placeholders, word normalisation, cleanup levels |
| `lt-styles` | `Styles` | Filler removal, the layout of spoken lists and letters, and numbers in digits |
| `lt-spoken-commands` | `SpokenCommands` | Emoji, dictated punctuation, line breaks, email and web addresses |
| `lt-snippets` | `Snippets` | Snippets (tested through the golden cases; the app loads none yet) |
| `lt-vocabulary` | `Vocabulary` | Vocabulary (the same) |
| `lt-cleanup` | `Cleanup` | The rules that need no language model, the prompt, the output guard, Deep's check (`SelfRepair`), and the executor that runs a model behind the `CleanupModel` trait under a deadline |
| `lt-language-model` | `Cleanup`'s `MLXCleaner`, and mlx-swift-lm's Qwen3 | Cleanup's language model on OpenVINO: the Qwen3 tokenizer and chat template, sampling, LoRA adapters bound per request as inputs of the model, and the pinned model's download. `examples/bench.rs` answers the Mac app's request files |
| `lt-dictation` | `Dictation` | The dictation flow from hotkey to typed text, and a transcript to the text it types |
| `lt-transcription` | `Transcription`, and mlx-audio-swift's Qwen3-ASR | Speech to text: the log-mel features, the prompt and decoding, behind the `SpeechModel` trait. `OpenVinoModel` runs Qwen3-ASR on OpenVINO, `sherpa` runs the catalog's other models on the CPU, and `catalog` reads the speech model catalog and checks a model's files before it is opened |
| `lt-hotkey` | `Hotkey` | The hold, tap and double-tap gesture; what each key means for it; reading the keyboards: evdev on Linux, a low-level keyboard hook on Windows |
| `lt-capture` | `Capture` | Recording the chosen or default microphone (cpal) as 16 kHz mono, and its level |
| `lt-insertion` | `Insertion` | What is known about the focused field, what the clipboard holds while text is pasted, and what an insertion did |
| `lt-dictation-ui` | `DictationUI` | The panel shown while dictating (what it shows when, drawn to pixels, and where by the pointer) and what the tray says, with its icons |
| `lt-wayland` | `Insertion`'s typing and the HUD's window, for Wayland | One connection for the desktop: the input method (input-method-v2), pasting where no field takes one (ext-data-control and a virtual keyboard), and the panel by the pointer (wlr-layer-shell) |
| `lt-windows` | `Insertion`'s typing, for Windows | Typing as Unicode keystrokes (SendInput), what the focused field is, and the clipboard where nothing would take the text |
| `lt-app` | the app | The `livetranscribe` command: `run` (dictation, with the tray and the Settings window, Tauri's; `ui/` holds their pages), `keys`, `transcribe`, `models`; the settings file; downloading the catalog's models. What dictation needs from the desktop is one trait (`src/dictation/desktop.rs`): Linux's side is `lt-wayland`, Windows' is `lt-windows` with the panel, a window of the app's own that shows `lt-dictation-ui`'s frames |

## Packages

The release workflow (`.github/workflows/release.yml`) builds a deb, an rpm and an AppImage on
Ubuntu 22.04, whose glibc (2.35) sets the oldest systems they run on: Ubuntu 22.04, Debian 12 and
any current Fedora, openSUSE or Arch. They are `live-transcribe_X.Y.Z_amd64.deb`,
`live-transcribe-X.Y.Z-1.x86_64.rpm` and `live-transcribe_X.Y.Z_amd64.AppImage`. A release tag
`vX.Y.Z` adds them, at the tag's version (the app crate's own is 0.0.0), to a draft release with
the Mac app, which the maintainer then publishes ([Releasing](../docs/releasing.md)). A pull
request that changes how the packages are made builds them too, to try from the run's artifacts.
Each carries:

- the app, `/usr/bin/livetranscribe`, which runs dictation when started with no command, as the
  desktop's menu starts it;
- OpenVINO 2026.2.1's runtime in `/usr/lib/live-transcribe/openvino`: Intel's prebuilt libraries,
  unmodified, under Intel's licence, which allows redistributing them (`licenses/` beside them).
  `packaging/linux/fetch-openvino.sh` fetches them, and `packaging/linux/check-packages.sh`
  checks that each package has them byte for byte. The app loads them from there
  (`vendor/openvino`'s `load_from_folder`), since Intel's libraries don't say where to find each
  other. **The AppImage has them in `usr/share/live-transcribe/openvino`**: linuxdeploy, which
  makes it, sets the RUNPATH of every library in `usr/lib`, and the licence doesn't allow changing
  them;
- sherpa-onnx 1.13.8's C API and ONNX Runtime 1.28.2 in `/usr/lib/live-transcribe/sherpa-onnx`,
  which the app links and finds through its RUNPATH (`crates/app/build.rs`), with their licences
  in `/usr/share/doc/live-transcribe/sherpa-onnx`. The AppImage has them in `usr/lib`.
  `check-packages.sh` also starts each package's app, as installed, to list the speech models;
- in the deb and rpm, a udev rule that lets whoever is logged in at the machine read the keyboards,
  which hold-to-talk needs. **Any program that user runs can then read what they type**, as any
  X11 program always could. The AppImage can't install it; `packaging/linux/README.Linux` says how.

The speech models and the cleanup model aren't in the packages, nor in the Windows installer; the
cleanup adapters are compiled into the app. The app downloads the speech model chosen the first time
it's needed (by default Nerdstorm/Qwen3-ASR-0.6B-Sinhala-OpenVINO, 1.1 GB, from Hugging Face), and
Settings › Models downloads and removes the others, which sherpa-onnx publishes on GitHub as
`.tar.bz2` archives. The catalog,
[`speech-models.json`](../Packages/LiveTranscribeKit/Sources/Transcription/Resources/speech-models.json),
pins each model: a Hugging Face repository at a commit, or an archive, with each file's size and
SHA-256 (`scripts/pin-linux-windows-speech-model.sh` prints a model's `linux` and `windows` section,
to paste in). A model downloads into a hidden folder beside the others and moves into place when its
files match (for an archive: its SHA-256 and each file's size; the unpacked files' SHA-256 are
checked right after), and from an archive only the catalog's files are unpacked
(`crates/app/src/speech_models/`). The app checks a model's files again before it opens it, since a
damaged file would crash ONNX Runtime rather than fail, and remembers what it checked
(`.verified.json`), so later starts hash only the files that changed. A download that stops carries
on where it stopped; after that the app never goes online for the model again.

Intel's NPU driver isn't in the packages either: the deb recommends `intel-level-zero-npu` and
`libze1`, the rpm `intel-npu-driver` (openSUSE's package is `linux-npu-driver`), Windows gets it
from Windows Update or the PC's maker, and without one the Qwen3-ASR models run on the CPU. On a
Core Ultra Series 3 PC, update the NPU driver to 32.0.100.5540 or newer first: OpenVINO 2026.2 to
2026.4 can crash with older ones.

To build the packages by hand, in Ubuntu 22.04 with Tauri's build dependencies and the Tauri CLI
2.12:

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

### The Windows installer

For Windows 10 and 11 on x86-64, the release workflow builds an installer with Tauri's NSIS
bundler, `live-transcribe_X.Y.Z_x64-setup.exe`, which the release carries with the others. It
installs for the current user, without administrator rights, and carries:

- the app, `livetranscribe.exe`, which runs dictation when started with no command, as the Start
  menu starts it. It's a windowed program, so it opens no console window; typed in a terminal, its
  commands print there, but cmd and PowerShell don't wait for a windowed program, so the output
  can come after the prompt (`livetranscribe models | more` waits for it);
- OpenVINO 2026.2.1's DLLs in the `openvino` folder beside it, where the app loads them from
  (`crates/app/src/paths.rs`), with their licences in `openvino\licenses`. They come from Intel's
  Python wheel for Windows, which is Apache-2.0 and has the NPU's compiler too.
  `packaging/windows/fetch-openvino.sh` fetches them;
- sherpa-onnx's and ONNX Runtime's DLLs beside the app, where Windows looks first (System32 has an
  older ONNX Runtime, which sherpa-onnx can't use), with their licences in `licenses\sherpa-onnx`;
- the parts of Microsoft's C++ runtime that OpenVINO's DLLs load, so no Visual C++
  Redistributable needs installing;
- the app's licence, `LICENSE.txt`.

What it carries is in `packaging/windows/tauri.installer.conf.json`, which only the installer's
build reads: Tauri's build script copies an app's resources beside it on every build, and other
builds have no OpenVINO to copy. `packaging/windows/check-installer.ps1` installs it silently,
checks every DLL and licence against those fetched, that the app starts and lists the speech
models, and that uninstalling removes what was installed. **The installer isn't signed**, so
Windows' SmartScreen warns about an unrecognised app when it's opened (More info, then Run anyway).
Uninstalling it (Settings › Apps) keeps the downloaded models and the settings, for a later
install, unless **Delete the application data** is ticked (`packaging/windows/installer-hooks.nsh`).

To build it by hand, in Git Bash, with Tauri's prerequisites and the Tauri CLI 2.12:

```bash
packaging/windows/fetch-openvino.sh
```

```bash
packaging/fetch-sherpa-onnx.sh
```

```bash
cd crates/app && cargo tauri build --bundles nsis --config ../../packaging/windows/tauri.installer.conf.json
```

The C++ runtime comes from the Visual Studio that builds it, which Tauri finds.

## Running it from source

At run time the app needs OpenVINO 2026.2. It loads it when it starts, so it builds without it.
The models it downloads itself, at its first start.

1. Install OpenVINO's runtime and point `INTEL_OPENVINO_DIR` at it, with its
   `runtime/lib/intel64` and `runtime/3rdparty/tbb/lib` on `LD_LIBRARY_PATH`.
2. Build and run it:

   ```bash
   cargo build --release -p lt-app
   ```

   ```bash
   target/release/livetranscribe run
   ```

   The tray's *Settings…* sets the hotkey, hands-free, the cleanup level, the microphone, the
   timing, the speech model and where it runs, each at once, and keeps them in `settings.json`
   ([Privacy](../docs/privacy.md#on-linux-and-windows) says where). Options after `run` set one for
   that run only: `livetranscribe run --key KEY_RIGHTALT` holds Right Alt instead of Right Ctrl,
   and `--device CPU` keeps speech-to-text on the CPU. `livetranscribe keys` names the keys you
   press, `livetranscribe models` lists the catalog, and
   `livetranscribe transcribe --model parakeet-tdt-0.6b-v2 clip.wav` transcribes a WAV file with
   one of its models, downloading it first (`--language de` tells Cohere Transcribe which
   language to write).

On Windows, from source, in Git Bash: `packaging/windows/fetch-openvino.sh`,
`cargo build --release -p lt-app`, then put OpenVINO where the installed app has it, beside the
program: `cp -r target/openvino-runtime target/release/openvino`. sherpa-onnx's DLLs are there
already, as its crate's build script copies them. `target/release/livetranscribe.exe run` starts
dictation.

**A model converted by hand.** `tools/export-qwen3-asr.py` converts a Qwen3-ASR checkpoint for
OpenVINO, in a Python environment with openvino (2026.2.1, the app's), nncf, torch (CPU), numpy
and safetensors. It reads mlx-audio's 8-bit checkpoints (turning them back into floats first) and
Qwen's own, and writes the audio convolutions and encoder (fp16) and the language model
(symmetric int8), checking each against PyTorch:

```bash
python tools/export-qwen3-asr.py --model /path/to/Qwen3-ASR-0.6B-Sinhala-8bit \
  --source Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit \
  --out ~/.local/share/live-transcribe/models/qwen3-asr-0.6b-sinhala-mine
```

Settings › Models › **Another model** chooses among the converted models in the models folder, as
`--model <folder>` does. Don't name the folder after a catalog id (`livetranscribe models` lists
them): the app checks such a folder against the catalog and downloads the published model over it.

**Where the models run.** The Qwen3-ASR models run on the NPU when OpenVINO sees one: the audio
encoder at fixed shapes, and the language model in the NPU's LLM mode, for prompts of up to 1,024
tokens (about 75 seconds of speech). A longer prompt, a reply that outgrows the NPU's cache, and
anything the NPU can't compile go to the CPU. Settings › Advanced (or `--device CPU`) keeps it all
on the CPU. OpenVINO keeps what it compiled in its cache folder, so later starts are faster.
sherpa-onnx's models run on the CPU, on half the CPU's logical processors (1 to 8 threads), whatever
the device setting says.

## Desktops

**Linux.** Dictation reads the keyboards from `/dev/input`, so the user needs read access to them (a
udev rule with `TAG+="uaccess"` gives it to whoever is logged in at the machine). The app registers
as the desktop's input method, so text goes straight into fields that take one (GTK, Qt, Firefox,
Chromium with Wayland IME, COSMIC's apps, foot and kitty). Those fields say what they are: password
fields are refused, as on the Mac; terminals and fields for one value (an address, a number) keep
dictated text on one line, and other fields take line breaks (most say nothing either way); and the
character before the cursor decides the leading space. Elsewhere it pastes: the text goes on the
clipboard, a virtual keyboard types Ctrl+V, and the clipboard is put back. **The paste knows nothing
about the field, so password fields aren't recognised there** and the text goes in on one line. With
IBus or Fcitx running, they hold the input method, and the app pastes.

The compositor has to offer `ext-data-control-v1` and `zwp-virtual-keyboard-v1`
(`crates/wayland/src/paste.rs`); `input-method-v2`, `wlr-layer-shell` and
`ext-image-copy-capture-v1` are optional. COSMIC has what it needs; Sway and Hyprland should, but
haven't been tried. On KDE Plasma and GNOME the compositor lacks a protocol the app needs, and X11
desktops have no Wayland, so dictation doesn't start there yet: the app starts anyway, and
Settings names the missing protocol (`desktop_blocker` in
`crates/app/src/dictation/desktop/linux.rs`).

The circle by the pointer is drawn with `wlr-layer-shell`. The desktop says where the pointer is
through cursor sessions (`ext-image-copy-capture-v1`), which report the pointer's position without
capturing the screen, and only while the circle shows. Where the desktop has none, the circle sits
at the bottom of the screen.

**Windows.** The hotkey is watched through a low-level keyboard hook, which needs no permission.
Text is typed as Unicode keystrokes (`SendInput`), so any script goes in whatever the keyboard
layout, and the clipboard is left alone: in pieces of 32 letters, stopping if the focus moves or a
modifier key is held down. Windows says what a field is only for its own edit controls (Notepad's,
and older programs'): their password fields are refused, and those with several lines take line
breaks. Browsers, Electron apps, Office and newer apps draw their fields themselves, so they are
typed on one line, line breaks as spaces, so that a Return never sends a message or a form; **their
password fields aren't recognised**. Nothing checks that a text field has the caret, so with none
focused the words reach the app as keystrokes (single-key shortcuts can fire). If Windows' privacy
settings keep desktop apps from the microphone (Settings › Privacy & security › Microphone), the app
hears nothing. Where Windows would drop the keystrokes, the text is left on the clipboard, out of
the clipboard history, for you to paste ([Using Live Transcribe](../docs/using.md#linux-and-windows)
lists when). The circle by the pointer is a small window of the app's own, drawn by the same code as
on Linux: it never takes the keyboard, lets clicks through, stays above other windows and out of the
taskbar, and follows the pointer from screen to screen at each screen's scale.

## Cleanup

Cleanup runs as the Mac app runs it: the same prompts, OutputGuard, Deep's check and executor
(`lt-cleanup`), on the same language model, Qwen3-1.7B, with the Mac app's two adapters, which are
compiled into the app from `Packages/LiveTranscribeKit/Sources/Cleanup`
(`crates/app/src/dictation/cleanup_model.rs`). While **Clean up transcripts with the LLM** is on
in Settings › Advanced, as it is at first, the app downloads the model the first time into the
models folder, checks each file's SHA-256, and loads it on the CPU on a thread of its own
(`cleaner.rs`). Settings › Advanced shows how that goes, and then where the model runs and with
which adapters. Until it's ready, or with it off, nothing is reworded: dictation still removes
filler words, lays out spoken lists and letters and writes numbers in digits from Medium up.
Turning it off lets the model go, and turning it on loads it again, without a restart. A cleanup
that takes longer than the **Timeout** there (3 s; for Deep, at least 8 s) is dropped, and the
text goes in without it, as on the Mac.

The model is
[Nerdstorm/Qwen3-1.7B-MLX-4bit-OpenVINO](https://huggingface.co/Nerdstorm/Qwen3-1.7B-MLX-4bit-OpenVINO)
(0.94 GB), pinned in `CLEANUP_MODEL` (`crates/language-model/src/pinned_model.rs`). It is the Mac
app's own weights, mlx-community/Qwen3-1.7B-4bit, which `tools/export-qwen3-cleanup.py` puts in
OpenVINO's graph for Qwen3-1.7B with each adapter's matrices as inputs of the model, so Medium and
High resolve self-corrections and Deep runs with its adapter, as on the Mac. To convert it again,
run the script in a Python environment with the packages it names and the OpenVINO the app ships
(2026.2.1), publish the folder it writes, and pin the new commit.

Cleanup runs on the CPU, and a Medium cleanup takes about four times as long as on a Mac (Deep
hasn't been timed on a desktop CPU); neither the NPU nor the GPU is used for it. Its answers match
the Mac's: 509 of the Mac app's 515 Medium test cases came out word for word the same, and, with
the same runtime on a Mac's CPU, all 114 of Deep's hand-written cases character for character.
`Train requests` writes the requests the Mac app makes for a set of cases, `examples/bench.rs` in
`lt-language-model` answers them, and `Train replay` scores the answers as `Train measure` scores
the Mac's.

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

The models, their licences and the software that runs them are credited in
[Models and credits](../README.md#models-and-credits) and in the app's **Settings › Models**. The
packages carry the licences of OpenVINO, sherpa-onnx and ONNX Runtime, and ONNX Runtime's
third-party notices.
