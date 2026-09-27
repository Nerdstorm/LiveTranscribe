# Live Transcribe for Linux and Windows

One Rust codebase for the Linux and Windows desktop app, which will run speech-to-text on the
computer's NPU. The Mac app stays in Swift (`Packages/LiveTranscribeKit`); the two share their
behaviour through the golden cases in [`Fixtures/golden`](../Fixtures/golden/README.md).

This is the start: the dictation text rules, ported from the Mac app, type the same text as the
Mac app for all 9,728 golden cases. There is no app to run yet.

## Building and testing

```bash
cargo test
```

`rust-toolchain.toml` pins the Rust version, and rustup installs it on the first build. The tests
include the golden cases (`crates/dictation/tests/golden.rs`). CI runs formatting, clippy and the
tests on Linux and Windows (`.github/workflows/linux-windows.yml`).

## Layout

One crate per slice of the Mac app's Swift package, with the same names, so a rule lives in the
same place in both apps:

| Crate | Swift module | What it holds |
|---|---|---|
| `lt-shared` | `Shared` | Text with Swift's semantics, the phrase protector and its placeholders, word normalisation, cleanup levels |
| `lt-styles` | `Styles` | Filler removal, and the layout of spoken lists and letters |
| `lt-spoken-commands` | `SpokenCommands` | Emoji, dictated punctuation, line breaks, email and web addresses |
| `lt-snippets` | `Snippets` | The user's snippets |
| `lt-vocabulary` | `Vocabulary` | The user's vocabulary |
| `lt-cleanup` | `Cleanup` | Cleanup at each level; for now the rules that need no language model |
| `lt-dictation` | `Dictation` | A transcript to the text dictation types |

## Matching the Mac app

The rules are written against Swift's `String`, whose characters are grapheme clusters and whose
equality is canonical equivalence. `lt_shared::swift_string` gives the port the same semantics, so
the rules read like their Swift originals. It was checked against the Swift runtime scalar by
scalar; where Swift's character properties differ from Rust's, the scalars are listed in
`crates/shared/src/swift_string/tables.rs`, which `tools/swift-character-tables.swift` writes. Run
that tool on a Mac after a macOS or Xcode update:

```bash
swiftc -O tools/swift-character-tables.swift -o /tmp/swift-character-tables
```

```bash
/tmp/swift-character-tables > crates/shared/src/swift_string/tables.rs
```

Emoji names come from `Fixtures/golden/emoji-names.tsv`, which the Mac app's tests write, rather
than from a Rust Unicode names table: macOS resolves names exactly, while Rust's name lookup
accepts loose spellings ("fire works" for FIREWORKS).

To change a rule, change the Swift first, regenerate the golden cases with `make golden` at the
repository root, then port the change here until `cargo test` passes.

Dictated text is never logged: log lines carry counts only.
