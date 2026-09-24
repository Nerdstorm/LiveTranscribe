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
| D6 | Local builds can be signed with a developer's own certificate through a gitignored `Config/Signing.local.xcconfig`, so macOS keeps the Accessibility and microphone grants across rebuilds. An ad-hoc build's designated requirement is its code hash (`cdhash`), which every build changes; a certificate's names the certificate. The committed default stays ad-hoc, so the public repository holds no team ID and builds anywhere. | Owner |
| H1 | Default hotkey: Fn (🌐), changeable in Settings. Settings open from the menu bar. | Owner |
| H2 | History is on by default and keeps everything until turned off or given a retention limit. It stays on this Mac and is never synced. | Owner |
| M1 | With **System Default** selected, capture follows macOS's default input as it changes, including mid-session, so a newly connected microphone (which macOS usually makes the default) is picked up without a restart. Virtual and aggregate devices are never followed automatically. | Owner |
| L1 | The structure of a dictation (a list, a letter) is found and laid out by deterministic rules; the D5 model only cleans the words. A new structure is one more rule in `Layout`. | Owner |
| L2 | List items keep the speaker's words: layout moves and punctuates, never rewords. | Owner |
| L4 | Line breaks (lists, letters, list markers, "new line") are decided per app: every app is multi-line unless the user, or the built-in list (terminals), sets it single-line. In a multi-line app a field that is certainly single-line stays single-line: a text field or combo box of the app's own interface, never one in a web page. This replaced laying out only in fields that report `AXTextArea`, which missed chat apps' message boxes such as Slack's. | Owner |
| L3 | At High, a dictation with a correction cue is cleaned in two passes: Medium's prompt, which the adapter was trained on, resolves the correction, then High's rewords the result within the same deadline. A rejected rewording keeps the first pass, which is not a fallback. D5 stands. | Owner |

### Assumptions made without the owner (review these)

- **Microphone opens on key-down.** Keeping it open all the time would meet the 50 ms start
  target and the 300 ms pre-roll trivially, but leaves the orange microphone indicator on for as
  long as the app runs. The default opens capture on key-down; Settings has *Keep the microphone
  ready*, which keeps it open with a 300 ms rolling pre-roll for instant starts.
- **No Dock icon.** The app lives in the menu bar (`LSUIElement`). It becomes a regular app
  (Dock icon, main menu) only while one of its windows is open, so ⌘C, ⌘W etc. work there.
- **Continuous mode and dictation don't overlap.** While the live transcript is listening, the
  dictation hotkey shows *Stop the live transcript to dictate* instead of recording, and the menu
  bar menu lists *Stop Live Transcript* (`MenuBarStatus.canStopLiveTranscript`).
