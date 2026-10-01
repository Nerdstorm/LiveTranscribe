# Known limitations

## Cleanup and speech

- **Cleanup is written for English.** Text with Sinhala in it skips the cleanup model, which drops
  Sinhala's vowel signs when it copies them. It gets only the steps that need no model, as when
  cleanup is turned off: spoken commands (and on the Mac snippets and vocabulary), and from Medium
  up filler removal and layout, all of which listen for English words. The other languages go
  through the English cleanup, which hasn't been tested with them.
- The speech model learnt Sinhala from read sentences (OpenSLR 52). Conversation, strong accents
  and noise are untested, and Sinhala sentences that mix in a lot of English may not always come
  out in English letters.
- **Long dictations are untested.** The eval's longest clip is about 40 words. Cleanup runs on
  the whole dictation under a timeout (3 s, and 8 s at Deep), so a dictation longer than a minute
  or two will likely be inserted uncleaned (fillers still removed from Medium up), without a
  message. Cleanup takes about four times as long on Linux and Windows, so it happens sooner
  there; raise **Timeout** in **Settings › Advanced**. Past the recording limit (5 minutes by
  default) speech is dropped, and the panel says so only when you finish.
- Spoken self-corrections ("fuel efficiency in cars, sorry, buses" → "fuel efficiency in buses")
  are resolved by a small fine-tuned adapter trained on synthetic data, so expect lower accuracy
  on real speech than the 97% it scored on synthetic held-out examples. The check turns down any
  answer that drops a correction cue without a genuine correction ([Cleanup](cleanup.md)).
- The adapter occasionally rewrites a plain sentence (1 of 65 eval clips); the check catches it
  and the dictation is inserted without the model (fillers removed from Medium up, lists and
  letters still laid out). In dictation such a fallback is silent; on the Mac, only **Dictation
  History** shows it, if history is on.
- A 1.7B model can't be relied on to fix words that sound alike, so **High** behaves close to
  Medium; on the Mac, a vocabulary entry fixes a specific one. Below Deep, the check catches a
  word left out and a name moved, but not a word replaced by a different one ("milk" → "cream",
  "three" → "4") unless it is a name. Words that only hold a sentence together ("the", "of",
  "really") may still be dropped. Names are recognised by the capital letter speech-to-text gives
  them.
