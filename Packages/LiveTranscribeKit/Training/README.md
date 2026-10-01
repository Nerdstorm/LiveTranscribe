# Cleanup adapter training

The cleanup model, Qwen3-1.7B-4bit, cannot resolve spoken self-corrections by prompting alone:
asked to turn "fuel efficiency in cars, sorry, buses" into "fuel efficiency in buses", it got at
most 1 in 7 right. This folder holds the data that teaches it with LoRA adapters, and the
`Train` tool builds the data, trains the adapters, and measures them. Everything runs on the
Mac, in Swift, with mlx-swift-lm. There are two adapters: the self-correction adapter, which
Medium and High use (most of this page), and Deep's ([Deep's adapter](#deeps-adapter)).

The adapter is trained on Medium's prompt with the adapter on (`Prompt.adapted`, that is
`PromptBuilder(adapted: true)` at Medium), so at Medium training and inference see the same
instructions; High adds its rewording line, and any level adds the request's vocabulary and
placeholder rules. Only the answer tokens are trained on. The app loads the base model at the exact
commit the adapter was trained on and applies the adapter; if that fails, it uses the base model
with the strict prompt (`adapted: false`), which tells Light and Medium to remove nothing and High
to reword without removing, and Deep too runs on the base model, with its own prompt.

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
  travel and daily life, with historical lowercase punctuation stress inputs and cased inputs, trained on. They were drafted with an AI assistant and each one passes the validator.
- `curated/test/*.jsonl`: examples written the same way and held out for evaluation only.
- `generated/{train,valid,test}.jsonl` (not committed; `Train generate` recreates them): examples
  built from sentence frames and word pools by `ExampleGenerator`, reproducibly from a seed. The
  test split uses sentence frames that never appear in training or validation, and slot values
  that don't either, except weekdays and months, so it measures generalisation rather than
  recall.

`ExampleValidator` checks every example before it is used: the target must pass the app's own
`OutputGuard` (so the adapter is never taught output the app would reject), and each category
may change the text only in its own way. The unit tests run the validator over the curated files
and the generator's output.

## Commands

From the repository root, `make train ARGS="<command>"` builds the tool and runs one command, for
example `make train ARGS="evaluate --no-adapter"`. To do it by hand, build the tool (MLX needs
xcodebuild for its Metal library), then run it from `Packages/LiveTranscribeKit`:

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
  in the training set; Deep ignores it) and `--seed`; the defaults are the settings the bundled
  adapter was trained with.
- `evaluate` cleans every test example through `MLXCleaner`, as the app does, and reports per
  category how often the shown text matches the target (ignoring casing and punctuation), how
  often OutputGuard fell back to the raw text, and latency. By default it evaluates the bundled
  adapter; `--adapter <dir>` evaluates another, `--no-adapter` the base model with the strict
  prompt. `--data <file>` picks the test files and `--report <file>` saves the JSON report.

To ship a new adapter, copy `adapters.safetensors` and `adapter_config.json` from the run folder
into `Sources/Cleanup/Adapter/`, then rebuild the app.

## Results

The bundled adapter was trained with the defaults (600 iterations, batch 8, learning rate 2e-5,
rank 8, scale 20, the last 16 layers, curated examples twice). `Train evaluate` on the 515 test
examples (420 generated, 95 curated), shown text matched to the target:

| Category | Base model, strict prompt | With the adapter |
|---|---:|---:|
| correction | 2/260 (0.8%) | 253/260 (97.3%) |
| control | 121/125 (96.8%) | 123/125 (98.4%) |
| cleanup | 95/100 (95.0%) | 99/100 (99.0%) |
| boundary | 30/30 (100%) | 30/30 (100%) |
| cleanup latency p50 / p95 | 138 / 191 ms | 152 / 230 ms |

Most remaining misses fall back to the uncorrected text; the rest respell a name ("Yasmin" →
"Yasmine") or keep the wrong words.



## Deep's adapter

