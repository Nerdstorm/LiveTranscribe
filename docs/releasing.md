# Releasing

A release is a disk image on [GitHub Releases](https://github.com/Nerdstorm/LiveTranscribe/releases)
that opens on any Apple silicon Mac without a Gatekeeper warning. The app is signed with a
Developer ID certificate and notarized by Apple, and both the app and the disk image carry their
notarization ticket. Installed copies update themselves with [Sparkle](https://sparkle-project.org)
from `appcast.xml` on the website. [`scripts/release.sh`](../scripts/release.sh) makes a release
from a tag, and the [Makefile](../Makefile) has a target for each step below.

## One-time setup

**A Developer ID Application certificate.** Only the Account Holder of the Apple Developer team
can create one: Xcode › Settings › Accounts › the team › Manage Certificates › + › Developer ID
Application. Another maintainer gets it from the Account Holder as a password-protected .p12
(Keychain Access › My Certificates › the certificate › Export) and double-clicks it to import it.
`security find-identity -v -p codesigning` lists it once it's in the keychain.

- Keep the .p12 in a password manager. A team can have five of these certificates, so a lost one
  can be replaced, but the backup saves the trouble.
- **Never revoke it after a release.** Apple then blocks every app signed with it: it no longer
  installs, and copies already installed no longer open.

**Notarization credentials.** In App Store Connect › Users and Access › Integrations › Team Keys,
add a key with the Developer role (personal keys can't notarize) and download its .p8 file. Then
save it in the keychain:

```bash
xcrun notarytool store-credentials LiveTranscribe-notary --key /path/to/AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER-UUID
```

**Keep the .p8 in a password manager and delete it from Downloads.** App Store Connect lets you
download it only once, and a build server will need it. If it leaks, revoke the key in App Store
Connect and make a new one. The repository ignores `*.p8` and `*.p12` files, but they don't belong
in it at all.

**The update signing key.** Sparkle signs every update with an EdDSA key, and the app installs
only updates signed with it. Its public half is `SUPublicEDKey` in `App/Info.plist`; the private
half is in the login keychain of the Mac it was made on, under the account `LiveTranscribe`.
Sparkle's tools come with its package, and `make resolve` puts them in
`Packages/LiveTranscribeKit/.build/artifacts/sparkle/Sparkle/bin/`. Export the private key to a
file in your home folder, outside the repository:

```bash
Packages/LiveTranscribeKit/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account LiveTranscribe -x ~/LiveTranscribe-update-key.txt
```

**The file is the private key itself: put it in the password manager with the certificate, then
delete it.** The repository ignores files named like it, but it doesn't belong there. Without the
key, installed copies can't be updated, and their users would have to download the next release
by hand. On another Mac, import it with `-f` in place of `-x`. The keychain asks before each of
Sparkle's tools first reads the key; allow it.

**The team ID.** The script takes `DEVELOPMENT_TEAM` from `Config/Signing.local.xcconfig` (see
[Signing and Gatekeeper](signing.md)), or `LT_TEAM_ID` from the environment.

**For `make release`,** the GitHub CLI, signed in with `gh auth login`.

`make doctor` checks all of these but the update signing key, which `make release` checks, as the
keychain may ask before the key is read.

## Making a release

1. Merge what goes into the release into main, and pick its version, x.y.z.
2. Write the release's changelog:

   ```bash
   make changelog VERSION=0.1.0
   ```

   This adds the release to `CHANGELOG.md`: a line for each pull request merged since the last
   release, with the title it was merged with, and one for each commit made on main directly.
   Reword the lines for the people who use the app and drop what doesn't concern them, then merge
   it into main, so that the tag includes it.
3. On main, up to date with origin, tag the release and push the tag:

   ```bash
   make tag VERSION=0.1.0
   ```

4. Build the release and upload it to a draft:

   ```bash
   make release VERSION=0.1.0
   ```

   This takes about ten minutes, mostly waiting for Apple's notary service, which sometimes takes
   much longer. It also writes the new appcast, `build/release/0.1.0/appcast.xml`.
5. Download the draft's disk image on a Mac that has never run a build of Live Transcribe, or in
   another user account. Open it, drag the app to Applications and open it. macOS should only
   say that it was downloaded from the internet.
6. Publish the draft on GitHub. The website's Download button goes to the latest release.
7. Offer it as an update: put the new appcast in `site/` and merge it into main through a pull
   request. The website workflow publishes it, and installed copies find the update at their
   next daily check or at **Check for Updates…**.

   ```bash
   make appcast VERSION=0.1.0
   ```

   **Only after the release is published.** The appcast points at the release's disk image, which
   GitHub serves only once the release is public, so an earlier appcast offers an update that
   fails to download. `make appcast` checks that the download works before it copies
   `build/release/0.1.0/appcast.xml` to `site/appcast.xml`.
8. Keep `build/release/<version>/LiveTranscribe.xcarchive`. Its debug symbols turn crash reports
   from that version into readable stack traces.

## What the script does

It stops at the first problem, and shows the end of that step's log.

1. Checks the tag, the certificate and the notary credentials, and for `--draft` that origin has
   the same tag.
2. Exports the tagged commit into `build/release/<version>/source`, so uncommitted changes in
   your checkout can't reach a release, and fetches the Swift packages.
3. Checks that the keychain's update signing key is the one `App/Info.plist` trusts. Steps 1 to 3
   come before the build, so a missing piece costs a minute at most.
4. Archives the app in Release, for Apple silicon, with the version from the tag and, as the build
   number, the number of commits up to it: macOS and Sparkle compare build numbers, so they must
   only grow. The appcast's address goes into the app, which turns updates on. Package versions
   come from `Package.resolved` alone.
5. Exports the app through Xcode's Developer ID distribution, and checks its signature: your
   team's Developer ID, the Hardened Runtime, a secure timestamp, and no debugging entitlement.
   It also checks that the app has Sparkle, the appcast's address and the update key.
6. Notarizes the app and staples its ticket, so a copy dragged out of the disk image opens
   offline.
7. Makes the disk image, with an Applications shortcut next to the app, then signs, notarizes and
   staples it.
8. Asks Gatekeeper about the disk image and about the app on it. Both must be accepted as
   notarized Developer ID software.
9. Signs the disk image as an update and adds it to the appcast in `site/` at the tag, which keeps
   the three newest releases, into `build/release/<version>/appcast.xml`. The new entry must point
   at the release's download and carry its signature.
10. Writes the disk image's SHA-256 next to it and, with `--draft`, uploads the disk image to a
    draft release.

Everything is in `build/release/<version>/`, with each step's output in `logs/`. When Apple
rejects a submission, its reasons are in `logs/notary-app-findings.json` or
`logs/notary-dmg-findings.json`.

| Environment variable | Default | What it is |
|---|---|---|
| `LT_TEAM_ID` | `DEVELOPMENT_TEAM` in `Config/Signing.local.xcconfig` | The certificate's team |
| `LT_NOTARY_PROFILE` | `LiveTranscribe-notary` | The keychain profile saved with `notarytool store-credentials` |
| `LT_NOTARY_TIMEOUT` | `1h` | How long to wait for each notarization |
| `LT_SPARKLE_ACCOUNT` | `LiveTranscribe` | The keychain account of the update signing key |
| `LT_UPDATE_FEED_URL` | `https://nerdstorm.github.io/LiveTranscribe/appcast.xml` | The appcast the app checks |
| `LT_RELEASES_URL` | `https://github.com/Nerdstorm/LiveTranscribe/releases` | Where the appcast's downloads are |

## Test builds

`make release-test VERSION=0.1.0` (`scripts/release.sh 0.1.0 --test`) builds HEAD with ad-hoc
signing, without notarization, and without signing an update or writing an appcast. It checks the
build and the packaging without the certificate, the update signing key or Apple's service.
Gatekeeper blocks the result on other Macs. Like a release, it checks the appcast for updates.

## A release on your own Mac

A release is signed differently from your own builds, so macOS treats it as a different app.
Grant Microphone and Accessibility again when you switch between a release and your own build.
Your own builds never check for updates.

## What must not change

**Once a release is out, the bundle ID (`org.nerdstorm.LiveTranscribe`) and the team stay
fixed.** macOS ties each user's Microphone and Accessibility permissions to them, so a change
makes everyone grant them again.

**So do the appcast's address and the update signing key.** Every installed copy checks
`https://nerdstorm.github.io/LiveTranscribe/appcast.xml` and installs only updates signed with the
key, so moving the appcast or changing the key cuts off the copies already installed. The address
is the repository's GitHub Pages site, so renaming the repository or the organization moves it
too.
