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

Release 1.3.0 bundles **F4 checkpoint 1950**, selected by validation loss after training stopped
at iteration 2400. It includes the measured synthetic transcript pool, public written pairs
from Disfl-QA/SQuAD and ErAConD, and synthetic app requests. The completed development checks
found correction gains and grammar, list and vocabulary regressions; it did not pass the
original promotion gates. The owner subsequently chose to release this checkpoint.
[The release record](../../../docs/deep-f4-release.md) preserves the exact identities,
comparison and limitations, and [the bundled notice](../Sources/Cleanup/DeepAdapter/NOTICE.md)
credits the public sources. No private dictation history was used. The recipes and results
below describe the earlier adapters; they do not recreate F4's frozen composition.

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
| `recognition` | 450 | A misheard word fixed from the rest of the text, or its capital alone when speech-to-text wrote a common word as a name ("in the Summer") |
| `layout` | 500 | An email, letter or list laid out in a field that takes several lines |
| `oneLine` | 250 | The same, kept to one paragraph in a field that doesn't |
| `unchanged` | 250 | Text that is already right stays as it is |
| `listTwo` | 400 | Two things set off with a colon ("two things I need: A and B"), or the full stop speech-to-text writes in its place, become a list, or stay a sentence in a one-line field |
| `listMany` | 600 | Three to six items, bulleted, or numbered when their order matters, with an opening sentence, a greeting or a closing sentence around them |
| `series` | 600 | A series inside a sentence ("we visited Lisbon, Porto and Faro last summer"), two items with no colon, and a colon that introduces no list, all stay as said |
| `body` | 700 | The body of an email, which the app sends without its greeting and sign-off and with `letterBody` set: a paragraph that stays one, a list laid out, a correction resolved |
| `placeholder` | 800 | Tokens for emoji, links and list markers stay once each, where they stand, with the text around them cleaned; spoken list markers keep the text one paragraph |
| `mention` | 200 | A correction said inside a mention ("tools like Docker, sorry, not Docker, Kubernetes") is resolved; an ordinary contrast ("three, not four") stays |

One more category, `composite`, isn't generated: the measured preparation joins examples of the
others into dictations of several sentences (below).

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
  adapter in release 1.2.0 was candidate E, trained with the defaults (batch 8, learning rate 2e-5, seed 1) for
  1,859 iterations on the 11,440 measured examples of
  [Preparing speech-to-text training data](#preparing-speech-to-text-training-data), with E's
  families and recipe (`train --deep --data-dir Training/prepared/deep-measured-e`, about 5.5
  hours on an M4 Pro; the best validation loss, at iteration 1,400, is the adapter kept). The
  prompt it is trained on includes the email-body line (`letterBody`), so the adapter and the
  app's prompt go together.
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
fillers and self-corrections; the Deep seeds also include whole sentences where a name and a
common word sound alike ("Bill paid the gas bill") and spelled acronyms (`context_seeds`).
Seeds are not the final training data: speak them and pass the audio through the app's speech
models first.

**A dictation is rarely one sentence.** The generator's examples are 13 words on average, so
Deep's preparation also joins them: of the examples that are sentences in one paragraph (no
context, letter body, layout or placeholder, and not a planted recognition error), 60% are joined
two to four at a time, in a field of the same kind, up to 80 words, into `composite` examples
whose target is each part's target in turn. In train and valid the parts leave the split, so
each is still trained on once; the test split keeps them as well, so they stay measured on their
own. `--composite-share` changes the share (0 for none); the report counts composites and parts.
A composite carries its parts, so when its transcript needs review (one misheard word in any
part), merging gives the parts back: the transcript is cut where the parts meet, before the
next part's first word or after this one's last, whichever the recognizer wrote as said, and
each part is reconciled on its own. One misheard word then costs one sentence, as it does said
alone. A composite that Deep's checks turn down still takes its parts with it. `Train --data-dir` refuses a seed or stress
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

**Families written by their own generators.** Some skills need sentences the Swift generator
doesn't make. Each family has a generator in `scripts/e_seeds/` that writes
`Training/generated-e/FAMILY-{train,valid,test}.jsonl` and a gate set of hand-checked cases in
`Training/eval/FAMILY.jsonl`. Each writes the same files on every run. `--check`
(slot-corrections, spoken-numbers) also checks that no raw text is shared with the held-out
files. The families are:

