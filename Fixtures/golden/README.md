# Golden cases

Both apps must turn a transcript into the same text: the Mac app (Swift, in
`Packages/LiveTranscribeKit`) and the Linux and Windows app (Rust, in `linux-windows/`). These
files pin down dictation's text path without the language model: snippets, spoken commands,
vocabulary, filler removal, and list and letter layout.

| File | What it holds |
|---|---|
| `dictation-inputs.txt` | One transcript per line, as speech-to-text would hand it over. Lines starting with `#` are skipped. |
| `dictation-settings.json` | The snippets, vocabulary and prompt limits every case runs with. |
| `dictation-text.jsonl` | What the Mac app makes of each transcript: at each cleanup level (`none`, `light`, `medium`, `high`), in a single-line and a multi-line field, the text it types, the text Undo AI edit puts back (`uncleaned`), and whether it fell back. |
| `emoji-names.tsv` | Every name an emoji command accepts, before its plural rule, and the emoji it inserts: the Mac app's common names, and each emoji's Unicode name that macOS resolves. |

The Swift implementation is the reference. `GoldenDictationFixtureTests` (in the package's
DictationTests) checks it against `dictation-text.jsonl` and `emoji-names.tsv` on every
`make test`. The Rust port runs the same cases with `cargo test` in `linux-windows/`, and builds
`emoji-names.tsv` into its emoji command, so both apps accept the same emoji names whatever their
Unicode data. The files keep LF line endings on every system (`.gitattributes`).

## Changing the rules

1. Change the Swift rules and their unit tests as usual.
2. Run `make golden`. It rewrites `dictation-text.jsonl` and `emoji-names.tsv` from the Swift
   implementation.
3. Review the diff: every changed line of `dictation-text.jsonl` is a transcript whose output
   changed, and every changed line of `emoji-names.tsv` a name.
4. Make the same change in the Rust port until `cargo test` passes in `linux-windows/`. The
   workflow in `.github/workflows/linux-windows.yml` runs it on Linux and Windows for every pull
   request that touches these files.

Commit all of it in one pull request, so neither app drifts.

## Adding cases

Add transcripts to `dictation-inputs.txt`, run `make golden`, and commit both files. Keep inputs
realistic: speech-to-text never writes line breaks or tabs, so the inputs have none.

Most inputs were collected from the string literals in the Swift unit tests (Dictation, Styles,
SpokenCommands, Snippets, Vocabulary, Shared and Cleanup), plus the spoken column of the dictation
eval clips and some Sinhala, Chinese, French, German and Spanish lines. About 100 inputs contain the
placeholder brackets `⟦` `⟧`, which speech-to-text never writes. They make dictation fall back, and
both apps must do so the same way.
