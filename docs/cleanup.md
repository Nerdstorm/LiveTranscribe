# Cleanup and spoken commands

## Cleanup levels

| Level | What cleanup changes |
|---|---|
| **None** | Nothing. The transcript is inserted as heard, with your snippets, vocabulary and spoken commands applied. |
| **Light** | Punctuation, casing and misheard words. Fillers and self-corrections are kept as spoken; the model is told not to add or remove words (it may drop a repeated word such as "the the"). |
| **Medium** (default) | Light, plus: fillers such as "um" are removed, spoken self-corrections are resolved ("Monday, no wait, Tuesday" → "Tuesday"), and spoken lists and letters are laid out wherever line breaks are allowed. |
| **High** | Medium, plus light rewording for grammar and clarity. On a 1.7B model it behaves close to Medium. A dictation with a self-correction is cleaned twice: Medium's pass resolves the correction, then High's rewords the result, and if that rewording is rejected, Medium's result is used. |
| **Deep** | Medium, plus repairs that need the whole dictation: a correction that reaches back into an earlier sentence ("…whether the release is tomorrow. No, sorry, the after tomorrow." → "…whether the release is the day after tomorrow."), a garbled correction phrase read as meant, grammar ("he actually check" → "he actually checked") and misheard words fixed from what the rest says, and emails, letters and lists laid out wherever line breaks are allowed. It doesn't reword as High does: every change must be one of those repairs. Slower, and never the default. |