- `slot-corrections`: a correction inside one slot of a sentence, which keeps the words before
  the slot ("the cost of parking, no wait, petrol has doubled" is "The cost of petrol has
  doubled.");
- `spoken-numbers`: numbers kept exactly as said, since the number rules write digits after the
  model;
- `marker-lists`: steps counted out loud in mixed styles, kept as said for the list rules to
  number.

Word fragments ("con consider") and the whole words that start like the next one ("an animal",
"new newsletter") are transcript seeds (`scripts/transcript-seeds.py`), as the recognizer writes
them.

`prepare --extra-dir Training/generated-e` adds the families to Deep's seeds, each split from the
files named for it. A row its split already holds, with the same words in the same kind of field and
punctuation aside, is left out, and the report counts those per file
(`extra_rows_already_held`).

There is no default lowercasing or blanket comma removal (`--input-variant`, below, adds a
bounded share of measured transcripts as other recognizers write them). `make prepare-stress-data` is an
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

`--jobs 8` synthesizes eight clips at once; a full run (`--all`, about 10,300 Deep clips) takes
about 45 minutes that way on an M4 Pro. A clip is renamed into place only when complete, so a
run that stops can be started again and keeps the clips it made.

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
  --output Packages/LiveTranscribeKit/Training/prepared/deep-measured \
  --sound-alike-rate 0.2 --include-synthetic-category recognition --include-transcript-seeds \
  --input-variant unpunctuated=0.2 --input-variant odd-stops=0.15 \
  --input-variant odd-case=0.1 --input-variant lowercase=0.1
```

Candidate E prepares its seeds with the families above
(`prepare --kind deep --extra-dir Packages/LiveTranscribeKit/Training/generated-e`). It then
merges with stops moved as well as added:

```bash
  --input-variant unpunctuated=0.2 --input-variant odd-stops=0.1 --input-variant odd-case=0.1 \
  --input-variant lowercase=0.1 --input-variant moved-stops=0.1
```

Repeat `--transcripts` for other recognizers. `--include-synthetic` explicitly adds the seed or
stress bank for an experiment; it is outside the default mix above.

**A word fix planted in writing doesn't survive speech.** The seed's recognition examples spell a
word as its sound-alike ("the knew laptop", "take the rode"); spoken, they sound right, so the
recognizer writes the right word, and 495 of them came back with nothing left to fix and were
excluded. `--include-synthetic-category recognition` keeps those examples as written in train and
valid, so the adapter keeps the skill; the held-out test stays measured. Sound-alikes planted in
measured sentences (`--sound-alike-rate`, at most 0.2 of eligible families) add the recognizer's
own kind of error.

Some of what the recognizer writes can't be made with a voice either: a common word it takes for
a name ("We need to Harry", for hurry; "the gas Bill") or letters it spells out ("the B B C"). A
synthetic voice says the word right and the recognizer writes it right. `transcript_seeds` in the
rules file holds general-English dictations as the recognizer writes them, some of several
sentences or laid out as lists, with controls that keep a name where it is one and letters that
aren't an acronym. `scripts/transcript-seeds.py --write` rewrites them reproducibly; it keeps each
template's sentences in one split, so the test's are sentences the adapter never saw.
`--include-transcript-seeds` adds each split's seeds to it.

**Cleanup must not depend on the punctuation or capitals the recognizer guesses.** Measured
transcripts are nearly all cased and punctuated, so an adapter trained on them alone leans on the
recognizer's full stops and commas, and does worse on text without them, such as a correction
said without a pause. `--input-variant KIND=RATE` (repeatable, each rate at most 0.5) also gives
that share of the measured train and valid families a copy of their transcript as another
recognizer writes it, with the same answer:

| Kind | The transcript |
|---|---|
| `unpunctuated` | Lower case, no punctuation between words |
| `lowercase` | Lower case, punctuation kept |
| `odd-stops` | One or two full stops where a speaker could pause ("the demo on Friday. Sorry, Thursday"), the next word capitalised |
| `odd-case` | One to three capitals guessed wrong: a common word as a name, a sentence or a name begun in lower case |
| `moved-stops` | A comma or full stop a word before or after where it belongs, as when the speaker pauses in the wrong place; never beside a number, a list marker or a correction's cue |

Families are chosen per kind by digest, and the stops and capitals by a seed from the row, so a
run is reproducible. The words stay the recognizer's, values such as `9:30` and placeholders are
kept, and the held-out test stays as it was measured.

**An answer keeps the optional punctuation of its own input.** English leaves some commas to the
writer: before "and", "but", "so", "or" or "yet", and after an opening word or phrase ("Actually,
it works"). Merging carries those from each input to its target: a target loses such a comma
where its input has none between the same two words, and gains one where the input has one.
Commas English requires (between list items, beside an addressed name, between clauses with no
word joining them), sentence ends, question marks, colons and layout stay the target's. So no
house style is taught, the generator's included, and an unpunctuated input is answered with only
what English requires. The report counts the targets changed, and each keeps its earlier target
in `target_before_optional_commas`.

### Reconcile targets automatically

`speech-to-text-rules.json` versions the rules and synthetic context seeds. Import never edits
the measured input. It changes the target only for these supported, auditable cases:

| Speech output change | Target rule |
|---|---|
| A known synthetic name's spelling, such as Siobhan → Shavon | Keep the recognized spelling. A pronoun/common word or a different known name stays unresolved; Ewan → you and John → Sam are not safe spelling changes. |
| Number/time representation, such as twenty → 20 or two pm → 2 p.m. | Require the same value, then use the recognized representation in retained prose. Keep target list numbering. A different value, sign or unsupported form needs review. |
| Allowed regional spelling or contraction, such as centre → center or there's → there is | Use the speech model's form consistently in retained target text. |
| A compound written apart or joined, such as frontend → front end or wifi → Wi-Fi (`spacing_variants`) | Use the speech model's form. |
| An article, or a title written out, such as the → a or Mr → Mister | Use the speech model's form; no cleanup could tell which was said. |
| A sound-alike spelling of a name in `name_variants`, such as Hana → Hannah | Keep the recognized spelling. |
| A currency sign or a dropped am/pm, such as twelve thousand dollars → $12,000 or four pm → 4:00 | Use the speech model's form; the value is the same and no cleanup could restore the marker. |
| An apostrophe put in a plural the target keeps, such as printers → printer's | Keep the target; this is a fix. "speaker's" for "speakers'" is not, and needs review. |
| A name or number a correction moves ("Sorry, I mean Gita" → "Gita will …") | The moved word takes the recognized form of the one spoken word that says it. |
| A change only to words the target doesn't keep: taken back, a cue or a garbled phrase | Keep the target, and let Deep's checks decide whether the transcript still supports it ("Sorry, know the Friday after" still corrects; "I'm ant" for "I meant" no longer does). |
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

**Deep's checks decide what can train, and retraining can't overcome them.** The first stress
audit rejected 1,177 pairs, with 901 output-guard failures and 736 colon-rule failures (they
overlap), because the checks read speech-to-text punctuation and capitals as the speaker's. They
now take a full stop as setting two items off, as a colon does, resolve a correction across a
full stop when the corrected words are said again or when it replaces the phrase the sentence
before ends with ("…in the garage. Actually, the lobby."), join spelled letters ("P R" → "PR"), and let
a word speech-to-text capitalised be respelled where it is written without a capital or starts a
list item (Swift and Rust, with guard fixtures; [Cleanup](../../../docs/cleanup.md)). The
preparation tools still don't widen those rules or filter failures away silently.

From the package folder, audit the **merged** directory. A nonzero result writes every blocked
row and dataset hash to `audit.json` and prevents training:

```bash
.build/xcode/Build/Products/Release/Train validate --deep \
  --data-dir Training/prepared/deep-measured --report Training/prepared/deep-measured/audit.json
.build/xcode/Build/Products/Release/Train measure --level deep \
  --data Training/prepared/deep-measured/test.jsonl --report Training/prepared/deep-measured/baseline-deep.json
```

Pairs that need a reviewed target, or whose target the checks turn down, can be set aside
instead of reviewed by hand. From the repository root, `quarantine` moves every row an audit
blocked into `quarantined.jsonl` with the audit's reasons, and records the counts in
`preparation-report.json`; audit again afterwards. It refuses an audit older than the files, and
any fault in the preparation itself (a duplicate id, a family in two splits, a wrong split), which
must be fixed rather than set aside. A row derived from one set aside (an input variant, or a
sound-alike planted in it) goes with it, since it shares the target the audit turned down. Read
the reasons before training: a reason that repeats across many rows is a check or a rule to fix,
not data to drop.

```bash
python3 scripts/prepare-cleanup-data.py quarantine \
  --dataset Packages/LiveTranscribeKit/Training/prepared/deep-measured \
  --audit Packages/LiveTranscribeKit/Training/prepared/deep-measured/audit.json
```

**Score meaning and required punctuation before comparing adapters.** The word-normalized
verdict can count `Macs?` and `macs.` as equal, and exact text counts a writer's choices as
errors. Score every held-out result, including fallbacks, with `score`
(`scripts/cleanup_scoring.py`). Its headline, `meaning`, needs the target's words, names and
numbers, its capitals for sentence starts, names, "I" and acronyms, its sentence ends and
question marks, and its lines and list layout. Optional punctuation counts neither way: a comma
before "and" or "but" or after an opening phrase, a dash, colon or full stop between sentences
that could stand apart, how a greeting or sign-off is punctuated, a full stop after a list item.
Commas between list items and beside an addressed name are reported as `required_commas`,
outside the headline, and exact text is reported too. Missing or duplicate results, or inputs
and targets that differ from the held-out file, fail scoring. Resolve or explicitly quarantine
ambiguous pairs before freezing the test file; scoring refuses any remaining `review_required`
label. Keep approved guard-failure cases in that held-out suite.

```bash
python3 scripts/prepare-cleanup-data.py score \
  --data Packages/LiveTranscribeKit/Training/prepared/deep-measured/test.jsonl \
  --measurements Packages/LiveTranscribeKit/Training/prepared/deep-measured/baseline-deep.json \
  --output Packages/LiveTranscribeKit/Training/prepared/deep-measured/baseline-deep-score.json
```

Any other `Train measure` report, such as the evaluation or Standard set, is scored with
`python3 scripts/cleanup_scoring.py <report.json>... --by-category`.

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
recipe keeps curated training x2. Measure and score the candidate on the unchanged
holdouts before copying any weights into either app.

Choose iterations from the report's weighted training count and batch size. Keeping 1,500
iterations after adding another recognizer would reduce the passes over the data; the shipped
Deep run was about 1.3 passes. Record that choice and the full recipe with each comparison.
