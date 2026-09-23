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

## Architecture

New package targets (vertical slices), each with its own test target:

| Target | Owns | Depends on |
|---|---|---|
| `Styles` | `CleanupLevel`, `FillerRemover`, `ListFormatter` | Shared |
| `Snippets` | `Snippet`, `SnippetStore`, `SnippetExpander` | Shared |
| `Vocabulary` | `VocabularyEntry`, `VocabularyStore`, `VocabularyReplacer`, `VocabularySelector` | Shared |
| `Hotkey` | `HotkeyBinding`, `HotkeyGesture` (pure state machine), `HotkeyMonitor`, `CGEventTapHotkeyMonitor` | Shared |
| `Insertion` | `TextInserter`, `AXTextInserter`, `PasteboardTextInserter`, `InsertionRouter`, `InserterOverrides`, `FocusedElement` | Shared |
| `Permissions` | Microphone and Accessibility status, prompts, System Settings links | Shared |
| `Dictation` | `DictationController` (the flow), `DictationRecorder`, `DictationProcessor`, `UndoController` | all of the above, Capture, Transcription, Cleanup, Persistence |
| `DictationUI` | menu bar content, HUD panel, history window, onboarding, settings panes | Dictation, TranscriptUI, … |

Changed slices:

- **Cleanup**: `Prompt` becomes `PromptBuilder`: base rules + level rules + vocabulary +
  placeholder rule + prior context, each a separately tested function. `Cleaner.clean` takes
  `CleanupOptions` (level, vocabulary terms, placeholder tokens, multi-line). `OutputGuard`
  takes the level's word-ratio bounds and rejects output that alters a placeholder.
- **Capture**: devices report whether they are virtual; the picker hides virtual devices unless
  *Show other devices* is on; capture follows the default input (M1).
- **Persistence**: `DictationRecord` and `DictationHistory` (JSON Lines, pruning).
- **Session**: the continuous pipeline passes `CleanupOptions` from settings.
- **App**: no sandbox, menu-bar app, composition of the dictation flow.

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

| Setting | Default | Where |
|---|---|---|
| `dictationHotkey` | Fn | UserDefaults |
| `handsFreeDoubleTap` | on | UserDefaults |
| `cleanupLevel` | Medium | UserDefaults |
| `undoWindowSeconds` | 30 | UserDefaults |
| `keepMicrophoneReady` | off | UserDefaults |
| `showVirtualInputDevices` | off | UserDefaults |
| `historyEnabled` / `historyRetentionDays` | on / 0 (keep everything) | UserDefaults |
| `inputDeviceUID` | system default | UserDefaults |
| snippets | none | `Application Support/org.nerdstorm.LiveTranscribe/snippets.json` |
| vocabulary | none | `…/vocabulary.json` |
| per-app insertion | bundled list + user entries | `…/insertion-overrides.json` |

Dictation settings apply immediately; model and segmentation settings still apply at the next
launch.

## Testing

- Unit tests with fakes for every slice: gesture state machine, prompt composition per level,
  snippet matching and placeholder round trips (including a property test with random
  snippets), vocabulary replacement, level guard bounds, filler removal, list formatting,
  inserter ordering with a fake AX layer, pasteboard snapshot and restore, device fallback,
  history pruning, and the whole dictation flow with fake audio, transcriber, cleaner and
  inserter.
- Eval set (`.models` tag and `Bench --dictation`): 40+ generated clips covering fillers,
  self-corrections, lists, dictionary terms, snippets and code dictation, with the expected
  output per level. Reports per-level WER, snippet integrity, fallback rate and latency.
- Manual QA (needs a person): the F2 app list, full screen, multiple displays, light and dark.
