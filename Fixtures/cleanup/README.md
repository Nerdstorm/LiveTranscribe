# Cleanup fixtures

Both apps must clean up text the same way: the Mac app (Swift, `Packages/LiveTranscribeKit/Sources/Cleanup`)
and the Linux and Windows app (Rust, `linux-windows/crates/cleanup`). The language model differs by
platform, but everything around it must not. These files pin that down: what the model is asked,
which output the guard accepts, and what a cleanup does with each thing the model can do.

| File | What it holds |
|---|---|
| `prompts.jsonl` | The request the model gets for a text: its messages, the chat template's variables, the token budget, the adapter it asks for and how tokens are sampled. For every level with and without the self-correction adapter, with each kind of vocabulary and placeholder list, on texts and contexts that test the context window and the token budget; Deep in a field that takes one line and in one that takes several, as it ships and set up each other way it can be (each adapter, thinking and its token budget, Medium's pass first); then a prompt override, the warm-up request, and the named prompts (`cleanup`, `adapted`, and `deep-shipped`, which records how Deep ships). |
| `guard-policy.json` | The output guard's default policy, word lists included, and each level's own word-ratio bounds. |
| `guard.jsonl` | The output guard's verdict at every level on a raw text and what the model made of it, in a field that takes one line (`verdicts`) and, for Deep, in one that takes several too (`deepMultiline`; the other levels don't read the field), with the placeholders and any changes to the default policy. Then the parts it judges by (the words, cue counts, alignment, names, dropped words and content, similarity and word ratio), and Deep's repair (`repair`: the words said and written, the rewrites of what was said that Deep's check tries in turn, and whether it accepts the output), so a difference shows where it starts. Every fallback reason the guard gives is there, with its description. |
| `executor.jsonl` | Whole cleanups with a scripted model. Each case lists what the model does with each request, in order: `reply`, `fail` with a message, `timeOut` (it is still generating when the deadline passes), or `cancel` (the cleanup is cancelled while it generates). The fixture records every request the cleanup made, in order, and what it returned: the text, whether it fell back and why. The time taken is recorded only when the model never ran, when it is 0. Deep's cases run it each way it can be set up, with Medium's fallback, replies that think first, and thinking that runs out of tokens. |

A request's `adapter` names the fine-tuned adapter the Mac app switches on for it: `medium`, the
self-correction adapter, at Medium and High (both of High's passes, and Medium's pass or fallback at
Deep); at Deep, `deep`, `medium` or `none` as Deep is set up; and `none` below Medium. The warm-up
asks for `medium` when the model has that adapter and `deep` when it doesn't. A model without the
adapter a request names runs Deep's requests with `medium` when it has that one, and any other
request on the base model (see `CleanupModel` in the port). `sampling` is greedy (no `seed`) unless
the request thinks: Deep with thinking on samples from a seed that depends only on the text, so
sampling is repeatable.

`options.multiline` is whether the field takes several lines; only Deep reads it, and in a one-line
field it turns down output with a line break. `deep`, in `prompts.jsonl` and `executor.jsonl`, is
how Deep was set up for the case; absent, it runs as it ships. A word in `guard.jsonl`'s `repair`
records only the flags that are set.

Numbers other than counts (word ratios, similarities, seconds, Deep's minimum timeout) are strings,
as Swift prints a `Double`, and `sampling`'s as it prints a `Float`: the shortest text that reads
back as the same value, so the port can compare them exactly. The files keep LF line endings on
every system (`.gitattributes`).

The Swift implementation is the reference. `CleanupFixtureWriterTests` (in the package's
CleanupTests) checks it against these files on every `make test`. The Rust port runs the same cases
with `cargo test -p lt-cleanup` in `linux-windows/` (`crates/cleanup/src/fixtures.rs`), replaying
each script with a clock it controls.

## Changing cleanup

1. Change the Swift code and its unit tests as usual.
2. Run `make golden`. It rewrites these files (with those in `Fixtures/golden`) from the Swift
   implementation.
3. Review the diff: every changed line is a prompt, a verdict or a cleanup that changed.
4. Make the same change in the Rust port until `cargo test` passes in `linux-windows/`. The
   workflow in `.github/workflows/linux-windows.yml` runs it on Linux and Windows for every pull
   request that touches these files.

Commit all of it in one pull request, so neither app drifts.

## Adding cases

The cases are in the Swift tests, next to the code that writes each file:
`CleanupFixtures+Prompts.swift`, `CleanupFixtures+GuardCases.swift` (Deep's in
`CleanupFixtures+DeepGuardCases.swift`) and `CleanupFixtures+Executor.swift` (Deep's in
`CleanupFixtures+DeepExecutorCases.swift`) in `Packages/LiveTranscribeKit/Tests/CleanupTests`. Add
a case, run `make golden`, and commit the case and the files. To rewrite only these files:

    cd Packages/LiveTranscribeKit && TEST_RUNNER_LT_WRITE_CLEANUP_FIXTURES=1 xcodebuild test \
      -scheme LiveTranscribeKit-Package -destination 'platform=macOS,arch=arm64' \
      -skipPackagePluginValidation -only-testing:CleanupTests/CleanupFixtureWriterTests
