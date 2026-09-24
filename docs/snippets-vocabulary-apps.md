# Snippets, vocabulary and apps

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

## How each app is handled

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
**Settings › Apps** lists built-in settings only for apps on your Mac; the rest are counted
there and apply once the app is installed. Your own settings stay listed after their app is
removed, so you can still delete them.

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
