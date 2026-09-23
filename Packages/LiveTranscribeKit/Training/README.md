# Cleanup adapter training

The cleanup model, Qwen3-1.7B-4bit, cannot resolve spoken self-corrections by prompting alone:
asked to turn "fuel efficiency in cars, sorry, buses" into "fuel efficiency in buses", it got at
most 1 in 7 right. This folder holds the data that teaches it with a LoRA adapter, and the
`Train` tool builds the data, trains the adapter, and measures it. Everything runs on the Mac,
in Swift, with mlx-swift-lm.

The adapter is trained on the prompt the app uses with it (`Prompt.adapted`), so training and
inference see identical input. Only the answer tokens are trained on. The app loads the base
model at the exact commit the adapter was trained on and applies the adapter; if that fails, it
uses the base model with the strict prompt (`Prompt.cleanup`), which never removes words.

## Data

Every example is a transcript segment (`raw`), the line the app should show (`target`), and
optionally earlier lines as read-only context, exactly as the app sends them.

| Category | What it teaches | Example raw → target |
|---|---|---|
| `correction` | Drop the retracted words and the cue, keep the correction | "we need three sorry four servers" → "We need four servers." |
| `control` | A cue word in its ordinary meaning stays | "sorry I'm late" → "Sorry I'm late." |
| `boundary` | A cue that corrects the previous segment stays (that segment is already shown) | "sorry, Thursday" → "Sorry, Thursday." |
| `cleanup` | Ordinary cleanup: casing and punctuation, and a doubled word may go | "the the build is green" → "The build is green." |

- `curated/train/*.jsonl`: conversational examples from work, incidents, sales, cooking, teaching,
  travel and daily life, in both a streaming style (lowercase, unpunctuated) and Parakeet's cased
  style, trained on. They were drafted with an AI assistant and each one passes the validator.
- `curated/test/*.jsonl`: examples written the same way and held out for evaluation only.
- `generated/{train,valid,test}.jsonl` (not committed; `Train generate` recreates them): examples
  built from sentence frames and word pools by `ExampleGenerator`, reproducibly from a seed. The
  test split uses frames and words that never appear in training or validation, so it measures
  generalisation rather than recall.

`ExampleValidator` checks every example before it is used: the target must pass the app's own
`OutputGuard` (so the adapter is never taught output the app would reject), and each category
may change the text only in its own way. The unit tests run the validator over the curated files
and the generator's output.

## Commands

Build the tool (MLX needs xcodebuild for its Metal library), then run it from
`Packages/LiveTranscribeKit`:

```bash
(cd Packages/LiveTranscribeKit && xcodebuild build -scheme Train -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -skipPackagePluginValidation)
```

```bash
cd Packages/LiveTranscribeKit
.build/xcode/Build/Products/Release/Train generate
.build/xcode/Build/Products/Release/Train validate
.build/xcode/Build/Products/Release/Train train
.build/xcode/Build/Products/Release/Train evaluate --adapter Training/runs/adapter
.build/xcode/Build/Products/Release/Train evaluate --no-adapter
```

- `generate [--seed <n>]` writes the generated splits.
- `validate` checks every data file, and that no test example appears in training data.
- `train` loads the cleanup model from the Hugging Face cache (`~/.cache/huggingface`) at the
  commit `main` points to there, or at `--revision <commit>`, and writes the adapter with the
  lowest validation loss to `Training/runs/adapter` (`--output` to change), with a
  `training-report.json`. Options: `--iterations`, `--batch-size`, `--learning-rate`, `--rank`,
  `--scale`, `--layers`, `--curated-repeats` (how many times the curated examples are repeated
  in the training set) and `--seed`; the defaults are the settings the bundled adapter was
  trained with.
- `evaluate` cleans every test example through `MLXCleaner`, as the app does, and reports per
  category how often the shown text matches the target (ignoring casing and punctuation), how
  often OutputGuard fell back to the raw text, and latency. By default it evaluates the bundled
  adapter; `--adapter <dir>` evaluates another, `--no-adapter` the base model with the strict
  prompt. `--data <file>` picks the test files and `--report <file>` saves the JSON report.

To ship a new adapter, copy `adapters.safetensors` and `adapter_config.json` from the run folder
into `Sources/Cleanup/Adapter/`, then rebuild the app.

## Results

The bundled adapter was trained with the defaults (600 iterations, batch 8, learning rate 2e-5,
rank 8, scale 20, the last 16 layers, curated examples twice) in 30 minutes on an Apple silicon
Mac; the lowest validation loss, 0.0015, came at iteration 450. `Train evaluate` on the 515 test
examples (420 generated, 95 curated), shown text matched to the target:

| Category | Base model, strict prompt | With the adapter |
|---|---:|---:|
| correction | 2/260 (0.8%) | 253/260 (97.3%) |
| control | 121/125 (96.8%) | 123/125 (98.4%) |
| cleanup | 95/100 (95.0%) | 99/100 (99.0%) |
| boundary | 30/30 (100%) | 30/30 (100%) |
| cleanup latency p50 / p95 | 138 / 191 ms | 152 / 230 ms |

On the 95 curated examples alone, which were written separately from the generator's templates,
the adapter matched 92 (corrections 39/40). Most remaining misses fall back to the uncorrected
text; the rest respell names ("Yasmin" → "Yasmine").

The adapter is loaded as separate LoRA layers, not fused into the model: fusing re-quantizes the
adapted weights to 4 bits, and the fused adapter resolved only 13% of self-corrections.
