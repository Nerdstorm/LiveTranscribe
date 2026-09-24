# Design notes

Why Live Transcribe is built the way it is. Its two pipelines and the layout of the code are
in the README's [Architecture](../README.md#architecture).

- **The self-correction adapter is switched on per request**, only at Medium and High, so Light
  never resolves corrections.
- **The adapter is loaded as separate LoRA layers**, at the exact base-model commit it was
  trained on, not fused into the weights. Fusing re-quantizes the adapted weights to 4 bits, and
  the fused adapter resolved only 13% of self-corrections.
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

More decisions, and the assumptions behind them, are in [dictation.md](dictation.md).