Deep (`CleanupLevel.deep`) has its own adapter, `Sources/Cleanup/DeepAdapter`, trained on Deep's
prompt (`PromptBuilder.deepRules`), which gives general rules and no examples. It has the
self-correction adapter's shape (rank 8, scale 20, the last 16 layers), so the app swaps one
for the other per request. Its answers are checked by `SelfRepair`, not by OutputGuard's limits.

### Data

`DeepExampleGenerator` builds every example from sentence frames and word pools
(`DeepFrames`), reproducibly from a seed, and `DeepExampleValidator` checks each one: the input
the model sees is what the app would send, and the target must pass `SelfRepair` at Deep. **No
example comes from anyone's dictation history**, and none from the hand-written cases below.

| Category | Train examples | What it teaches |
|---|---:|---|
| `crossSentence` | 800 | A correction that reaches back into an earlier sentence: "…is tomorrow. No, sorry, the day after." |
| `malformed` | 650 | A garbled correction phrase, read as meant: "the after tomorrow" → "the day after tomorrow" |
| `sameSentence` | 450 | A correction within a sentence, in Deep's words |
| `control` | 650 | Cue words in their ordinary sense stay: "No, it's the day after." answering a question |
| `facts` | 300 | Names, numbers, dates and times said outside a correction stay |
| `grammar` | 550 | Agreement and tense fixed without rewording: "he actually check" → "he actually checked" |
| `recognition` | 450 | A misheard word fixed from the rest of the text |
| `layout` | 500 | An email, letter or list laid out in a field that takes several lines |
| `oneLine` | 250 | The same, kept to one paragraph in a field that doesn't |
| `unchanged` | 250 | Text that is already right stays as it is |
| `listTwo` | 400 | Two things set off with a colon ("two things I need: A and B") become a list, or stay a sentence in a one-line field |
| `listMany` | 600 | Three to six items, bulleted, or numbered when their order matters, with an opening sentence, a greeting or a closing sentence around them |
| `series` | 600 | A series inside a sentence ("we visited Lisbon, Porto and Faro last summer"), two items with no colon, and a colon that introduces no list, all stay as said |
| `body` | 700 | The body of an email, which the app sends without its greeting and sign-off and with `letterBody` set: a paragraph that stays one, a list laid out, a correction resolved |
| `placeholder` | 800 | Tokens for emoji, links and list markers stay once each, where they stand, with the text around them cleaned; spoken list markers keep the text one paragraph |
| `mention` | 200 | A correction said inside a mention ("tools like Docker, sorry, not Docker, Kubernetes") is resolved; an ordinary contrast ("three, not four") stays |

Validation and test get a tenth and an eighth of these. Training and validation also get 1,260 and
126 of Medium's own examples (`ExampleGenerator`), a third of them in a field that takes several
lines, so Deep keeps what Medium does. Examples the validator rejects are left out. Some raw texts
are historical lowercase/punctuation stress cases; these are not a description of current
speech-to-text output. The measured preparation workflow below replaces that input assumption.
`generated/deep-*.jsonl` is not committed; `Train generate --deep` recreates it.

The layout categories use `DeepLayoutFrames` (lists as packs of items with their intros, series
frames, email bodies, token frames, mention frames), written by hand and split into training and
test pools. No frame, intro or item pack of the test pool is in training; plain values such as
names, cities and homophone pairs may repeat across the two, since the split measures the layout.
They follow the conventions of the eval cases: a bulleted list is
the intro and a colon, then `- Item` lines with a capital and no full stop; a numbered one has
`1. Item.` lines; text after a list follows a blank line; a greeting has a line and a blank line
to itself; a list of two is laid out only after a colon the speaker said, and `or` stays in the
sentence, since Deep's check does not let a list drop it. Placeholder tokens are written as the
words the model sees (`S1`), as `CleanupExecutor.trainingPair` makes them.

Two files of hand-written cases are never trained on and kept out of the generated data. Both
read as `EvalCase`s (`letterBody` marks an email's body; the placeholder tokens in the raw text
are the ones the app passes):