- Choose the level from **Cleanup** in the menu bar or in **Settings › General › Cleanup**. It
  applies to dictation and the live transcript. Snippets, vocabulary, spoken commands and layout
  apply to dictation only. The Linux and Windows app has the same levels, with the same prompts,
  adapters and checks (see [Linux and Windows](#linux-and-windows)).
- Self-correction cues are "sorry", "I mean", "I meant", "no", "wait", "rather", "actually",
  "make that", "scratch that" and "correction". A cue may be followed by "not" and the words it
  takes back, said again ("room four, no, not four, five" → "room five"); the "not" goes only
  then, so "Thursday, not Friday" keeps it. The bundled adapter resolves them at Medium and
  High only (**Resolve spoken self-corrections** in **Settings › Advanced**, on by default).
  Deep has an adapter of its own, trained on its prompt, which the same switch turns off; without
  it Deep keeps corrections as spoken, like the other levels.
- At Deep, in a field that takes several lines, the model lays out what you didn't: a short
  email's greeting, body and sign-off, and things you need or steps to take as a list, even when
  you didn't announce one ("We need milk, eggs and bread." becomes three bullets). It doesn't yet
  split a longer letter's body into paragraphs or a list: the layout rules put that letter's
  greeting and sign-off on lines of their own, and the model gets only the body (see
  [Limitations](limitations.md)). What you lay out yourself, by saying "new line", "bullet point"
  or "number one", the layout rules lay out as at Medium, and the model keeps that dictation to
  one paragraph.
- At Deep, a cue only corrects what it follows: "No" that answers a question, "sorry" that
  apologises and "actually" that starts a new point stay ("Is the release tomorrow? No, it's the
  day after." is unchanged). Names, numbers, dates, times and negations are kept as said outside
  the words a correction takes back, and nothing is added that wasn't said.
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
- Deep's output gets a check of its own instead of the word-count and similarity limits: every
  difference from what was said must be one of the repairs Deep may make, found by lining up the
  said and the written words (`SelfRepair`). A word may be respelled, take another form of itself
  ("check" → "checked", "was" → "were"), join or split ("do not" → "don't"), or be a filler, a
  repeat or a small grammar word dropped or added ("a", "the", "is", "to", …). A correction may
  take back up to six words before its cue, with a "not" after the cue that says them again, and
  its phrase may bring up to two new words ("the after tomorrow" → "the day after tomorrow").
  One that reaches back past the end of a sentence must be about the same thing: a shared word,
  or the same kind (a number, a day, a month, a time or a name). Numbers, negations, words of
  time and placeholders may never be added, dropped or changed outside what a correction takes
  back, and in a one-line field Deep may not break lines. In a field that takes several lines, a
  bulleted list Deep makes needs at least three items (two things said in a sentence stay in it;
  a numbered list may have two, as when they were counted), and no line may hold only a
  placeholder, such as an emoji moved below the sentence it ended. When Deep's answer is turned
  down, Medium's pass runs in the time left, so Deep never shows less than Medium would. Deep may
  take 8 s, or the **Timeout** when it is longer.
- With **Clean up transcripts with the LLM** off in **Settings › Advanced**, nothing is reworded.
  In dictation, Medium, High and Deep still remove fillers and lay out lists and letters, and
  snippets, vocabulary and spoken commands still apply; the live transcript shows the raw text.
  The switch applies at the next launch.

## How Deep was chosen

Deep's spec asked for an experiment between three ways to do it (the self-correction adapter with
a new prompt, a separate pass, or training), and for Qwen3's thinking mode to ship only if it
helped. Each was measured with `Train measure` on an M4 Pro on 2026-09-30, on the 114 hand-written
cases in [`Training/eval/deep.jsonl`](../Packages/LiveTranscribeKit/Training/eval/deep.jsonl),
which nothing was trained on. Right means the shown text is the target, ignoring casing and
punctuation.

| Deep ran with | Right | Fell back | Unchanged | Meaning changed | Other | p50 (ms) | p95 (ms) |
|---|---:|---:|---:|---:|---:|---:|---:|
| Deep's prompt, no adapter | 52 | 0 | 39 | 23 | 0 | 200 | 260 |
| No adapter, thinking (768 tokens) | 58 | 52 | 0 | 1 | 3 | 4,781 | 5,026 |
| Medium's pass, then Deep's, no adapter | 72 | 0 | 40 | 2 | 0 | 289 | 410 |
| The self-correction adapter | 88 | 5 | 17 | 1 | 3 | 225 | 364 |
| **Deep's adapter, as shipped** | **108** | 1 | 2 | 0 | 3 | 227 | 360 |

Unchanged means an accepted answer kept the words as they were, so whatever needed repairing is
still there. Meaning changed means it changed the words and lost a fact the case keeps (a name,
number, date or "not"), or has one the case rules out, such as the word a correction replaced.
Each row is one run, so latencies from different rows are only roughly comparable.

- **Thinking was left off.** Qwen3's thinking, with 768 tokens to think in, got 58 right and ran
  out of tokens on most of the rest, at 4.8 s a cleanup at p50. With 3,072 tokens, on the 67
  corrections, controls and facts, it got 27 right against 60 for the self-correction adapter
  without thinking, and took 10.4 s at p50 and 21.8 s at p95. Its reasoning went round in circles
  and it reworded what was right. The code keeps it (`DeepCleanup.thinking`), reasoning removed
  before the check, for a larger model.
- **One pass, not two.** Medium's pass before Deep's, on every dictation with a cue, got 72
  right, against 88 for one pass with the self-correction adapter, and took two generations.
- **An adapter of its own.** Trained on Deep's prompt with synthetic examples only
  ([Training/README.md](../Packages/LiveTranscribeKit/Training/README.md#deeps-adapter)), it
  fixed what the prompt alone could not: the model copied every correction without it.
- **Medium's pass after a rejected answer**, so Deep shows at least what Medium would: on Medium's
  own 515 test cases, Deep got 505 right, as many as Medium, where Deep's answer alone got
  499.

Deep was also run on 246 dictations from the owner's history on the Mac. They were used only
to measure: never trained on, never in a prompt, never committed. Their target is the text the
app inserted at the time, which is not always right, so this measures how much Deep changes more
than how right it is. Deep's text matched it on 198, Medium's on 214, and neither changed a
protected fact. Reading Deep's other 48 answers:

- many differ only in what this run leaves out: spoken emoji, and the line breaks the app laid
  out in fields that take several lines;
- several are better: a correction resolved, or words kept that Medium had dropped;
- a few reword more than they need to;
- one dropped a later sentence's correction together with what it corrected, which the check
  now turns down, so Medium's cleanup is shown.

## Linux and Windows

The Linux and Windows app has the same levels and cleans up the same way: the prompts,
OutputGuard, Deep's check and the executor are ported to Rust (`lt-cleanup`), and the Mac app's
tests write fixtures of every prompt, verdict and executor trace that the port must match
(`Fixtures/cleanup`). The model is the same Qwen3-1.7B, run on OpenVINO on the CPU, with the Mac
app's two adapters compiled into the app. With the Mac's weights, 509 of its answers to Medium's
515 test cases were word for word the Mac app's, and all 114 of its answers to Deep's
hand-written cases were character for character the same. The model it downloads for now takes
no adapters, so there Medium and High keep self-corrections as spoken and Deep runs without its
adapter, until the Mac's weights with adapter inputs are published
([linux-windows/README.md](../linux-windows/README.md#cleanup)). A cleanup takes about four times
as long on a desktop CPU as on the Mac.

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
  underscore or digit in its name, or a word such as "email", "to" or "at" before it. One that
  speech-to-text writes out itself is kept too, in lower case.
- "Fireworks" is 🎆 (Unicode's FIREWORKS); 🎇 is "sparkler". A snippet with the same words wins
  over a command, so you can map any phrase to the emoji you prefer. An emoji said on its own
  after a sentence takes no full stop: "See you soon. 🙂".
