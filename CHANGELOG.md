# Changelog

What changed in each release of Live Transcribe, newest first. Before a release,
`make changelog VERSION=x.y.z` summarises what was merged since the last one
([Releasing](docs/releasing.md)).

## 1.0.0 - 2026-09-30

- Live Transcribe for Linux and Windows, in the same release and at the same version as the Mac app. Hold a key to talk, or double-tap it for hands-free, and the text is typed where you're typing. The speech model runs on the NPU of an Intel Core Ultra, or on the CPU. Cleanup is the Mac app's, with its model at every level. It runs on the CPU, where it takes about four times as long as on a Mac. On Linux, dictation types on COSMIC, and should on Sway and Hyprland; GNOME, KDE Plasma and X11 desktops come later ([#31](https://github.com/Nerdstorm/LiveTranscribe/pull/31), [#33](https://github.com/Nerdstorm/LiveTranscribe/pull/33), [#40](https://github.com/Nerdstorm/LiveTranscribe/pull/40), [#41](https://github.com/Nerdstorm/LiveTranscribe/pull/41))
- Add **Deep**, a fifth cleanup level after High. It reads the whole dictation, so it can:
  - follow a correction back into an earlier sentence ("…whether the release is tomorrow. No, sorry, the after tomorrow." → "…whether the release is the day after tomorrow.");
  - read a garbled correction as meant;
  - fix grammar and misheard words from the rest of what you said;
  - lay out an email or a list in a field that takes several lines.

  Names, numbers, dates and negations stay as you said them. When Deep's answer doesn't pass its check, you get Medium's. In our tests of such repairs, Deep got 108 of 114 right and Medium 75. It takes a little longer than Medium, and is never the default ([#40](https://github.com/Nerdstorm/LiveTranscribe/pull/40))
- Medium, High and Deep now resolve a correction that repeats what it takes back: "room four, no, not four, five" → "room five". Their checks used to read the dropped "not" as a lost negation, and kept what you said ([#40](https://github.com/Nerdstorm/LiveTranscribe/pull/40))
- Choose the speech model in the new **Settings › Models**, on every system. It shows each model's languages, size and licence, and lets you download it, use it without restarting, or remove it. The Mac offers seven, from the default, Qwen3-ASR fine-tuned for Sinhala, to Whisper large-v3-turbo. Linux and Windows offer four: the Sinhala fine-tune, Parakeet v2 (English) and v3 (25 European languages), and Cohere Transcribe. Cohere Transcribe can't tell which language it hears, so you choose one of its 14. On the Mac, **Another model** takes any other repository or folder, in place of the field in Settings › Advanced ([#35](https://github.com/Nerdstorm/LiveTranscribe/pull/35), [#37](https://github.com/Nerdstorm/LiveTranscribe/pull/37), [#38](https://github.com/Nerdstorm/LiveTranscribe/pull/38))
- Mac: after updating, the app downloads its speech model once more, about 1 GB, at the exact version we tested. Once that's done, the previous copy can go to the Trash. For the default model it's `~/.cache/huggingface/hub/mlx-audio/Nerdstorm_Qwen3-ASR-0.6B-Sinhala-8bit` (about 1 GB; in Finder, **Go › Go to Folder…** opens it) ([#37](https://github.com/Nerdstorm/LiveTranscribe/pull/37))
- Mac: the dictation panel is now a small circle by the mouse pointer, instead of a capsule at the text cursor, which often appeared in the wrong place. It shows the microphone's level as you speak and spins while transcribing. Words appear beside it only when something needs your attention. Esc, or **Cancel Dictation** in the menu bar, cancels ([#39](https://github.com/Nerdstorm/LiveTranscribe/pull/39))

[Every commit since v0.3.0](https://github.com/Nerdstorm/LiveTranscribe/compare/v0.3.0...v1.0.0)

## 0.3.0 - 2026-09-26

- Recognise Sinhala. The speech model is now Qwen3-ASR fine-tuned for Sinhala, which writes Sinhala in Sinhala script with English words in English letters ("meeting එක cancel කරන්න"). Cleanup is written for English, so Sinhala is typed as recognised ([#26](https://github.com/Nerdstorm/LiveTranscribe/pull/26))
- After updating, the app downloads the new model once, about 1 GB. It recognises English almost as well as the previous model: in our dictation tests at Medium, 6.4% of words differed from what was meant, against 5.1%. To keep the previous model, enter `mlx-community/Qwen3-ASR-0.6B-8bit` in **Settings › Advanced**. Otherwise it can go to the Trash: it's in `~/.cache/huggingface/hub/models--mlx-community--Qwen3-ASR-0.6B-8bit` and `~/.cache/huggingface/hub/mlx-audio/mlx-community_Qwen3-ASR-0.6B-8bit` (about 1 GB; in Finder, **Go › Go to Folder…** opens them) ([#26](https://github.com/Nerdstorm/LiveTranscribe/pull/26))
- Recognise speech better with noise in the background: the app now prepares the audio the way the speech model was trained. In our tests with background noise, 9.8% of English words came out wrong instead of 16.4% ([#24](https://github.com/Nerdstorm/LiveTranscribe/pull/24))
- If the speech model gets stuck repeating a phrase, stop after a few seconds' worth of text instead of typing up to a minute of it ([#25](https://github.com/Nerdstorm/LiveTranscribe/pull/25))

[Every commit since v0.2.0](https://github.com/Nerdstorm/LiveTranscribe/compare/v0.2.0...v0.3.0)

## 0.2.0 - 2026-09-25

- Recognise speech with Qwen3-ASR instead of Parakeet. It made fewer mistakes in our dictation tests, downloads about 1 GB instead of 2.3 GB and uses less memory. It also recognises 29 languages besides English, but cleanup has only been tested with English ([#20](https://github.com/Nerdstorm/LiveTranscribe/pull/20))
- After updating, the app downloads the new model once. The menu bar shows the progress, and dictation comes back when the model has loaded. To keep using Parakeet instead, enter `mlx-community/parakeet-tdt-0.6b-v3` in **Settings › Advanced**. Otherwise the old model can go to the Trash: it's in `~/.cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v3` (about 2.3 GB; in Finder, **Go › Go to Folder…** opens it) ([#20](https://github.com/Nerdstorm/LiveTranscribe/pull/20), [#22](https://github.com/Nerdstorm/LiveTranscribe/pull/22))
- Stop **Settings › Advanced** from saving the models it shows just because you opened it, which kept Parakeet in place of the new default ([#22](https://github.com/Nerdstorm/LiveTranscribe/pull/22))
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
