# Development

Building, testing and measuring Live Transcribe. How it is put together is in
[Architecture](architecture.md), and why, in [Design notes](design-notes.md). The Linux and
Windows app has its own guide, [linux-windows/README.md](../linux-windows/README.md). Releases are
in [Releasing](releasing.md).

## Mac

### Build and run

You need an Apple silicon Mac, Xcode 26.4 or later (Swift 6.3 or later) with its Metal Toolchain
component (`xcodebuild -downloadComponent MetalToolchain`), and disk space: about 2 GB for the
models and 2 GB for the build, and about 6 GB more for the tests and the bench, which build into
their own copy of the build (the models are shared). MLX compiles Metal shaders, so build with
`xcodebuild` or Xcode: `swift build` produces binaries without the Metal library.

```bash
make run
```

builds the app in Release and opens it. `make` on its own lists every target, and `make doctor`
checks what building on your Mac needs. Or open `LiveTranscribe.xcodeproj` in Xcode and choose
Run. The shared scheme uses the **Release** configuration, because MLX inference in Debug is
several times slower. On the first build Xcode asks you to trust mlx-swift's `CudaBuild` plugin,
which only does work in CUDA builds; the Makefile skips that prompt with
`-skipPackagePluginValidation`.

### Signing your builds

Builds from this repository are ad-hoc signed ("Sign to Run Locally") and not notarized, so they
run on the Mac that built them, and Gatekeeper blocks a copy downloaded onto another Mac. The app
runs outside the App Sandbox, since typing into other apps needs the Accessibility permission,
which sandboxed apps can't use; that rules out the Mac App Store.

**macOS treats every ad-hoc build as a new app.** After a rebuild it asks for microphone access
again, and the shortcut doesn't work until you remove the old Live Transcribe entry in Privacy &
Security › Accessibility and add the new build. If the floating panel then says to quit and reopen
Live Transcribe so it can paste, do that: **Reopen Live Transcribe** in **Settings › Permissions**
does it for you.

To keep the permissions across rebuilds, sign with your own certificate. Copy
`Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` (gitignored) and set
your team ID. An Apple Development certificate is enough; Xcode › Settings › Accounts makes one
for free with any Apple ID. Grant the permissions once more after switching, and they survive
every rebuild after that. Releases are signed with Developer ID and notarized by Apple
([Releasing](releasing.md)).

### Tests

```bash
make test
```

The Swift package has more than 1,000 Swift Testing tests, and unit tests need no models. The
target also runs `scripts/tests/`, which tests the release scripts.

The end-to-end tests and the bench use short spoken clips. The clips aren't in the repository,
because Apple's licence doesn't allow publishing recordings of its system voices. `make audio`
generates them with macOS text-to-speech, and `make dictation-audio` generates the dictation
eval's 65 clips
(`Packages/LiveTranscribeKit/Tests/IntegrationTests/Fixtures/Dictation/clips.tsv`). Each runs its
script only if a clip is missing, and the script then makes every clip again
(`scripts/generate-test-audio.sh`, `scripts/generate-dictation-audio.sh`); the targets that use
the clips run it first.

```bash
make test-integration
```

runs the end-to-end tests with the real models, downloading them into `~/.cache/huggingface`.
xcodebuild passes environment variables to the test runner only with the `TEST_RUNNER_` prefix,
so the target sets `TEST_RUNNER_LT_RUN_MODEL_TESTS=1`. `make prompt-probe` sets
`TEST_RUNNER_LT_PROMPT_PROBE=1` instead, to print the cleanup model's answers to a set of hard
prompts while you change a prompt.

### Bench and eval

`make bench` builds the `Bench` tool and measures the live transcript pipeline on spoken clips:
word error rate (WER) of the raw and cleaned text, and p50 and p95 latency per stage. It checks
that p95 from end of speech to text is under 1.5 s, that cleaned WER is no worse than raw WER,
that no clip gets more than 2 points worse, and that cleanup falls back to the raw text for fewer
than 5% of segments.

With the default speech model the first check fails: p95 was 1,645 ms in the last real-time run (M4
Pro, 2026-09-25, four synthetic clips), because Qwen3-ASR writes its text a token at a time, so a
long segment takes longer; Parakeet TDT 0.6B v3 passed at 1,290 ms. The fix, transcribing during the
silence that ends a segment, isn't built yet. Dictation is not affected: its p95 is 654 ms at High,
against a 1.2 s target.

`make eval` measures dictation on the 65 clips (plain sentences, fillers, self-corrections,
questions, longer passages, emoji, dictated punctuation, addresses, line breaks, spoken lists and
letters). At each cleanup level it reports the WER against what was *said* and against what was
*meant*, the fallbacks, and p50 and p95 latency against a target of p95 under 1.2 s. Latency is
speech-to-text plus cleanup; stopping the recorder and inserting the text aren't included.

Both take options with `ARGS`, for example `make eval ARGS="--multiline --level deep"`:

- `--level <none|light|medium|high|deep>` picks the cleanup level (the eval repeats it);
- `--multiline` (eval) dictates into a field that takes several lines, where lists and letters
  are laid out, and counts the clips that came out with the intended lines;
- `--no-cleanup` (bench) measures speech-to-text alone, and `--no-adapter` cleans up without the
  adapters;
