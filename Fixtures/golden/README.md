# Golden cases

Both apps must turn speech into the same text: the Mac app (Swift, in
`Packages/LiveTranscribeKit`) and the Linux and Windows app (Rust, in `linux-windows/`). These
files pin down dictation's text path without the language model (snippets, spoken commands,
vocabulary, filler removal, list and letter layout, and numbers written in digits), and what speech
to text feeds the speech model.

| File | What it holds |
|---|---|
| `dictation-inputs.txt` | One transcript per line, as speech-to-text would hand it over. Lines starting with `#` are skipped. |
| `dictation-settings.json` | The snippets, vocabulary and prompt limits every case runs with. |
| `dictation-text.jsonl` | What the Mac app makes of each transcript: at each cleanup level (`none`, `light`, `medium`, `high`, `deep`), in a single-line and a multi-line field, the text it types, the text Undo AI edit puts back (`uncleaned`), and whether it fell back. |
| `emoji-phrasing.tsv` | The ways people may ask for an emoji ("emoji fireworks", "insert a fireworks emoji", "smiley face") or talk about one ("the fire emoji is my favourite"), the text the speaker wants, and whether dictation makes it yet (`works`) or not (`gap`). Hand-written; edit it, and set a row's status when a rule change flips it. Not written by `make golden`. |
| `emoji-names.tsv` | Every name an emoji command accepts, before its plural rule, and the emoji it inserts: the Mac app's common names, and each emoji's Unicode name that macOS resolves. |
| `speech-features/*.f32` | Qwen3-ASR's log-mel features as the Mac app computes them (mlx-audio-swift) for three synthetic test clips, which both tests generate with integer arithmetic: 128 little-endian float32 values per frame. Compared within 1e-4. |
| `speech-layout.tsv` | For every clip length from 101 to 1,000 mel frames, the audio placeholders mlx-audio-swift's Qwen3-ASR prompt gets and the rows its encoder makes. |

The Swift implementation is the reference. `GoldenDictationFixtureTests` (in the package's
DictationTests) checks it against `dictation-text.jsonl` and `emoji-names.tsv` on every
`make test` (and `EmojiPhrasingFixtureTests` against `emoji-phrasing.tsv`), and `GoldenSpeechFeatureTests` (in TranscriptionTests) against the speech files. The Rust port runs the same cases with `cargo test` in `linux-windows/`, and builds
`emoji-names.tsv` into its emoji command, so both apps accept the same emoji names whatever their
Unicode data. The text files keep LF line endings on every system, and the `.f32` files are
binary (`.gitattributes`).

## Updating mlx-audio-swift

The speech files change only when mlx-audio-swift changes how Qwen3-ASR prepares audio. The
Sinhala model was trained on exactly what they record, so a change to them needs the model
evaluated again, and possibly retrained, before the update ships. Run `make golden`, review the
diff (`git diff --stat` for the features), and port the change to
`linux-windows/crates/transcription` until `cargo test` passes.

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
