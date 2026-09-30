# Architecture

A map of Live Transcribe for contributors. It covers:

- what happens between the words you say and the text that appears;
- which code runs each step, on the Mac and on Linux and Windows;
- why cleanup is made of rules, a prompt, a trained adapter and a check;
- how the two apps are kept the same;
- where to make a change.

The details are in other pages:

- what each cleanup level does: [Cleanup](cleanup.md);
- the decisions behind the design: [Dictation design](dictation.md) and
  [Design notes](design-notes.md);
- building, testing and measuring: [Development](development.md), and for Linux and Windows the
  [Linux and Windows README](../linux-windows/README.md).

## Two apps, one behaviour

The Mac app is written in Swift. The Linux and Windows app is written in Rust. They share their
models, their cleanup adapters, their speech model catalog and their expected results, so the same
dictation comes out the same.

| | Mac | Linux and Windows |
|---|---|---|
| Code | `App/` (the menu bar app) and `Packages/LiveTranscribeKit` (every feature, as vertical slices) | `linux-windows/`, a Cargo workspace; the app is a Tauri tray app |
| Runs the models with | MLX, on Apple silicon | OpenVINO: Qwen3-ASR on an Intel NPU or the CPU, the cleanup model on the CPU; sherpa-onnx for the catalog's other speech models |
| Does | dictation, dictation history and the live transcript | dictation, and transcribing a file from the command line |

```mermaid
flowchart LR
    subgraph shared["Shared by both apps"]
        HF[("Hugging Face:<br/>speech and cleanup models")]
        AD["Cleanup adapters<br/>Sources/Cleanup/Adapter and DeepAdapter"]
        CAT["Speech model catalog<br/>speech-models.json"]
        FX["Expected results<br/>Fixtures/golden, Fixtures/cleanup"]
    end
    MAC["Mac app<br/>Swift and MLX"]
    LW["Linux and Windows app<br/>Rust, OpenVINO and sherpa-onnx"]
    HF -->|downloaded once| MAC
    HF -->|downloaded once| LW
    AD --> MAC
    AD -->|compiled in| LW
    CAT --> MAC
    CAT -->|compiled in| LW
    MAC -->|its tests write| FX
    FX -->|its tests replay| LW
```

Audio and text stay on the computer. The app goes online only to download the models, and on
the Mac to check for a new version if you allow it ([Privacy](privacy.md)).

## Dictation, step by step

You hold the shortcut, speak and let go. The text appears where you were typing.

```mermaid
flowchart TD
    A["Shortcut held"] --> B["Recording<br/>16 kHz mono"]
    B --> C["Speech to text<br/>Qwen3-ASR by default"]
    C --> D["Phrases protected<br/>snippet triggers, spoken commands and list markers<br/>become placeholders such as ⟦S1⟧"]
    D --> E["Vocabulary<br/>what speech-to-text wrote, spelt your way"]
    E --> F{"Level is None?"}
    F -->|yes| N["Placeholders put back<br/>nothing cleaned or laid out"]
    F -->|no| G["Letter frame<br/>a letter's greeting and sign-off<br/>go on lines of their own"]
    G --> H["Cleanup of the body<br/>the only step that uses the language model"]
    H --> I["Line breaks and list markers put back<br/>lists and letters laid out"]
    I --> J["Snippets, emoji and addresses put back"]
    J --> K["Inserted at the cursor"]
    N --> K
    K --> L["Dictation history, if on (Mac)"]
```

