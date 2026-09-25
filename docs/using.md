# Using Live Transcribe

How dictated text is cleaned up is in [Cleanup and spoken commands](cleanup.md), and how it
gets into each app in [Snippets, vocabulary and apps](snippets-vocabulary-apps.md).

## First launch

Live Transcribe runs in the menu bar. It has a Dock icon and a main menu only while one of its
windows is open, and it keeps running when you close them all.

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

## Dictation

- **Hold** the shortcut (**fn (🌐)** by default) for at least 300 ms, speak, and release. The
  text is inserted where the cursor is.
- **Double-tap** it to dictate hands-free, and press it once more to finish. (**Double-tap the
  shortcut for hands-free**, on by default.) A single short tap does nothing.
- **Esc** cancels, while recording or while the text is being prepared. Esc works while the
  shortcut is running (dictation on and Accessibility granted); the **×** in the floating panel
  and **Cancel Dictation** in the menu always cancel. A cancelled dictation is neither inserted
  nor saved.
- **Start Dictation** in the menu bar starts a hands-free dictation without the shortcut; press
  the shortcut or choose **Stop Dictation** to finish.
- The text is inserted in the first way that works:
  1. **Accessibility**: the text replaces the field's selection, and the app reads the field
     back to check that it arrived. Your clipboard is not touched.
  2. **Paste**, for apps that ignore that, or that are set to paste in **Settings › Apps**. The
     clipboard is saved, the text is pasted with ⌘V, and the clipboard is put back after 250 ms,
     unless you copied something in the meantime. A paste cannot be verified.
  3. Otherwise the text is left on the clipboard, and the floating panel says why:
     - "*App* didn't accept the text. It's on the clipboard: press ⌘V" when the app refused both.
     - "Quit and reopen Live Transcribe so it can paste. The text is on the clipboard: press ⌘V"
       when Accessibility is on but macOS doesn't let Live Transcribe send ⌘V yet.
     - "Allow Live Transcribe in Accessibility so it can paste. The text is on the clipboard:
       press ⌘V" when Accessibility is off.
- A space is added before the text when it follows a word, in apps that let Accessibility read
  the character before the cursor.
- Nothing is typed or copied into a password field: a field macOS marks as secure, or any field
  while secure keyboard entry is on. Text inserted through Accessibility goes into the field you
  dictated into, wherever the focus is by then. If another app has focus by the time the text is
  ready to paste, the text goes on the clipboard instead, and the panel says another app took
  focus.
- **Undo AI Edit** (⌃⌥Z, within 30 seconds, in the field you dictated into) swaps the cleaned
  text for what you said before cleanup. Snippets, vocabulary and spoken commands stay applied;
  lists and letters go back to how you said them. It changes nothing
  if another app or field has focus (click back into the field and try again within the
  30 seconds) or if the text was edited since. It works between dictations, and at **None** there
  is nothing to undo.
- **Copy Last Dictation** puts the last dictated text on the clipboard, until the app quits.
- Recordings shorter than 300 ms are ignored ("Didn't catch that").
- Only the first 5 minutes of a recording are kept (**Longest recording** in **Timing**, from
  10 seconds to 30 minutes). The panel keeps showing **Listening** and doesn't warn at the limit.
  When you finish, those 5 minutes are inserted and the panel says "Recording stopped at 5 min;
  the rest wasn't heard".
- Long dictations have not been measured. Cleanup runs on the whole dictation in one call,
  within the cleanup timeout (3 s by default). By extrapolation from the eval, a dictation longer
  than a minute or two will likely exceed it and be inserted uncleaned, with fillers still
  removed, and without a message.
- If the microphone stops for good partway (a Bluetooth headset disconnects on a Mac with no
  other microphone, for example), what was heard is inserted and the floating panel says so.
- One dictation runs at a time, and none while the live transcript is listening: **Stop Live
  Transcript** in the menu bar frees the microphone.
- With fn as the shortcut, set System Settings › Keyboard › **Press 🌐 key to** to **Do
  Nothing**, or macOS also acts on the key (changing the input source, showing emoji, or starting
  its own dictation). Setup and Settings warn you until it is set.
- Change the shortcuts in **Settings › General › Shortcuts**. The **Dictation shortcut** can be
  one modifier held on its own (fn (🌐), Right ⌘ Command, Right ⌥ Option, Left ⌥ Option, Right ⌃
  Control, Left ⌃ Control or Right ⇧ Shift) or a combination that includes ⌘, ⌥ or ⌃. **Undo AI
  edit** must be a combination. Standard macOS shortcuts (⌘C, ⌘V, ⌘Z, ⌘Tab, ⌘Space, ⌃Space and
  others) are refused.

## Dictation History

**Dictation History…** in the menu bar lists saved dictations, newest first. Search matches the
inserted text, what you said and the app, ignoring case and accents. Each entry shows both texts,
the app, the cleanup level, whether cleanup fell back and why, how the text was delivered, the
audio length and the latency, with **Copy**, **Copy Original** and **Delete**.

In **Settings › History**: **Keep dictation history** (on by default), **Keep dictations for**
(Forever, 7 days, 30 days, 90 days or 1 year), **Show History…** and **Clear History…**. Expired
dictations are deleted at launch, when settings change, and every hour while the app runs.

## Live transcript

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

## Microphones

Choose the microphone from the menu bar's **Microphone** menu, above the transcript, or in
**Settings › General**; all three show the same list and the same choice. **System Default**
follows the input selected in macOS, including while you dictate or transcribe, so a newly
connected microphone is picked up when macOS makes it the default input. Virtual and aggregate
devices (from Teams, Zoom, audio routing tools) are hidden unless you turn on **Show Other
Devices** (**Show other devices** in Settings), and are never switched to automatically while a
physical microphone is connected. If a microphone you chose disconnects, capture falls back to
the system default, tells you, and switches back when it reconnects.

**Keep the microphone ready** (**Settings › General**, off by default) keeps the microphone open
between dictations, so dictation starts faster and keeps the 300 ms before you pressed the key.
macOS's microphone indicator then stays on while the app runs.

## Updates

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

## Settings

**Settings** (⌘, or the menu bar) has seven tabs, along the top of its window:

| Tab | What it holds |
|---|---|
| **General** | **Enable dictation**, the shortcuts, the cleanup level, the microphone, **Keep the microphone ready**, **Timing**: 13 controls for gestures, recording limits, undo, messages, pasting, Accessibility and vocabulary, and in a downloaded release, **Updates** |
| **Snippets** | trigger phrases and the text they insert |
| **Vocabulary** | names and jargon, with how they are spoken |
| **Apps** | per app, how text goes in (Accessibility or paste) and whether it takes line breaks |
| **History** | dictation history on or off, retention, clearing |
| **Permissions** | microphone and Accessibility status, with buttons that open the right System Settings pane, and **Reopen Live Transcribe** when macOS won't let it paste until it reopens |
| **Advanced** | for dictation and the live transcript: the speech-to-text and cleanup models, **Clean up transcripts with the LLM**, **Resolve spoken self-corrections**, the cleanup **Timeout**, the GPU cache and capture restarts; for the live transcript only: the voice-activity model, silence, speech threshold, pre-roll and minimum speech, maximum segment length, live partials, context segments and queue capacity |

Settings on every tab but **Advanced** apply immediately, to the next dictation. **Settings on
the Advanced tab apply the next time the app starts.** Its **Restore Defaults** resets only that
tab: dictation settings, shortcuts, cleanup level, history and microphone stay as they are.
