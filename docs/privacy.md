# Privacy

- Audio and transcripts never leave your Mac. There is no telemetry.
- The only network traffic is to Hugging Face (huggingface.co and the download servers it
  redirects to), to download the models on first launch, and on the next launch after you choose
  a different model in Settings. Downloaded models are reused without contacting Hugging Face
  again.
- **Dictation history is on by default.** Every completed dictation (what you said, the text
  inserted, the app, the cleanup level, whether and why cleanup fell back, how the text was
  delivered, and timings) is kept unencrypted in
  `~/Library/Application Support/org.nerdstorm.LiveTranscribe/History/dictations.jsonl`, on this
  Mac only and readable only by your account. It is never synced to iCloud or anywhere else.
  Cancelled dictations are never saved. Turn history off, set how long it is kept, or clear it in
  Settings › History; **Dictation History** in the menu bar shows and searches it, and deletes
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
- Deleting the app does not delete its data. To remove it, delete
  `~/Library/Application Support/org.nerdstorm.LiveTranscribe` (sessions, dictation history,
  snippets, vocabulary and per-app settings),
  `~/Library/Preferences/org.nerdstorm.LiveTranscribe.plist` (settings) and the models in
  `~/.cache/huggingface/hub` (folders named `models--mlx-community--…`, and `mlx-audio`).
- Earlier builds ran in the App Sandbox and kept their data in
  `~/Library/Containers/org.nerdstorm.LiveTranscribe`. The current app doesn't read it: move old
  sessions from its `Data/Library/Application Support/org.nerdstorm.LiveTranscribe/Sessions`
  folder if you want them, then delete the folder to free the models' space.
