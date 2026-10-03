# Using Live Transcribe

Live Transcribe runs on the Mac, on Linux and on Windows. This guide covers the Mac first, then
[Linux and Windows](#linux-and-windows), which dictate the same way with fewer features:

| | Mac | Linux and Windows |
|---|---|---|
| Dictation, the five cleanup levels, spoken commands | yes | yes |
| Dictation shortcut | **fn (🌐)**, a modifier held on its own, or a combination | **Right Ctrl**, or one other key |
| Speech models to choose from | 7 | 4 |
| Live transcript window, dictation history, Undo AI Edit | yes | not yet |
| Snippets, vocabulary, per-app settings | yes | not yet |
| Updates | itself | download the new version |

How dictated text is cleaned up is in [Cleanup and spoken commands](cleanup.md), and how it gets
into each app in [Snippets, vocabulary and apps](snippets-vocabulary-apps.md).

## Mac

### First launch

Open `LiveTranscribe.dmg` from [GitHub
Releases](https://github.com/Nerdstorm/LiveTranscribe/releases/latest) and drag Live Transcribe to
Applications. It runs in the menu bar. It has a Dock icon and a main menu only while one of its
windows is open, and it keeps running when you close them all; opening the app again with no window
open shows Live Transcript.

While dictation is on and a permission is missing, **Set Up Dictation** opens at launch. Its
steps are **Microphone**, **Accessibility** (which lets the dictation shortcut work in every app
and type the text), **fn key** (only while fn is the shortcut) and **Try it**, a practice box.
Every step can be skipped, and each is checked again when you come back from System Settings.
**Set Up Dictation…** stays in the menu bar menu while a permission is missing. If macOS still
won't let Live Transcribe paste after Accessibility is switched on, setup and **Settings ›
Permissions** say so and offer **Reopen Live Transcribe**.

At the same time the app downloads the models (about 2 GB) into the Hugging Face cache
(`~/.cache/huggingface`, shared with the tests, the bench and other Hugging Face tools). The menu
bar and the transcript window show the progress. Dictation and **Start Transcribing** become
available once the models have loaded. If the cleanup model fails to load, the app transcribes
without cleanup and offers **Retry**.

### Dictation

While you dictate, a small circle by the mouse pointer (the *panel*) shows the microphone level,
then a spinner while the text is prepared. It never takes focus or clicks. Only when something
needs attention does a short message appear in a bubble beside it.

- **Hold** the shortcut (**fn (🌐)** by default) for at least 300 ms, speak, and release. The
  text is inserted where the cursor is.
- **Double-tap** it to dictate hands-free, and press it once more to finish. (**Double-tap the
  shortcut for hands-free**, on by default.) A single short tap does nothing, and pressing any
  other key while a single-modifier shortcut is held cancels that dictation without a message.
- **Esc** cancels, while recording or while the text is being prepared. Esc works while the
  shortcut is running (dictation on and Accessibility granted). **Cancel Dictation** in the menu
  bar is listed only while a dictation is recording or being prepared, and works even when the
  shortcut is off. A cancelled dictation is neither inserted nor saved.
- **Start Dictation** in the menu bar starts a hands-free dictation without the shortcut; press
  the shortcut or choose **Stop Dictation** to finish.
- The text is inserted in the first way that works:
  1. **Accessibility**: the text replaces the field's selection, and the app reads the field
     back to check that it arrived. Your clipboard is not touched.
  2. **Paste**, for apps that ignore that, or that are set to paste in **Settings › Apps**. The
     clipboard is saved, the text is pasted with ⌘V, and the clipboard is put back after 250 ms,
     unless you copied something in the meantime. A paste cannot be verified.
  3. Otherwise the text is left on the clipboard, and the panel says why:
     - "*App* didn't accept the text. It's on the clipboard: press ⌘V" when the app refused both.
     - "Quit and reopen Live Transcribe so it can paste. The text is on the clipboard: press ⌘V"
       when Accessibility is on but macOS doesn't let Live Transcribe send ⌘V yet.
     - "Allow Live Transcribe in Accessibility so it can paste. The text is on the clipboard:
       press ⌘V" when Accessibility is off.
- A space is added before the text when it follows a word, in apps that let Accessibility read
  the character before the cursor.
- Nothing is typed or copied into a password field: a field macOS marks as secure, or any field
  while secure keyboard entry is on. The panel says "Dictation is off in password fields", and the
  recording is thrown away before it is transcribed. Text inserted through Accessibility goes into
  the field you dictated into, wherever the focus is by then. If another app has focus by the time
  the text is ready to paste, the text goes on the clipboard instead, and the panel says another
  app took focus.
- **Undo AI Edit** (⌃⌥Z, within 30 seconds, in the field you dictated into) swaps the cleaned
  text for what you said before cleanup. Snippets, vocabulary and spoken commands stay applied;
  lists, letters and numbers go back to how you said them. It changes nothing if another app or
  field has focus (click back into the field and try again within the 30 seconds) or if the text
  was edited since. It works between dictations, and at **None** there is nothing to undo.
- **Copy Last Dictation** puts the last dictated text on the clipboard. The app remembers it only
  until it quits.
- Recordings shorter than 300 ms are ignored ("Didn't catch that").
- Only the first 5 minutes of a recording are kept (**Longest recording** in **Timing**, from
  10 seconds to 30 minutes). The panel keeps showing the microphone level and doesn't warn at the
  limit. When you finish, those 5 minutes are inserted and the panel says "Recording stopped at 5
  min; the rest wasn't heard".
- Long dictations have not been measured. Cleanup runs on the whole dictation in one call,
  within the cleanup timeout (3 s by default, and at least 8 s at Deep). By extrapolation from
  the eval, a dictation longer than a minute or two will likely exceed it and be inserted
  uncleaned (fillers still removed from Medium up), and without a message.
- If the microphone stops for good partway (a Bluetooth headset disconnects on a Mac with no
  other microphone, for example), what was heard is inserted and the panel says so.
- One dictation runs at a time. Pressing the shortcut while the last dictation is still being
  inserted records nothing, and the panel says "Press again to dictate: the last dictation was
  still being inserted". None runs while the live transcript is listening: **Stop Live
  Transcript** in the menu bar frees the microphone.
- With fn as the shortcut, set System Settings › Keyboard › **Press 🌐 key to** to **Do
  Nothing**, or macOS also acts on the key (changing the input source, showing emoji, or starting
  its own dictation). Setup and Settings warn you until it is set.
- Change the shortcuts in **Settings › General › Shortcuts**. The **Dictation shortcut** can be
  one modifier held on its own (fn (🌐), Right ⌘ Command, Right ⌥ Option, Left ⌥ Option, Right ⌃
  Control, Left ⌃ Control or Right ⇧ Shift) or a combination that includes ⌘, ⌥ or ⌃. **Undo AI
  edit** must be a combination. Standard macOS shortcuts (⌘C, ⌘V, ⌘Z, ⌘Tab, ⌘Space, ⌃Space and
  others) are refused.

### Dictation History

**Dictation History…** in the menu bar lists saved dictations, newest first. Search matches the
inserted text, what you said and the app, ignoring case and accents. Each entry shows both texts,
the app, the cleanup level, whether cleanup fell back and why, how the text was delivered, the
audio length, the latency and when it was made (and, if the microphone stopped early, that it
did), with **Copy**, **Copy Original** and **Delete** (also on a right click). **Refresh** (⌘R)
reloads the list and **Clear All…** asks before it deletes everything. A banner says when history
is off.

In **Settings › History**: **Keep dictation history** (on by default), **Keep dictations for**
(Forever, 7 days, 30 days, 90 days or 1 year), **Show History…** and **Clear History…**. Expired
dictations are deleted at launch, when settings change, and every hour while the app runs.

### Live transcript

**Live Transcript…** in the menu bar opens the window. **Start Transcribing** (⌘R) starts
listening. **Stop** releases the microphone at once, then finishes and saves every segment
already spoken.

- Words appear in grey while you speak (every 1,000 ms by default). When you pause, the line
  shows the raw transcript, then the cleaned text replaces it.
- A wand icon marks a line the model changed; its tooltip shows the raw text. An orange mark
  means cleanup was rejected, and its tooltip says why.
- **Copy** copies the whole transcript. **Sessions** opens the folder of saved sessions.
- Closing the window stops a transcript that is listening, and **Stop Live Transcript** in the
  menu bar stops it from any app.
- A segment ends after 600 ms of silence, is split at 15 s, and is dropped as noise with less
  than 250 ms of speech. Each line is cleaned with the 3 previous lines as context.

### Microphones

Choose the microphone from the menu bar's **Microphone** menu, above the transcript, or in
**Settings › General**; all three show the same list and the same choice, and are locked while a
live transcript is listening or finishing. **System Default** follows the input selected in
macOS, including while you dictate or transcribe, so a newly connected microphone is picked up
when macOS makes it the default input. Virtual and aggregate devices (from Teams, Zoom, audio
routing tools) are hidden unless you turn on **Show Other Devices** (**Show other devices** in
Settings), and are never switched to automatically while a physical microphone is connected. If a
microphone you chose disconnects, capture falls back to the system default, tells you, and
switches back when it reconnects.

**Keep the microphone ready** (**Settings › General**, off by default) keeps the microphone open
between dictations, so dictation starts faster and keeps the 300 ms before you pressed the key.
macOS's microphone indicator then stays on while the app runs.

### Updates

A release downloaded from GitHub updates itself with [Sparkle](https://sparkle-project.org). On
its second launch it asks whether to check for updates automatically, about once a day; change
that in **Settings › General › Updates**, which also has **Check Now** and when it last checked.
**Check for Updates…** in the menu bar checks at once. A new version found by a daily check
doesn't interrupt you: its window waits behind your other apps, and the menu bar offers **Update
to** the new version until you look at it. Updates are signed, and Sparkle checks the signature
before installing one.

A build from source never checks for updates, and has neither the menu item nor the Settings
section.

**About Live Transcribe** in the menu bar shows the version, the models' credits and the licences
of the open-source packages the app is built with.

### Settings

**Settings** (⌘, or the menu bar) has eight tabs, along the top of its window:

| Tab | What it holds |
|---|---|
| **General** | **Enable dictation**, the shortcuts, the cleanup level, the microphone, **Keep the microphone ready**, **Timing**: 13 controls for gestures, recording limits, undo, messages, pasting, Accessibility and vocabulary, and in a downloaded release, **Updates** |
| **Snippets** | trigger phrases and the text they insert |
| **Vocabulary** | names and jargon, with how they are spoken |
| **Apps** | per app, how text goes in (Accessibility or paste) and whether it takes line breaks |
| **History** | dictation history on or off, retention, clearing |
| **Permissions** | microphone and Accessibility status, with buttons that open the right System Settings pane, and **Reopen Live Transcribe** when macOS won't let it paste until it reopens |
| **Models** | the speech-to-text model: models to download, switch to and remove, each with its languages, size and licence, and **Another model**, for any Hugging Face repository or a model folder on your Mac |
| **Advanced** | for dictation and the live transcript: the cleanup model, **Clean up transcripts with the LLM**, **Resolve spoken self-corrections** (both adapters: Medium and High's, and Deep's), the cleanup **Timeout**, the GPU cache and capture restarts; for the live transcript only: the voice-activity model, silence, speech threshold, pre-roll and minimum speech, maximum segment length, live partials, context segments and queue capacity |

Settings on every tab but **Advanced** apply immediately, to the next dictation. A speech model
chosen in **Models** loads straight away; dictation waits the few seconds it takes, and a live
transcript keeps the model it started with until you stop it. **Settings on the Advanced tab
apply the next time the app starts.** Its **Restore Defaults** resets only that tab: dictation
settings, shortcuts, cleanup level, history and microphone stay as they are. A model you haven't
changed follows the default, including a new default in a later version. The cleanup and
voice-activity models are Hugging Face repository IDs that mlx-swift-lm and mlx-audio-swift can
load; the adapters work only with mlx-community/Qwen3-1.7B-4bit.

## Linux and Windows

Both systems run the same app, and dictate as the Mac does: hold a key, speak, let go, and the
cleaned text is typed where you are working. It has a tray icon and a Settings window, and nothing
else: no live transcript, dictation history, Undo AI Edit, snippets, vocabulary or per-app
settings yet ([Known limitations](limitations.md)). Spoken commands, fillers, lists and letters,
numbers in digits, and all five cleanup levels work as on the Mac ([Cleanup](cleanup.md)).

### Installing and first start

Download the package for your system from
[GitHub Releases](https://github.com/Nerdstorm/LiveTranscribe/releases/latest); the release notes
give the install commands.

- **Linux** (x86-64, glibc 2.35 or later): a deb for Ubuntu 22.04 or later and Debian 12 or later,
  an rpm for Fedora and openSUSE, or an AppImage for any other distribution. **The desktop has to be
  a Wayland one that allows typing:** COSMIC works; Sway and Hyprland should, but haven't been
  tried; GNOME, KDE Plasma and X11 desktops don't yet. There the app starts, and Settings names what
  is missing. The deb and rpm install a udev rule that lets the app read the keyboard for its hotkey
  (restart the computer if Settings asks you to). The AppImage can't; its
  [README.Linux](../linux-windows/packaging/linux/README.Linux) gives the rule. **The rule lets any
  program you run read what you type**, as any X11 program always could.
- **Windows** (10 or 11, x86-64): run the setup program. It installs for your account, without
  administrator rights. It isn't signed yet, so SmartScreen warns about an unrecognised app: choose
  More info, then Run anyway. If it hears nothing, check that Settings › Privacy & security ›
  Microphone lets desktop apps use the microphone.

There is no account or sign-in. The app starts in the tray. The first start downloads the speech
model (1.1 GB) and the cleanup model (0.9 GB) from Hugging Face. The tray's status line shows how
far the speech model got ("Downloading speech models… 42%", then "Loading speech models…") until it
reads "Hold Right Ctrl to dictate"; **Settings › Advanced** shows the cleanup model's progress, and
until it has loaded, dictation works without its cleanup (fillers are still removed from Medium up).
With an Intel Core Ultra's NPU (its driver comes from your distribution, or on Windows from Windows
Update or the PC's maker) the default speech model runs on the NPU; otherwise on the CPU. Cleanup
always runs on the CPU, and takes about four times as long as on a Mac. If dictation can't start (on
Linux the desktop can't type or the keyboards can't be read; on Windows the hotkey can't be
watched), Settings opens at once and says why, and closing it quits the app, since some desktops
show no tray icon. A second copy is refused.

### Dictating

- **Hold** the hotkey (**Right Ctrl** by default) for at least 300 ms, speak, and release. The
  text goes into the focused field.
- **Double-tap** it to dictate hands-free, and press it once more to finish. A single short tap
  is dropped.
- **Esc** cancels, while recording or while the text is being prepared, as does **Cancel Dictation**
  in the tray's menu; a cancelled dictation types nothing. Pressing another key while the hotkey is
  held cancels too, without a message.
- **Start Dictation** in the tray's menu records hands-free: **Stop Dictation** ends it and **Cancel
  Dictation** cancels it. With **Dictate with the hotkey** on, the hotkey also ends it and Esc also
  cancels it; with it off they do nothing, so use the menu.
- **Copy Last Dictation** puts the last dictation on the clipboard. The app remembers it only until
  it quits, and on Linux quitting also empties a clipboard the app set.
- A small circle shows that you are dictating: a red disc that grows with the microphone's level, a
  ring round it when hands-free, and a spinning ring while the speech is transcribed. On Windows,
  and on Linux desktops that tell apps where the pointer is (COSMIC does), it follows the mouse
  pointer, below and to the right of it; elsewhere on Linux it sits at the bottom of the screen, and
  it needs `wlr-layer-shell` (without it there is none). It has no words and takes no clicks. When
  something needs you, a short message shows beside it for a few seconds: "Didn't catch that" (a
  recording under 300 ms, or nothing came out), "Dictation is off in password fields", "The
  microphone stopped: …", "The microphone stopped after 12 s; the rest wasn't heard" (what came
  before is typed anyway), "Speech-to-text failed: …", "The text couldn't be typed: …", "Recording
  stopped at 5 min; the rest wasn't heard", "Press again to dictate: the last dictation was still
  being typed", and, when nothing took the text, "Copied: press Ctrl+V to paste (Ctrl+Shift+V in a
  terminal)".
- Recordings under 300 ms are ignored, and only the first 5 minutes of one are kept (**Longest
  recording**, from 10 seconds to 30 minutes). A cleanup that times out or is rejected is silent:
  the text goes in as spoken, with fillers still removed from Medium up.
- A space is added before the text only on Linux, in fields that take the input method and report
  what comes before the cursor. On Windows, and in pasted Linux text, none is added, so a second
  dictation runs straight into the first.

### The hotkey

The hotkey is one key, **Right Ctrl** at first. In **Settings › General**, click the **Hotkey**
button and press the key you want (a modifier on its own is taken when you release it); Esc stops
recording. Esc and the mouse or gamepad buttons can't be the hotkey, and there are no
combinations. **The focused app also sees the hotkey and Esc**, so pick a key apps ignore. If
Settings can't record a key, start Live Transcribe with `--key` and the key's name, which
`livetranscribe keys` prints as you press keys (`livetranscribe run --key KEY_RIGHTALT`). On
Windows, a key the system doesn't report on its own (Fn, the keypad's Enter) is refused, and the
hotkey isn't seen while an app running as administrator has the keyboard.

### The tray menu

Left-click the tray icon. The menu shows the status ("Hold Right Ctrl to dictate", "Listening…",
"Transcribing…", "Downloading speech models… 42%", or what stops it), then **Start Dictation** (it
reads **Stop Dictation** while recording), **Cancel Dictation**, **Copy Last Dictation**,
**Cleanup** (None, Light, Medium, High and Deep; the choice is saved), **Settings…** and **Quit
Live Transcribe**. The icon shows the state: a waveform when ready, a microphone when recording,
a warning triangle when something needs attention.

### Settings

**Settings…** has three tabs. There is no Save button: each control applies at once, to the next
dictation.

| Tab | What it holds |
|---|---|
| **General** | **Dictate with the hotkey** (off, and the tray's **Start Dictation** still works), the hotkey, **Double-tap for hands-free**, the cleanup level, the microphone to **Record from** (System default, or one listed), and **Timing**: longest tap 300 ms, double-tap window 300 ms, shortest recording 300 ms, longest recording 300 s, message duration 2.5 s and the clipboard restore delay 250 ms (which does nothing on Windows) |
| **Models** | the speech models, each with its languages, size and licence: **Download**, **Use** and **Remove** them, and **Another model** for a converted model in the models folder. Cohere Transcribe has a **Language** menu (14 languages) |
| **Advanced** | **Runs on**: Auto (the NPU if there is one, else the CPU), NPU only or CPU only, for Qwen3-ASR only; GPU only is offered but the packages can't run it; **Clean up transcripts with the LLM**; the cleanup **Timeout** (3 s; at least 8 s at Deep); and the state of both models with **Try Again**. **Restore Defaults** resets these three |

The speech models are Qwen3-ASR 0.6B fine-tuned for Sinhala (the default), Parakeet TDT 0.6B v2
(English) and v3 (25 European languages), and Cohere Transcribe (the one of its 14 languages you
choose). Where each setting is stored, and what is kept, is in [Privacy](privacy.md).

### How the text gets in

**On Linux** the app registers as the desktop's input method, so text goes straight into fields that
take one (GTK, Qt, Firefox, Chromium with Wayland IME, COSMIC's apps, foot and kitty). Those fields
say what they are: password fields are refused ("Dictation is off in password fields"); terminals
and fields for one value (an address, a number) keep the text on one line, and other fields take
line breaks. Elsewhere, and while IBus or Fcitx hold the input method, the app pastes: the text goes
on the clipboard, Ctrl+V is typed, and your clipboard is put back. **A pasted dictation knows
nothing about the field: password fields aren't recognised there, so don't dictate into one.** The
text goes in on one line.

**On Windows** the text is typed as Unicode keystrokes, in pieces, so any script goes in whatever
the keyboard layout, and your clipboard is left alone. Windows says what a field is only for its own
edit controls (Notepad's, and older programs'): their password fields are refused, and those with
several lines take line breaks. **Browsers, Electron apps, Office and newer apps draw their own
fields and Windows says nothing about them, so their password fields aren't recognised; don't
dictate into a password field there.** Their text is typed on one line, line breaks as spaces, so
that a Return never sends a message or a form. **Windows types into whatever window has the
keyboard, and nothing checks that a text field has the caret:** with none focused, the words reach
the app as keystrokes and single-key shortcuts can fire, so click into a field first. **Where
Windows would drop the keystrokes, the text is left on the clipboard** (out of the clipboard history
and the cloud clipboard), and the message says to press Ctrl+V. That happens when:

- Shift, Ctrl, Alt or the Windows key is still held down when the text is ready (typing waits a
  second for it to be let go);
- no window has the keyboard (a UAC prompt, the lock screen);
- the desktop or the taskbar has it;
- the tray's menu was the last thing you used (for example you chose Stop Dictation there), which
  leaves the keyboard with the app itself instead of your field;
- the focused app runs as administrator, which Windows keeps other apps from typing into.

If the field loses focus, or a modifier key is pressed, partway through, typing stops with "The
text couldn't be typed: …" and says how much went in.

### Not yet

The Mac app has these; Linux and Windows don't: the live transcript, dictation history, Undo AI
Edit, snippets, vocabulary and per-app settings, combination shortcuts, **Keep the microphone
ready**, three of the Mac's speech models (Qwen3-ASR 0.6B and 1.7B, and Whisper large-v3-turbo), a
microphone menu in the tray, and updates from inside the app. A new version is a new download:
reinstall the deb or rpm, replace the AppImage, or run the new setup program over the old one, which
keeps your models and settings.
