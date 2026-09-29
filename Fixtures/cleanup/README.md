# Cleanup fixtures

Both apps must clean up text the same way: the Mac app (Swift, `Packages/LiveTranscribeKit/Sources/Cleanup`)
and the Linux and Windows app (Rust, `linux-windows/crates/cleanup`). The language model differs by
platform, but everything around it must not. These files pin that down: what the model is asked,
which output the guard accepts, and what a cleanup does with each thing the model can do.

| File | What it holds |
|---|---|
| `prompts.jsonl` | The request the model gets for a text: its messages, the chat template's variables, the token budget, and whether the fine-tuned adapter is on. For every level with and without the adapter, with each kind of vocabulary and placeholder list, on texts and contexts that test the context window and the token budget; then a prompt override, the warm-up request, and the two named prompts (`cleanup`, `adapted`). |
| `guard-policy.json` | The output guard's default policy, word lists included, and each level's own word-ratio bounds. |
| `guard.jsonl` | The output guard's verdict at every level on a raw text and what the model made of it, with the placeholders and any changes to the default policy; and the parts it judges by (the words, cue counts, alignment, names, dropped words and content, similarity and word ratio), so a difference shows where it starts. Every fallback reason is there, with its description. |
| `executor.jsonl` | Whole cleanups with a scripted model. Each case lists what the model does with each request, in order: `reply`, `fail` with a message, `timeOut` (it is still generating when the deadline passes), or `cancel` (the cleanup is cancelled while it generates). The fixture records every request the cleanup made, in order, and what it returned: the text, whether it fell back and why. The time taken is recorded only when the model never ran, when it is 0. |

A request's `adapter` is whether the Mac app switches the fine-tuned adapter on for it: at Medium
and High, for both of High's passes, and for the warm-up. Numbers other than counts (word ratios,
similarities, seconds) are strings, as Swift prints a `Double`: the shortest text that reads back as
the same value, so the port can compare them exactly. The files keep LF line endings on every
system (`.gitattributes`).

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
`CleanupFixtures+Prompts.swift`, `CleanupFixtures+GuardCases.swift` and
`CleanupFixtures+Executor.swift` in `Packages/LiveTranscribeKit/Tests/CleanupTests`. Add a case,
run `make golden`, and commit the case and the files. To rewrite only these files:

    cd Packages/LiveTranscribeKit && TEST_RUNNER_LT_WRITE_CLEANUP_FIXTURES=1 xcodebuild test \
      -scheme LiveTranscribeKit-Package -destination 'platform=macOS,arch=arm64' \
      -skipPackagePluginValidation -only-testing:CleanupTests/CleanupFixtureWriterTests
