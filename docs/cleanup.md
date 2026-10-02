# Cleanup and spoken commands

## Cleanup levels

| Level | What cleanup changes |
|---|---|
| **None** | Nothing. The transcript is inserted as heard, with spoken commands applied (and, on the Mac, your snippets and vocabulary). |
| **Light** | Punctuation, casing and misheard words. Fillers and self-corrections are kept as spoken; the model is told not to add or remove words (it may drop a repeated word such as "the the"). |
| **Medium** (default) | Light, plus: fillers such as "um" are removed, spoken self-corrections are resolved ("Monday, no wait, Tuesday" → "Tuesday"), and spoken lists and letters are laid out wherever line breaks are allowed. |
| **High** | Medium, plus light rewording for grammar and clarity. On a 1.7B model it behaves close to Medium. A dictation with a word that can cue a correction ("no", "actually", …, whether or not it is one) is cleaned twice: Medium's pass resolves the correction, then High's rewords the result, and if that rewording is rejected, Medium's result is used. |
| **Deep** | Medium, plus repairs that need the whole dictation: a correction that reaches back into an earlier sentence ("…whether the release is tomorrow. No, sorry, the after tomorrow." → "…whether the release is the day after tomorrow."), a garbled correction phrase read as meant, grammar ("he actually check" → "he actually checked") and misheard words fixed from what the rest says, and emails, letters and lists laid out wherever line breaks are allowed. It doesn't reword as High does: every change must be one of those repairs. Slower, and never the default. |

The levels work the same on the Mac, Linux and Windows: Linux and Windows run a Rust port of the
Mac app's prompts, checks and executor, held to the Swift code by test fixtures, with the same two
adapters ([Architecture](architecture.md)). Choose the level from the menu bar (Mac) or the tray
(Linux and Windows), or in **Settings › General**. It applies to dictation and, on the Mac, to the
live transcript. Spoken commands and layout apply to dictation only, as do the Mac's snippets and
vocabulary (Linux and Windows have none yet).

## What cleanup does