- `--fast` (bench) feeds audio as fast as possible, so its latencies mean nothing;
- `--stt-model <repository or folder>` measures another speech-to-text model on the same clips;
- `--stt-language <code>` sets the language for a speech model that is told which to write
  (Cohere Transcribe), such as `de`;
- `--fixtures <dir>` (bench) and `--clips <dir>` (eval) read other clips, `--p95-target-ms <n>`
  (eval) changes the 1.2 s target (the bench's 1.5 s is fixed), and `--verbose` (eval) prints
  every output with the reason for each fallback.

The clips are synthetic speech, so measure with real recordings on your own hardware before you
rely on the numbers. Speech-to-text and cleanup calls are also marked as signpost intervals
("STT", "LLM") for Instruments.

The last `make eval ARGS="--multiline"` (M4 Pro, macOS 27, the macOS voice Samantha, the default
speech model), dictating into a field that takes several lines:

| Level | WER vs said | WER vs meant | Fallbacks | p50 | p95 | Laid out as meant |
|---|---:|---:|---:|---:|---:|---:|
| None | 12.1% | 24.9% | 0 | 126 ms | 266 ms | 57/65 |
| Light | 11.7% | 23.9% | 1 | 258 ms | 541 ms | 57/65 |
| Medium | 22.7% | 6.4% | 3 | 280 ms | 641 ms | 65/65 |
| High | 22.7% | 6.4% | 3 | 319 ms | 654 ms | 65/65 |

Every level is well under the 1.2 s target. At Medium and High all 12 self-corrections are
resolved and every filler is removed. WER against what was said counts spoken commands as wrong,
since they are replaced by what they name; against what was meant, most of the 6.4% is words both
speech models mishear in the synthetic voice ("emoji" as "M O G", "comma" as "common"). The
Sinhala fine-tune costs English a little: 6.4% at Medium, against 5.1% for the base Qwen3-ASR.
Deep, measured later beside Medium in one run (7.6% at Medium), took 8.0% against what was meant,
379 ms at p50 and 715 ms at p95 (Medium 288 and 639 ms), and laid out 63 of 65 clips as meant: the
two it lays out otherwise are what Deep is for ("We need milk, eggs, and bread." as three bullets,
and the three things to do before a merge as a numbered list).

The three fallbacks at Medium and High are a plain sentence the adapter mistakes for a correction
("I've attached the invoice and the signed agreement."); a sentence the speech model breaks at a
hesitation, after which the model drops a word that carries meaning ("Um, the package should
arrive tomorrow, uh, before noon"); and a spoken "comma" the speech model hears as "common" ("we
need milk comma eggs comma and bread full stop"), which the check counts as words dropped.

### Training the adapters

The `Train` tool generates the synthetic data, trains the cleanup adapters on the Mac, in Swift,
and measures them as the app runs them: `make train ARGS="evaluate"`. The commands and the data
are in [Training/README.md](../Packages/LiveTranscribeKit/Training/README.md).

### Licence notices

**About Live Transcribe** shows the licence of every Swift package the app is built with, from
`Packages/LiveTranscribeKit/Sources/About/Acknowledgements.json`. After adding, removing or
updating a package, run:

```bash
make acknowledgements
```

and commit what it writes: AboutTests fails while the file doesn't match `Package.resolved`. The
script (`scripts/generate-acknowledgements.sh`) takes each package's LICENSE, COPYING and NOTICE
files. A licence kept in a source file's header instead, like the PocketFFT code in MLX, needs an
entry in `embeddedNotices` in `scripts/generate-acknowledgements.swift`.

### Icons

The app icon is drawn as SVG in `design/`: `AppIcon.svg` for every size from 32 pixels up,
`AppIcon-16.svg`, a simpler drawing whose edges fall on the 16-pixel grid, and `TouchIcon.svg`, a
square version for the website's home-screen icon. The website's favicon and header mark is
`site/favicon.svg`. The PNGs made from them are committed, so building the app doesn't need this.
After editing an SVG, run `make icons` and commit what it writes: the app icon set in
`App/Assets.xcassets/AppIcon.appiconset` and the website's icons.

## Linux and Windows

The app is a Cargo workspace in `linux-windows/`. From there, `packaging/fetch-sherpa-onnx.sh`
fetches the libraries that run the catalog's other speech models, and `cargo test` runs the
tests, including the golden cases. CI runs formatting, clippy and the tests on Linux and Windows
for every change to `linux-windows/` or to the fixtures. Building it, its packages and its
installer are in [linux-windows/README.md](../linux-windows/README.md).

## Keeping the two apps the same

The Mac app is the reference. Its tests write the expected results in `Fixtures/golden` and
`Fixtures/cleanup`, and the Rust tests must reproduce them. After changing a rule, run `make
golden`, review the diff, and port the change until `cargo test` passes in `linux-windows/`; commit
both apps' changes in one pull request. The steps for each kind of change are in
[Architecture](architecture.md#where-to-change-what), and the fixtures are described in
[Fixtures/golden](../Fixtures/golden/README.md) and
[Fixtures/cleanup](../Fixtures/cleanup/README.md).

A pull request that changes behaviour also updates the page that describes it:
[Using](using.md), [Cleanup](cleanup.md) or [Known limitations](limitations.md).
