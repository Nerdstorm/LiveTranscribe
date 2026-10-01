# Design notes

Why Live Transcribe is built the way it is. Its two pipelines and the layout of the code are
in [Architecture](architecture.md), with diagrams.

## Models

- **One multilingual speech model that can be fine-tuned.** On 2026-09-25 Qwen3-ASR replaced
  Parakeet TDT 0.6B v3 as the default, because Sinhala could be added to it by fine-tuning. Since
  0.3.0 the default is that fine-tune
  ([Nerdstorm/LiveTranscribe-Sinhala](https://github.com/Nerdstorm/LiveTranscribe-Sinhala)). Cleanup
  stays on Qwen3-1.7B: a 4B model fixed only a little more, at 2 to 2.5 times the time
  ([Architecture](architecture.md)), and no 4B or larger model is planned, now or for a later
  Command Mode. That is also why **High** behaves close to Medium.
- **Speech models are loaded by kind** (`Transcription/SpeechModelKind.swift`): the app reads
  `model_type` from a model's config.json and loads it from its folder, downloaded or local, with
  mlx-audio-swift's loader for that kind. The list mirrors mlx-audio-swift's own `STT.loadModel`,
  aliases included, so an update that adds or renames a model needs the same change there.
- **The speech model catalog is a file both apps read**
  (`Transcription/Resources/speech-models.json`), built in and never fetched. Each model has a
  download for each platform it runs on (three of the seven are Mac-only). The Mac's is a Hugging
  Face repository pinned to a commit, so a release downloads what was tested with it;
  `scripts/pin-speech-model.sh` prints a repository's commit and download size. Linux and
  Windows models are a repository at a commit or a sherpa-onnx archive, with each file's size and
  SHA-256 (`scripts/pin-linux-windows-speech-model.sh`). On the Mac a catalog model is downloaded
  into the Hugging Face cache and loaded from its snapshot there (`SpeechModelDownloads`), not
  copied into `mlx-audio/` as mlx-audio-swift copies any other repository, and falls back to such
  a copy, made by an earlier version, when its commit can't be downloaded. Only licences that allow
  commercial use are listed (`SpeechModelCatalogTests`).
- **The speech model switches without a restart.** A new Speech-to-text setting reaches
  `SessionCoordinator.useSpeechModel`, which loads it once nothing uses the model: at once, or
  when the live transcript or the loading under way ends. `MLXTranscriber` downloads first, while
  the old model keeps transcribing, then drops it before loading the new one, so the two are never
  in memory together; a transcription asked for meanwhile waits. Linux and Windows unload the model
  in use first, then wait for the new one's download and load it, so dictation is unavailable
  meanwhile.

## Cleanup

- **The adapters are switched per request**: the self-correction adapter at Medium and High,
  Deep's at Deep, and none at Light, so Light never resolves corrections. Both adapt the same
  layers, so one set of LoRA layers is loaded and the adapter a request needs has its weights
  swapped in, in the same step as the generation.
- **The adapters are loaded as separate LoRA layers**, at the exact base-model commit they were
  trained on, not fused into the weights. Fusing re-quantizes the adapted weights to 4 bits, and
  the fused adapter resolved only 13% of self-corrections.
- **At High, a dictation with a correction cue is cleaned twice**: Medium's prompt, which the
  adapter was trained on, resolves the correction, then High's rewords the result within the same
  deadline. A rejected rewording keeps the first pass.
- **Fillers and layout are rules, not model output.** A 1.7B model does neither reliably, and a
  rule can be tested exhaustively. Fillers are removed before the model runs; lists are laid out
  after it, only where line breaks are allowed; list items keep the speaker's words, since layout
  moves and punctuates and never rewords. A letter's greeting and sign-off are found before the
  model runs and only its body is cleaned: shown a whole letter, the model moved the name in the
  sign-off into the greeting.
- **The check keeps names in place and content words in, at every level below Deep.** In a
  single-line field there is no letter frame, and the model still moved the sign-off's name into
  the greeting; at High, rewording was checked for length and similarity only, and dropped "milk"
  from a shopping list. Now a name (a capitalised word that does not start a sentence) must stay
  where it was said, or be respelled there, and a word that is not a function word ("the", "of",
  "is", "really") may not be deleted with nothing in its place. Function words are a fixed list
  rather than a part-of-speech tagger: a list is deterministic and testable, and a tagger's errors
  on unpunctuated speech would decide what counts as content. On 860 texts without a correction
  cue, cleaned at High, the two checks rejected only 2 answers the old check accepted, and both had
  changed the meaning.
- **Snippets and spoken commands are hidden from the model.** Each snippet trigger, emoji,
  address, line break and list marker becomes a placeholder (`⟦S1⟧`) that the model must copy
  unchanged. The check rejects any output that alters one, and what it stands for goes back in only
  after cleanup. The model itself sees a plain word ("S1"): it stripped or dropped the bracketed
  tokens in 17 of 23 probe sentences, and kept 21 of 23 as words. Dictated punctuation is not
  hidden; it is written into the text the model sees.
- **The cleanup prompt is multi-turn.** Each previous segment becomes a user `TEXT:` turn
  followed by an assistant turn holding its cleaned text, and the new segment is the last user
  turn. With the context inlined into a single message, the model sometimes echoed the context
  back and the check rejected the output for its word count. With multi-turn, fallbacks on a
  set of hard prompt cases went from 1 in 10 to none. Dictation cleans each dictation on its own,
  without context.
- **Line breaks are a per-app setting, not a field's report.** Only fields that reported a text
  area used to get lists and letters, which left out chat apps' message boxes, such as Slack's.
  Now every app is multi-line unless set otherwise, and only a field that certainly takes one
  line (a text field of the app's own window, never one in a web page) stays on one line.

## Deep

- **Deep is a level of its own, not a stronger High.** Repairs across sentences need a model that
  may change more, and a check that knows which changes are repairs. Widening the check's
  word-count and similarity limits would let rewording through too, so Deep's answer is checked by
  lining up the words said with the words written (`SelfRepair`), where every difference must be
  a repair Deep may make and names, numbers, dates, negations and placeholders are protected.
- **Deep has its own adapter, not a longer prompt or thinking** (below).
- **Deep's prompt gives rules, not examples.** It says what to do with a dictation in general
  terms, and the adapter learnt the rest from synthetic examples. Dictation history, which is
  real speech, was used only to measure; no dictation of anyone's is in the prompt or the
  training data.
- **Deep lays out only what the speaker didn't.** A list marked in speech is laid out by the
  rules after cleanup, from placeholders; had Deep's model laid it out too, both would have, and
  the eval's spoken lists came out with a stray line between items. So a dictation with a spoken
  line break or list marker goes to the model as one paragraph. Deep's check also turns down a
  bulleted list of two things (a sentence's "the invoice and the agreement" pulled apart, unless the
  speaker set them off with a colon) and a placeholder left on a line of its own (an emoji moved
  below its sentence), the two layouts the eval found wrong.
- **A rejected Deep answer gets Medium's pass**, not the uncleaned text, so choosing Deep never
  shows less than Medium would. Running Medium's pass first, on every dictation with a
  correction cue, took two passes and got fewer right (72 of the 114, against 88 in one pass).
- **Deep's limits.** A correction may take back up to six words, as at Medium, and its phrase may
  bring up to two new ones; one from a later sentence must share a word or a kind of fact with what
  it corrects; Deep waits at least 8 s, since a rejected answer runs Medium's pass too; and an
  answer that drops a later sentence's correction whole is rejected, after Deep's adapter did that
  on a real dictation.

### How Deep was chosen

Deep's spec asked for an experiment between three ways to do it (the self-correction adapter with
a new prompt, a separate pass, or training), and for Qwen3's thinking mode to ship only if it
helped. Each was measured with `Train measure` on an M4 Pro on 2026-09-30, on the 114 hand-written
cases in [`Training/eval/deep.jsonl`](../Packages/LiveTranscribeKit/Training/eval/deep.jsonl),
which nothing was trained on. Right means the shown text is the target, ignoring casing and
punctuation.

| Deep ran with | Right | Fell back | Unchanged | Meaning changed | Other | p50 (ms) | p95 (ms) |
|---|---:|---:|---:|---:|---:|---:|---:|
| Deep's prompt, no adapter | 52 | 0 | 39 | 23 | 0 | 200 | 260 |
| No adapter, thinking (768 tokens) | 58 | 52 | 0 | 1 | 3 | 4,781 | 5,026 |
| Medium's pass, then Deep's, no adapter | 72 | 0 | 40 | 2 | 0 | 289 | 410 |
| The self-correction adapter | 88 | 5 | 17 | 1 | 3 | 225 | 364 |
| **Deep's adapter, as shipped** | **108** | 1 | 2 | 0 | 3 | 227 | 360 |

Unchanged means an accepted answer kept the words as they were, so whatever needed repairing is
still there. Meaning changed means it changed the words and lost a fact the case keeps (a name,
number, date or "not"), or has one the case rules out, such as the word a correction replaced.
Each row is one run, so latencies from different rows are only roughly comparable.

- **Thinking was left off.** Qwen3's thinking, with 768 tokens to think in, got 58 right and ran
  out of tokens on most of the rest, at 4.8 s a cleanup at p50. With 3,072 tokens, on the 67
  corrections, controls and facts, it got 27 right against 60 for the self-correction adapter
  without thinking, and took 10.4 s at p50 and 21.8 s at p95. Its reasoning went round in circles
  and it reworded what was right. The code keeps it (`DeepCleanup.thinking`), reasoning removed
  before the check, for a larger model.
- **One pass, not two.** Medium's pass before Deep's, on every dictation with a cue, got 72
  right, against 88 for one pass with the self-correction adapter, and took two generations.
- **An adapter of its own.** Trained on Deep's prompt with synthetic examples only
  ([Training/README.md](../Packages/LiveTranscribeKit/Training/README.md#deeps-adapter)), it
  fixed what the prompt alone could not: the model copied every correction without it.
- **Medium's pass after a rejected answer**, so Deep shows at least what Medium would: on
  Medium's own 515 test cases, Deep got 505 right, as many as Medium, where Deep's answer alone
  got 499.

Deep was also run on 246 dictations from the owner's history on the Mac. They were used only to
measure: never trained on, never in a prompt, never committed. Their target is the text the app
inserted at the time, which is not always right, so this measures how much Deep changes more than
how right it is. Deep's text matched it on 198, Medium's on 214, and neither changed a protected
fact. Of Deep's other 48 answers, many differ only in what this run leaves out (spoken emoji, and
the line breaks the app laid out in fields that take several lines), several are better, a few
reword more than they need to, and one dropped a later sentence's correction together with what it
corrected, which the check now turns down.

## Dictation on the Mac

- **The shortcut is read with a `CGEventTap`**, which needs Accessibility. That is also the
  permission typing into other apps needs, so dictation asks for only two permissions. The tap
  runs on its own thread, and is re-enabled at once if macOS disables it. The keys the app posts
  itself (a paste's ⌘V, Undo AI Edit's ⌘Z) are tagged, and the tap passes them through: without
  the tag, the ⌘Z posted while the Z of ⌃⌥Z was still held was swallowed as that key's repeat.
- **The microphone opens on key-down**, not when the app starts: keeping it open all the time
  would make every start instant, but leaves the orange microphone indicator on for as long as the
  app runs. **Keep the microphone ready** does keep it open, with a 300 ms rolling pre-roll.
- **Capture uses an input-only `AVCaptureSession`, not `AVAudioEngine`.** On macOS,
  `AVAudioEngine` stops whenever its audio device reconfigures, and a Bluetooth headset
  reconfigures every time its microphone opens, because it switches to its call profile.
  Restarting the engine reopened the microphone, so capture looped. A capture session has no
  output side and keeps running through the switch. It also delivers 16 kHz mono directly and
  opens the chosen microphone by its ID. **System Default** follows macOS's default input as it
  changes, so a newly connected microphone is picked up without a restart; a virtual or aggregate
  device is never switched to mid-session, and at a start it is used only when no physical
  microphone is connected.
- **The panel is a small circle that follows the mouse pointer.** It used to sit at the text
  caret, whose position, read through Accessibility, was unreliable and put it in seemingly random
  places. Ordinary dictation is wordless; only a notice that needs attention is put in words, in a
  bubble beside the circle, and VoiceOver still announces what the panel leaves unsaid.
- **Live Transcript and dictation share one instance of each model.** Dictation refuses to start
  while the live transcript is listening, and closing the transcript window stops it: a transcript
  left listening with no window kept the microphone open, saved everything said nearby and refused
  every dictation.
- **Undo AI Edit puts back the uncleaned text, not the literal transcript.** Everything cleanup
  changed is taken back (fillers, punctuation, casing, rewording, layout, and spoken list markers
  go back to the words said), but snippet expansions, spoken commands and vocabulary spellings
  stay: the user set those up or asked for them. History keeps the literal transcript. After a
  paste it checks the field, not what it holds: a paste records no range, and reading a field's
  whole value after every paste would block on large fields (a terminal's scrollback), so undo
  refuses when another field has focus, but not when you typed more in the same field.
- **Local builds can be signed with a developer's own certificate**, through a gitignored
  `Config/Signing.local.xcconfig`, so macOS keeps the Accessibility and microphone grants across
  rebuilds. An ad-hoc build's designated requirement is its code hash, which every build changes;
  a certificate's names the certificate. The committed default stays ad-hoc, so the public
  repository holds no team ID and builds anywhere.

## Both apps

- **Linux and Windows run the Mac app's cleanup, not a lookalike.** The prompts, the check,
  `SelfRepair` and the executor are ported to Rust (`lt-cleanup`) and held to the Swift code by
  fixtures the Mac app's tests write (`Fixtures/cleanup`). The model is the Mac's own 4-bit
  weights converted to OpenVINO with each adapter's matrices as inputs, so both adapters plug in
  unchanged and one compiled model serves every level. It runs on the app's own OpenVINO runtime
  (`lt-language-model`), since OpenVINO GenAI's bindings have no LoRA adapters and no control
  token by token.
- **The Mac app is the reference.** A rule is changed in Swift first, and the fixtures it writes are
  what the Rust port must reproduce ([Development](development.md#keeping-the-two-apps-the-same)).

## Build and dependencies

- **The Hugging Face downloader and tokenizer adapters are hand-written**
  (`Cleanup/HuggingFaceAdapters.swift`) instead of using mlx-swift-lm's `MLXHuggingFace` macros,
  which would need Xcode's macro-trust prompt. That makes `swift-huggingface` and
  `swift-transformers` direct dependencies; both were already indirect ones.
- **`mlx-audio-swift` is pinned by revision**, not by version: it uses `unsafeFlags`, which
  SwiftPM accepts only from packages pinned by revision or by local path. The revision is `main`
  of 2026-09-18, past the latest tag (v0.1.3), for its fix to Qwen3-ASR's audio features
  (Blaizzy/mlx-audio-swift#247).
