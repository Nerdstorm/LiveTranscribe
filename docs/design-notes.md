# Design notes

Why Live Transcribe is built the way it is. Its two pipelines and the layout of the code are
in [Architecture](architecture.md), with diagrams.

- **The adapters are switched per request**: the self-correction adapter at Medium and High,
  Deep's at Deep, and none at Light, so Light never resolves corrections. Both adapt the same
  layers, so one set of LoRA layers is loaded and the adapter a request needs has its weights
  swapped in, in the same step as the generation.
- **The adapters are loaded as separate LoRA layers**, at the exact base-model commit they were
  trained on, not fused into the weights. Fusing re-quantizes the adapted weights to 4 bits, and
  the fused adapter resolved only 13% of self-corrections.
- **Deep is a level of its own, not a stronger High.** Repairs across sentences need a model that
  may change more, and a check that knows which changes are repairs. Widening OutputGuard's
  word-count and similarity limits would let rewording through too, so Deep's answer is checked
  by lining up the words said with the words written (`SelfRepair`), where every difference must
  be a repair Deep may make and names, numbers, dates, negations and placeholders are protected.
- **Deep has its own adapter, not a longer prompt or thinking.** On the same 114 hand-written
  cases, Deep's prompt alone got 52 right (the model copied every correction), with the
  self-correction adapter 88, after Medium's pass 72, and with Qwen3's thinking 58, taking 20
  times as long; with an adapter trained on Deep's prompt, 108 ([How Deep was
  chosen](cleanup.md#how-deep-was-chosen)).
- **Deep's prompt gives rules, not examples.** It says what to do with a dictation in general
  terms, and the adapter learnt the rest from synthetic examples. Dictation history, which is
  real speech, was used only to measure; no dictation of anyone's is in the prompt or the
  training data.
- **Deep lays out only what the speaker didn't.** A list marked in speech is laid out by the
  rules after cleanup, from placeholders; had Deep's model laid it out too, both would have, and
  the eval's spoken lists came out with a stray line between items. So a dictation with a spoken
  line break or list marker goes to the model as one paragraph. Deep's check also turns down a
  bulleted list of two things (a sentence's "the invoice and the agreement" pulled apart) and a
  placeholder left on a line of its own (an emoji moved below its sentence), the two layouts the
  eval found wrong.
- **A rejected Deep answer gets Medium's pass**, not the uncleaned text, so choosing Deep never
  shows less than Medium would. Running Medium's pass first, on every dictation with a
  correction cue, took two passes and got fewer right (72 of the 114, against 88 in one pass).
- **Linux and Windows run the Mac app's cleanup, not a lookalike.** The prompts, OutputGuard,
  SelfRepair and the executor are ported to Rust (`lt-cleanup`) and held to the Swift code by
  fixtures the Mac app's tests write (`Fixtures/cleanup`). The model is the Mac's own 4-bit
  weights converted to OpenVINO with each adapter's matrices as inputs, so both adapters plug in
  unchanged and one compiled model serves every level. It runs on the app's own OpenVINO runtime
  (`lt-language-model`), since OpenVINO GenAI's bindings have no LoRA adapters and no control
  token by token.
- **Fillers and layout are rules, not model output.** A 1.7B model does neither reliably, and a
  rule can be tested exhaustively. Fillers are removed before the model runs; lists are laid out
  after it, only where line breaks are allowed. A letter's greeting and sign-off are found before
  the model runs and only its body is cleaned: shown a whole letter, the model moved the name in
  the sign-off into the greeting.
- **Line breaks are a per-app setting, not a field's report.** Only fields that reported a text
  area used to get lists and letters, which left out chat apps' message boxes, such as Slack's.
  Now every app is multi-line unless set otherwise, and only a field that certainly takes one
  line (a text field of the app's own window, never one in a web page) stays on one line.
- **Snippets and spoken commands are hidden from the model.** Each trigger, emoji, address, line
  break and list marker becomes a placeholder (`⟦S1⟧`) that the model must copy unchanged.
  OutputGuard rejects any output that alters one, and what it stands for goes back in only after
  cleanup. The model itself sees a plain word ("S1"): it stripped or dropped the bracketed tokens
  in 17 of 23 probe sentences, and kept 21 of 23 as words.
- **The shortcut is read with a `CGEventTap`**, which needs Accessibility. That is also the
  permission typing into other apps needs, so dictation asks for only two permissions. The tap
  runs on its own thread, and is re-enabled at once if macOS disables it.
- **Capture uses an input-only `AVCaptureSession`, not `AVAudioEngine`.** On macOS,
  `AVAudioEngine` stops whenever its audio device reconfigures, and a Bluetooth headset
  reconfigures every time its microphone opens, because it switches to its call profile.
  Restarting the engine reopened the microphone, so capture looped. A capture session has no
  output side and keeps running through the switch. It also delivers 16 kHz mono directly and
  opens the chosen microphone by its ID.
- **The cleanup prompt is multi-turn.** Each previous segment becomes a user `TEXT:` turn
  followed by an assistant turn holding its cleaned text, and the new segment is the last user
  turn. With the context inlined into a single message, the model sometimes echoed the context
  back and OutputGuard rejected the output for its word count. With multi-turn, fallbacks on a
  set of hard prompt cases went from 1 in 10 to none. Dictation cleans each dictation on its own,
  without context.
- **The Hugging Face downloader and tokenizer adapters are hand-written**
  (`Cleanup/HuggingFaceAdapters.swift`) instead of using mlx-swift-lm's `MLXHuggingFace` macros,
  which would need Xcode's macro-trust prompt. That makes `swift-huggingface` and
  `swift-transformers` direct dependencies; both were already indirect ones.
- **`mlx-audio-swift` is pinned by revision** (the commit of tag v0.1.3), not by version. It uses
  `unsafeFlags`, which SwiftPM accepts only from packages pinned by revision or by local path.
- **Speech models are loaded by kind** (`Transcription/SpeechModelKind.swift`): the app reads
  `model_type` from a model's config.json and loads it from its folder, downloaded or local, with
  mlx-audio-swift's loader for that kind. The list mirrors mlx-audio-swift's own `STT.loadModel`,
  aliases included, so an update that adds or renames a model needs the same change there.
- **The speech model catalog is a file both apps read**
  (`Transcription/Resources/speech-models.json`), built in and never fetched. Each model has a
  download per platform, and the Mac's is a Hugging Face repository pinned to a commit, so a
  release downloads what was tested with it; `scripts/pin-speech-model.sh` prints a repository's
  commit and download size. A catalog model is downloaded into the Hugging Face cache and loaded
  from its snapshot there (`SpeechModelDownloads`), not copied into `mlx-audio/` as mlx-audio-swift
  copies any other repository, and falls back to such a copy, made by an earlier version, when
  its commit can't be downloaded. Only licences that allow commercial use are listed
  (`SpeechModelCatalogTests`).
- **The speech model switches without a restart.** A new Speech-to-text setting reaches
  `SessionCoordinator.useSpeechModel`, which loads it once nothing uses the model: at once, or
  when the live transcript or the loading under way ends. `MLXTranscriber` downloads first, while
  the old model keeps transcribing, then drops it before loading the new one, so the two are never
  in memory together; a transcription asked for meanwhile waits. The Linux and Windows app does
  the same.

More decisions, and the assumptions behind them, are in [dictation.md](dictation.md).
