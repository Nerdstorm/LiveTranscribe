# Releasing

A release is one [GitHub release](https://github.com/Nerdstorm/LiveTranscribe/releases) with the
app for every system, all at the same version, built from one tag `vX.Y.Z` by the
[release workflow](../.github/workflows/release.yml):

- **Mac:** a disk image that opens on any Apple silicon Mac without a Gatekeeper warning. The app
  is signed with a Developer ID certificate and notarized by Apple, and both the app and the disk
  image carry their notarization ticket. Installed copies update themselves with
  [Sparkle](https://sparkle-project.org) from `appcast.xml` on the website.
  [`scripts/release.sh`](../scripts/release.sh) builds it.
- **Linux:** a deb, an rpm and an AppImage for x86-64
  ([`linux-windows/README.md`](../linux-windows/README.md#packages) says what they carry).
- **Windows:** an installer for x86-64, `live-transcribe_X.Y.Z_x64-setup.exe`, which isn't signed
  ([`linux-windows/README.md`](../linux-windows/README.md#the-windows-installer) says what it
  carries).

The [Makefile](../Makefile) has a target for each step below that runs on your Mac.

## One-time setup

The workflow signs and notarizes the Mac app with keys kept as secrets on GitHub. They start on
your Mac, as below, and go to GitHub at the end.

**A Developer ID Application certificate.** Only the Account Holder of the Apple Developer team
can create one: Xcode › Settings › Accounts › the team › Manage Certificates › + › Developer ID
Application. Another maintainer gets it from the Account Holder as a password-protected .p12
(Keychain Access › My Certificates › the certificate › Export) and double-clicks it to import it.
`security find-identity -v -p codesigning` lists it once it's in the keychain.

- Keep the .p12 in a password manager. A team can have five of these certificates, so a lost one
  can be replaced, but the backup saves the trouble.
- **Export the "Developer ID Application" identity, not an Apple Development or Apple
  Distribution one.** Before you upload the .p12, import it into a temporary keychain and run
  `security find-identity -v -p codesigning` on that keychain: it must list
  `Developer ID Application: …`.
- **Never revoke it after a release.** Apple then blocks every app signed with it: it no longer
  installs, and copies already installed no longer open.
- It expires: Keychain Access shows the date. Make a new one before then, and replace the
  certificate and password secrets.

**Notarization credentials.** In App Store Connect › Users and Access › Integrations › Team Keys,
add a key with the Developer role (personal keys can't notarize) and download its .p8 file. To
notarize from your Mac as well, save it in the keychain:

```bash
xcrun notarytool store-credentials LiveTranscribe-notary --key /path/to/AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER-UUID
```

**Keep the .p8 in a password manager and delete it from Downloads.** App Store Connect lets you
download it only once. If it leaks, revoke the key in App Store Connect and make a new one. The
repository ignores `*.p8` and `*.p12` files, but they don't belong in it at all.

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
delete it once it's on GitHub (below).** Without the key, installed copies can't be updated, and
their users would have to download the next release by hand. On another Mac, import it with `-f`
in place of `-x`. The keychain asks before each of Sparkle's tools first reads the key; allow it.

**The team ID.** On your Mac, the script takes `DEVELOPMENT_TEAM` from
`Config/Signing.local.xcconfig` (see [Signing your builds](development.md#signing-your-builds)),
or `LT_TEAM_ID` from the environment.

**The release environment.** The workflow reads the keys from the secrets of a GitHub environment
named `release`, and only the jobs that sign use it. In the repository's Settings › Environments,
make it with:

- **Required reviewers:** you. Each run then waits for your approval before it reads the keys.
- **Deployment branches and tags:** selected ones, the tag `v*` and the branch `main` (for
  rehearsals, below).
- **Secrets**, which the GitHub CLI can set from the files, before you delete them:

  ```bash
  base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERTIFICATE --env release
  gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD --env release
  gh secret set TEAM_ID --env release
  gh secret set NOTARY_KEY --env release < AuthKey_KEYID.p8
  gh secret set NOTARY_KEY_ID --env release
  gh secret set NOTARY_ISSUER --env release
  gh secret set SPARKLE_KEY --env release < ~/LiveTranscribe-update-key.txt
  ```

  `gh secret set` asks for the values it isn't given: the .p12's password, the team ID, the API
  key's ID and its issuer. GitHub sometimes answers HTTP 500; run the command again.

**Then, in Settings › Rules › Rulesets, protect the tags `v*`, so that only you can make, move or
delete them.** Anyone who can push a tag or change the workflow on main could otherwise have the
keys used for their own build, if you approve the run. With the keys, someone could sign software
as your team and offer it as an update to every installed copy. If a key leaks, revoke it as above
and replace its secret.

After setting or changing the secrets, [rehearse](#rehearsing) once.

**An earlier macOS SDK,** to build a release or a test build on your Mac. Every build is checked
against the Swift runtime of an earlier macOS, which the oldest macOS SDK on your Mac that is older
than Xcode's describes. Command Line Tools (`xcode-select --install`) keeps the previous macOS's
SDK. `LT_BASELINE_SDK` names another.

**For `make appcast`,** the GitHub CLI, signed in with `gh auth login` (`xmllint` and `curl` come
with macOS).

## Making a release

1. Merge what goes into the release into main, and pick its version, x.y.z. Every system gets it,
   even one that hasn't changed since the last release.
2. Write the release's changelog:

   ```bash
   make changelog VERSION=x.y.z
   ```

   This adds the release to `CHANGELOG.md`: a line for each pull request merged since the last
   release, with the title it was merged with, and one for each commit made on main directly.
   Reword the lines for the people who use the app, say which system a line is about when it's
   only one, and drop what doesn't concern them. Then merge it into main, so that the tag includes
   it. Its section becomes the release's notes, followed by how to install it on each system
   (`.github/release-notes.md`).
3. On main, up to date with origin, tag the release and push the tag:

   ```bash
   make tag VERSION=x.y.z
   ```

   The tag starts the release workflow. It stops at once if `CHANGELOG.md` has no section for the
   release, and so does `make tag`.
4. Approve the run: the Actions tab › the run › Review deployments › `release`. The Mac app takes
   about nine minutes, most of it compiling (Apple's notary service took about a minute in the
   1.0.0 run, but sometimes takes much longer); the Linux packages about 14 and the Windows
   installer about 6, meanwhile. Then the workflow drafts the release, with every download,
   `SHA256SUMS` and the notes.

   If a job fails, nothing is public yet. Fix the problem on main, delete the tag
   (`git push origin --delete vx.y.z` and `git tag -d vx.y.z`), and tag again. **Never delete the
   tag of a release that is published.**
5. Try the draft's downloads:
   - the disk image, on a Mac that has never run a build of Live Transcribe, or in another user
     account. Open it, drag the app to Applications and open it. macOS should only say that it
     was downloaded from the internet;
   - a Linux package, on a desktop the app types on;
   - the Windows installer, on a PC that has never had Live Transcribe. SmartScreen warns about an
     unrecognised app, since it isn't signed (More info, then Run anyway); then dictate into
     Notepad and into a browser.
6. Publish the draft on GitHub. It becomes the latest release, which the website's Download button
   goes to.
7. Offer the Mac app as an update: put the new appcast in `site/` and merge it into main through a
   pull request. The website workflow publishes it, and copies with automatic checks on find the
   update within a day, and any copy at **Check for Updates…**.

   ```bash
   make appcast VERSION=x.y.z
   ```

   It fetches what the workflow made besides the downloads into `build/release/x.y.z/`: the
   appcast and the app's archive (`scripts/fetch-release.sh`). Then it checks that the download
   works and copies the appcast to `site/appcast.xml`.

   **Only after the release is published.** The appcast points at the release's disk image, which
   GitHub serves only once the release is public, so an earlier appcast offers an update that
   fails to download.
8. Keep `build/release/<version>/LiveTranscribe.xcarchive`. Its debug symbols turn crash reports
   from that version into readable stack traces, and GitHub deletes the workflow's copy after 90
   days.

## Rehearsing

The Actions tab › Release › Run workflow, on main, with "Sign and notarize the Mac app as a
release would, without releasing anything" ticked (the workflow's `rehearse` input), builds main's
Mac app as a release would: signed, notarized and signed as an update, with the keys in the
release environment, so it waits for your approval too. It builds the Linux packages and the Windows
installer as well, and releases nothing. A problem with the keys shows there, not after a tag.

## How the Mac build works

`scripts/release.sh` stops at the first problem and shows the end of that step's log. It checks the
tag, the certificate, the notary credentials and the earlier macOS SDK, exports the tagged commit
and fetches the Swift packages, and checks the update signing key, all before it builds, so a
missing piece fails early. Then it archives the app in Release for Apple silicon, exports it through
Xcode's Developer ID distribution, checks its signature and its Swift runtime, notarizes and staples
the app, makes, signs, notarizes and staples the disk image, asks Gatekeeper about both, signs the
disk image as an update, and writes the appcast and the disk image's SHA-256. The build number is
the number of commits up to the tag: macOS and Sparkle compare build numbers, so they must only
grow.

Everything is in `build/release/<version>/`, with each step's output in `logs/`. When Apple
rejects a submission, its reasons are in `logs/notary-app-findings.json` or
`logs/notary-dmg-findings.json`. `scripts/release.sh 0.0.0 --rehearse` does the same from HEAD.
The workflow runs the script with its keys in a keychain of its own, and gives it the notary key
and the update signing key as files.

| Environment variable | Default | What it is |
|---|---|---|
| `LT_TEAM_ID` | `DEVELOPMENT_TEAM` in `Config/Signing.local.xcconfig` | The certificate's team |
| `LT_NOTARY_PROFILE` | `LiveTranscribe-notary` | The keychain profile saved with `notarytool store-credentials` |
| `LT_NOTARY_KEY_FILE` | None | An App Store Connect API key (.p8) to notarize with instead of the profile |
| `LT_NOTARY_KEY_ID`, `LT_NOTARY_ISSUER` | None | That key's ID and issuer |
| `LT_NOTARY_TIMEOUT` | `1h` | How long to wait for each notarization |
| `LT_SPARKLE_ACCOUNT` | `LiveTranscribe` | The keychain account of the update signing key |
| `LT_SPARKLE_KEY_FILE` | None | The update signing key in a file, as `generate_keys -x` exports it, instead of the keychain's |
| `LT_UPDATE_FEED_URL` | `https://nerdstorm.github.io/LiveTranscribe/appcast.xml` | The appcast the app checks |
| `LT_RELEASES_URL` | `https://github.com/Nerdstorm/LiveTranscribe/releases` | Where the appcast's downloads are |
| `LT_BASELINE_SDK` | The oldest macOS SDK older than Xcode's | The SDK whose Swift runtime the app is checked against |

## Test builds

`make release-test VERSION=0.0.0` (`scripts/release.sh 0.0.0 --test`) builds HEAD with ad-hoc
signing, without notarization, and without signing an update or writing an appcast. It checks the
build and the packaging without the certificate, the update signing key or Apple's service.
Gatekeeper blocks the result on other Macs. A pull request that changes the release workflow, its
scripts or the Linux or Windows packaging makes test builds for every system, to try from the
run's artifacts.

### A release on your own Mac

A release is signed differently from your own builds, so macOS treats it as a different app:
grant Microphone and Accessibility again when you switch between a release and your own build.
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
