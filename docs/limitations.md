# Known limitations

- **A Bluetooth headset's microphone switches the headset into call mode.** macOS does this
  whenever any app opens a headset microphone: the headset drops to 16 kHz and its playback
  quality falls until capture stops. Transcription works, but for better playback use the
  built-in or a wired microphone while the headset plays audio.
- **Dictation needs Accessibility, which macOS ties to the app's signature.** Each ad-hoc
  rebuild is a new app to macOS: remove Live Transcribe from Privacy & Security › Accessibility
  and add the new build, or the shortcut stops working. Builds signed with your own certificate
  keep the permission (see [Signing and Gatekeeper](signing.md)).
- **Pasting can need a reopen after Accessibility is switched on.** Seen once, after the
  Accessibility entry was removed and added back while the app ran: Accessibility read as on and
  the shortcut worked, but macOS refused to let the app send ⌘V, so text for apps that are
  pasted into (terminals, browsers, Electron apps) was left on the clipboard. The panel, setup
  and **Settings › Permissions** now say so and offer **Reopen Live Transcribe**. That reopening
  fixes it is expected but not yet confirmed.
- **Long dictations are untested.** The eval's longest clip is about 40 words. Cleanup runs on
  the whole dictation under a 3 s timeout, so a dictation longer than a minute or two will likely
  be inserted uncleaned (fillers still removed at Medium and High), without a message. Past the
  recording limit (5 minutes by default) speech is dropped, and the panel says so only when you
  finish.
- Correcting with a 1.7B model does not reliably fix homophones ("cash" → "cache"). That needs a
  larger model; in dictation, a vocabulary entry fixes a specific one. OutputGuard's similarity
  floor limits how far the model can change the text. **High** behaves close to Medium for the
  same reason.
- Spoken self-corrections ("fuel efficiency in cars, sorry, buses" → "fuel efficiency in buses")
  are resolved by a small fine-tuned adapter trained on synthetic data, so expect lower accuracy
  on real speech than the 97% it scored on synthetic held-out examples. OutputGuard rejects any
  cleanup that drops a correction cue ("sorry", "I mean", "no", "wait", "actually", "scratch
  that", …) unless the only words it removed were up to six retracted words before that cue, the
  cue itself, fillers such as "um", and immediately repeated words; and cleanup that keeps every
  cue may not delete a run of spoken words, a word that carries meaning or a negation, or move a
  name.
- The self-correction adapter occasionally rewrites a plain sentence (1 of 65 eval clips);
  OutputGuard catches it and inserts the raw transcript instead of the cleaned text. In
  dictation such a fallback is silent: only **Dictation History** shows it, if history is on.
- Spoken lists are laid out only when you say their markers ("first…", "number one…", "bullet
  point…"), and lists and letters only where line breaks are allowed. The model sometimes drops
  or rewrites a list item; OutputGuard then inserts your words, still laid out.
- A text box in a web page always counts as taking several lines, so a list dictated into a
  web page's one-line field, such as a site's search box, gets line breaks the field then drops
  ("items:1. Milk"). Set that browser to single-line if it happens often.
- In a single-line field a letter is cleaned as a whole, and the model sometimes moves the name
  in the sign-off into the greeting ("hi John … cheers Sam" → "Hi Sam, … Cheers."). OutputGuard
  rejects that, so your words are inserted uncleaned.
- OutputGuard catches a word left out and a name moved, but not a word replaced by a different
  one ("milk" → "cream", "three" → "4") unless it is a name. Words that only hold a sentence
  together ("the", "of", "really") may still be dropped. Names are recognised by the capital
  letter speech-to-text gives them.
- The floating panel sits next to the cursor, and a leading space is added, only in apps that
  report their text through Accessibility. Elsewhere the panel appears near the bottom of the
  screen and no space is added.
- After a pasted dictation, **Undo AI Edit** can't tell whether you typed more in the same field;
  ⌘Z then undoes that typing first.
- The microphone opens while the focused field is read, so in a password field the microphone
  indicator may flash briefly. The recording is thrown away before it is transcribed, and
  nothing is typed.
- Reserved system shortcuts (⌘Space, ⌘Tab, …) are recognised by key position on a US layout, so
  on other layouts Settings may accept a shortcut that macOS already uses.
- ⌃⌥Space is allowed as a shortcut but can clash with input-source switching on some Macs.
- If the app crashes, up to `cleanupQueueCapacity` + 1 segments (9 by default) that were
  transcribed but not yet cleaned are lost: their raw text was on screen but not yet saved.
- The models come from each repository's `main` branch at first launch and are then reused, so
  Macs that install at different times can end up with different model versions.
- mlx-audio-swift copies the speech-to-text weights into a second folder of the Hugging Face
  cache; on APFS the copy is a clone, so `du` counts it twice but it takes no extra space.
