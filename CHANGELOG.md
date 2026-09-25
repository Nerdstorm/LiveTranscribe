# Changelog

What changed in each release of Live Transcribe, newest first. Before a release,
`make changelog VERSION=x.y.z` summarises what was merged since the last one
([Releasing](docs/releasing.md)).

## 0.2.0 - 2026-09-25

- Recognise speech with Qwen3-ASR instead of Parakeet. It made fewer mistakes in our dictation tests, downloads about 1 GB instead of 2.3 GB and uses less memory. It also recognises 29 languages besides English, but cleanup has only been tested with English ([#20](https://github.com/Nerdstorm/LiveTranscribe/pull/20))
- After updating, the app downloads the new model once. The menu bar shows the progress, and dictation comes back when the model has loaded. The old model stays in `~/.cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v3` (about 2.3 GB; in Finder, **Go › Go to Folder…** opens it): move it to the Trash unless you chose it in **Settings › Advanced** ([#20](https://github.com/Nerdstorm/LiveTranscribe/pull/20))
- The live transcript shows each segment a little later than before, by about 0.1 to 0.3 s in our tests. A fix is planned ([#20](https://github.com/Nerdstorm/LiveTranscribe/pull/20))

[Every commit since v0.1.1](https://github.com/Nerdstorm/LiveTranscribe/compare/v0.1.1...v0.2.0)

## 0.1.1 - 2026-09-25

- Open on macOS 14 to 26. 0.1.0 didn't open on any macOS before 27, and a copy that doesn't open can't update itself, so download 0.1.1 from the website ([#17](https://github.com/Nerdstorm/LiveTranscribe/pull/17))
- Number a list said with "one…, two…", as "first…, second…" already was ([#17](https://github.com/Nerdstorm/LiveTranscribe/pull/17))
- Lay out a message that opens with a greeting and ends with just "Thanks" as a letter, with its list ([#17](https://github.com/Nerdstorm/LiveTranscribe/pull/17))
- Start a new paragraph after a spoken list ([#17](https://github.com/Nerdstorm/LiveTranscribe/pull/17))

[Every commit since v0.1.0](https://github.com/Nerdstorm/LiveTranscribe/compare/v0.1.0...v0.1.1)

## 0.1.0 - 2026-09-24

- Live Transcribe: on-device realtime transcription for Apple silicon
- Keep the chosen microphone when restoring default settings
- Keep cleanup model loads offline after the first launch
- Correct the README against the code
- Resolve spoken self-corrections with a bundled LoRA adapter ([#1](https://github.com/Nerdstorm/LiveTranscribe/pull/1))
- System-wide dictation: a menu bar app that types cleaned speech at the cursor ([#2](https://github.com/Nerdstorm/LiveTranscribe/pull/2))
- Say why dictated text went to the clipboard, and offer to reopen when macOS won't let the app paste ([#3](https://github.com/Nerdstorm/LiveTranscribe/pull/3))
- Keep macOS permissions across rebuilds by signing with your own certificate ([#4](https://github.com/Nerdstorm/LiveTranscribe/pull/4))
- Add a one-page website, published with GitHub Pages ([#5](https://github.com/Nerdstorm/LiveTranscribe/pull/5))
- Show the app on the website ([#6](https://github.com/Nerdstorm/LiveTranscribe/pull/6))
- Lay out spoken lists and letters, add spoken commands, fix placeholder fallbacks ([#7](https://github.com/Nerdstorm/LiveTranscribe/pull/7))
- Reject cleanup that drops content or moves a name ([#8](https://github.com/Nerdstorm/LiveTranscribe/pull/8))
- Choose line breaks per app, multi-line by default ([#10](https://github.com/Nerdstorm/LiveTranscribe/pull/10))
- Keep the "is" that introduces a list item out of the item ([#9](https://github.com/Nerdstorm/LiveTranscribe/pull/9))
- Show Settings with toolbar tabs, like Apple's Settings windows ([#11](https://github.com/Nerdstorm/LiveTranscribe/pull/11))
- List built-in app settings only for apps on this Mac ([#12](https://github.com/Nerdstorm/LiveTranscribe/pull/12))
- Add the app icon, brand the website, and split the README into docs/ ([#13](https://github.com/Nerdstorm/LiveTranscribe/pull/13))
- Releases: Developer ID, notarization, Sparkle updates and licence notices ([#14](https://github.com/Nerdstorm/LiveTranscribe/pull/14))
- Add a Makefile for building, testing, releasing and upkeep ([#15](https://github.com/Nerdstorm/LiveTranscribe/pull/15))

[Every commit](https://github.com/Nerdstorm/LiveTranscribe/commits/v0.1.0)
