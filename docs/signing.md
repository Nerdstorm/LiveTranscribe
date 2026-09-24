# Signing and Gatekeeper

The app is built for Developer ID distribution: it runs outside the App Sandbox (inserting text
into other apps needs the Accessibility permission, which sandboxed apps cannot use), with the
Hardened Runtime and only the microphone entitlement. That rules out the Mac App Store.

Builds from this repository are ad-hoc signed ("Sign to Run Locally") by default and not
notarized, so they run on the Mac that built them. Gatekeeper blocks a copy downloaded onto
another Mac; build it there instead, or allow it under System Settings › Privacy & Security. To
distribute a build, sign it with your Developer ID and notarize it.

**The ad-hoc signature changes with every build.** After a rebuild, macOS asks for microphone
access again, and the Accessibility permission must be granted again: remove the old Live
Transcribe entry in Privacy & Security › Accessibility and add the new build. Until then the
shortcut does not work. If the floating panel then says to quit and reopen Live Transcribe so it
can paste, do that: **Reopen Live Transcribe** in **Settings › Permissions** does it for you.

**To keep the permissions across rebuilds, sign with your own certificate.** Copy
`Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` (gitignored) and set
your team ID. An Apple Development certificate is enough; Xcode › Settings › Accounts makes one
for free with any Apple ID. macOS then ties the permissions to the certificate rather than to
each build: grant them once more after switching, and they survive every rebuild after that.
