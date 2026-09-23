# System-wide dictation: design

This branch turns Live Transcribe into a system-wide, on-device dictation tool: hold a hotkey,
speak, and cleaned text is inserted at the cursor in any app. The continuous transcript window
stays as a second mode. It implements Phase 1 (F1–F7) of the *Dictation Features —
Implementation Handoff*, plus following a newly connected microphone. Phase 2 (per-app tone,
focus context, Command Mode, multilingual) is not started.

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | Developer ID distribution without the App Sandbox (rules out the Mac App Store). Hardened Runtime stays; builds stay ad-hoc signed ("Sign to Run Locally") until someone signs a release with their Developer ID. | Owner |
| D2 | Push-to-talk is the primary mode; the continuous transcript window stays. | Handoff |
| D3 | Default cleanup level: Medium. | Handoff |
| D4 | English only in v1. | Handoff |
| D5 | Models stay Parakeet TDT 0.6B v3 + Qwen3-1.7B-4bit (+ Silero VAD). No 4B or larger model, now or for Command Mode. | Owner |
| H1 | Default hotkey: Fn (🌐), changeable in Settings. Settings open from the menu bar. | Owner |
| H2 | History is on by default and keeps everything until turned off or given a retention limit. It stays on this Mac and is never synced. | Owner |
| M1 | With **System Default** selected, capture follows macOS's default input as it changes, including mid-session, so a newly connected microphone (which macOS usually makes the default) is picked up without a restart. Virtual and aggregate devices are never followed automatically. | Owner |

### Assumptions made without the owner (review these)

- **Microphone opens on key-down.** Keeping it open all the time would meet the 50 ms start
  target and the 300 ms pre-roll trivially, but leaves the orange microphone indicator on for as
  long as the app runs. The default opens capture on key-down; Settings has *Keep the microphone
  ready*, which keeps it open with a 300 ms rolling pre-roll for instant starts.
- **No Dock icon.** The app lives in the menu bar (`LSUIElement`). It becomes a regular app
  (Dock icon, main menu) only while one of its windows is open, so ⌘C, ⌘W etc. work there.
- **Continuous mode and dictation don't overlap.** While the live transcript is listening, the
  dictation hotkey shows *Stop the live transcript to dictate* instead of recording.