- `eval/deep.jsonl`, 114 cases: the acceptance case twice, 18 controls, 15 cross-sentence and 14
  garbled corrections, 14 grammar, 10 each of facts, unchanged text, misheard words and layout, 8
  corrections within a sentence and 3 one-line fields.
- `eval/layout.jsonl`, 229 cases, in the categories of the table above: 35 `list-two`, 42
  `list-many` (some of them lists that must stay sentences), 40 `series`, 40 `email-body`, 50
  `placeholder` (four with the markers of a spoken list, as the app sends them) and 22 `mention`.
  A unit test holds every target to Deep's own check.

### Commands

```bash
cd Packages/LiveTranscribeKit
.build/xcode/Build/Products/Release/Train generate --deep
.build/xcode/Build/Products/Release/Train validate --deep
.build/xcode/Build/Products/Release/Train train --deep --iterations 1500
.build/xcode/Build/Products/Release/Train measure --level deep --data Training/eval/deep.jsonl --data Training/eval/layout.jsonl --deep-adapter-dir Training/runs/deep-adapter
```

- `train --deep` trains on `generated/deep-train.jsonl` and writes to `Training/runs/deep-adapter`;
  the other options are `train`'s, except `--curated-repeats`, which Deep ignores. The bundled
  adapter was trained with the defaults (batch 8, learning rate 2e-5, seed 1) for 1,500
  iterations on the 9,345 examples above (about 4 hours on an M4 Pro; the best validation loss, at
  iteration 1,400, is the adapter kept). The prompt it is trained on includes the email-body line
  (`letterBody`), so the adapter and the app's prompt go together.
