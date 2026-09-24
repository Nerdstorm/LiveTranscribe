# Features

## Say it naturally, get what you meant

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
  "first… second… and third…", "one is… two is…", "number one… number two…" or "bullet point…
  bullet point…" and
  each item gets its own numbered or bulleted line, under a lead-in ending in a colon. The items
  keep your words.
- **Letters and emails laid out.** Start with a greeting ("Dear sir or madam", "Hi John") and
  end with a sign-off ("Kind regards Jordan Lee", "Cheers Sam"), and at Medium or High, in any
  app that takes several lines, the greeting and the sign-off each get their own lines. The
  model cleans only the body, so it cannot move the names around.
- **Emoji, punctuation and line breaks by voice.** At every level, say "hi emoji fireworks" for
  "hi 🎆", "thanks heart emoji" for "thanks ❤️", "is it ready question mark" for "is it ready?",
  "new line" or "new paragraph" for a line break, and "john dot smith at example dot com" for
  john.smith@example.com. See [Spoken commands](cleanup.md#spoken-commands).
- **You choose how much it edits.** Pick **None**, **Light**, **Medium** or **High** from the
  menu bar in two clicks, and your next dictation uses it.
- **Undo the AI, keep your words.** Press ⌃⌥Z within 30 seconds, in the field you dictated
  into, and what you actually said replaces the cleaned text, with your snippets, vocabulary and
  spoken commands still applied.
- **A safety net against rewrites.** Every edit is checked. If the model drops a "not", deletes
  words you said (below High) or rewrites too much, your own words are typed instead, with
  fillers still removed and lists and letters still laid out at Medium and High.

## Dictate from any app

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

## Make it yours

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

## Dependable, app after app

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
  [How each app is handled](snippets-vocabulary-apps.md#how-each-app-is-handled).
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

## Private by design

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

## A live transcript, too

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

## Easy to start, easy to trust

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
- **Keeps itself up to date.** A downloaded release checks GitHub for a new version about once
  a day, if you let it, without interrupting what you're doing. Updates are signed and checked
  before they install.
- **Bring your own models.** Point **Settings › Advanced** at another Hugging Face
  speech-to-text, cleanup or voice-activity model that the MLX libraries can load. Or turn the
  language model off, and dictation still removes fillers and lays out spoken lists and letters
  at Medium and High.

## Coming next

Ideas for a later phase. None of this is started, and **none of it is in the app yet**:

- Bullet lists without spoken markers. Today a list needs "first… second…", "one is… two is…",
  "number one…" or "bullet point…".
- Paragraph breaks in long dictations, without saying "new paragraph".
- Per-app cleanup level and tone. Apps can be set single-line today, but every app gets the
  same cleanup.
- Awareness of the focused app's context.
- **Command Mode**: select text and say how to change it.
- Multilingual cleanup. Today dictation and cleanup are English only.