- **Self-corrections.** The cues are "sorry", "I mean", "I meant", "no", "wait", "rather",
  "actually", "make that", "scratch that" and "correction" (and, at Deep, "or rather"). A cue may be
  followed by "not" and the words it takes back, said again ("room four, no, not four, five" → "room
  five"); the "not" goes only then, so "Thursday, not Friday" keeps it. A small adapter, trained on
  synthetic data, resolves them at Medium and High; Deep has an adapter of its own. On the Mac,
  **Resolve spoken self-corrections** in **Settings › Advanced** (on by default) switches both
  adapters off, and then corrections are kept as spoken.
- **Deep** cares about what a cue follows: "No" that answers a question, "sorry" that apologises and
  "actually" that starts a new point stay ("Is the release tomorrow? No, it's the day after." is
  unchanged). A cue after a full stop corrects the end of the sentence before as it would after a
  comma, since speech-to-text writes a full stop where the speaker paused ("I left my charger in the
  garage. Actually, the lobby." → "I left my charger in the lobby."), but not a whole sentence ("I
  finished the report. Sorry, I was late." stays). Names, numbers, dates, times and negations are
  kept as said outside the words a correction takes back, and nothing is added that wasn't said. In
  a field that takes several lines, it lays out what you didn't: a short email's greeting, body and
  sign-off, and things you need or steps to take as a list, even when you didn't announce one ("We
  need milk, eggs and bread." becomes three bullets). It doesn't yet split a longer letter's body
  into paragraphs ([Known limitations](limitations.md)). What you lay out yourself, by saying "new
  line", "bullet point" or "number one", the layout rules lay out as at Medium.
- **Lists.** A list needs at least two items, marked by spoken ordinals in order from "first"
  ("first", "second", … to "tenth", or "firstly", …; "finally" or "lastly" may end it), by the
  numbers one, two, … to ten in order, each starting a clause and followed by "is" or "was", a
  comma, a colon or a full stop ("one is the launch, two, the marketing"), by "number", "item" or
  "step" with the numbers one, two, … to twenty in order (after "number one", the later numbers may
  be said bare: "Number one, the form. Two, the sign-in."; each then starts a clause after an item
  and is followed by a comma, colon, full stop or "is", so "number one, two, three" stays as said),
  or by "bullet point". A marker that is talked about stays as said: after a determiner or
  possessive ("the", "my", "Apple's") or a form of "be" ("cost is number two", "we're number one"),
  and a bullet marker also after an ordinal or "last", "next", "previous", "final" or "other" ("the
  second bullet point is wrong"). The markers become "1." or "-", each item starts with a capital,
  the line before the list ends with a colon, text after the list starts a new paragraph, and items
  keep their full stops only if every item is a sentence of four words or more. No other words
  change.
- **Letters.** A letter needs a greeting at the start ("Dear…", "Hi…", "Hello…", "Hey…", "Good
  morning…", "To whom it may concern") and a sign-off at the end ("Kind regards", "Sincerely",
  "Best wishes", …). An everyday sign-off ("Thanks", "Thank you", "Cheers", "Best", "Love", "Take
  care", "Talk soon") counts before a name, or
  with no name after a body of two sentences or more or a spoken list, so a one-line chat message
  ("Hi John, can you send it? Thanks") stays as it is. The greeting and the sign-off get lines of
  their own, and only the body goes to the model; Deep, in a field that takes several lines, is
  told that it is an email's body, which has no greeting or sign-off to write.
- **Where line breaks are allowed.** Lists, letters and "new line" get line breaks only in a
  field that takes several lines. In a field that takes one line, and on the Mac in an app you set
  to single-line, they stay in the sentence
  ([How each app is handled](snippets-vocabulary-apps.md#how-each-app-is-handled)). On Windows,
  only the system's own edit controls (Notepad's, older programs') are known to take several
  lines; browser, Electron and Office fields are typed on one line, with line breaks as spaces.
- **A check on every answer.** The model's answer is used only if it passes. Otherwise your own
  words are typed instead, with fillers still removed from Medium up and lists and letters still
  laid out. Below Deep, an answer fails if it:
  - is empty or chatty;
  - drops a correction cue without a genuine self-correction;
  - deletes a run of spoken words (below High), or leaves out a word that carries meaning at any
    level ("milk" from "milk, eggs and bread"): rewording may replace, reorder or respell words,
    but not drop them;
  - drops or moves a name ("hi John … cheers Sam" → "Hi Sam, … Cheers."), or drops a negation;
  - alters a placeholder (for a snippet, emoji, address, line break or list marker);
  - or changes the word count or the text too much.

  At every level an answer also fails if the cleanup takes longer than the timeout: 3 s, and at
  least 8 s at Deep (**Timeout** in **Settings › Advanced**). In dictation this is silent. On the
  Mac, **Dictation History** shows the fallback and why, if history is on. Deep has a check of its
  own (`SelfRepair`) in place of those on words, names, length and similarity: every difference from
  what was said must be one of the repairs Deep may make, numbers, negations, words of time and
  placeholders may never be added, dropped or changed outside what a correction takes back, and no
  other new word may appear. A name is kept as said, but a capital alone doesn't make one:
  speech-to-text capitalises letters you spell out and words it mishears, so Deep may join the
  letters ("P R" → "PR") and respell a misheard word where it writes it without a capital or at the
  start of a list item ("can you Madge it" → "can you merge it", "First, Madge the PR" → "1. Merge
  the PR"). It also turns down a line break in a field that takes one line, a bulleted list of
  fewer than three items (two are a list only when you set them off: with a colon or a pause that
  speech-to-text writes as a full stop, "a few things we need. Getting the feeds working and
  releasing the fix", or with a comma after words that count them, "two things, …"), and a
  placeholder alone on a line. When Deep's answer is turned down, Medium's pass runs in the time
  left, so Deep never shows less than Medium would.
- **With the language model off**, nothing is reworded. Medium, High and Deep still remove fillers
  and lay out lists and letters in dictation, and snippets, vocabulary and spoken commands still
  apply. The switch is **Clean up transcripts with the LLM** in **Settings › Advanced**; on the
  Mac it applies at the next launch, on Linux and Windows at once.

## Spoken commands

Dictation turns these phrases into what they name, at every cleanup level. The language model
never sees an emoji, an address or a line break, only a placeholder it must copy.

| Say | Get |
|---|---|
| "emoji fireworks", "heart emoji", "emoji party popper" | 🎆, ❤️, 🎉: 326 common emoji under 657 names, then any Unicode emoji name |
| "question mark", "exclamation mark", "full stop", "comma", "semicolon" | ? ! . , ; |
| "open quote … close quote", "quote … unquote", "open bracket … close bracket" | "…" and (…) |
| "new line", "new paragraph" | a line break or a blank line; a space in single-line apps and fields |
| "john dot smith at example dot com", "example dot com slash pricing", "w w w dot example dot org" | john.smith@example.com, example.com/pricing, www.example.org |

- A command is a command only when it is not talked about: "a question mark", "the fire emoji",
  "Apple's new line" and "new line of code" stay as said. "Period", "colon" and "dash" always
  stay words, because they are common nouns ("the trial period").
- A comma or semicolon needs a word on each side. Quotes and brackets work only in pairs, so a lone
  "end quote" or the idiom "quote unquote" stays as said.
- An address needs a known ending (.com, .org, .io, .co.uk, …). An email address needs a dot,
  underscore, hyphen, plus sign or digit in its name, or a word such as "email", "to" or "at" before
  it. One that speech-to-text writes out itself is kept too, in lower case.
- "Fireworks" is 🎆 (Unicode's FIREWORKS); 🎇 is "sparkler". A snippet with the same words wins
  over a command, so you can map any phrase to the emoji you prefer. An emoji said on its own
  after a sentence takes no full stop: "See you soon. 🙂".

## On Linux and Windows

Cleanup runs on the CPU with the same model, Qwen3-1.7B, which the app downloads at its first start
(0.9 GB,
[Nerdstorm/Qwen3-1.7B-MLX-4bit-OpenVINO](https://huggingface.co/Nerdstorm/Qwen3-1.7B-MLX-4bit-OpenVINO)).
Until it has loaded, nothing is reworded. A Medium cleanup takes about four times as long as on a
Mac (Deep hasn't been timed on a desktop CPU), so the timeout matters more: if long dictations go in
uncleaned, raise **Timeout** in **Settings › Advanced**. The model is the Mac's own weights
converted for OpenVINO, with the adapters as inputs of the model. Its answers match the Mac's: 509
of the Mac app's 515 Medium test cases word for word, and, run on a Mac's CPU, all 114 of Deep's
hand-written cases character for character
([linux-windows/README.md](../linux-windows/README.md#cleanup)).
