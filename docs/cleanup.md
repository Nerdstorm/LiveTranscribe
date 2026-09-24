# Cleanup and spoken commands

## Cleanup levels

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
  "second", … or "firstly", …, each starting a clause; "finally" or "lastly" may end it), by the
  numbers one, two, … in order, each starting a clause and followed by "is", a comma, a colon or
  a full stop ("one is the launch, two, the marketing"), by "number", "item" or "step" with the
  numbers one, two, … in order, or by "bullet point". A
  marker that is talked about stays as said: after "the" or "a", after "is" or "are" ("cost is
  number two"), or for bullets after "first", "second", … ("the second bullet point is wrong").
  An "is" that only introduces the item goes with its marker ("first is call the bank", "second
  thing is…", "number one is…"), but not after a comma or in a question ("first, is it ready?").
  The markers become "1." or "-", each item starts with a capital, the line before the list ends
  with a colon, text after the list starts a new paragraph, and items keep their full stops only
  if every item is a sentence of four words or more. No other words change. Lists and letters are
  laid out only where line breaks are allowed (see
  [How each app is handled](snippets-vocabulary-apps.md#how-each-app-is-handled)).
- A letter needs a greeting at the start ("Dear…", "Hi…", "Hello…", "Good morning…") and a
  sign-off at the end ("Kind regards", "Sincerely", "Best wishes", …). An everyday sign-off
  ("Thanks", "Thank you", "Cheers", "Best", "Love") counts before a name, or with no name after
  a body of two sentences or more or a spoken list, so a one-line chat message ("Hi John, can
  you send it? Thanks") stays as it is. The greeting and the sign-off get lines of their own,
  and only the body goes to the model.
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

## Spoken commands

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