- `measure --level <level>` cleans every case through `MLXCleaner` and `CleanupExecutor`, as the app
  does at that level, and reports per category how often the shown text matches the target, fell
  back, came out unchanged, changed the meaning (lost a word the case keeps, or has one it rules
  out), or differed, with latency. `--data` picks the cases (by default Medium's 515 test examples),
  `--deep-adapter-dir` another Deep adapter, `--deep-adapter none|medium|deep`, `--deep-passes
  one|after-medium`, `--thinking` and `--thinking-tokens` other ways of running Deep, and
  `--no-medium-fallback` Deep's pass alone.
- `requests` writes the requests the app would make, and `replay` scores another runtime's
  answers to them, which is how the Linux and Windows runtime is checked against the Mac.

To ship a new Deep adapter, copy `adapters.safetensors` and `adapter_config.json` from the run
folder into `Sources/Cleanup/DeepAdapter/`. The Linux and Windows app compiles the same files in.

Deep's measured results, and how the design was chosen, are in
[Design notes](../../../docs/design-notes.md#how-deep-was-chosen); `measure` reproduces them.

## Preparing speech-to-text training data

The next recipe preserves the speech model's punctuation and capitals. The proposed choices
are None, Standard and Deep; until that rename lands, the CLI calls Standard `high` and its
self-correction adapter `medium`. `--kind medium` prepares that adapter's data.

### Seeds and the candidate mix

`make prepare-data` **regenerates** `Training/generated/` and writes speech seeds to
`Training/prepared/{standard,deep}`. Seeds contain each original dictation once, including its
fillers and self-corrections; the Deep seeds also include whole sentences for Macs/max,
merge/Madge and spelled acronyms. Seeds are not the final training data: speak them and pass
the audio through the app's speech models first. `Train --data-dir` refuses a seed or stress
directory. All generated data, audio, exports and reports stay git-ignored.

The default candidate recipe is:

- One untouched measured transcript per clip per chosen speech model. Related inputs keep
  their original family's training, validation or test split.
- Placeholder rehearsal at the original pool's family rate, selected reproducibly. A full
  audio run restores every placeholder family, including the 800 original Deep training
  examples for emoji, snippets and list-marker tokens. No placeholder is spoken to TTS.
  Training weights compensate for the number of speech models; a pilot gets a proportional
  sample instead of being overwhelmed by all 800 rows.
- Extra whole-sentence sound-alike inputs from the versioned allowlist, for at most 10% of
  eligible Deep families. Clean controls remain. This is explicit synthetic augmentation,
  labelled separately from measured transcripts; `--sound-alike-rate 0` disables it.
- Curated self-correction training pairs retain their shipped **x2** weight through
  `training_weight`; other pairs have x1. Validation and test pairs have x1. The first
  preparation version included curated pairs once and changed that recipe; it is corrected.

There is no default lowercasing or blanket comma removal. `make prepare-stress-data` is an
optional diagnostic set with bulk punctuation/casing variants; it is separate from this
recipe and must not be substituted for measured training data. `preparation-report.json`
reports category/profile counts, weights, capitals, sentence lengths and separator rates.
Inspect these before selecting a production mix: the old seed frames themselves are not a
frequency fit to real dictation, and a small TTS pilot does not prove that they are.

### Speak and transcribe

From the repository root, synthesize a pilot; use `--all` instead of `--limit 60` for all
non-placeholder families. Speak the original dictation, not its cleaned target, so fillers
and corrections survive.

```bash
python3 scripts/prepare-cleanup-data.py audio \
  --dataset Packages/LiveTranscribeKit/Training/prepared/deep \
  --output Packages/LiveTranscribeKit/Training/prepared/audio --limit 60 --voice Samantha
```

Build the package's `Bench` scheme with `xcodebuild`, as for `Train` above. Use a pinned local
speech-model snapshot from the app's cache:
`~/.cache/huggingface/hub/models--OWNER--MODEL/snapshots/<full-commit>/`. For the default model,
the directory starts with `models--Nerdstorm--Qwen3-ASR-0.6B-Sinhala-8bit`. Choose an actual
installed snapshot, not its mutable `refs/main` file or the `mlx-audio` convenience alias.

From `Packages/LiveTranscribeKit`, export speech output before dictation commands or cleanup:

```bash
.build/xcode/Build/Products/Release/Bench --dictation \
  --clips Training/prepared/audio --stt-model /absolute/path/to/the/snapshot \
  --asr-output Training/prepared/speech-default.jsonl
```

Repeat for each chosen recognizer on the same clips. Another voice/rate can be another batch.
Exports fingerprint the actual weight bytes, model configuration, language setting and audio;
the folder path or configuration alone cannot identify weights. Keep the audio manifest and
exports with the run. The importer rejects mixed identities, duplicate/missing clips and stale
audio or source examples.

From the repository root:

```bash
python3 scripts/prepare-cleanup-data.py merge-asr \
  --dataset Packages/LiveTranscribeKit/Training/prepared/deep \
  --audio-manifest Packages/LiveTranscribeKit/Training/prepared/audio/audio-manifest.jsonl \
  --transcripts Packages/LiveTranscribeKit/Training/prepared/speech-default.jsonl \
  --output Packages/LiveTranscribeKit/Training/prepared/deep-measured
```

Repeat `--transcripts` for other recognizers. `--include-synthetic` explicitly adds the seed or
stress bank for an experiment; it is outside the default mix above.

### Reconcile targets automatically

`speech-to-text-rules.json` versions the rules and synthetic context seeds. Import never edits
the measured input. It changes the target only for these supported, auditable cases:

| Speech output change | Target rule |
|---|---|
| A known synthetic name's spelling, such as Siobhan → Shavon | Keep the recognized spelling. A pronoun/common word or a different known name stays unresolved; Ewan → you and John → Sam are not safe spelling changes. |
| Number/time representation, such as twenty → 20 or two pm → 2 p.m. | Require the same value, then use the recognized representation in retained prose. Keep target list numbering. A different value, sign or unsupported form needs review. |
| Allowed regional spelling or contraction, such as centre → center or there's → there is | Use the speech model's form consistently in retained target text. |
| An allowlisted sound-alike common word in context, such as merge → Madge | Keep the intended clean target; this is the word-repair signal. Preserve the original category in metadata when classifying a newly misheard sentence as recognition. |
| The recognizer already fixed every planted grammar/word error | Exclude the pair and record it in `excluded.jsonl`; do not teach a word-fix category with no remaining word to fix. |
| Any other insertion, deletion, changed fact or ambiguous name | Keep the pair visible with `review_required`; do not guess its target. |

Every pair records its original `source_target`, rules version, changes and unresolved spans.
Routine changes do not need hand editing. For an unresolved pair, inspect the synthetic spoken
text/audio, transcript and intended output; edit its `target` only with evidence, add a review
note to its reconciliation record, clear `review_required`, then re-audit. Exclusions remain
inspectable rather than disappearing silently. Context, field flags and family splits stay fixed.

Private Dictation History is **evaluation only**, read into the local scratchpad and never
committed or used for training. The importer rejects its `rawText`/`cleanedText` schema. Its
historical cleaned output is not automatically a correct expected answer.

### Guard prerequisites, baseline and training

**The current Deep checks are a prerequisite, not something retraining can overcome.** They
require a colon before a two-item list. The first stress audit rejected 1,177 pairs, with
901 output-guard failures and 736 colon-rule failures; those counts overlap. Deep's short-list
policy must allow an unambiguous two-item lead without a colon in Swift and Rust, with matching
guard/layout fixtures, before those pairs can train. Other sound-alike, number and acronym
cases must also pass the runtime guard and the training category checks. The preparation tools
do not widen those runtime rules or filter such failures away.

From the package folder, audit the **merged** directory. A nonzero result writes every blocked
row and dataset hash to `audit.json` and prevents training:

```bash
.build/xcode/Build/Products/Release/Train validate --deep \
  --data-dir Training/prepared/deep-measured --report Training/prepared/deep-measured/audit.json
.build/xcode/Build/Products/Release/Train measure --level deep \
  --data Training/prepared/deep-measured/test.jsonl --report Training/prepared/deep-measured/baseline-deep.json
```

**An exact text score is required before comparing adapters.** The existing word-normalized
verdict can count `Macs?` and `macs.` as equal. Score every held-out result, including fallbacks,
with the additional tool; it reports exact text, case-sensitive words, and the positions of
question marks and colons, by category. Missing or duplicate results fail scoring. Resolve or
explicitly quarantine ambiguous pairs before freezing the test file; scoring refuses any
remaining `review_required` label. Keep approved guard-failure cases in that held-out suite.

```bash
python3 scripts/prepare-cleanup-data.py score \
  --data Packages/LiveTranscribeKit/Training/prepared/deep-measured/test.jsonl \
  --measurements Packages/LiveTranscribeKit/Training/prepared/deep-measured/baseline-deep.json \
  --output Packages/LiveTranscribeKit/Training/prepared/deep-measured/baseline-deep-exact.json
```

That scoring command runs from the repository root. Measure Standard with the current
`--level high` flag and score it too. Keep the merged test file/hash fixed for baseline and
candidate, include the existing Deep/layout and self-correction regression sets, and require
no regression in names, negation, values, token preservation or questions. TTS gives repeatable
inputs; held-out real speech and private evaluation are still needed before shipping.

After the audit passes, start a **fresh LoRA from the pinned base**, not the shipped adapter.
Find the base's full commit in `base_revision` in
`Sources/Cleanup/DeepAdapter/adapter_config.json` (or `Sources/Cleanup/Adapter/adapter_config.json`
for the self-correction adapter). From the package folder:

```bash
.build/xcode/Build/Products/Release/Train train --deep \
  --data-dir Training/prepared/deep-measured --revision <full-base_revision-commit> \
  --output Training/runs/deep-speech-candidate
```

Training reruns the audit and writes dataset hashes beside its report. The Standard adapter
uses the same procedure without `--deep`, with `standard` seeds and the corresponding merged
directory. `--curated-repeats` is replaced by each prepared row's recorded weight; its default
recipe keeps curated training x2. Measure and exactly score the candidate on the unchanged
holdouts before copying any weights into either app.

Choose iterations from the report's weighted training count and batch size. Keeping 1,500
iterations after adding another recognizer would reduce the passes over the data; the shipped
Deep run was about 1.3 passes. Record that choice and the full recipe with each comparison.
