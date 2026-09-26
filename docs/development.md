# Development

Building and running the app is in the README's [Build and run](../README.md#build-and-run).
This covers the tests, the bench, the adapter, the licence notices and the icons.

## Tests

The package has more than 1,000 Swift Testing tests. Unit tests need no models:

```bash
make test
```

It also runs `scripts/tests/`, which tests `scripts/write-changelog.sh` in a scratch repository and
`scripts/check-swift-runtime.sh` with small programs.

The end-to-end tests and the bench use short spoken clips. The clips are not in the repository,
because Apple's licence does not allow publishing recordings of its system voices. `make audio`
generates them with macOS text-to-speech, and `make dictation-audio` generates the dictation
eval's 65 clips (`Tests/IntegrationTests/Fixtures/Dictation/clips.tsv`). Each makes only the clips
that are missing, and the targets that use them run it first. To make every clip again, run
`scripts/generate-test-audio.sh` or `scripts/generate-dictation-audio.sh`.

The end-to-end tests run the real models, downloading them into `~/.cache/huggingface`:

```bash
make test-integration
```

xcodebuild passes environment variables to the test runner only with the `TEST_RUNNER_` prefix,
so this sets `TEST_RUNNER_LT_RUN_MODEL_TESTS=1`. `make prompt-probe` sets
`TEST_RUNNER_LT_PROMPT_PROBE=1` instead, to print the cleanup model's output for a set of hard
prompt cases, a development aid for prompt changes.

## Bench

```bash
make bench
```

It builds the `Bench` tool and runs it. Give it options with `ARGS`, for example
`make bench ARGS="--level high --fast"`:

- `--fixtures <dir>`: a folder of `.wav` clips, each with a matching `.txt` transcript.
- `--level <none|light|medium|high>`: the cleanup level (default: Medium).
- `--no-cleanup`: speech-to-text only.
- `--no-adapter`: clean up without the fine-tuned self-correction adapter.
- `--fast`: feed audio as fast as possible instead of in real time. Latency numbers are then
  meaningless.
- `--stt-model <repo>`: measure another speech-to-text model instead of the default, such as
  `mlx-community/parakeet-tdt-0.6b-v3`, to compare models on the same clips.

The bench prints the word error rate (WER) of the raw and cleaned text, p50 and p95 latency per
stage, and four checks:

- p95 from end of speech to text on screen is under 1.5 s;
- cleaned WER is no worse than raw WER;
- no clip's WER gets more than 2 points worse after cleanup;
- cleanup falls back to the raw text for fewer than 5% of segments.

Last run, on an M4 Pro with the four generated clips played in real time, with the default
speech model (Qwen3-ASR 0.6B fine-tuned for Sinhala) and, for comparison, Parakeet TDT 0.6B v3
(the default until 2026-09-25) on the same clips:

| Stage | Qwen3-ASR p50 (ms) | p95 (ms) | Parakeet v3 p50 (ms) | p95 (ms) |
|---|---:|---:|---:|---:|
| Silence that ends a segment | 608 | 608 | 608 | 608 |
| Speech-to-text | 204 | 481 | 68 | 148 |
| Cleanup | 227 | 556 | 219 | 557 |
| End of speech → text | 1038 | 1645 | 900 | 1290 |

With Qwen3-ASR, WER was 1.0% raw and 1.0% cleaned (Parakeet: 2.5% and 2.5%), with no fallbacks.
The base Qwen3-ASR 0.6B, the default in 0.2.0, took 195 and 465 ms for speech-to-text on the
same clips. **Qwen3-ASR fails the latency check: p95 from end of speech to text is 1,645 ms,
against the 1.5 s target that Parakeet meets.** Qwen3-ASR writes its text a token at a time, so a segment
takes longer the more words it holds. The other three checks pass with both. The first row is
the configured 600 ms of silence that closes a segment; lower `vadSilenceMs` to trade it for
more segment splits. The clips are synthetic speech, so measure with real recordings on your own
hardware before relying on these numbers. Speech-to-text and cleanup calls are also marked as
signpost intervals ("STT", "LLM") for Instruments.

### Dictation eval

```bash
make eval
```

Runs the 65 dictation clips (plain sentences, fillers, self-corrections, questions, longer
passages, emoji, dictated punctuation, addresses, line breaks, spoken lists and letters) through
dictation's speech-to-text and cleanup at every cleanup level, and reports per level and
category the WER against what was *said* and against what was *meant* (fillers dropped,
self-corrections resolved, commands turned into what they name), the fallbacks, and p50/p95
latency against the target of p95 under 1.2 s. Latency here is speech-to-text plus cleanup;
stopping the recorder and inserting the text are not included. `--multiline` dictates into a
multi-line field, where line breaks, lists and letters are laid out, and adds how many clips came
out with the intended lines. `--level <none|light|medium|high>` (repeatable) limits the levels,
`--clips <dir>` reads other clips, `--p95-target-ms <n>` changes the target, `--no-adapter`
cleans up without the adapter, `--stt-model <repo>` measures another speech-to-text model and
`--verbose` prints every output, with the reason for each fallback. Give them with `ARGS`, as for the bench: `make eval ARGS="--multiline --verbose"`.

