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
opens Settings, whose General and Advanced tabs change dictation without a restart. The speech
model, the Mac app's Sinhala fine-tune of Qwen3-ASR, runs on the NPU of an Intel Core Ultra, or on
the CPU. Settings' other tabs, the history window, and Windows come later.

## Building and testing

```bash
cargo test
```

`rust-toolchain.toml` pins the Rust version, and rustup installs it on the first build. The tests
include the golden cases (`crates/dictation/tests/golden.rs`). CI runs formatting, clippy and the
tests on Linux and Windows (`.github/workflows/linux-windows.yml`).

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
| `lt-transcription` | `Transcription`, and mlx-audio-swift's Qwen3-ASR | Speech to text: the log-mel features, the encoder's chunks and windows, the prompt, greedy decoding and its limits. The model's forward passes are behind the `SpeechModel` trait; `OpenVinoModel` runs them on OpenVINO |
| `lt-hotkey` | `Hotkey` | The hold, tap and double-tap gesture; what each key means for it; on Linux, reading the keyboards (evdev) |
| `lt-capture` | `Capture` | Recording the microphone chosen in Settings, or the default one (cpal; on Linux, the sound server's), as 16 kHz mono, and its level for the meter |
| `lt-insertion` | `Insertion` | What is known about the focused field, what the clipboard holds while text is pasted, and what an insertion did |
| `lt-dictation-ui` | `DictationUI` | The panel shown while dictating (what it shows when, drawn to pixels, and where by the pointer) and what the tray says, with its icons |
| `lt-wayland` | `Insertion`'s typing and the HUD's window, for Wayland | One connection for the desktop: the input method (input-method-v2), which reads the focused field and types straight into it; pasting where no field takes one (ext-data-control and a virtual keyboard); the panel by the mouse pointer (wlr-layer-shell, with ext-image-copy-capture's cursor sessions saying where the pointer is), or at the bottom of the screen |
| `lt-app` | the app | The `livetranscribe` command: `run` (dictation, with the tray and the Settings window, Tauri's; `ui/` holds the window's page), `keys`, `transcribe`; the settings file |

## Running it

The app needs OpenVINO 2026.2 and the speech model converted for it. On the owner's Fedora
machine, the setup kit (not in the repository) installs both in an Ubuntu 24.04 toolbox. By hand:

1. Install OpenVINO's runtime and point `INTEL_OPENVINO_DIR` at it, with its `runtime/lib/intel64`
   and `runtime/3rdparty/tbb/lib` on `LD_LIBRARY_PATH`. The app loads it when it starts, so it
   builds without it.
2. Get the speech model. The app's default is the Mac app's,
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
   transcribe gibberish. Settings › Advanced chooses among the models converted into
   `~/.local/share/live-transcribe/models`.
3. `cargo build --release -p lt-app` (the tray builds against WebKitGTK, libxdo and the app
   indicator library: Tauri's prerequisites), then:

   ```bash
   target/release/livetranscribe run
   ```

   The tray's *Settings…* sets the hotkey, hands-free, the cleanup level, the microphone, the
   timing, and the model and where it runs, each at once, and keeps them in
   `~/.config/live-transcribe/settings.json`. Options after `run` set one for that run only:
   `livetranscribe run --key KEY_RIGHTALT` holds Right Alt instead of Right Ctrl.
   `livetranscribe keys` names the keys you press.

The speech model runs on the NPU when OpenVINO sees one: the audio encoder at fixed shapes, and the
language model in the NPU's LLM mode, for prompts of up to 1,024 tokens (about 75 seconds of
speech). A longer prompt, a reply that outgrows the NPU's cache, and anything the NPU can't compile
go to the CPU. Settings › Advanced (or `--device CPU`) keeps it all on the CPU. The first start
compiles the model for the NPU, which takes a few seconds; OpenVINO keeps what it compiled in
`~/.cache/live-transcribe`, so later starts take under a second.

Dictation reads the keyboard from `/dev/input`, so the user needs read access to it; a udev rule
with `TAG+="uaccess"` gives it to whoever is logged in at the machine. The app registers as the
desktop's input method, so text goes straight into fields that take one (GTK, Qt, Firefox,
Chromium with Wayland IME, COSMIC's apps and most Wayland terminals). Those fields say what they
are: password fields are refused, as on the Mac; terminals and fields for one value (an address, a
number) keep dictated text on one line, and other fields take line breaks, as the Mac app decides
(most say nothing either way); and the character before the cursor decides the leading space.
Elsewhere it pastes: the text goes on the clipboard, a virtual keyboard types Ctrl+V, and the
clipboard is put back. COSMIC has everything this needs. KDE Plasma has no input-method-v2, so
there it always pastes; GNOME has none of it. With IBus or Fcitx running, they hold the input
method, and the app pastes.

While you dictate, a small circle below and to the right of the mouse pointer follows it: a red
disc that grows with the microphone's level, a ring round it when hands-free, and a spinning ring
while the speech is transcribed. It has no words and takes no clicks; Esc or the tray's menu
cancels. When something needs your attention (nothing was heard, the text was left on the
clipboard, the microphone stopped), a short message shows in a bubble beside it for a few seconds.
The desktop says where the pointer is through cursor sessions (ext-image-copy-capture-v1), which
report the pointer's position without capturing the screen, and only while the circle shows.
Where the desktop has none, the circle sits at the bottom of the screen.

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

Dictated text is never logged: log lines carry counts only.

## Credits

The default speech model, [Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit](https://huggingface.co/Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit),
is [Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) by the Qwen team, Alibaba Cloud
(Apache-2.0), fine-tuned for Sinhala by Nerdstorm on OpenSLR 52 (Google, CC BY-SA 4.0). The
fine-tune is licensed CC-BY-SA-4.0.