- **Closing the live transcript window stops it** (the lead's call in review). Closing it used to
  quit the app; the menu bar app now keeps running, and a transcript left listening with no
  window kept the microphone open, saved everything said nearby and refused every dictation.
  `WindowPresenter` calls `TranscriptViewModel.stopListening()`, which stops only a listening
  session and never starts one. A Start still opening the microphone when the window closes is
  stopped as soon as it reports listening. Keeping it running in the background, with a prompt on
  close, was the alternative.
- **Settings keeps one view per window.** `SettingsNavigation` holds the selected tab, so asking
  for a tab (History's *History Settings…*, setup's *Choose Another Shortcut…*) switches the open
  window instead of rebuilding it, which threw away an editor sheet and its unsaved draft. While a
  sheet is open the tab stays as it is and the window only comes forward, because switching away
  from the tab that opened the sheet can close it, and at best leaves it over the wrong tab.
  Settings reopens on the tab it last showed.
- **The cleanup level applies to both modes.** Medium removes fillers in the live transcript too.
  Snippets and vocabulary apply only to dictation.
- **A chosen microphone that disconnects** falls back to the system default with a notice
  (the handoff's F6), replacing the old behaviour of stopping capture.
- **Fillers are removed deterministically** (um, uh, er, …) before the LLM at Medium and High,
  and **spoken lists are laid out deterministically** after it, only where line breaks are
  allowed (L4).
  A 1.7B model does neither reliably, and a rule can be tested exhaustively.
- **A letter's greeting and sign-off are laid out before the model runs**, and only the body is
  cleaned. Layout was planned to run after cleanup (L1), but given a whole letter the model moved
  the name in the sign-off into the greeting ("Hi John … cheers Sam" became "Hi Sam, … Cheers.")
  and the guard accepted it. A letter needs a greeting at the start and a sign-off at the end;
  "Thanks", "Cheers", "Best" and "Love" count as sign-offs only before a name, so a chat message
  ("Hi John, can you send it? Thanks") is left alone.
- **OutputGuard keeps names in place and content words in, at every level.** In a single-line
  field there is no letter frame, and the model still moved the sign-off's name into the
  greeting; at High, rewording was checked for length and similarity only, and dropped "milk"
  from a shopping list. Now a name (a capitalised word that does not start a sentence) must stay
  where it was said, or be respelled there, and a word that is not a function word ("the", "of",
  "is", "really") may not be deleted with nothing in its place. Rewording may still replace,
  reorder, respell and merge words, and write numbers as digits. Function words are a fixed list
  rather than NLTagger's parts of speech: a list is deterministic and testable, and a tagger's
  errors on unpunctuated speech would decide what counts as content. On 860 texts without a
  correction cue, cleaned at High by the model, the two checks rejected only 2 answers the old
  guard accepted, and both had changed the meaning.
- **Spoken commands apply at every level, in dictation only**, like snippets: emoji by name,
  punctuation by name, "new line" and "new paragraph", and email and web addresses. They are
  words, not commands, after a determiner or possessive ("a question mark", "the fire emoji",
  "Apple's new line"). "Period", "colon" and "dash" never are commands. The user's snippets are
  matched first, so a snippet with the same words replaces a built-in command.
- **"Fireworks" is 🎆** (Unicode FIREWORKS); 🎇 is FIREWORK SPARKLER, said "sparkler". A
  snippet can remap either.
- **The cleanup model sees each placeholder as a word** ("S1"), not the bracketed token. The
  prompt probe showed it stripping or dropping `⟦S1⟧` in 17 of 23 sentences, so snippets had
  mostly been falling back at Medium; as words, 21 of 23 survived. It punctuates the words like
  names, so dictation drops commas next to an emoji that the speaker did not say.
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
  transcribed or inserted records nothing, rather than opening the microphone late and losing the
  first words. The HUD says *Press again to dictate: the last dictation was still being inserted*
  under *Transcribing…* and again once that dictation is in, so the message is seen however
  quickly it finishes; it is worded to be true at both times.
- **A dictation started from the menu** is hands-free: the shortcut stops it and Esc cancels it.
- **Undo AI edit** works only between dictations, never during one.
- **Undo AI edit puts back the uncleaned text, not the literal transcript.** F3 says undo
  "swaps to the raw transcript"; it is read as "the text before cleanup". Everything cleanup
  changed is taken back (fillers, punctuation, casing, rewording, layout, and spoken list
  markers go back to the words said), but snippet expansions, spoken commands and vocabulary
  spellings stay: the user set those up or asked for them, and turning a snippet back into its
  spoken trigger would not help anyone. History keeps the literal transcript.
- **Undo after a paste checks the field, not what it holds.** A paste records no range, and
  reading a field's whole value after every paste would block on large fields (a terminal's
  scrollback) and misfire where the app changes the value by itself (live terminal output,
  rich-text reformatting). So undo refuses when another field has focus, whenever Accessibility
  sees the field at both ends, but not when the user typed more in the same field: ⌘Z then
  undoes that typing first. An Accessibility insertion is checked for both. Apps whose
  accessibility is off (Electron apps such as Slack, until something turns it on) may report no
  field, or one element for the whole window; there only the app is checked.
- **The self-correction adapter is on only at Medium and High.** It resolves corrections
  whatever the prompt says, so at Light (every word kept) it is switched off per request and
  the base model cleans up.
- **Microphone notices** (a new default, a fallback, a skipped virtual default) appear in the
  HUD once, and again only after the set of microphones changes, since dictation reopens the
  microphone on every press. A chosen microphone that reconnects is switched back to
  automatically. When the macOS default input is a virtual device, a physical microphone is used
  unless none is connected.
- **Notices about the dictation in progress show under *Listening*.** With the microphone
  opening on key-down, capture reports a fallback while the dictation is already recording. The
  notice takes the hint's line (*Listening* / *Transcribing…*) for `dictationNoticeSeconds`, then
  the hint comes back, and it is shown again once the dictation ends. That second showing is when
  VoiceOver announces it (nothing is announced while the microphone is open, or it would be
  dictated) and when someone watching their text rather than the HUD sees it. Only the latest
  microphone notice of a dictation is repeated: an earlier one no longer describes the
  microphone in use. Every notice capture reports is therefore shown, so counting it as shown
  when it arrives (`CaptureNoticeFilter`) is correct.
- **Notices at the end of a dictation follow one another** instead of the most recent hiding
  the rest, each for `dictationNoticeSeconds`: first where the text went, if it needs attention
  (on the clipboard, not inserted, a password field); then what the recording missed (the
  length limit, or the microphone stopping); then the notices from during the dictation. Any
  still waiting when the next dictation starts are dropped, since they were about the last one.
- **A microphone that stops mid-dictation ends it.** When capture fails for good during a
  recording (a Bluetooth headset disconnects on a Mac with no other microphone), the recording
  ends at once instead of showing *Listening* while nothing arrives. What was heard is
  transcribed and inserted, the HUD says *The microphone stopped after 12 s; the rest wasn't
  heard*, and the history record keeps the reason (`captureFailure`). If too little was heard to
  transcribe, the HUD says *The microphone stopped:* and the reason instead of *Didn't catch that*.
- **Durations in messages are written out in English** ("30 s", "1 min 30 s"), not formatted for
  the locale, like every other message (D4).
- **The HUD mentions Esc only when Esc works.** Esc is caught by the shortcut's keyboard tap, which
  does not run when dictation is off in Settings, Accessibility is missing, or the tap failed. A
  dictation started from the menu in those states shows *Finish from the menu bar · × to cancel*,
  and the × button's tooltip says *Cancel* without *(esc)*.
- **Settings apply after a short settle** (`settingsApplyDelayMs`, 300 ms), and the hotkey
  monitor restarts only when a shortcut changes, so editing other settings never interrupts a
  dictation. New timing takes effect once the current gesture ends.
- **Models are shared.** Dictation uses the transcript session's transcriber and cleaner, so they
  load once; dictation is available as soon as the session's models are.
- **Focus that moves while a dictation is processed.** The field is read when the key is
  released, and paste goes wherever the focus is when ⌘V is posted, up to seconds later. So paste
  reads the focus again just before it writes the pasteboard. A secure field now gets nothing,
  not even a clipboard copy, as if it had been focused all along. Another app now (a different
  process, so a relaunch counts) gets nothing either: the text goes on the clipboard, and the
  notice says another app took focus rather than that the app dictated into refused it. Only
  the app is compared, not the field: tabbing to another field of the same app pastes there, as
  typing would, and a stricter element comparison could turn pastes into clipboard copies in the
  apps that are pasted into, whose Accessibility elements are the least dependable.
  Accessibility insertion writes to the field that was read, wherever the focus is, so it needs
  no check.
- **The automatic space needs `AXStringForRange`.** Deciding whether dictated text needs a leading
  space reads the selection and then at most 16 UTF-16 units before it, never the whole field,
  which can be a multi-megabyte document. An app without that attribute gets no automatic space.
  The 16 is not a setting: it only has to hold one character (the longest standard emoji
  sequences are 15 units), and a longer one is cut to a tail that spacing treats the same way.
- **History retention is kept while the app runs.** Besides at launch and on a settings change,
  history past *Keep dictations for* is deleted every `historyPruneIntervalMinutes` (60) and
  after a saved dictation once that long has passed since the last prune, so a menu bar app left
  running for weeks keeps to it. The History window hides records past the retention whenever
  it loads.
  The interval is not shown in Settings.
- **Cleanup turned off in Advanced is a choice, not a failure.** Like the model, the switch is
  read at launch. Without the model, Medium and High still remove fillers and lay out spoken
  lists and letters, nothing is reworded, and dictations are not marked *Cleanup didn't apply*; the live
  transcript shows the raw text. General's cleanup note describes the switches in effect since
  launch and says when a change in Advanced waits for a restart.
- **The Accessibility prompt is remembered for the launch** by setup and Settings alike: macOS
  shows it once per launch, so after either has shown it, *Grant Access…* in Settings opens
  System Settings instead.
- **Pasting that macOS refuses is fixed by reopening the app.** Inferred from one Mac's logs,
  not yet confirmed: after the Accessibility entry was removed and added back while the app ran,
  `AXIsProcessTrusted` returned true and the keyboard tap restarted, but
  `CGPreflightPostEventAccess` stayed false, so every ⌘V was dropped and pasted apps got nothing.
  A new process is assumed to be checked afresh. So paste checks `CGPreflightPostEventAccess`
  before it touches the pasteboard (`pasteNotPermitted`), and the notice says *Quit and reopen
  Live Transcribe so it can paste* when Accessibility is on (*Allow Live Transcribe in
  Accessibility* when it is off) instead of blaming the app. Setup and Settings › Permissions
  show the state (*Allowed, but can't paste yet*) with *Reopen Live Transcribe*, which starts a
  shell that waits for this process to exit before opening the app again, so two instances never
  hold the microphone and the keyboard tap at once. Setup counts Accessibility as done only once
  pasting is allowed too; the menu's *Set Up Dictation…* still follows the permissions alone.

## Architecture

New package targets (vertical slices), each with its own test target:

| Target | Owns | Depends on |
|---|---|---|
| `Styles` | `FillerRemover`, and `Layout` with its rules: `LetterFrame` (before cleanup), `MarkedListLayout` and `OrdinalListLayout` (after), `ListMarkerCommand`, `ListStyle`, `ListFormatter` | Shared |
| `SpokenCommands` | `EmojiCommand` (with `EmojiNames`), `PunctuationCommand`, `LineBreakCommand`, `AddressCommand`: phrase matchers for commands said aloud | Shared |
| `Snippets` | `Snippet`, `SnippetStore`, `SnippetExpander` | Shared |
| `Vocabulary` | `VocabularyEntry`, `VocabularyStore`, `VocabularyReplacer`, `VocabularySelector` | Shared |
| `Hotkey` | `HotkeyBinding`, `HotkeyGesture` (pure state machine), `HotkeyMonitor`, `CGEventTapHotkeyMonitor` | Shared |
| `Insertion` | `TextInserter`, `AXTextInserter`, `PasteboardTextInserter`, `InsertionRouter`, `AppOverrides` (per-app method and `LineMode`), `SingleLineField`, `FocusedElement` | Shared |
| `Permissions` | Microphone and Accessibility status, prompts, System Settings links | Shared |
| `Dictation` | `DictationController` (the flow, including Undo AI edit), `DictationRecorder`, `DictationProcessor` with `PreparedDictation` (phrases, placeholders and layout around cleanup), `TextDelivery` | all of the above, Capture, Transcription, Cleanup, Persistence |
| `DictationUI` | menu bar content and icon, HUD panel, history window, onboarding, Settings tabs, readiness from the session, reopening the app | Dictation, TranscriptUI, Session, … |

Changed slices:

- **Shared**: `CleanupLevel`, because `AppSettings` carries it and four slices read it; the
  placeholder token format (`⟦S1⟧`), which the phrase protector writes and Cleanup checks;
  `PhraseProtector`, which runs every `PhraseMatcher` (snippets, spoken commands, list markers)
  over a transcript and keeps what each placeholder stands for, with its role (content, line
  break, structure) deciding when it is put back; `PhraseGrammar` and `SentenceCase`, the word
  rules the matchers and layout share;
  `SyntheticEventMarker`, the tag Insertion puts on the keys it posts and Hotkey's tap reads.
- **Cleanup**: `Prompt` becomes `PromptBuilder`: base rules + level rules + vocabulary +
  placeholder rule + prior context, each a separately tested function. `Cleaner.clean` takes
  `CleanupOptions` (level, vocabulary terms, placeholder tokens, multi-line). `OutputGuard`
  takes the level's word-ratio bounds and rejects output that alters a placeholder, drops or
  moves a name (`SpokenNames`) or leaves out a content word (`ContentWords`); those checks and
  `DroppedWords` share one `WordAlignment` of the words said with the words returned.
  `PlaceholderAliases` shows the model a plain word for each token and swaps the tokens back
  before the guard. `CleanupExecutor` runs High in two passes when there is a correction cue
  (L3).
- **Capture**: devices report whether they are virtual; capture follows the default input (M1).
  `MicrophonePickerList` is the one rule for what the three microphone pickers (the menu bar,
  Settings › General, the live transcript window) list: virtual devices only with
  *Show other devices* on, unless one is chosen, and a chosen microphone that is not connected,
  by the name last seen. *System Default* names the microphone capture would open for it at the
  next start, so a virtual default input is not named when a physical one is used.
- **Persistence**: `DictationRecord` and `DictationHistory` (JSON Lines, pruning). A record
  keeps `captureFailure` when the microphone stopped partway through; older records read back
  without it.
- **Session**: the continuous pipeline passes `CleanupOptions` from settings.
- **App**: no sandbox, menu-bar app (`LSUIElement`), composition of the dictation flow, and
  `WindowPresenter`, which opens every window with AppKit, switches the activation policy, stops
  the live transcript when its window closes and switches Settings tabs through
  `SettingsNavigation`.

### Dictation flow

"Line breaks" below is decided once, when the key is released, from the app's line setting and
the focused field (L4, and *Line breaks* further down).

```
Hotkey down ─▶ record (pre-roll if the mic is kept ready)
Hotkey up ───▶ discard if < 300 ms
             ─▶ transcribe the whole buffer (Parakeet)
             ─▶ phrases → ⟦S1⟧ placeholders: snippets first, then emoji, addresses and
                line breaks; list markers too (Medium+, line breaks); punctuation said
                by name is written in directly
             ─▶ vocabulary: known spoken variants → canonical spelling
             ─▶ level None: breaks and commands put back; done
             ─▶ remove fillers (Medium, High); a letter's greeting and sign-off laid out
                (Medium+, line breaks), only its body goes on
             ─▶ LLM cleanup (level rules + vocabulary + placeholder rule + context), tokens
                shown as words; High with a correction cue: Medium pass, then High pass;
                skipped with OutputGuard when cleanup is off in Advanced (read at launch)
             ─▶ OutputGuard (level bounds, placeholders intact, names in place, no content
                word left out) — else the pre-LLM text
             ─▶ line breaks and list markers put back and tidied; lists laid out
                (Medium+, line breaks); then snippets, emoji and addresses
             ─▶ insert at the cursor (AX, else paste, else clipboard + HUD)
             ─▶ history (raw + cleaned), undo buffer
```

Esc cancels at any point before insertion, while the shortcut's keyboard tap runs; the HUD's ×
button and the menu always can. Nothing is inserted into secure (password) fields, including one
focused while the dictation was processed, and nothing is recorded in history for a cancelled
dictation.

### Hotkey gestures

- Hold ≥ 300 ms, release: push-to-talk; the recording is processed.
- Tap (< 300 ms) then press again within 300 ms: hands-free; the next tap stops and processes.
- A single tap: cancelled (too short to be speech).
- Esc while recording or processing: cancel.
- Any other key pressed while a modifier-only hotkey (Fn, right ⌥, …) is held: the user is
  typing a shortcut, so the recording is cancelled silently.
- Fn conflicts with macOS's *Press 🌐 key to* setting; Settings shows a warning with the fix
  unless it is set to *Do Nothing*.
- Standard macOS shortcuts (⌘C, ⌘V, ⌘Z, ⇧⌘Z, ⌘W, ⌘Q, ⌘Tab, ⌘Space, ⌃Space, ⌃ and an arrow,
  and a few more, listed in `Hotkey/ReservedShortcuts.swift`) can't be chosen for dictation or
  undo: the tap would take them from every app. ⌃⌥Space stays allowed: macOS uses it only to
  step through several input sources, and apps leave it alone.
- The ⌘V and ⌘Z the app posts itself (a paste, Undo AI edit) carry `SyntheticEventMarker` in
  `eventSourceUserData`, and the tap passes them through untouched: not swallowed, not a
  shortcut, not another key. Without the tag, the ⌘Z that undo posts while the Z of ⌃⌥Z is
  still held was swallowed as that key's repeat. Other apps' posted keys count as typing.
- While Settings records a new shortcut, the shortcuts are paused so every key reaches the
  recorder. A dictation being recorded then is dropped silently, and the menu's *Start
  Dictation* says to finish recording first. They resume however recording ends.

### Insertion

1. `AXTextInserter`: set `kAXSelectedTextAttribute` on the focused element and verify by
   re-reading its value. Used only when the value is readable before and after.
2. `PasteboardTextInserter`: snapshot every pasteboard item and type, read the focus again,
   write the text (marked transient so clipboard managers skip it), post ⌘V, restore the snapshot
   after 250 ms unless the pasteboard changed in the meantime. If macOS doesn't let the app post
   keystrokes, or the focus is now secure or in another app, nothing is written or pasted
   (`pasteNotPermitted`, `focusBecameSecure`, `focusMovedToAnotherApp`).
3. Otherwise the text stays on the clipboard, and the HUD says why (`ClipboardReason`): the app
   refused it, another app took focus, or macOS doesn't let the app paste.

Per-app settings (`AppOverrides`: bundled defaults for terminals, Electron and Chromium apps;
user entries in Settings › Apps, stored in `insertion-overrides.json`) pick paste first and
decide line breaks. Secure fields (`AXSecureTextField`, or secure event input active) get
nothing, whether they were focused when the key was released or only when the paste ran.

### Line breaks

`TextDelivery.allowsLineBreaks(in:)` answers once per dictation, while the snippets and
vocabulary load, and the answer is `DictationProcessor.Configuration.multiline`:

1. An app set to **Single-line** (the seven terminals out of the box, since a pasted line break
   can run a command) gets none: lists and letters stay in the sentence, list markers stay
   words, and "new line" types a space.
2. An app set to **Multi-line**, or with no setting, gets them, unless the field is certainly
   single-line (`SingleLineField`): its role is `AXTextField` (search fields report it too) or
   `AXComboBox`, and its ancestors reach `AXWindow` or `AXApplication` without passing
   `AXWebArea`. Browsers and Electron apps report a rich text box that the page doesn't mark
   `aria-multiline` as a text field, so a field in a web page is never certain. An ancestor that
   can't be read, or no window within 64 levels, isn't certain either. The walk costs two
   Accessibility calls a level, only for a field with a single-line role.
3. With no focused element (an app that hides its fields), a multi-line app gets them.

A user setting wins over the built-in one, setting by setting; `lines` is written to the file
only when there are line settings, so earlier versions still read it.

The leading space before dictated text comes from the character before the caret, read off the
main actor with `kAXSelectedTextRangeAttribute` and `kAXStringForRangeParameterizedAttribute`
(`AccessibilityElement.characterBeforeSelection()`), never by copying the field's value.

### Undo AI edit

⌃⌥Z within 30 s of an insertion, in the same app and field: select the inserted range via AX
and replace it with the uncleaned text; otherwise send ⌘Z and insert the uncleaned text. The
uncleaned text is the dictation before cleanup, with snippets, spoken commands and vocabulary
still applied, list markers as they were said and nothing laid out (see *Assumptions*).

Undo refuses, changing nothing, when another app is in front, when another field of the same
app has focus (checked for pasted text too, whenever Accessibility sees the field when it is
inserted and when undo is pressed), when an Accessibility insertion was edited since, and in a
password field. A refused undo can be tried again within the window, for example after clicking
back into the dictated field.

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
| `historyPruneIntervalMinutes` | 60 |
| `dictationNoticeSeconds` | 2.5 |
| `inputDeviceUID` | system default |

Files in `~/Library/Application Support/org.nerdstorm.LiveTranscribe/`, owner-only (0600):
`snippets.json`, `vocabulary.json`, `insertion-overrides.json` (the user's per-app insertion
methods and line settings; the bundled ones are in code) and `History/dictations.jsonl`.

Dictation settings apply immediately; model and segmentation settings (Settings › Advanced)
still apply at the next launch. Advanced's Restore Defaults resets only the settings on that tab
(`AppSettingsKey.advancedTab`): the dictation settings, shortcuts, cleanup level, history and
microphone stay as they are.

## Testing

- Unit tests with fakes for every slice: gesture state machine, prompt composition per level,
  snippet matching and placeholder round trips (including a property test with random
  snippets), spoken commands, vocabulary replacement, level guard bounds, filler removal, list
  and letter layout, placeholder aliases, two-pass High,
  inserter ordering with a fake AX layer, pasteboard snapshot and restore, device policy and
  fallback, history pruning, the dictation controller with fake audio, transcriber, cleaner and
  inserter, and the Settings, menu and editor models.
- Eval set: `Tests/IntegrationTests/Fixtures/Dictation/clips.tsv`, 65 clips (plain,
  fillers, self-corrections, long, questions, emoji, dictated punctuation, addresses, line
  breaks, lists and letters), each with what is said and what is meant, laid out as in a
  multi-line field. `scripts/generate-dictation-audio.sh` synthesises them; `Bench --dictation`
  runs each through the dictation processor at every level and reports WER against both
  references, fallbacks and latency; with `--multiline` it dictates into a multi-line field and
  also counts the clips that come out with the intended lines. Snippets and vocabulary are
  covered by unit tests rather than clips.
- Prompt probe (`PromptProbeTests`, run with `TEST_RUNNER_LT_PROMPT_PROBE=1`): prints the
  model's answers for hard cases, and compares prompts, placeholder token formats and visible
  emoji. `compareContentChecksAtHigh` cleans every cleanup example in `Training/` at High and
  prints the answers the name and content checks reject that the guard accepted before them.
- Manual QA (needs a person): the F2 app list, full screen, multiple displays, light and dark,
  plugging in and removing microphones mid-dictation, a virtual default input.

### Eval results

M4 Pro, macOS 27, synthetic speech (Samantha), latency = speech-to-text + cleanup
(9df55e4), 65 clips. Dictating into a multi-line field (`--multiline`):

| Level | WER vs said | WER vs meant | Fallbacks | p50 | p95 | Laid out as meant |
|---|---:|---:|---:|---:|---:|---:|
| None | 10.9% | 20.1% | 0 | 34 ms | 66 ms | 57/65 |
| Light | 11.1% | 19.9% | 2 | 162 ms | 325 ms | 57/65 |
| Medium | 21.8% | 2.2% | 3 | 185 ms | 423 ms | 65/65 |
| High | 21.8% | 2.2% | 3 | 210 ms | 426 ms | 65/65 |

Into a single-line field:

| Level | WER vs said | WER vs meant | Fallbacks | p50 | p95 |
|---|---:|---:|---:|---:|---:|
| None | 10.9% | 20.1% | 0 | 35 ms | 67 ms |
| Light | 11.1% | 19.9% | 2 | 174 ms | 353 ms |
| Medium | 20.2% | 5.0% | 5 | 199 ms | 457 ms |
| High | 20.2% | 5.0% | 5 | 232 ms | 441 ms |

Every level is well under the p95 target of 1.2 s. At Medium and High all 12 self-corrections
and all 10 filler clips come out as meant, and in a multi-line field every list and letter is
laid out. WER against what was said counts spoken commands as wrong, since they are replaced by
what they name; the 44 clips from before the commands score as they did (Medium: 1.8% against
what was meant, one fallback).

The fallbacks:
- "I've attached the invoice and the signed agreement." at Medium and High: the adapter
  mistakes a plain sentence for a correction.
- Two lists at Medium and High, multi-line: the model rewrote the bulleted one, dropping three
  of its words, and dropped an item from the numbered one. The uncleaned text is still laid out.
- In a single-line field, where lists are not laid out, both lists at Medium and High: the model
  dropped the words "bullet point" or "number", which are not commands there, to lay the list
  out itself. At Light it did the same to the numbered list in both kinds of field.
- In a single-line field, the passport letter at Medium and High (the model changed more than
  the self-correction), and "hi John … cheers Sam" at Medium and High, which the model turned
  into "Hi Sam, … Cheers."; in a multi-line field the letter frame keeps the names where they
  were said.
- The passport letter at Light, where resolving the correction is not allowed.

The name and content checks (9df55e4) added the fallbacks for the numbered list, the bulleted
list at High and the letter with the moved name; before them OutputGuard accepted those outputs
(ledger LiveTranscribe-0103, LiveTranscribe-0104). In a single-line field that raises High's
WER against what was meant from 3.8% to 5.0%, since the lists the model had numbered itself now
come out as said. Every other output is unchanged, and so is latency: two passes in opposite
orders put the difference within run-to-run variation.

The time from releasing the key to the text appearing adds the recorder stop and insertion, a
few milliseconds each, which the controller logs.