1. **Shortcut.** A hold, tap or double tap starts recording.
2. **Speech to text.** The speech model writes what it heard, with its mistakes.
3. **Phrases protected.** Snippet triggers, spoken commands (emoji, punctuation, "new line",
   addresses) and, from Medium up in fields that take several lines, spoken list markers ("number
   one", "bullet point") are replaced by placeholders such as `⟦S1⟧`. The language model can't
   change what a placeholder stands for, and its answer is turned down if a placeholder goes
   missing.
4. **Vocabulary.** Each "heard as" form you listed is rewritten to your spelling ("nerd storm" →
   "Nerdstorm"). Terms that sound like something in the dictation are also listed in the cleanup
   prompt, to be spelt as written.
5. **Letter frame.** From Medium up, in fields that take several lines, a letter's greeting and
   sign-off go on lines of their own, by rules, and only the body goes to the language model.
6. **Cleanup.** See the next section.
7. **Layout, then the rest put back.** Line breaks and list markers come back first, so the
   layout rules can lay out lists and letters. Then snippets, emoji and addresses come back, where
   no rule can change them.
8. **Insertion.** On the Mac, the text is set through Accessibility and read back to check it
   arrived, or pasted with your clipboard restored afterwards, as each app's settings say. Linux
   types it through the Wayland input method, or pastes it. Windows types it as Unicode
   keystrokes. Where nothing would take the text, it is left on the clipboard for you to paste.

Where each step lives:

| Step | Mac: `Packages/LiveTranscribeKit/Sources/…` | Linux and Windows: `linux-windows/crates/…` |
|---|---|---|
| The flow, one dictation at a time | `Dictation` (`DictationController`, `DictationProcessor`, `PreparedDictation`) | `dictation` |
| Shortcut and its gestures | `Hotkey` | `hotkey` |
| Recording | `Capture` | `capture` |
| Speech to text | `Transcription` | `transcription`, with `language-model` for OpenVINO |
| Placeholders | `Shared` (`PhraseProtector`), `Snippets`, `SpokenCommands`, `Styles` (list markers) | `shared`, `snippets`, `spoken-commands`, `styles` |
| Vocabulary | `Vocabulary` | `vocabulary` |
| Fillers, lists and letters | `Styles` (`FillerRemover`, `LetterFrame`) | `styles` |
| Cleanup | `Cleanup` | `cleanup`, with `language-model` |
| Insertion | `Insertion` | `insertion`, `wayland` (Linux), `windows` (Windows) |
| Panel, menu, Settings | `DictationUI` | `dictation-ui`, `app` |
| History | `Persistence` | — |

## Cleanup: rules, a prompt, an adapter and a check

Cleanup has four layers. Each one does what the one before can't.

```mermaid
flowchart LR
    T["Text from the<br/>steps before"] --> R["1. Rules<br/>fillers removed,<br/>no model"]
    R --> P["2. Prompt<br/>the level's rules<br/>in plain English"]
    P --> M["3. Model and adapter<br/>Qwen3-1.7B with a<br/>10 MB LoRA adapter"]
    M --> C{"4. Check<br/>the answer against<br/>what was said"}
    C -->|accepted| OK["Cleaned text"]
    C -->|turned down| FB["The text after step 1"]
```

1. **Rules** (`Styles`) do what needs no judgement: fillers such as "um" go from Medium up, and
   lists and letters are laid out by rules around the model, as the previous section shows.
2. **The prompt** (`PromptBuilder`) tells the model the level's rules in plain English, with no
   worked examples. Light to High start from the same two base rules, and each level adds its
   own; Deep has its own, longer set. This is what Medium sends, with one vocabulary term:

   ```text
   Correct transcription errors, punctuation, casing and grammar in the TEXT.
   Preserve meaning, tone, hedging and filler intent exactly.
   Do not add, summarise or rephrase content.
   When the speaker corrects themselves, keep only the correction.
   If the text is already correct, return it unchanged.
   Spell these names and terms exactly as written: Nerdstorm.
   Output only the corrected text.
   ```

3. **The model and its adapter.** Qwen3-1.7B runs on the computer, with a LoRA adapter chosen per
   request: none at Light, the self-correction adapter at Medium and High, and Deep's adapter at
   Deep. An adapter is a small set of extra weights, trained on examples of exactly these rules.
   It doesn't replace the prompt: Medium's prompt above is the one its adapter was trained with.
   If the adapters can't be loaded, every level gets rules that keep every word, since the model
   alone can't resolve a correction reliably.
4. **The check** (`OutputGuard`) compares the answer with what was said. The answer may not drop
   a negation or a word that carries meaning, move a name, damage a placeholder, or come out much
   longer, shorter or more different than the level allows. It may drop a correction cue
   ("sorry", "I mean") only together with the words the cue takes back. Deep's check
   (`SelfRepair`) lines up the words said with the words written, and every difference must be a
   repair Deep may make. An answer that fails is never shown: the text after step 1 is inserted
   instead, and dictation history records why.

Two cases skip the model and get the rules only: cleanup turned off in Settings, and text in a
script the model can't write, such as Sinhala.

Each level runs one or more passes of the model:

```mermaid
flowchart TD
    S["Text after the rules"] --> L{"Level"}
    L -->|Light, Medium| M1["Pass with the level's prompt"]
    L -->|"High, no correction cue"| H1["Pass with High's prompt"]
    L -->|"High, with a cue such as sorry"| H2["Medium's pass<br/>resolves the correction"]
    L -->|Deep| D1["Deep's pass<br/>its own prompt and adapter"]
    M1 --> C{"Check"}
    H1 --> C
    H2 --> HC{"Check"}
    HC -->|accepted| H3["High's pass<br/>rewords the result"]
    HC -->|turned down| RAW
    H3 --> HC2{"Check"}
    HC2 -->|accepted| OUT["Cleaned text"]
    HC2 -->|"turned down, or no time left"| MED["Medium's result"]
    D1 --> DC{"Deep's check<br/>SelfRepair"}
    DC -->|accepted| OUT
    DC -->|turned down| M2["Medium's pass<br/>in the time left"]
    DC -->|no answer in time| RAW
    M2 --> C
    C -->|accepted| OUT
    C -->|"turned down, or timed out"| RAW["Text after the rules<br/>recorded as a fallback"]
```

All passes of one dictation share one deadline: 3 s by default, and at least 8 s at Deep. The code
is `CleanupExecutor` and `DeepCleanup` on the Mac, and the same names in the `cleanup` crate.

### Why an adapter, and not only the prompt?

The rules are in the prompt, and every request sends them. What the adapter adds is a model that
follows them. Qwen3-1.7B is small enough to answer in about a quarter of a second on the
computer, but on its own it reads the rules and follows them loosely. These are the measurements
behind that choice:

| What was tried | Result |
|---|---|
| Prompting Qwen3-1.7B to resolve self-corrections ("cars, sorry, buses" → "buses") | at most 1 of 7 in an early test |
| The same with Qwen3-4B, a download twice the size | at most 2 of 7, 2 to 2.5 times slower, and one changed meaning |
| Qwen3-1.7B with the self-correction adapter | 97% of held-out self-corrections resolved and 98% of plain sentences kept, 0.23 s at p95 |
| Deep's prompt, no adapter | 52 of 114 hand-written cases right: the model copied every correction |
| Deep's prompt, with the model reasoning first ("thinking") | 58 of 114, taking 20 times as long |
| Deep's prompt, with the self-correction adapter | 88 of 114 |
| Deep's prompt, with an adapter trained on it | 108 of 114, 0.23 s at p50 |

[Cleanup](cleanup.md#how-deep-was-chosen) has the full comparison for Deep. Large hosted models
follow a prompt of rules well, but Live Transcribe runs on your computer and works offline, so
the model has to be small. The adapter teaches the small model to follow the prompt. It is
10 MB, it is swapped in per request, and it adds no measurable time.

This has a cost, and contributors should know it. **The model does what its training showed it.
A new rule in the prompt alone rarely changes what it does.** For example, Deep's prompt asks
for a letter's paragraphs, but its training never showed a letter's body on its own, so it
doesn't split one ([Limitations](limitations.md)). To change what the model does:

1. add examples to the training data;
2. retrain the adapter;
3. measure before and after;
4. change the check if it would turn the new answers down.

The check is what makes this safe. Whatever the model writes, a changed meaning is not inserted.

## The live transcript (Mac)

The live transcript window writes down speech continuously, in three loops that run at the same
time (`Session/SessionPipeline`):

```mermaid
flowchart LR
    MIC["Microphone"] --> CAP["Capture<br/>16 kHz mono"]
    CAP --> VAD["Segmentation<br/>Silero voice activity detection"]
    VAD -->|"queue that never drops"| STT["Transcription<br/>Qwen3-ASR"]
    STT -->|"bounded queue"| CL["Cleanup<br/>at the chosen level"]
    CL --> OUT["Window, and a JSONL file per session"]
```

A raw transcript is never lost. The transcription queue has no limit, and when the cleanup queue
is full, the oldest waiting segment is saved with its raw text instead of being cleaned.
Dictation and the live transcript share one instance of each model and never run at the same time.

## Code map

### Mac

Every feature is a slice in `Packages/LiveTranscribeKit/Sources`, and `App/AppComposition.swift`
builds the concrete ones. Slices depend on protocols (`Transcriber`, `Cleaner`, `TextDelivery`,
…), which the tests replace with fakes. The main dependencies (every slice also uses `Shared`):

```mermaid
flowchart TD
    APP["App/<br/>menu bar app, composition root"] --> DUI["DictationUI<br/>menu, panel, Settings, history window"]
    DUI --> DIC["Dictation"]
    DUI --> TUI["TranscriptUI"]
    TUI --> SES["Session<br/>live transcript"]
    DIC --> TR["Transcription"]
    DIC --> CL["Cleanup"]
    DIC --> TXT["Snippets, SpokenCommands,<br/>Vocabulary, Styles"]
    DIC --> IO["Hotkey, Capture,<br/>Insertion, Persistence"]
    SES --> TR
    SES --> CL
    SES --> SEG["Segmentation"]
    CL --> STY["Styles"]
```

The README's [Architecture](../README.md#architecture) lists every slice. The command-line tools
are slices too: `Bench` measures speech to text and dictation, and `Train`, with
`CleanupTraining`, generates the adapters' data, trains them and measures cleanup.

### Linux and Windows

The crates in `linux-windows/crates` mirror the Mac's slices:

```mermaid
flowchart TD
    APP["app<br/>the livetranscribe command, tray, Settings"] --> DIC["dictation"]
    APP --> DUI["dictation-ui"]
    APP --> TR["transcription"]
    APP --> CL["cleanup"]
    APP --> LM["language-model<br/>Qwen3 on OpenVINO"]
    APP --> IO["capture, hotkey, insertion"]
    APP -->|Linux| WL["wayland"]
    APP -->|Windows| WIN["windows"]
    DIC --> CL
    DIC --> TXT["snippets, spoken-commands,<br/>vocabulary, styles"]
    DUI --> DIC
    TR --> LM
    CL --> STY["styles"]
```

`shared` holds what they all use, including string handling that matches Swift's exactly, so that
text is compared, cased and split the same way as on the Mac. The
[Linux and Windows README](../linux-windows/README.md) describes each crate.

## Keeping the two apps the same

The Mac app is the reference. Its tests write the expected results, and the Rust tests must
reproduce them:

```mermaid
flowchart LR
    SW["Mac app's tests<br/>make golden"] -->|write| G["Fixtures/golden<br/>9,728 dictation cases,<br/>speech features"]
    SW -->|write| CF["Fixtures/cleanup<br/>every prompt, check verdict<br/>and executor trace"]
    G --> RT["Rust tests<br/>cargo test"]
    CF --> RT
    RT --> CI["CI on Linux and Windows"]
```

To change a behaviour:

1. change the Swift;
2. run `make golden` at the repository root to write the fixtures again;
3. port the change to the crate until `cargo test` passes in `linux-windows/`.

CI runs the Rust tests on Linux and Windows whenever `linux-windows/` or the fixtures change.

## Measuring and training

A cleanup change is measured before it ships:

```mermaid
flowchart LR
    GEN["Example generators<br/>CleanupTraining"] --> DATA["Training/generated<br/>and Training/curated"]
    DATA --> TRAIN["Train train<br/>LoRA on Qwen3-1.7B"]
    TRAIN --> ADP["Adapter"]
    ADP --> MEAS["Train measure<br/>on Training/eval,<br/>never trained on"]
    MEAS -->|"better, and nothing worse"| SHIP["Adapter committed<br/>in Sources/Cleanup"]
```

- `Train measure` cleans a data set through the app's own cleanup at one level. It counts the
  answers that were right, fell back, stayed unchanged, changed the meaning or were otherwise
  different, and reports latency.
- `make bench` and `make eval` measure word error rate and latency on spoken clips, for the live
  transcript and for dictation.
- The training data is generated from templates, plus examples written by hand
  (`Training/curated`). No one's dictations are in it.

[Development](development.md) and
[Training/README.md](../Packages/LiveTranscribeKit/Training/README.md) have the commands.

## Where to change what

| To… | Change | Then |
|---|---|---|
| add a spoken command | `Sources/SpokenCommands` | `make golden`, and port it to `crates/spoken-commands` |
| change how lists or letters are laid out | `Sources/Styles` | `make golden`, and port it to `crates/styles` |
| change what a level may do | the prompt in `PromptBuilder`, and the check (`OutputGuard`, `SelfRepair`) | `make golden`, port it to `crates/cleanup`, and measure with `Train measure` |
| teach the model something new | the generators in `Sources/CleanupTraining` | retrain, measure before and after, and commit the adapter if nothing gets worse |
| add a speech model | `Sources/Transcription/Resources/speech-models.json` | pin its Linux and Windows download with `scripts/pin-linux-windows-speech-model.sh` |
| change how text is typed into apps | `Sources/Insertion` | `crates/insertion`, with `crates/wayland` and `crates/windows` |

A pull request that changes behaviour also updates the page that describes it: [Using](using.md),
[Cleanup](cleanup.md) or [Limitations](limitations.md).