Last run, on an M4 Pro with macOS 27 and synthetic speech, with the default speech model and
`--multiline` ([Eval results](dictation.md#eval-results) compares the base Qwen3-ASR and the
single-line field):

| Level | WER vs said | WER vs meant | Fallbacks | p50 (ms) | p95 (ms) | Laid out as meant |
|---|---:|---:|---:|---:|---:|---:|
| None | 12.1% | 24.9% | 0 | 126 | 266 | 57/65 |
| Light | 11.7% | 23.9% | 1 | 258 | 541 | 57/65 |
| Medium | 22.7% | 6.4% | 3 | 280 | 641 | 65/65 |
| High | 22.7% | 6.4% | 3 | 319 | 654 | 65/65 |

Medium resolved all 12 self-corrections and removed the fillers from all 10 filler clips, and
Medium and High laid out every list and letter. WER against what was said counts each spoken
command as wrong, because it is replaced by what it names. None and Light lay out only line
breaks, by design. Every level met the latency target; High takes longer on self-corrections
because it cleans them in two passes. Most of the 6.4% against what was meant is words both
Qwen3-ASR models mishear in the synthetic voice ("emoji" as "M O G", "hi" as "high", "Acme" and
"comma"); the rest is how the fine-tune writes some words, such as "10" for "ten" and "We are"
for "We're". The base model scores 5.1% on the same run.

The fallbacks, where OutputGuard rejected the model's output and the uncleaned transcript was
inserted:
- The same plain sentence at Medium and High ("I've attached the invoice and the signed
  agreement."): the self-correction adapter changed a sentence that had nothing to correct
  (three spoken words dropped at Medium; similarity 0.48, below the floor, at High).
- A filler clip at Medium and High: Qwen3-ASR ends a sentence at the hesitation ("tomorrow. Ah,
  before noon"), and the model then drops a word that carries meaning. The filler rule has
  already removed "ah".
- A punctuation clip at Medium and High: Qwen3-ASR hears the spoken "comma" as "common"
  ("We need milk, common eggs, common, and bread."), and the model drops both.
- The long letter at Light, which keeps every word: the model resolved its self-correction.

Without `--multiline` (a single-line field), where lists are not laid out, Light falls back on 1
clip and Medium and High on 4 each: the same clips, and the long letter at Medium and High too,
where the model changed more than the self-correction. The longest clip is about 40 words, so
these numbers say nothing about long dictations.

## Training the adapter

The self-correction adapter is trained on the Mac, in Swift, with the `Train` tool: `generate`
builds the synthetic dataset, `validate` checks every example against the app's own OutputGuard,
`train` fine-tunes the adapter and `evaluate` measures it as the app runs it. On 515 held-out
examples of synthetic sentences it resolved 97.3% of self-corrections (the base model 0.8%) and
kept 98.4% of look-alike sentences as spoken. On the 95 curated held-out examples alone, written
separately from the generator's templates, it resolved 39 of 40 corrections. `make train
ARGS="evaluate"` builds the tool and runs a step. Commands and full results are in
[Training/README.md](../Packages/LiveTranscribeKit/Training/README.md).

## Licence notices

**About Live Transcribe** shows the licence of every Swift package the app is built with, from
`Sources/About/Acknowledgements.json`. After adding, removing or updating a package, run:

```bash
make acknowledgements
```

It runs `scripts/generate-acknowledgements.sh`. Commit what it writes: AboutTests fails while the
file doesn't match `Package.resolved`. It takes each package's LICENSE, COPYING and NOTICE files.
A licence kept in a source file's header instead, like the PocketFFT code in MLX, needs an entry in
`embeddedNotices` in `scripts/generate-acknowledgements.swift`.

## Icons

The app icon is drawn as SVG in `design/`: `AppIcon.svg` for every size from 32 pixels up,
`AppIcon-16.svg`, a simpler drawing whose edges fall on the 16-pixel grid, and `TouchIcon.svg`,
a square version for the website's home-screen icon, which iOS rounds itself. The website's
favicon and header mark is `site/favicon.svg`.

The PNGs made from them are committed, so building the app doesn't need this. After editing an
SVG, run:

```bash
make icons
```

It runs `scripts/render-icons.sh`, which writes the app icon set in
`App/Assets.xcassets/AppIcon.appiconset`, and the website's `favicon-32.png`,
`apple-touch-icon.png` and `images/app-icon.png`. WebKit draws each one, so it matches what a
browser shows, at the screen's scale; the script then scales it down by averaging each block of
pixels, which keeps edges on the pixel grid sharp. Commit what it writes.
