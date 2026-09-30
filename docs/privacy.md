# Privacy

Audio and transcripts never leave your computer. There is no account, no telemetry and no crash
reporting. Dictated text is never written to a log.

## What goes over the network

The app goes online for these things only:

- **Downloading models.** From Hugging Face (huggingface.co and the download servers it redirects
  to), and on Linux and Windows the Parakeet and Cohere Transcribe models from GitHub
  (github.com/k2-fsa/sherpa-onnx releases). It downloads on first launch, and whenever you choose or
  add a model in **Settings › Models**; on the Mac also on the next launch after you change the
  cleanup or voice-activity model in **Settings › Advanced**. Downloaded models are reused without
  contacting the server again. A request carries only what any web request carries, such as your IP
  address. On the Mac, if a Hugging Face access token is set on the computer (`HF_TOKEN` or
  `HUGGING_FACE_HUB_TOKEN`, or a token file such as `~/.cache/huggingface/token`), the requests to
  Hugging Face carry it.
- **Checking for updates (Mac).** In a release downloaded from GitHub, about once a day if you
  allow it (the app asks on its second launch, and **Settings › General › Updates** changes it),
  and whenever you choose **Check for Updates…**. The check reads a list of releases from
  nerdstorm.github.io and sends nothing about you or your dictation, only what any web request
  carries: your IP address, and the app's and Sparkle's versions. Updates download from
  github.com. A build from source never checks. Linux and Windows never check for updates.

## On the Mac

- **Dictation history is on by default.** Every completed dictation (what you said, the text
  inserted, the app, the cleanup level, whether and why cleanup fell back, how the text was
  delivered, and timings) is kept unencrypted in
  `~/Library/Application Support/org.nerdstorm.LiveTranscribe/History/dictations.jsonl`, on this
  Mac only and readable only by your account. It is never synced to iCloud or anywhere else.
  Cancelled dictations are never saved. Turn history off, set how long it is kept, or clear it in
  **Settings › History**; **Dictation History** in the menu bar shows and searches it, and deletes
  single dictations.
- Snippets, vocabulary and per-app settings are JSON files in
  `~/Library/Application Support/org.nerdstorm.LiveTranscribe/` (`snippets.json`,
  `vocabulary.json`, `insertion-overrides.json`), readable only by your account.
- Every live transcript session is saved as an unencrypted JSONL file in
  `~/Library/Application Support/org.nerdstorm.LiveTranscribe/Sessions/`, which the **Sessions**
  button opens. Each line holds one segment: the raw and cleaned text, whether and why cleanup
  fell back to the raw text, start and end times, per-stage latencies, a timestamp and IDs. Files
  are kept until you delete them.
- Dictated text is not written to the system log. Transcript text, file paths and device names
  are logged only as private data, which macOS redacts. Text the app pastes is marked transient,
  so clipboard managers that honour the nspasteboard.org convention skip it; text left on the
  clipboard for you to paste is an ordinary copy.
- **To remove everything,** delete the app and then:
  - `~/Library/Application Support/org.nerdstorm.LiveTranscribe` (sessions, dictation history,
    snippets, vocabulary and per-app settings);
  - `~/Library/Preferences/org.nerdstorm.LiveTranscribe.plist` (settings);
  - `~/Library/Caches/org.nerdstorm.LiveTranscribe` and
    `~/Library/HTTPStorages/org.nerdstorm.LiveTranscribe` (cached update-check responses);
  - the models in `~/.cache/huggingface/hub`, in the folders named `models--<owner>--<name>`
    (`models--Nerdstorm--Qwen3-ASR-0.6B-Sinhala-8bit`, `models--mlx-community--Qwen3-1.7B-4bit`
    and `models--mlx-community--silero-vad`, and those of any other speech model you chose), and
    the folder `mlx-audio` there. Other Hugging Face tools use that hub folder too.

## On Linux and Windows

Nothing is kept about what you say. There is no dictation history, no session file and no log
file; the last dictation stays in memory for **Copy Last Dictation**. Audio stays in memory too.

| What | Linux | Windows |
|---|---|---|
| Settings (your choices, no text or audio) | `~/.config/live-transcribe/settings.json` | `%APPDATA%\live-transcribe\settings.json` |
| Models | `~/.local/share/live-transcribe/models` | `%LOCALAPPDATA%\live-transcribe\models` |
| OpenVINO's compiled models | `~/.cache/live-transcribe/openvino` | `%LOCALAPPDATA%\live-transcribe\openvino` |

(The folders follow `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_CACHE_HOME` on Linux.) The
Settings window keeps its browser engine's own profile in a folder named after the app's
identifier, `org.nerdstorm.LiveTranscribe`.

- **Logs** go to the terminal only, and carry counts, timings, device names and model paths,
  never text.
- **The clipboard.** On Linux the app types into the field through the desktop's input method
  where it can; otherwise it puts the text on the clipboard, presses Ctrl+V and puts your
  clipboard back. The text is offered with the `x-kde-passwordManagerHint=secret` hint, which
  clipboard managers that honour it skip. On Windows the app types and never pastes; only when
  nothing would take the keystrokes does it leave the text on the clipboard, out of the clipboard
  history and the cloud clipboard. **Copy Last Dictation** is an ordinary copy that clipboard
  histories keep.
- **Keyboard access.** The app has to see your hotkey. On Linux it reads the keyboards in
  `/dev/input`, which needs a udev rule that the deb and rpm install. **The rule lets whoever is
  logged in at the machine read the keyboards, so any program that user runs can read what they
  type**, as any X11 program always could; removing the package removes the rule. On Windows it
  uses a low-level keyboard hook, which needs no permission. The app acts only on the hotkey, Esc
  and another key pressed while the hotkey is held, and keeps no keystrokes.
- **To remove it.** On Linux, uninstalling the deb or rpm removes the app and the udev rule, and
  leaves your data (the models take several GB): delete the three folders above. On Windows,
  uninstalling (Settings › Apps) keeps the models and settings for a later install unless you
  tick **Delete the application data**.
