# Deep F4 in release 1.3.0

On 7 October 2026, the owner requested installation of the latest trained model for
local testing, then instructed: “we should ship this model and app as a minor version
upgrade.” Release 1.3.0 therefore replaces the bundled Deep adapter with **F4 checkpoint
1950** on Mac, Linux and Windows. Workstate decision **LiveTranscribe-0405** records this
authorization.

F4 **failed the original promotion gates**. The release instruction overrides the
hold; it does not change the scores or qualify the model under those gates. Independent
acceptance remains sealed. Earlier training and evaluation records remain unchanged in
the local research checkout.

## Exact model

| Identity | Value |
| --- | --- |
| Base model | `mlx-community/Qwen3-1.7B-4bit` |
| Base revision | `3b1b1768f8f8cf8351c712464f906e86c2b8269e` |
| Adapter | F4, validation-selected iteration 1950 |
| Weight SHA-256 | `d6814f8e23b247080a4e892cc569405621c5504a3205095a9a028d6f045d5daa` |
| Config SHA-256 | `4da7a22747aee524dd279579f7deabd20bf6da0ba6381acf0a87bce23309679e` |
| Recipe SHA-256 | `55286ebe3e04dde2f42c3c773aaf13bef44991095afd06f18adedb273fdcdabf` |
| Training report SHA-256 | `88f9446633480559d9947699b0a8da3ec856b39e0ff63c5c85f00f02a9a9ec49` |
| Evaluation runtime SHA-256 | `79a7b696887ec5d75b3dcfdcc176e998377cf439a0a564ef97b056154644c331` |

Training stopped naturally at iteration 2400 on 6 October 2026, after validation
plateaued. Iteration 1950 had the lowest combined validation loss, **0.020062044**;
final loss was 0.023241386. Selection used validation only. The released files are
byte-identical to the selected root adapter and checkpoint.

The LoRA shape remains rank 8, scale 20, last 16 layers. Medium and High retain their
existing adapter. The base model, prompts, guards, vocabulary handling, greeting framing
and other cleanup levels are unchanged by this release. No rejected runtime prototype
is included. The same Deep resource is copied into the Mac app and embedded by the Rust app.

## Completed development comparison

All 12 model phases, 11 scoring commands and required individual reviews completed
before the release request. These results are retained; release preparation does not
rerun the experiment or select another checkpoint.

| Frozen check | 1.2.0 adapter E | F4 |
| --- | ---: | ---: |
| Short app, 150 conditions | 102 | 103 |
| Long app, 30 conditions | 18 | 18 |
| Broad transcripts, 1158 cases | 1073 | 1065 |
| Broad grammar, 46 cases | 42 | 38 |
| Lists with many items, 60 cases | 53 | 47 |
| Lists with two items, 45 cases | 39 | 41 |
| Vocabulary app, 216 conditions | 191 | 186 |
| External app and boundary, 108 cases | 62 | 76 |
| New app-source full insertion, 48 conditions | 41 | 43 |
| New app-source model boundary, 48 conditions | 42 | 43 |

The external check newly passes 16 conditions and newly fails two versus E. Short app
newly passes six and newly fails five; new app-source full insertion newly passes three
and newly fails one. Broad newly passes 25 and newly fails 33; vocabulary newly passes
four and newly fails nine.

Known regressions include joining `nerd storm` to `Nerdstorm` without a relevant hint,
losing packing-list bullets, joining a parcel instruction to its negative inspection-label
instruction, and changing temporal modifier or clause attachment. Guards block some
unsafe proposals but do not prevent all reviewed failures. Question-correction gains
do not remove these costs. **Undo AI edit** restores the pre-cleanup transcript.

These are adaptive development checks, including related synthetic variants, public
written pairs and some existing text-to-speech recognizer inputs. They are not independent
human judgments or fresh human dictation measurements. The app-source heldout has 38
families; related variants are counted as conditions, not independent speakers. Existing
scorer limits for punctuation, casing, contractions and annotations remain. The frozen
broad/external scores must not be replaced with the looser native totals of 1079 and 91.
These results do not establish cross-platform model quality, rare-error safety or a
confidence percentage.

## Training sources and distribution

F4 uses the F3 transcript and public correction pool plus synthetic compound app requests
and inherited letter/list projections. Its combined training pool contains 13,221 rows,
15,506 weighted rows and 8,436 source families. Added validation contributes 43 of 1,538
conditions, so aggregate loss is dominated by the original pool. These counts do not
measure independent human speech or token exposure.

The public written sources are Disfl-QA (CC BY 4.0), its SQuAD 2.0 lineage (CC BY-SA 4.0),
and ErAConD (MIT). The [bundled notice](../Packages/LiveTranscribeKit/Sources/Cleanup/DeepAdapter/NOTICE.md)
provides authors, pinned revisions, source and licence links, modifications and the
original ErAConD copyright/permission text. Nerdstorm's adapter contribution retains MIT;
the base model and source datasets retain their own licences. Dataset rows, private
history, private audio and sealed acceptance material are not distributed here.
DisfluencySpeech, Switchboard and the closed audiobook routes supplied no F4 training data.

Release packages carry the notice: in the Mac Cleanup resource bundle, in
`/usr/share/doc/live-transcribe/deep-adapter/NOTICE.md` in Linux packages, and in
`licenses/deep-adapter/NOTICE.md` beside the Windows app. Packaging checks verify it
against the source file before publication.
