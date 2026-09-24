# Live Transcribe

**Talk the way you talk. Get the sentence you meant, typed at your cursor in almost any app, and
not a word leaves your Mac.**

Hold **fn (🌐)**, speak, and let go. Live Transcribe turns what you said into clean, punctuated
text and types it where you are working: a message, an email, a document, a terminal. The "um"s
are gone. "Monday, no wait, Tuesday" comes out as "Tuesday". Add your names and jargon once, and
they are spelled your way.

Speech-to-text and a small language model run on your Apple silicon Mac with
[MLX](https://github.com/ml-explore/mlx-swift). There is no account, no cloud and no telemetry,
and once the models are downloaded it works offline. When you would rather watch than type, a
live transcript window shows your words as you speak and tidies each line in place.

Free and open source (MIT) · Apple silicon · macOS 14 or later (tested on macOS 27) · English ·
[build from source](#build-and-run)

## See the difference

Real outputs from the dictation eval, at the default **Medium** cleanup level:

| You say | Live Transcribe types |
|---|---|
| Um, I think we should, uh, push the launch by a week | I think we should push the launch by a week. |
| Let's meet on Monday, no wait, Tuesday | Let's meet on Tuesday. |
| The budget is fifty thousand, I mean sixty thousand | The budget is 60,000. |
| We're flying into Boston, scratch that, into New York | We're flying into New York. |
| Tell Daniel, sorry, tell Maria the draft is ready | Tell Maria the draft is ready. |
| So, uh, what time does the, um, the train leave | So, what time does the train leave? |
| I'll be about ten minutes late, the train is running slow today | I'll be about 10 minutes late. The train is running slow today. |
| hi emoji fireworks | Hi 🎆. |
| email me at john dot smith at example dot com | Email me at john.smith@example.com. |

And in anything that takes several lines, such as a document, an email or a chat message:

| You say | Live Transcribe types |
|---|---|
| Things to do today. First, call the bank. Second, book the flights. Third, send the invoice. | Things to do today:<br>1. Call the bank<br>2. Book the flights<br>3. Send the invoice |
| hi John thanks for the update I will review it tomorrow cheers Sam | Hi John,<br><br>Thanks for the update, I will review it tomorrow.<br><br>Cheers,<br>Sam |

**12 of 12 self-corrections resolved. 10 of 10 filler clips cleaned. 65 of 65 clips laid out as
meant. 428 ms at p95.** In the 65-clip dictation eval at Medium, dictating into a multi-line
field, speech-to-text plus cleanup of sentence-length dictations took 186 ms at p50 and 428 ms at
p95, well inside the 1.2 s target.

Measured on an M4 Pro with synthetic speech: the left column is the script a macOS text-to-speech
voice read aloud. Stopping the recorder and inserting the text are not included in those times.
Three of the 65 clips fell back to the uncleaned transcript: a plain sentence and two spoken
lists, which were still laid out ([details](#dictation-eval)).

## What you get

### Say it naturally, get what you meant

- **Fillers disappear.** At **Medium** and **High**, "um", "uh", "er" and "hmm" are removed by a
  fixed rule, so it happens every time, and words such as "umbrella" are never touched.
- **Correct yourself out loud.** At Medium and High, say "fuel efficiency in cars, sorry, buses"
  and "fuel efficiency in buses" is typed. Cues such as "no wait", "I mean", "actually" and
  "scratch that" work too. The bundled adapter resolved all 12 corrections in the eval, though
  you should expect lower accuracy on real speech.
- **A small model, taught a new skill.** A 10 MB fine-tuned adapter, trained in this repository
  and bundled with the app, resolved 97.3% of the self-corrections in a 515-example held-out
  test of synthetic sentences (the base model alone: 0.8%). It left 98.4% of look-alike
  sentences, such as "sorry I'm late", as spoken.
- **Punctuation and capitals, done.** From **Light** up, the local model fixes punctuation,
  casing and misheard words.
- **Spoken lists become lists.** At Medium or High, in any app that takes several lines, say
  "first… second… and third…", "number one… number two…" or "bullet point… bullet point…" and
  each item gets its own numbered or bulleted line, under a lead-in ending in a colon. The items
  keep your words.
- **Letters and emails laid out.** Start with a greeting ("Dear sir or madam", "Hi John") and
  end with a sign-off ("Kind regards Jordan Lee", "Cheers Sam"), and at Medium or High, in any
  app that takes several lines, the greeting and the sign-off each get their own lines. The
  model cleans only the body, so it cannot move the names around.
- **Emoji, punctuation and line breaks by voice.** At every level, say "hi emoji fireworks" for
  "hi 🎆", "thanks heart emoji" for "thanks ❤️", "is it ready question mark" for "is it ready?",
  "new line" or "new paragraph" for a line break, and "john dot smith at example dot com" for
  john.smith@example.com. See [Spoken commands](#spoken-commands).
- **You choose how much it edits.** Pick **None**, **Light**, **Medium** or **High** from the
  menu bar in two clicks, and your next dictation uses it.
- **Undo the AI, keep your words.** Press ⌃⌥Z within 30 seconds, in the field you dictated
  into, and what you actually said replaces the cleaned text, with your snippets, vocabulary and
  spoken commands still applied.
- **A safety net against rewrites.** Every edit is checked. If the model drops a "not", deletes
  words you said (below High) or rewrites too much, your own words are typed instead, with
  fillers still removed and lists and letters still laid out at Medium and High.

### Dictate from any app

- **One key, from any app.** Hold the shortcut in whatever app you are in, speak, and let go:
  the cleaned text is typed at your cursor, with no window to switch to.
- **Hands-free for longer thoughts.** Double-tap the shortcut, keep talking, and tap once more
  to finish. A recording keeps up to 5 minutes by default, and you can change that in
  **Timing**.
- **Starts when you do.** Recording begins the moment the key goes down, and with **Keep the
  microphone ready** on, it even keeps the 300 ms before you pressed it.
- **Unplugged mid-sentence? Nothing heard is thrown away.** If your microphone disconnects
  during a dictation, capture moves to another microphone after a brief gap. If there is none,
  the dictation ends, what was heard is typed, and the panel says how many seconds it caught.
- **Change your mind with Esc.** Esc throws the dictation away while you are talking or while
  the text is being prepared, and nothing is typed or saved. (Esc needs the shortcut to be on;
  the **×** on the panel always cancels.)
- **Always know what it is doing.** A small panel by your cursor (or near the bottom of the
  screen in apps that don't report the cursor's position), on any display and over full-screen
  apps, shows a live microphone level, then **Transcribing…**, and never takes focus from your
  app. If something needs you, it says so in one plain sentence.

### Make it yours

- **Say a phrase, get your saved text.** Say "my calendar link" and the link, address or
  signature you saved in **Snippets** is inserted exactly as written, line breaks included,
  because the language model never sees it.
- **Your names, spelled your way.** Add "Nerdstorm" to **Vocabulary** with how it gets misheard
  ("nerd storm"), and dictation replaces that mishearing with your spelling, at every cleanup
  level.
- **Your terms, in context.** From Light up, the cleanup model is also given up to 50 of your
  most relevant terms, so it can sometimes catch mishearings you never listed.
- **The shortcut you like.** Use fn, a single modifier key such as Right ⌥ Option, or a
  combination such as ⌃⌥Space. The shortcut recorder refuses shortcuts that would break copy,
  paste or other standard macOS shortcuts, and says why.
- **fn, sorted.** fn needs macOS's **Press 🌐 key to** setting on **Do Nothing**. Setup and
  Settings check it and open the right pane for you.
- **Change anything, no restart.** Shortcuts, the cleanup level, the microphone and 13 timing
  controls all apply to your next dictation.

### Dependable, app after app

- **Text that lands, and is checked.** Text goes straight into the field through Accessibility,
  and the app reads the field back to confirm it arrived, leaving your clipboard alone.
- **Terminals, browsers and Electron apps too.** Where typing through Accessibility isn't
  accepted, the text is pasted, and then your clipboard is put back as it was, images, files and
  rich text included.
- **Ready for your apps.** Seven terminals and eleven Electron and Chromium apps (VS Code,
  Cursor, Slack, Notion, Claude, Chrome, Arc and more) are set to paste out of the box, and any
  other app is a few clicks away in **Settings › Apps**.
- **Line breaks where they belong.** Lists, letters and "new line" get line breaks in every app,
  chat apps included, but not in a field that takes one line, such as a search box or an address
  bar, and not in terminals, where a line break could run a command. Make any app single-line,
  or a terminal multi-line, in **Settings › Apps**. See
  [How each app is handled](#how-each-app-is-handled).
- **Refused text isn't lost.** If an app accepts neither method, the text waits on the
  clipboard, a note at your cursor says to press ⌘V, and **Copy Last Dictation** in the menu
  copies it again later. When the fix is on your side, such as reopening Live Transcribe so
  macOS lets it paste, the note says that instead of blaming the app.
- **Spaces where they belong.** Dictate right after a word and a space is added for you, but
  not after an opening bracket or before a full stop (in apps that let Accessibility read the
  text before the cursor).
- **Safe around passwords and app switches.** Dictated text never goes into a password field
  that macOS marks as secure. If you switch apps while the text is being prepared, it still goes
  into the field you dictated into, or onto the clipboard when it would have to be pasted, never
  into the other app.
- **Your other shortcuts keep working.** fn with the arrow keys, other modifier shortcuts and
  Esc reach your apps as usual. Esc is taken only while a dictation is in progress.
- **Never stalls on a frozen app.** Each Accessibility call to another app gives up after
  250 ms instead of the system default of about 6 s, and text dictated into a Spotlight-style
  launcher panel goes to the panel, not the app behind it.
- **Microphones that behave.** When macOS switches to a microphone you plug in, **System
  Default** follows it. A chosen microphone that goes missing is replaced by another until it
  returns. Meeting apps' virtual devices are never switched to automatically while a physical
  microphone is connected.
- **Bluetooth headsets keep recording.** AirPods and other headsets keep recording when macOS
  switches them to call mode, instead of restarting in a loop.

### Private by design

- **Nothing leaves your Mac.** All three models run locally with MLX, and after the first
  download no internet connection is needed.
- **One set of models, two modes.** Dictation and the live transcript share one copy of each
  model, about 3 GB of memory with the defaults.
- **History you control.** Dictations are kept on this Mac only, never synced, and **Dictation
  History** finds them by what you said, what was typed or the app. Set how long they are kept,
  or turn history off.
- **See what the AI changed.** Each entry shows the typed text beside what you said, with
  **Copy Original** to get your own words back.
- **Discreet about what you say.** Dictated text is never written to the system log. Pasted
  text is marked so clipboard managers that honour the nspasteboard.org convention skip it. The
  app's own VoiceOver announcements wait until you finish dictating, so they aren't dictated
  along with you.

### A live transcript, too

- **Watch your words appear.** Press **Start Transcribing** and words show up while you are
  still talking, then each line is cleaned in place.
- **See every change.** A wand icon marks each line the model corrected, and its tooltip shows
  the raw text.
- **Every line in context.** Each line is cleaned with up to three lines before it as context.
- **Stop without losing the end.** **Stop** turns the microphone off at once, then finishes and
  saves every line you already spoke.
- **Every session saved.** Each session is a JSON Lines file with the raw and cleaned text and
  per-stage timings, ready for your own scripts, and **Copy** puts the whole transcript on the
  clipboard.

### Easy to start, easy to trust

- **Guided setup.** **Set Up Dictation** walks you through microphone access, Accessibility and
  the fn key, ticks off each step as soon as macOS reports it, and ends with a practice box.
- **Problems come with a fix.** The menu bar icon and status line show whether dictation is
  ready, listening, downloading models or waiting for a permission, and a missing permission
  comes with a button that opens the right System Settings pane.
- **Built for VoiceOver.** Setup, Settings, the menu and the history window are labelled for
  VoiceOver, and status changes are announced.
- **Open all the way down.** MIT licensed, with more than 1,000 tests, a **Bench** tool that
  measures accuracy and speed on your own recordings, and a **Train** tool that rebuilds the
  self-correction adapter on your Mac, in Swift (the bundled one took 30 minutes).
- **Bring your own models.** Point **Settings › Advanced** at another Hugging Face
  speech-to-text, cleanup or voice-activity model that the MLX libraries can load. Or turn the
  language model off, and dictation still removes fillers and lays out spoken lists and letters
  at Medium and High.

## Coming next

Ideas for a later phase. None of this is started, and **none of it is in the app yet**:

- Bullet lists without spoken markers. Today a list needs "first… second…", "number one…" or
  "bullet point…".
- Paragraph breaks in long dictations, without saying "new paragraph".
- Per-app cleanup level and tone. Apps can be set single-line today, but every app gets the
  same cleanup.
- Awareness of the focused app's context.
- **Command Mode**: select text and say how to change it.
- Multilingual cleanup. Today dictation and cleanup are English only.

## Status

A working proof of concept, free and open source under the [MIT License](LICENSE).

- There are no prebuilt downloads: build it from source (below).
- Tested on an M4 Pro Mac with macOS 27 and Xcode 27. The app targets macOS 14 or later but has
  not been run on older systems.
- Tested with English speech. Parakeet v3 also recognises other European languages, but the
  cleanup step has not been tested with them.
- Issues and pull requests are welcome.

## Requirements

- An Apple silicon Mac. With the default models the app uses about 3 GB of memory. It has not
  been tested on 8 GB Macs.
- To build: Xcode 26.4 or later (Swift 6.3 or later), with its Metal Toolchain component
  (`xcodebuild -downloadComponent MetalToolchain`). MLX compiles Metal shaders, so build with
  `xcodebuild` or Xcode; `swift build` produces binaries without the Metal library.
- Disk space: about 3.5 GB for the models (Parakeet TDT 0.6B v3 is 2.5 GB, Qwen3-1.7B-4bit about
  1 GB) and about 2 GB for the build. The tests and the bench need roughly 7 GB more: their own
  copy of the models and their own build.

## Build and run

From the repository root:

```bash
xcodebuild build -project LiveTranscribe.xcodeproj -scheme LiveTranscribe -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-app -skipPackagePluginValidation
```

```bash
open .build/xcode-app/Build/Products/Release/LiveTranscribe.app
```

Or open `LiveTranscribe.xcodeproj` in Xcode and choose Run. The shared scheme runs the
**Release** configuration, because MLX inference in Debug is several times slower. On the first
build Xcode asks you to trust mlx-swift's `CudaBuild` build-tool plugin, which only does work in
CUDA builds; `-skipPackagePluginValidation` skips that prompt on the command line.

### First launch

Live Transcribe runs in the menu bar. It has a Dock icon and a main menu only while one of its
windows is open, and it keeps running when you close them all.

While dictation is on and a permission is missing, **Set Up Dictation** opens at launch. Its
steps are **Microphone**, **Accessibility** (which lets the dictation shortcut work in every app
and type the text), **fn key** (only while fn is the shortcut) and **Try it**, a practice box.
Every step can be skipped, and each is checked again when you come back from System Settings.
**Set Up Dictation…** stays in the menu bar menu while a permission is missing. If macOS still
won't let Live Transcribe paste after Accessibility is switched on, setup and **Settings ›
Permissions** say so and offer **Reopen Live Transcribe**.

At the same time the app downloads the models (about 3.5 GB) into the Hugging Face cache
(`~/.cache/huggingface`, shared with the tests, the bench and other Hugging Face tools). The menu
bar and the transcript window show the progress. Dictation and **Start Transcribing** become
available once the models have loaded. If the cleanup model fails to load, the app transcribes
without cleanup and offers **Retry**.

### Signing and Gatekeeper

The app is built for Developer ID distribution: it runs outside the App Sandbox (inserting text
into other apps needs the Accessibility permission, which sandboxed apps cannot use), with the
Hardened Runtime and only the microphone entitlement. That rules out the Mac App Store.

Builds from this repository are ad-hoc signed ("Sign to Run Locally") by default and not
notarized, so they run on the Mac that built them. Gatekeeper blocks a copy downloaded onto
another Mac; build it there instead, or allow it under System Settings › Privacy & Security. To
distribute a build, sign it with your Developer ID and notarize it.

**The ad-hoc signature changes with every build.** After a rebuild, macOS asks for microphone
access again, and the Accessibility permission must be granted again: remove the old Live
Transcribe entry in Privacy & Security › Accessibility and add the new build. Until then the
shortcut does not work. If the floating panel then says to quit and reopen Live Transcribe so it
can paste, do that: **Reopen Live Transcribe** in **Settings › Permissions** does it for you.

**To keep the permissions across rebuilds, sign with your own certificate.** Copy
`Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` (gitignored) and set
your team ID. An Apple Development certificate is enough; Xcode › Settings › Accounts makes one
for free with any Apple ID. macOS then ties the permissions to the certificate rather than to
each build: grant them once more after switching, and they survive every rebuild after that.

## Using Live Transcribe

### Dictation

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

### Cleanup levels

| Level | What cleanup changes |
|---|---|
| **None** | Nothing. The transcript is inserted as heard, with your snippets, vocabulary and spoken commands applied. |
| **Light** | Punctuation, casing and misheard words. Fillers and self-corrections are kept as spoken; the model is told not to add or remove words (it may drop a repeated word such as "the the"). |
| **Medium** (default) | Light, plus: fillers such as "um" are removed, spoken self-corrections are resolved ("Monday, no wait, Tuesday" → "Tuesday"), and spoken lists and letters are laid out wherever line breaks are allowed. |
| **High** | Medium, plus light rewording for grammar and clarity. On a 1.7B model it behaves close to Medium. A dictation with a self-correction is cleaned twice: Medium's pass resolves the correction, then High's rewords the result, and if that rewording is rejected, Medium's result is used. |

- Choose the level from **Cleanup** in the menu bar or in **Settings › General › Cleanup**. It
  applies to dictation and the live transcript. Snippets, vocabulary, spoken commands and layout
  apply to dictation only.
- Self-correction cues are "sorry", "I mean", "I meant", "no", "wait", "rather", "actually",
  "make that", "scratch that" and "correction". The bundled adapter resolves them at Medium and
  High only (**Resolve spoken self-corrections** in **Settings › Advanced**, on by default).
- A list needs at least two items, marked by spoken ordinals in order from "first" ("first",
  "second", … or "firstly", …, each starting a clause; "finally" or "lastly" may end it), by
  "number", "item" or "step" with the numbers one, two, … in order, or by "bullet point". A
  marker that is talked about stays as said: after "the" or "a", after "is" or "are" ("cost is
  number two"), or for bullets after "first", "second", … ("the second bullet point is wrong").
  An "is" that only introduces the item goes with its marker ("first is call the bank", "second
  thing is…", "number one is…"), but not after a comma or in a question ("first, is it ready?").
  The markers become "1." or "-", each item starts with a capital, the line before the list ends
  with a colon, and items keep their full stops only if every item is a sentence of four words
  or more. No other words change. Lists and letters are laid out only where line breaks are
  allowed (see [How each app is handled](#how-each-app-is-handled)).
- OutputGuard checks every output of the model. The uncleaned text is used instead, with fillers
  still removed and lists and letters still laid out, if the output:
  - is empty or chatty;
  - drops a correction cue without a genuine self-correction;
  - deletes a run of spoken words (below High);
  - leaves out a word that carries meaning, at any level ("milk" from "milk, eggs and bread"):
    rewording may replace, reorder or respell words, but not drop them;
  - drops or moves a name ("hi John … cheers Sam" → "Hi Sam, … Cheers."), or drops a negation;
  - alters a placeholder (for a snippet, emoji, address, line break or list marker);
  - changes the word count or the text too much;
  - or takes longer than 3 s (**Timeout** in **Settings › Advanced**).

  In dictation this is silent: **Dictation History** shows it and the reason, if history is on.
- With **Clean up transcripts with the LLM** off in **Settings › Advanced**, nothing is reworded.
  In dictation, Medium and High still remove fillers and lay out lists and letters, and
  snippets, vocabulary and spoken commands still apply; the live transcript shows the raw text.
  The switch applies at the next launch.

### Spoken commands

Dictation turns these phrases into what they name, at every cleanup level. The language model
never sees an emoji, an address or a line break, only a placeholder it must copy.

| Say | Get |
|---|---|
| "emoji fireworks", "heart emoji", "emoji party popper" | 🎆, ❤️, 🎉: about 350 common names, then any Unicode emoji name |
| "question mark", "exclamation mark", "full stop", "comma", "semicolon" | ? ! . , ; |
| "open quote … close quote", "quote … unquote", "open bracket … close bracket" | "…" and (…) |
| "new line", "new paragraph" | a line break or a blank line; a space in single-line apps and fields |
| "john dot smith at example dot com", "example dot com slash pricing", "w w w dot example dot org" | john.smith@example.com, example.com/pricing, www.example.org |

- A command is a command only when it is not talked about: "a question mark", "the fire emoji",
  "Apple's new line" and "new line of code" stay as said. "Period", "colon" and "dash" always
  stay words, because they are common nouns ("the trial period").
- A comma or semicolon needs a word after it. Quotes and brackets work only in pairs, so a lone
  "end quote" or the idiom "quote unquote" stays as said.
- An address needs a known ending (.com, .org, .io, .co.uk, …). An email address needs a dot,
  underscore or digit in its name, or a word such as "email", "to" or "at" before it.
- "Fireworks" is 🎆 (Unicode's FIREWORKS); 🎇 is "sparkler". A snippet with the same words wins
  over a command, so you can map any phrase to the emoji you prefer.

### Snippets, vocabulary and apps

- **Settings › Snippets**: a **Trigger phrase** and the **Text to insert**. Triggers match whole
  words, ignoring case and punctuation. The text is inserted exactly as written, line breaks
  included, at every cleanup level; the language model sees only a placeholder.
- **Settings › Vocabulary**: a **Term**, spelled as you want it written, and optional **Spoken
  variants**, one per line. Each variant is replaced by the term at every level ("I work at nerd
  storm." → "I work at Nerdstorm."). Terms with distinctive casing, such as GitHub or macOS, are
  also re-cased wherever they appear. From Light up, each dictation also gives the cleanup model
  up to 50 of the most relevant terms (**Vocabulary terms per dictation** in **Timing**).
- **Settings › Apps**: for any app, **Insert text with** **Accessibility** or **Paste**, and
  **Line breaks** **Multi-line** or **Single-line**. Built in, paste is used for Terminal, iTerm2,
  Warp, Ghostty, Alacritty, kitty, WezTerm, VS Code, Cursor, Slack, Discord, Notion, Figma,
  Claude, Chrome, Brave, Edge and Arc, and the seven terminals are single-line. Your setting wins
  over a built-in one. See [How each app is handled](#how-each-app-is-handled).
- The three lists are JSON files you can also edit by hand. A damaged file (one that can't be
  decoded) is renamed to `<name>.corrupt-<timestamp>` rather than overwritten, and Settings says
  where it went.

### How each app is handled

Live Transcribe looks at the app and the field you dictate into. Two things can be set for each
app in **Settings › Apps**; everything else happens by itself.

| Setting | Choices | Out of the box |
|---|---|---|
| **Insert text with** | **Accessibility**: typed into the field and checked, clipboard untouched, and pasted if the app doesn't accept it. **Paste**: ⌘V, then your clipboard is put back. | Accessibility; Paste for 7 terminals and 11 Electron and Chromium apps |
| **Line breaks** | **Multi-line**: lists, letters and "new line" get line breaks, except in a field that takes one line. **Single-line**: everything stays on one line; lists and letters stay in the sentence, and "new line" types a space. | Multi-line; Single-line for the 7 terminals, where a line break could run a command |

A field takes one line when it is a text field of the app's own window: an address bar, a
search box, a form field, an email's subject line. A text box in a web page, in a browser or an
Electron app such as Slack, always counts as taking several lines, because browsers report
message boxes as text fields too. Delete your setting for an app to go back to the built-in one.

In every app, whatever its settings:

- **Password fields get nothing.** In a field macOS marks as secure, or while secure keyboard
  entry is on, recording stops at once and nothing is typed or copied. This is checked when you
  start, when you finish, and again just before a paste.
- **Text goes where you dictated.** A paste goes ahead only if the same app still has focus;
  otherwise the text waits on the clipboard. In a launcher panel such as Spotlight, the text goes
  to the panel, not to the app behind it.
- **Checked, never typed twice.** Text typed through Accessibility is read back and must match
  exactly. If the app took only part of it, the text goes on the clipboard instead of being
  pasted again.
- **Spaces where they belong.** A space is added after a word, but not after an opening bracket
  or before a full stop, in apps that let Accessibility read the text before the cursor.
- **The panel sits at your cursor** where the app reports it, and near the bottom of the screen
  otherwise.
- **Undo AI Edit stays in its field.** It works only in the app, and the field, the dictation
  went into.
- **Apps that hide their fields** from Accessibility get paste only, no automatic space, and the
  panel near the bottom of the screen.

### Dictation History

**Dictation History…** in the menu bar lists saved dictations, newest first. Search matches the
inserted text, what you said and the app, ignoring case and accents. Each entry shows both texts,
the app, the cleanup level, whether cleanup fell back and why, how the text was delivered, the
audio length and the latency, with **Copy**, **Copy Original** and **Delete**.

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

### Settings

**Settings** (⌘, or the menu bar) has seven tabs, along the top of its window:

| Tab | What it holds |
|---|---|
| **General** | **Enable dictation**, the shortcuts, the cleanup level, the microphone, **Keep the microphone ready**, and **Timing**: 13 controls for gestures, recording limits, undo, messages, pasting, Accessibility and vocabulary |
| **Snippets** | trigger phrases and the text they insert |
| **Vocabulary** | names and jargon, with how they are spoken |
| **Apps** | per app, how text goes in (Accessibility or paste) and whether it takes line breaks |
| **History** | dictation history on or off, retention, clearing |
| **Permissions** | microphone and Accessibility status, with buttons that open the right System Settings pane, and **Reopen Live Transcribe** when macOS won't let it paste until it reopens |
| **Advanced** | for dictation and the live transcript: the speech-to-text and cleanup models, **Clean up transcripts with the LLM**, **Resolve spoken self-corrections**, the cleanup **Timeout**, the GPU cache and capture restarts; for the live transcript only: the voice-activity model, silence, speech threshold, pre-roll and minimum speech, maximum segment length, live partials, context segments and queue capacity |

Settings on every tab but **Advanced** apply immediately, to the next dictation. **Settings on
the Advanced tab apply the next time the app starts.** Its **Restore Defaults** resets only that
tab: dictation settings, shortcuts, cleanup level, history and microphone stay as they are.

## Privacy

- Audio and transcripts never leave your Mac. There is no telemetry.
- The only network traffic is to Hugging Face (huggingface.co and the download servers it
  redirects to), to download the models on first launch, and on the next launch after you choose
  a different model in Settings. Downloaded models are reused without contacting Hugging Face
  again.
- **Dictation history is on by default.** Every completed dictation (what you said, the text
  inserted, the app, the cleanup level, whether and why cleanup fell back, how the text was
  delivered, and timings) is kept unencrypted in
  `~/Library/Application Support/org.nerdstorm.LiveTranscribe/History/dictations.jsonl`, on this
  Mac only and readable only by your account. It is never synced to iCloud or anywhere else.
  Cancelled dictations are never saved. Turn history off, set how long it is kept, or clear it in
  Settings › History; **Dictation History** in the menu bar shows and searches it, and deletes
  single dictations.
- Snippets, vocabulary and per-app settings are JSON files in
  `~/Library/Application Support/org.nerdstorm.LiveTranscribe/` (`snippets.json`,
  `vocabulary.json`, `insertion-overrides.json`), readable only by your account.
- Every live transcript session is saved as an unencrypted JSONL file in
  `~/Library/Application Support/org.nerdstorm.LiveTranscribe/Sessions/`, which the **Sessions**
  button opens. Each line holds one segment: the raw and cleaned text, whether and why cleanup
  fell back to the raw text, start and end times, per-stage latencies, a timestamp and IDs. Files
  are kept until you delete them.
- Dictated text is not written to the system log. Transcript text, file paths and device names
  are logged only as private data, which macOS redacts. Text the app pastes is marked transient,
  so clipboard managers that honour the nspasteboard.org convention skip it; text left on the
  clipboard for you to paste is an ordinary copy.
- Deleting the app does not delete its data. To remove it, delete
  `~/Library/Application Support/org.nerdstorm.LiveTranscribe` (sessions, dictation history,
  snippets, vocabulary and per-app settings),
  `~/Library/Preferences/org.nerdstorm.LiveTranscribe.plist` (settings) and the models in
  `~/.cache/huggingface/hub` (folders named `models--mlx-community--…`, and `mlx-audio`).
- Earlier builds ran in the App Sandbox and kept their data in
  `~/Library/Containers/org.nerdstorm.LiveTranscribe`. The current app doesn't read it: move old
  sessions from its `Data/Library/Application Support/org.nerdstorm.LiveTranscribe/Sessions`
  folder if you want them, then delete the folder to free the models' space.

## Models and credits

The app downloads the models from Hugging Face. They are not part of this repository and not
covered by its licence. The cleanup adapter, a 10 MB LoRA adapter for Qwen3-1.7B, is part of
this repository.

| Role | Model used | Original model | Licence |
|---|---|---|---|
| Speech-to-text | [mlx-community/parakeet-tdt-0.6b-v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3) | [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Cleanup | [mlx-community/Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit) | [Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B) by the Qwen team, Alibaba Cloud | Apache-2.0 |
| Self-correction adapter | bundled (`Sources/Cleanup/Adapter`) | trained on synthetic data in this repository ([`Training/`](Packages/LiveTranscribeKit/Training/README.md)) | MIT |
| Voice activity detection | [mlx-community/silero-vad](https://huggingface.co/mlx-community/silero-vad) | [Silero VAD](https://github.com/snakers4/silero-vad) by the Silero team | MIT |

If you redistribute the Parakeet weights, for example bundled with a build, CC BY 4.0 requires
you to credit NVIDIA.

Other models can be tried in **Settings › Advanced** (a Hugging Face repository ID for each role;
it is downloaded on the next launch). They must be models mlx-audio-swift or mlx-swift-lm can
load, and the self-correction adapter is used only with mlx-community/Qwen3-1.7B-4bit.

Built with [mlx-swift](https://github.com/ml-explore/mlx-swift),
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm),
[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift),
[swift-huggingface](https://github.com/huggingface/swift-huggingface) and
[swift-transformers](https://github.com/huggingface/swift-transformers). Every package
dependency, including indirect ones, is MIT or Apache-2.0 licensed. Some bundle third-party code
under other permissive licences (MLX includes the BSD-licensed PocketFFT, for example), so a
redistributed build must carry those notices too.

## Project layout

```
App/                          menu bar app: menu, windows, composition root
LiveTranscribe.xcodeproj      app project (ad-hoc signed, hardened runtime, no App Sandbox)
docs/dictation.md             dictation: decisions, assumptions, settings and eval results
scripts/                      generate-test-audio.sh, generate-dictation-audio.sh
Packages/LiveTranscribeKit/   all feature code, as vertical slices
  Sources/
    Shared/          value types, AppSettings, logging, deadline, edit distance, atomic file writes
    Capture/         AVCaptureSession microphone capture → 16 kHz mono; microphone list and choice
    Segmentation/    Silero VAD + segmentation state machine (pre-roll, hysteresis, max length)
    Transcription/   Parakeet via mlx-audio-swift
    Cleanup/         Qwen3 via mlx-swift-lm, prompt, OutputGuard fallbacks, fine-tuned adapter
    Persistence/     JSONL session files and dictation history
    Session/         SessionCoordinator (lifecycle) + SessionPipeline (3 concurrent stages)
    TranscriptUI/    live transcript view model and views
    Hotkey/          global shortcut monitor (event tap), hold/double-tap gestures, bindings
    Permissions/     Accessibility and microphone permission, System Settings links
    Insertion/       typing at the cursor: Accessibility, paste with clipboard restore, per-app settings
    Styles/          rule-based filler removal and layout: lists and letters
    SpokenCommands/  emoji, punctuation, line breaks and addresses said aloud
    Snippets/        trigger phrases and the text they insert
    Vocabulary/      names and jargon, with how they are spoken
    Dictation/       DictationController: hotkey → record → transcribe → clean up → insert
    DictationUI/     menu bar menu, floating panel, setup, Settings tabs, history window
    MLXSupport/      MLX runtime configuration (GPU cache limit)
    Bench/           command-line tool: WER and latency over test clips, live transcript or dictation
    CleanupTraining/ dataset, LoRA training and evaluation for the cleanup adapter
    Train/           command-line tool: generate, validate, train and evaluate the adapter
  Tests/             Swift Testing; tests that need the models run only when enabled
  Training/          the adapter's dataset, and how it is trained (Training/README.md)
```

`App/AppComposition.swift` is the app's composition root: it constructs every concrete slice
implementation (the bench and the tests wire their own). The Settings window is the exception: it
reads and writes the settings in UserDefaults directly. Everything else depends on protocols
(`AudioSource`, `SpeechSegmenter`, `Transcriber`, `Cleaner`, `SessionSink`,
`MicrophonePermissionProviding`, for dictation `HotkeyMonitor`, `FocusedTargetProvider`,
`TextDelivery`, `DictationHistory` and `AccessibilityPermissionProviding`, and in the UI
`SessionControlling` and `InputDeviceSelecting`), which the unit tests replace with fakes or, for
`SessionSink`, the in-memory `MemorySessionSink`. Dictation and the live transcript share one
instance of each model; they never run at the same time.

## Tests

The package has more than 1,000 Swift Testing tests. Unit tests need no models:

```bash
(cd Packages/LiveTranscribeKit && xcodebuild test -scheme LiveTranscribeKit-Package -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -skipPackagePluginValidation -skip-testing:IntegrationTests)
```

The end-to-end tests and the bench use short spoken clips. The clips are not in the repository,
because Apple's licence does not allow publishing recordings of its system voices. Generate them
with macOS text-to-speech before building the tests:

```bash
scripts/generate-test-audio.sh
```

The dictation eval's 44 clips (`Tests/IntegrationTests/Fixtures/Dictation/clips.tsv`) are
generated the same way:

```bash
scripts/generate-dictation-audio.sh
```

The end-to-end tests run the real models, downloading them into `~/.cache/huggingface`.
xcodebuild passes environment variables to the test runner only with the `TEST_RUNNER_` prefix:

```bash
(cd Packages/LiveTranscribeKit && TEST_RUNNER_LT_RUN_MODEL_TESTS=1 xcodebuild test -scheme LiveTranscribeKit-Package -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -skipPackagePluginValidation -only-testing:IntegrationTests)
```

Set `TEST_RUNNER_LT_PROMPT_PROBE=1` instead to print the cleanup model's output for a set of
hard prompt cases, a development aid for prompt changes.

## Bench

```bash
(cd Packages/LiveTranscribeKit && xcodebuild build -scheme Bench -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -skipPackagePluginValidation)
```

```bash
(cd Packages/LiveTranscribeKit && .build/xcode/Build/Products/Release/Bench)
```

Options:

- `--fixtures <dir>`: a folder of `.wav` clips, each with a matching `.txt` transcript.
- `--level <none|light|medium|high>`: the cleanup level (default: Medium).
- `--no-cleanup`: speech-to-text only.
- `--no-adapter`: clean up without the fine-tuned self-correction adapter.
- `--fast`: feed audio as fast as possible instead of in real time. Latency numbers are then
  meaningless.

The bench prints the word error rate (WER) of the raw and cleaned text, p50 and p95 latency per
stage, and four checks:

- p95 from end of speech to text on screen is under 1.5 s;
- cleaned WER is no worse than raw WER;
- no clip's WER gets more than 2 points worse after cleanup;
- cleanup falls back to the raw text for fewer than 5% of segments.

Last run, on an M4 Pro with the four generated clips played in real time. **These numbers are
from Parakeet v2, the previous default; v3 has not been benchmarked yet.**

| Stage | p50 (ms) | p95 (ms) |
|---|---:|---:|
| Silence that ends a segment | 608 | 608 |
| Speech-to-text | 68 | 113 |
| Cleanup | 157 | 403 |
| End of speech → text | 837 | 1126 |

WER was 1.0% raw and 1.0% cleaned, with no fallbacks, and all four checks passed. The first row
is the configured 600 ms of silence that closes a segment; lower `vadSilenceMs` to trade it for
more segment splits. The clips are synthetic speech, so measure with real recordings on your own
hardware before relying on these numbers. Speech-to-text and cleanup calls are also marked as
signpost intervals ("STT", "LLM") for Instruments.

### Dictation eval

```bash
(cd Packages/LiveTranscribeKit && .build/xcode/Build/Products/Release/Bench --dictation)
```

Runs the 65 dictation clips (plain sentences, fillers, self-corrections, questions, longer
passages, emoji, dictated punctuation, addresses, line breaks, spoken lists and letters) through
dictation's speech-to-text and cleanup at every cleanup level, and reports per level and
category the WER against what was *said* and against what was *meant* (fillers dropped,
self-corrections resolved, commands turned into what they name), the fallbacks, and p50/p95
latency against the target of p95 under 1.2 s. Latency here is speech-to-text plus cleanup;
stopping the recorder and inserting the text are not included. `--multiline` dictates into a
multi-line field, where line breaks, lists and letters are laid out, and adds how many clips came
out with the intended lines. `--level <none|light|medium|high>` (repeatable) limits the levels,
`--clips <dir>` reads other clips, `--p95-target-ms <n>` changes the target, `--no-adapter`
cleans up without the adapter and `--verbose` prints every output, with the reason for each
fallback.

Last run, on an M4 Pro with macOS 27 and synthetic speech, with `--multiline`:

| Level | WER vs said | WER vs meant | Fallbacks | p50 (ms) | p95 (ms) | Laid out as meant |
|---|---:|---:|---:|---:|---:|---:|
| None | 10.9% | 20.1% | 0 | 34 | 66 | 57/65 |
| Light | 11.1% | 19.9% | 2 | 162 | 325 | 57/65 |
| Medium | 21.8% | 2.2% | 3 | 185 | 423 | 65/65 |
| High | 21.8% | 2.2% | 3 | 210 | 426 | 65/65 |

Medium resolved all 12 self-corrections and removed the fillers from all 10 filler clips, and
Medium and High laid out every list and letter. WER against what was said counts each spoken
command as wrong, because it is replaced by what it names. None and Light lay out only line
breaks, by design. Every level met the latency target; High takes longer on self-corrections
because it cleans them in two passes.

The fallbacks, where OutputGuard rejected the model's output and the uncleaned transcript was
inserted:
- The same plain sentence at Medium and High ("I've attached the invoice and the signed
  agreement."): the self-correction adapter changed a sentence that had nothing to correct
  (three spoken words dropped at Medium; similarity 0.48, below the floor, at High).
- Two spoken lists at Medium and High: the model rewrote a bulleted list, dropping three of its
  words, and dropped an item from a numbered one. The uncleaned text was still laid out as meant.
- Two clips at Light, which keeps every word: the long letter, where the model resolved its
  self-correction, and the numbered list, where it dropped the spoken word "number" to number the
  items itself.

Without `--multiline` (a single-line field), where lists are not laid out, Light falls back on 2
clips and Medium and High on 5 each. The model drops "number" or "bullet point" to lay a list
out itself, and it moves the name in a letter's sign-off into the greeting; a letter is cleaned
as a whole there. The longest clip is about 40 words, so these numbers say nothing about long
dictations.

## Training the adapter

The self-correction adapter is trained on the Mac, in Swift, with the `Train` tool: `generate`
builds the synthetic dataset, `validate` checks every example against the app's own OutputGuard,
`train` fine-tunes the adapter and `evaluate` measures it as the app runs it. On 515 held-out
examples of synthetic sentences it resolved 97.3% of self-corrections (the base model 0.8%) and
kept 98.4% of look-alike sentences as spoken. On the 95 curated held-out examples alone, written
separately from the generator's templates, it resolved 39 of 40 corrections. Commands and full
results are in [Training/README.md](Packages/LiveTranscribeKit/Training/README.md).

## Design notes

- **Two pipelines, one set of models.** The live transcript runs microphone → Silero voice
  activity detection → Parakeet speech-to-text → Qwen3-1.7B cleanup at the chosen level → window
  and JSONL file. Dictation runs shortcut → recording → Parakeet → placeholders for snippets,
  spoken commands and list markers, and vocabulary → filler rule, letter frame and Qwen3-1.7B
  cleanup, checked by OutputGuard → line breaks and layout → snippets, emoji and addresses
  restored → text at the cursor. One Parakeet and one Qwen3-1.7B instance serve both.
- **A menu bar app.** Dictation has to be available in every app, so Live Transcribe lives in
  the menu bar (`LSUIElement`) and becomes a regular app with a Dock icon only while one of its
  windows (transcript, history, Settings, setup) is open.
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

More decisions, and the assumptions behind them, are in [docs/dictation.md](docs/dictation.md).

## Known limitations

- **A Bluetooth headset's microphone switches the headset into call mode.** macOS does this
  whenever any app opens a headset microphone: the headset drops to 16 kHz and its playback
  quality falls until capture stops. Transcription works, but for better playback use the
  built-in or a wired microphone while the headset plays audio.
- **Dictation needs Accessibility, which macOS ties to the app's signature.** Each ad-hoc
  rebuild is a new app to macOS: remove Live Transcribe from Privacy & Security › Accessibility
  and add the new build, or the shortcut stops working. Builds signed with your own certificate
  keep the permission (see [Signing and Gatekeeper](#signing-and-gatekeeper)).
- **Pasting can need a reopen after Accessibility is switched on.** Seen once, after the
  Accessibility entry was removed and added back while the app ran: Accessibility read as on and
  the shortcut worked, but macOS refused to let the app send ⌘V, so text for apps that are
  pasted into (terminals, browsers, Electron apps) was left on the clipboard. The panel, setup
  and **Settings › Permissions** now say so and offer **Reopen Live Transcribe**. That reopening
  fixes it is expected but not yet confirmed.
- **Long dictations are untested.** The eval's longest clip is about 30 words. Cleanup runs on
  the whole dictation under a 3 s timeout, so a dictation longer than a minute or two will likely
  be inserted uncleaned (fillers still removed at Medium and High), without a message. Past the
  recording limit (5 minutes by default) speech is dropped, and the panel says so only when you
  finish.
- Correcting with a 1.7B model does not reliably fix homophones ("cash" → "cache"). That needs a
  larger model; in dictation, a vocabulary entry fixes a specific one. OutputGuard's similarity
  floor limits how far the model can change the text. **High** behaves close to Medium for the
  same reason.
- Spoken self-corrections ("fuel efficiency in cars, sorry, buses" → "fuel efficiency in buses")
  are resolved by a small fine-tuned adapter trained on synthetic data, so expect lower accuracy
  on real speech than the 97% it scored on synthetic held-out examples. OutputGuard rejects any
  cleanup that drops a correction cue ("sorry", "I mean", "no", "wait", "actually", "scratch
  that", …) unless the only words it removed were up to six retracted words before that cue, the
  cue itself, fillers such as "um", and immediately repeated words; and cleanup that keeps every
  cue may not delete a run of spoken words, a word that carries meaning or a negation, or move a
  name.
- The self-correction adapter occasionally rewrites a plain sentence (1 of 65 eval clips);
  OutputGuard catches it and inserts the raw transcript instead of the cleaned text. In
  dictation such a fallback is silent: only **Dictation History** shows it, if history is on.
- Spoken lists are laid out only when you say their markers ("first…", "number one…", "bullet
  point…"), and lists and letters only where line breaks are allowed. The model sometimes drops
  or rewrites a list item; OutputGuard then inserts your words, still laid out.
- A text box in a web page always counts as taking several lines, so a list dictated into a
  web page's one-line field, such as a site's search box, gets line breaks the field then drops
  ("items:1. Milk"). Set that browser to single-line if it happens often.
- In a single-line field a letter is cleaned as a whole, and the model sometimes moves the name
  in the sign-off into the greeting ("hi John … cheers Sam" → "Hi Sam, … Cheers."). OutputGuard
  rejects that, so your words are inserted uncleaned.
- OutputGuard catches a word left out and a name moved, but not a word replaced by a different
  one ("milk" → "cream", "three" → "4") unless it is a name. Words that only hold a sentence
  together ("the", "of", "really") may still be dropped. Names are recognised by the capital
  letter speech-to-text gives them.
- The floating panel sits next to the cursor, and a leading space is added, only in apps that
  report their text through Accessibility. Elsewhere the panel appears near the bottom of the
  screen and no space is added.
- After a pasted dictation, **Undo AI Edit** can't tell whether you typed more in the same field;
  ⌘Z then undoes that typing first.
- The microphone opens while the focused field is read, so in a password field the microphone
  indicator may flash briefly. The recording is thrown away before it is transcribed, and
  nothing is typed.
- Reserved system shortcuts (⌘Space, ⌘Tab, …) are recognised by key position on a US layout, so
  on other layouts Settings may accept a shortcut that macOS already uses.
- ⌃⌥Space is allowed as a shortcut but can clash with input-source switching on some Macs.
- If the app crashes, up to `cleanupQueueCapacity` + 1 segments (9 by default) that were
  transcribed but not yet cleaned are lost: their raw text was on screen but not yet saved.
- The models come from each repository's `main` branch at first launch and are then reused, so
  Macs that install at different times can end up with different model versions.
- mlx-audio-swift copies the speech-to-text weights into a second folder of the Hugging Face
  cache; on APFS the copy is a clone, so `du` counts it twice but it takes no extra space.

## License

[MIT](LICENSE) © 2026 Nerdstorm. The licence covers this repository's code only. The models
(see [Models and credits](#models-and-credits)) and the Swift package dependencies have their own
licences.