- **Deep's repairs are learnt from synthetic data**, and were checked on 114 hand-written cases and
  on dictations of the owner's own; expect less on real speech. The model doesn't always fix what it
  could, and the check lets through any other form of a word that was said, so a wrong tense or
  plural would pass as a repair. The check turns down repairs that reorder words ("Friday night.
  Sorry, the night Saturday." → "Saturday night"), or that replace a word across a sentence end with
  one that has nothing in common with it, and then Medium's cleanup is shown. A correction inside a
  mention ("words like Docker, sorry, not Docker, Kubernetes") the model may leave as said, or read
  the wrong way round, which the check turns down. Deep is slower than Medium (379 ms against 288 ms
  at p50, speech-to-text plus cleanup, on an M4 Pro; [Development](development.md#bench-and-eval)),
  and a rejected answer adds Medium's pass.
- Spoken lists are laid out only when you say their markers ("first…", "one is…", "number one…" with
  the later numbers said bare, "bullet point…"), and lists and letters only where line breaks are
  allowed. The model sometimes drops or rewrites a list item; the check then inserts your words,
  still laid out. **Deep** also makes lists you didn't mark, in fields that take several lines:
  things you need or steps to take become a list of three or more ("We need milk, eggs and bread."),
  and it may do the same for two after a colon you said ("A few things: fixing the feeds and
  releasing the patch."), which in a chat box may be more than you wanted. For a longer
  letter, the rules put the greeting and sign-off on lines of their own and the model gets only
  the body, with a line saying so: Deep lays out the lists in it, but doesn't split it into
  paragraphs.

## Mac

- **A Bluetooth headset's microphone switches the headset into call mode.** macOS does this
  whenever any app opens a headset microphone: the headset drops to 16 kHz and its playback
  quality falls until capture stops. Transcription works, but for better playback use the
  built-in or a wired microphone while the headset plays audio.
- **Dictation needs Accessibility, which macOS ties to the app's signature.** Each ad-hoc
  rebuild is a new app to macOS: remove Live Transcribe from Privacy & Security › Accessibility
  and add the new build, or the shortcut stops working. Builds signed with your own certificate
  keep the permission ([Signing your builds](development.md#signing-your-builds)).
- **Pasting can need a reopen after Accessibility is switched on.** Seen once, after the
  Accessibility entry was removed and added back while the app ran: Accessibility read as on and
  the shortcut worked, but macOS refused to let the app send ⌘V, so text for apps that are
  pasted into (terminals, browsers, Electron apps) was left on the clipboard. The panel says so,
  and setup and **Settings › Permissions** offer **Reopen Live Transcribe**. That reopening
  fixes it is expected but not yet confirmed.
- A text box in a web page always counts as taking several lines, so a list dictated into a
  web page's one-line field, such as a site's search box, gets line breaks the field then drops
  ("items:1. Milk"). Set that browser to single-line if it happens often.
- A leading space is added only in apps that report their text through Accessibility.
  Elsewhere no space is added.
- After a pasted dictation, **Undo AI Edit** can't tell whether you typed more in the same field;
  ⌘Z then undoes that typing first.
- The microphone opens while the focused field is read, so in a password field the microphone
  indicator may flash briefly. The recording is thrown away before it is transcribed, and
  nothing is typed.
- Reserved system shortcuts (⌘Space, ⌘Tab, …) are recognised by key position on a US layout, so
  on other layouts Settings may accept a shortcut that macOS already uses. ⌃⌥Space is allowed as
  a shortcut but can clash with input-source switching on some Macs.
- With a cleanup model other than Qwen3-1.7B-4bit (**Settings › Advanced**), Medium and High stop
  resolving corrections and Deep runs on its prompt alone, since the adapters fit only that model.
- The speech models in the catalog download at the commit pinned in `speech-models.json`, and
  the cleanup model at its adapters' commit. Silero VAD, a cleanup model without adapters and a
  repository entered under **Another model** follow the repository's `main` branch, so Macs that
  install at different times can end up with different versions of those.
- If the app crashes, up to `cleanupQueueCapacity` + 1 segments (9 by default) that were
  transcribed but not yet cleaned are lost: their raw text was on screen but not yet saved.

## Linux and Windows

- **Linux has been run on COSMIC only, and Windows has been built, tested, installed and started in
  CI** ([Status](../README.md#status)), so expect rough edges on other setups.
- **Linux needs a Wayland desktop that allows typing.** The compositor has to offer
  `ext-data-control-v1` and `zwp-virtual-keyboard-v1`. COSMIC works; Sway and Hyprland should but
  haven't been tried; on GNOME, KDE Plasma and X11 desktops the app starts but can't type yet, and
  Settings says why.
- **Linux hold-to-talk reads the keyboards in `/dev/input`, which needs a udev rule.** The deb
  and rpm install it; the AppImage can't, so add it by hand
  ([README.Linux](../linux-windows/packaging/linux/README.Linux)). **The rule lets any program the
  user runs read what they type**, as any X11 program always could.
- The hotkey is one key, not a combination, and **the focused app also sees it and Esc**: pick a
  key apps leave alone, such as Right Ctrl. On Windows, the hotkey isn't seen while an app running
  as administrator has the keyboard.
- **Password fields are recognised only where the app can tell.** On Linux that is fields that use
  the input method; a pasted dictation (X11 apps, Electron apps without Wayland IME, any app while
  IBus or Fcitx hold the input method) knows nothing about the field. On Windows it is the system's
  own edit controls; in browsers, Electron apps, Office and newer apps it isn't. **Don't dictate
  into a password field elsewhere.** Text goes in on one line there (on Windows, with line breaks as
  spaces).
- **Windows types into whatever window has the keyboard, and nothing checks that a text field has
  the caret:** with none focused, the words reach the app as keystrokes and single-key shortcuts (a
  web page's, an editor's) can fire. Click into a field first. Where Windows would drop the
  keystrokes (no window has the keyboard, the desktop or taskbar has it, the tray's menu was the
  last thing you used, a modifier is still held, or the focused app runs as administrator), the text
  is left on the clipboard to paste.
- The Windows installer isn't signed, so SmartScreen warns about an unrecognised app the first time
  (More info, then Run anyway). If Windows' privacy settings (Settings › Privacy & security ›
  Microphone) keep desktop apps from the microphone, the app hears nothing.
- Linux and Windows have no live transcript, dictation history, Undo AI Edit, snippets, vocabulary
  or per-app settings, no combination shortcuts, no **Keep the microphone ready**, no microphone
  menu in the tray, and no updates from inside the app (a new version is a new download). Settings
  has General, Models and Advanced only, and three of the Mac's speech models (Qwen3-ASR 0.6B and
  1.7B, and Whisper large-v3-turbo) aren't offered.
- Cleanup runs on the CPU only, about four times slower than on a Mac (measured on an Intel desktop
  CPU on Linux). Qwen3-ASR prompts over 1,024 tokens (about 75 seconds of speech), and replies that
  outgrow the NPU's cache, fall back from the NPU to the CPU.
- **x86-64 only:** no Windows on Arm (Snapdragon PCs) or Arm Linux, and Linux needs glibc 2.35 or
  later. Only Intel NPUs are used; other computers run everything on the CPU. The packages carry
  OpenVINO's CPU and NPU plugins only, so **Runs on › GPU only** can't work.

## Not built yet

- Paragraph breaks in long dictations without saying "new paragraph".
- Per-app cleanup level and tone: apps can be set single-line today, but every app gets the same
  cleanup.
- Awareness of the focused app's context, and **Command Mode** (select text and say how to change
  it).
- Multilingual cleanup: speech is recognised in 31 languages, but cleanup is written for English.
- Linux and Windows: GNOME, KDE Plasma and X11 desktops, and the Mac's features listed above.