- **The cleanup level applies to both modes.** Medium removes fillers in the live transcript too.
- **A chosen microphone that disconnects** falls back to the system default with a notice
  (the handoff's F6), replacing the old behaviour of stopping capture.
- **Fillers are removed deterministically** (um, uh, er, …) before the LLM at Medium and High,
  and **spoken lists are formatted deterministically** after it, only for multi-line fields.
  A 1.7B model does neither reliably, and a rule can be tested exhaustively.
- **High** allows light rewording for grammar. On a 1.7B model it behaves close to Medium; real
  restructuring would need a larger model, which D5 rules out.
- **The `Dictionary/` slice is named `Vocabulary`**, because a module called `Dictionary` would
  shadow Swift's `Dictionary` type in every file that imports it.
- **The `AudioDevices/` slice stays inside `Capture`**, which already owns device listing and
  selection; splitting it would move code without changing behaviour.
- **History lives in `Persistence`** as the handoff says (a `DictationRecord` type), as JSON Lines.
- **The microphone opens while the focused field is read.** Reading it through Accessibility can
  wait up to `accessibilityTimeoutMs` on a busy app, which would lose the first word. If the
  field turns out to be a password field, the recording is thrown away before anything is
  transcribed; the microphone indicator may flash.
- **One dictation at a time.** Pressing the shortcut while the last dictation is still being
  transcribed or inserted shows *Still inserting the last dictation* and records nothing, rather
  than opening the microphone late and losing the first words.
- **A dictation started from the menu** is hands-free: the shortcut stops it and Esc cancels it.
- **Undo AI edit** works only between dictations, never during one.
- **The self-correction adapter is on only at Medium and High.** It resolves corrections
  whatever the prompt says, so at Light (every word kept) it is switched off per request and
  the base model cleans up.
- **Microphone notices** (a new default, a fallback, a skipped virtual default) appear in the
  HUD once, and again only after the set of microphones changes, since dictation reopens the
  microphone on every press. A chosen microphone that reconnects is switched back to
  automatically. When the macOS default input is a virtual device, a physical microphone is used
  unless none is connected.
- **Settings apply after a short settle** (`settingsApplyDelayMs`, 300 ms), and the hotkey
  monitor restarts only when a shortcut changes, so editing other settings never interrupts a
  dictation. New timing takes effect once the current gesture ends.
- **Models are shared.** Dictation uses the transcript session's transcriber and cleaner, so they
  load once; dictation is available as soon as the session's models are.

## Architecture

New package targets (vertical slices), each with its own test target:

| Target | Owns | Depends on |
|---|---|---|
| `Styles` | `FillerRemover`, `ListFormatter`: the deterministic rules the levels turn on | Shared |
| `Snippets` | `Snippet`, `SnippetStore`, `SnippetExpander` | Shared |
| `Vocabulary` | `VocabularyEntry`, `VocabularyStore`, `VocabularyReplacer`, `VocabularySelector` | Shared |
| `Hotkey` | `HotkeyBinding`, `HotkeyGesture` (pure state machine), `HotkeyMonitor`, `CGEventTapHotkeyMonitor` | Shared |
| `Insertion` | `TextInserter`, `AXTextInserter`, `PasteboardTextInserter`, `InsertionRouter`, `InserterOverrides`, `FocusedElement` | Shared |
| `Permissions` | Microphone and Accessibility status, prompts, System Settings links | Shared |
| `Dictation` | `DictationController` (the flow, including Undo AI edit), `DictationRecorder`, `DictationProcessor`, `TextDelivery` | all of the above, Capture, Transcription, Cleanup, Persistence |
| `DictationUI` | menu bar content and icon, HUD panel, history window, onboarding, Settings tabs, readiness from the session | Dictation, TranscriptUI, Session, … |

Changed slices:

- **Shared**: `CleanupLevel`, because `AppSettings` carries it and four slices read it; the
  snippet placeholder token format (`⟦S1⟧`), which Snippets writes and Cleanup checks.
- **Cleanup**: `Prompt` becomes `PromptBuilder`: base rules + level rules + vocabulary +
  placeholder rule + prior context, each a separately tested function. `Cleaner.clean` takes
  `CleanupOptions` (level, vocabulary terms, placeholder tokens, multi-line). `OutputGuard`
  takes the level's word-ratio bounds and rejects output that alters a placeholder.
- **Capture**: devices report whether they are virtual; the picker hides virtual devices unless
  *Show other devices* is on; capture follows the default input (M1).
- **Persistence**: `DictationRecord` and `DictationHistory` (JSON Lines, pruning).
- **Session**: the continuous pipeline passes `CleanupOptions` from settings.
- **App**: no sandbox, menu-bar app (`LSUIElement`), composition of the dictation flow, and
  `WindowPresenter`, which opens every window with AppKit and switches the activation policy.

### Dictation flow

```
Hotkey down ─▶ record (pre-roll if the mic is kept ready)
Hotkey up ───▶ discard if < 300 ms
             ─▶ transcribe the whole buffer (Parakeet)
             ─▶ snippets: triggers → ⟦S1⟧ placeholders
             ─▶ vocabulary: known spoken variants → canonical spelling
             ─▶ level None: done; else remove fillers (Medium, High)
             ─▶ LLM cleanup (level rules + vocabulary + placeholder rule + context)
             ─▶ OutputGuard (level bounds, placeholders intact) — else the pre-LLM text
             ─▶ placeholders → expansions; lists → numbered lines (Medium+, multi-line only)
             ─▶ insert at the cursor (AX, else paste, else clipboard + HUD)
             ─▶ history (raw + cleaned), undo buffer
```

Esc cancels at any point before insertion. Nothing is inserted into secure (password) fields,
and nothing is recorded in history for a cancelled dictation.

### Hotkey gestures

- Hold ≥ 300 ms, release: push-to-talk; the recording is processed.
- Tap (< 300 ms) then press again within 300 ms: hands-free; the next tap stops and processes.
- A single tap: cancelled (too short to be speech).
- Esc while recording or processing: cancel.
- Any other key pressed while a modifier-only hotkey (Fn, right ⌥, …) is held: the user is
  typing a shortcut, so the recording is cancelled silently.
- Fn conflicts with macOS's *Press 🌐 key to* setting; Settings shows a warning with the fix
  unless it is set to *Do Nothing*.

### Insertion

1. `AXTextInserter`: set `kAXSelectedTextAttribute` on the focused element and verify by
   re-reading its value. Used only when the value is readable before and after.
2. `PasteboardTextInserter`: snapshot every pasteboard item and type, write the text (marked
   transient so clipboard managers skip it), post ⌘V, restore the snapshot after 250 ms unless
   the pasteboard changed in the meantime.
3. Otherwise the text stays on the clipboard and the HUD says so.

Per-app overrides (bundled defaults for terminals, Electron and Chromium apps; user entries in
Settings) pick paste first. Secure fields (`AXSecureTextField`, or secure event input active)
get nothing.

### Undo AI edit

⌃⌥Z within 30 s of an insertion, in the same app: select the inserted range via AX and replace
it with the raw transcript; otherwise send ⌘Z and insert the raw transcript.

## Settings

All in UserDefaults (keys are `AppSettingsKey` raw values), read at each use.

| Setting | Default |
|---|---|
| `dictationEnabled` | on |
| `dictationHotkey` / `undoHotkey` | Fn / ⌃⌥Z |
| `handsFreeEnabled` | on |
| `cleanupLevel` | Medium |
| `hotkeyTapMaxMs` / `hotkeyDoubleTapWindowMs` | 300 / 300 |
| `dictationMinUtteranceMs` / `dictationMaxRecordingSeconds` | 300 / 300 |
| `keepMicrophoneReady` / `dictationPreRollMs` | off / 300 |
| `undoWindowSeconds` / `undoSettleDelayMs` | 30 / 150 |
| `pasteRestoreDelayMs` | 250 |
| `accessibilityTimeoutMs` / `accessibilityVerificationDelayMs` | 250 / 75 |
| `permissionPollMs` / `settingsApplyDelayMs` | 1000 / 300 |
| `vocabularyPromptLimit` / `vocabularySimilarityThreshold` | 50 / 0.8 |
| `showVirtualInputDevices` | off |
| `historyEnabled` / `historyRetentionDays` | on / 0 (keep everything) |
| `dictationNoticeSeconds` | 2.5 |
| `inputDeviceUID` | system default |

Files in `~/Library/Application Support/org.nerdstorm.LiveTranscribe/`, owner-only (0600):
`snippets.json`, `vocabulary.json`, `insertion-overrides.json` (user entries; the bundled list
is in code) and `History/dictations.jsonl`.

Dictation settings apply immediately; model and segmentation settings (Settings › Advanced)
still apply at the next launch.

## Testing

- Unit tests with fakes for every slice: gesture state machine, prompt composition per level,
  snippet matching and placeholder round trips (including a property test with random
  snippets), vocabulary replacement, level guard bounds, filler removal, list formatting,
  inserter ordering with a fake AX layer, pasteboard snapshot and restore, device policy and
  fallback, history pruning, the dictation controller with fake audio, transcriber, cleaner and
  inserter, and the Settings, menu and editor models.
- Eval set: `Tests/IntegrationTests/Fixtures/Dictation/clips.tsv`, 44 clips (plain,
  fillers, self-corrections, long, questions), each with what is said and what is meant.
  `scripts/generate-dictation-audio.sh` synthesises them; `Bench --dictation` runs each through
  the dictation processor at every level and reports WER against both references, fallbacks and
  latency. Snippets, vocabulary and lists are covered by unit tests rather than clips.
- Manual QA (needs a person): the F2 app list, full screen, multiple displays, light and dark,
  plugging in and removing microphones mid-dictation, a virtual default input.

### Eval results

M4 Pro, macOS 27, synthetic speech (Samantha), latency = speech-to-text + cleanup
(be4d502):

| Level | WER vs said | WER vs meant | Fallbacks | p50 | p95 |
|---|---:|---:|---:|---:|---:|
| None | 1.9% | 24.2% | 0 | 32 ms | 59 ms |
| Light | 2.1% | 23.9% | 0 | 159 ms | 308 ms |
| Medium | 15.5% | 1.8% | 1 | 184 ms | 386 ms |
| High | 15.5% | 1.8% | 1 | 199 ms | 388 ms |

Every level is well under the p95 target of 1.2 s. At Medium and High all 12 self-corrections
and all 10 filler clips come out as meant. The one fallback ("I've attached the invoice and the
signed agreement.") is the adapter mistaking a plain sentence for a correction; OutputGuard
rejects it and the transcript is used. The time from releasing the key to the text appearing
adds the recorder stop and insertion, a few milliseconds each, which the controller logs.
