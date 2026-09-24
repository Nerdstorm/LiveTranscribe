#!/bin/zsh
# Builds a Live Transcribe release that opens on any Apple silicon Mac: signed with Developer ID,
# notarized by Apple, stapled, and packed in a disk image with an Applications shortcut. It also
# signs the disk image as a Sparkle update and adds it to the appcast, which updates installed copies.
#
#   scripts/release.sh 0.1.0           builds the tag v0.1.0 into build/release/0.1.0/
#   scripts/release.sh 0.1.0 --draft   also uploads the disk image to a draft GitHub release
#   scripts/release.sh 0.1.0 --test    builds HEAD ad-hoc signed and not notarized, to check the
#                                      build and the packaging without Apple credentials
#
# The source is exported from the tag into a clean folder, so nothing uncommitted in this checkout
# reaches a release. The one-time setup (the Developer ID certificate, the notary credentials and
# the update signing key) and the steps around a release are in docs/releasing.md.
#
# Settings, from the environment:
#   LT_TEAM_ID          the Developer ID certificate's team. Default: DEVELOPMENT_TEAM in
#                       Config/Signing.local.xcconfig
#   LT_NOTARY_PROFILE   the keychain profile saved with `xcrun notarytool store-credentials`.
#                       Default: LiveTranscribe-notary
#   LT_NOTARY_TIMEOUT   how long to wait for each notarization. Default: 1h
#   LT_SPARKLE_ACCOUNT  the keychain account of the key that signs updates, made with Sparkle's
#                       generate_keys. Default: LiveTranscribe
#   LT_UPDATE_FEED_URL  the appcast the app checks for updates. Default:
#                       https://nerdstorm.github.io/LiveTranscribe/appcast.xml
#   LT_RELEASES_URL     the GitHub releases the appcast downloads from. Default:
#                       https://github.com/Nerdstorm/LiveTranscribe/releases
#
# Every copy of the app keeps the feed and the key it was built with, so changing either strands
# the copies already installed.
set -euo pipefail

root="${0:A:h:h}"
notary_profile="${LT_NOTARY_PROFILE:-LiveTranscribe-notary}"
notary_timeout="${LT_NOTARY_TIMEOUT:-1h}"
sparkle_account="${LT_SPARKLE_ACCOUNT:-LiveTranscribe}"
feed_url="${LT_UPDATE_FEED_URL:-https://nerdstorm.github.io/LiveTranscribe/appcast.xml}"
releases_url="${LT_RELEASES_URL:-https://github.com/Nerdstorm/LiveTranscribe/releases}"
app_name=LiveTranscribe
volume_name="Live Transcribe"

log() { print -u2 -r -- "[$(date +%H:%M:%S)] $*" }
fail() { print -u2 -r -- "release: $*"; exit 1 }

usage() {
  print -u2 -r -- "usage: scripts/release.sh <x.y.z> [--draft | --test]"
  exit 2
}

version=""
test_build=false
draft=false
for arg in "$@"; do
  case $arg in
    --test) test_build=true ;;
    --draft) draft=true ;;
    -h|--help) usage ;;
    -*) print -u2 -r -- "release: unknown option $arg"; usage ;;
    *) [[ -z $version ]] || usage; version=$arg ;;
  esac
done
[[ $version == <->.<->.<-> ]] || usage
if $test_build && $draft; then
  fail "a --test build isn't notarized, so it can't be published with --draft"
fi

out="$root/build/release/$version"
logs="$out/logs"
archive="$out/$app_name.xcarchive"
app="$out/export/$app_name.app"
dmg="$out/$app_name.dmg"
mount_point=""

cleanup() {
  if [[ -n $mount_point ]]; then
    hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# run <step> <command...>: runs the command with its output added to logs/<step>.log, and stops
# with the end of that log if the command fails.
run() {
  local step=$1
  shift
  if ! "$@" >> "$logs/$step.log" 2>&1; then
    tail -n 30 "$logs/$step.log" >&2
    fail "$step failed. The full log is ${logs#$root/}/$step.log"
  fi
}

# The SHA-1 of the keychain's Developer ID Application identity for team $1, or nothing.
developer_id_identity() {
  security find-identity -v -p codesigning \
    | awk -v team="($1)\"" '/"Developer ID Application: / && index($0, team) { print $2; exit }'
}

# Everything that can be checked before the long build.
preflight() {
  if $test_build; then ref=HEAD; else ref="v$version"; fi
  commit="$(git -C "$root" rev-parse -q --verify "$ref^{commit}")" \
    || fail "there is no tag $ref. Tag the release commit and push the tag first (docs/releasing.md)."
  # macOS compares CFBundleVersion between copies of the app, so it must grow with every release.
  # The number of commits on main does.
  build_number="$(git -C "$root" rev-list --count "$commit")"
  if $test_build && [[ -n "$(git -C "$root" status --porcelain)" ]]; then
    log "Uncommitted changes in this checkout are not in the build: it is made from HEAD."
  fi
  # Sparkle refuses a feed over plain HTTP, and so does the app.
  [[ $feed_url == https://?* ]] || fail "LT_UPDATE_FEED_URL must be an https address"
  # verify_app checks the app against the Swift runtime of an earlier macOS, from its SDK.
  "$root/scripts/check-swift-runtime.sh" --sdk >/dev/null \
    || fail "there's no earlier macOS SDK to check the app against (docs/releasing.md)"

  if ! $test_build; then
    team_id="${LT_TEAM_ID:-$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([^[:space:]/]*\).*/\1/p' \
      "$root/Config/Signing.local.xcconfig" 2>/dev/null | tail -n 1)}"
    [[ -n $team_id && $team_id != YOUR_TEAM_ID ]] \
      || fail "set LT_TEAM_ID, or DEVELOPMENT_TEAM in Config/Signing.local.xcconfig, to the team of your Developer ID certificate"
    identity="$(developer_id_identity "$team_id")"
    [[ -n $identity ]] \
      || fail "the keychain has no Developer ID Application certificate for team $team_id (docs/releasing.md says how to get one)"
    xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 \
      || fail "notarytool can't sign in with the keychain profile \"$notary_profile\" (docs/releasing.md says how to save it)"
  fi

  if $draft; then
    command -v gh >/dev/null || fail "--draft needs the GitHub CLI, gh"
    gh auth status >/dev/null 2>&1 || fail "gh isn't signed in to GitHub: run gh auth login"
    local ours theirs
    ours="$(git -C "$root" rev-parse "refs/tags/$ref")"
    theirs="$(git -C "$root" ls-remote --tags origin "refs/tags/$ref" | cut -f 1)"
    [[ $theirs == "$ours" ]] || fail "origin doesn't have this tag $ref. Push it first: git push origin $ref"
  fi
}

# Exports the commit into a clean folder, so the build sees exactly what the tag holds.
export_source() {
  rm -rf "$out"
  mkdir -p "$logs" "$out/source"
  git -C "$root" archive "$commit" | tar -x -C "$out/source"
  update_key="$(plutil -extract SUPublicEDKey raw -o - "$out/source/App/Info.plist" 2>/dev/null || true)"
  [[ -n $update_key ]] || fail "App/Info.plist at $ref has no SUPublicEDKey, so the release couldn't update itself"
}

# Fetches the packages Package.resolved names, which brings Sparkle's tools for signing updates.
resolve_packages() {
  log "Fetching the Swift packages"
  run resolve xcodebuild -resolvePackageDependencies -project "$out/source/$app_name.xcodeproj" \
    -scheme "$app_name" -derivedDataPath "$out/DerivedData" -disableAutomaticPackageResolution
  sparkle_bin="$out/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
  [[ -x $sparkle_bin/generate_appcast ]] || fail "Sparkle's tools aren't in ${sparkle_bin#$root/}"
}

# The keychain's update signing key must be the one the app trusts (SUPublicEDKey), or installed
# copies would refuse the update. Checked before the long build; the keychain may ask first.
check_update_key() {
  local ours
  ours="$("$sparkle_bin/generate_keys" --account "$sparkle_account" -p 2>/dev/null)" \
    || fail "couldn't read the update signing key for the account \"$sparkle_account\": the keychain doesn't have it, or access was denied (docs/releasing.md says how to import it)"
  [[ $ours == "$update_key" ]] \
    || fail "the keychain's update signing key for \"$sparkle_account\" isn't the one App/Info.plist trusts (SUPublicEDKey)"
}

build_archive() {
  log "Archiving. Building MLX from scratch takes several minutes."
  local -a signing
  if $test_build; then
    signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
  else
    signing=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application" "DEVELOPMENT_TEAM=$team_id"
      OTHER_CODE_SIGN_FLAGS=--timestamp)
  fi
  # Package versions come only from Package.resolved, so a release has the tested dependencies.
  # ARCHS here reaches the packages too, which otherwise also build for Intel, where MLX can't run.
  # The feed turns updates on; a build without it never updates.
  run archive xcodebuild archive \
    -project "$out/source/$app_name.xcodeproj" -scheme "$app_name" -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" -derivedDataPath "$out/DerivedData" \
    -disableAutomaticPackageResolution -skipPackagePluginValidation ARCHS=arm64 \
    "MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build_number" "LT_UPDATE_FEED_URL=$feed_url" \
    "${signing[@]}"
}

# Exports the app from the archive through Xcode's Developer ID distribution, which signs every
# piece of it for distribution. A test build takes the archived app as it is.
export_app() {
  mkdir -p "${app:h}"
  if $test_build; then
    ditto "$archive/Products/Applications/$app_name.app" "$app"
    return
  fi
  log "Exporting for Developer ID distribution"
  local options="$out/ExportOptions.plist"
  plutil -create xml1 "$options"
  plutil -insert method -string developer-id "$options"
  plutil -insert signingStyle -string manual "$options"
  plutil -insert signingCertificate -string "Developer ID Application" "$options"
  plutil -insert teamID -string "$team_id" "$options"
  run export xcodebuild -exportArchive -archivePath "$archive" -exportPath "${app:h}" -exportOptionsPlist "$options"
}

# verify_app <app>: checks the signature, the version, the updates and that an earlier macOS can
# launch it, and for a release everything notarization requires of the signature.
verify_app() {
  local app=$1
  run verify codesign --verify --strict --deep --verbose=2 "$app"
  # dyld won't launch an app that needs a symbol the Swift runtime of the Mac's macOS lacks.
  run verify "$root/scripts/check-swift-runtime.sh" "$app"
  local info="$app/Contents/Info.plist"
  [[ "$(plutil -extract CFBundleShortVersionString raw -o - "$info")" == "$version" ]] \
    || fail "${app:t} isn't version $version"
  [[ "$(plutil -extract CFBundleVersion raw -o - "$info")" == "$build_number" ]] \
    || fail "${app:t} isn't build $build_number"
  [[ -d $app/Contents/Frameworks/Sparkle.framework ]] || fail "${app:t} has no Sparkle.framework"
  [[ "$(plutil -extract SUFeedURL raw -o - "$info" 2>/dev/null)" == "$feed_url" ]] \
    || fail "${app:t} doesn't check $feed_url for updates"
  [[ "$(plutil -extract SUPublicEDKey raw -o - "$info" 2>/dev/null)" == "$update_key" ]] \
    || fail "${app:t} doesn't trust the update signing key in App/Info.plist"
  if $test_build; then
    return
  fi
  local signature
  signature="$(codesign -dvv "$app" 2>&1)"
  [[ $signature == *"Authority=Developer ID Application: "*"($team_id)"* ]] \
    || fail "${app:t} isn't signed with the Developer ID of team $team_id"
  [[ $signature == *flags=0x*runtime* ]] \
    || fail "${app:t} doesn't have the Hardened Runtime, which notarization requires"
  [[ $signature == *Timestamp=* ]] \
    || fail "${app:t}'s signature has no secure timestamp, which notarization requires"
  [[ "$(codesign -d --entitlements - --xml "$app" 2>/dev/null)" != *get-task-allow* ]] \
    || fail "${app:t} allows debugging (get-task-allow), which notarization rejects"
}

# notarize <file> <label>: submits the file to Apple's notary service and waits for it. Apple's
# answer and its findings are kept in logs/notary-<label>*.json.
notarize() {
  local file=$1 label=$2
  local result="$logs/notary-$label.json"
  log "Notarizing the $label. Apple usually takes a few minutes."
  xcrun notarytool submit "$file" --keychain-profile "$notary_profile" --wait --timeout "$notary_timeout" \
    --output-format json > "$result" 2>> "$logs/notary-$label.log" || true
  local id notary_status
  id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  notary_status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  if [[ -n $id ]]; then
    xcrun notarytool log "$id" --keychain-profile "$notary_profile" "$logs/notary-$label-findings.json" \
      >> "$logs/notary-$label.log" 2>&1 || true
  fi
  [[ $notary_status == Accepted ]] \
    || fail "Apple didn't notarize the $label (${notary_status:-no answer}). See ${logs#$root/}/notary-$label*"
}

make_dmg() {
  log "Making the disk image"
  local staging="$out/dmg"
  mkdir -p "$staging"
  ditto "$app" "$staging/$app_name.app"
  ln -s /Applications "$staging/Applications"
  run dmg hdiutil create -volname "$volume_name" -srcfolder "$staging" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -ov "$dmg"
  rm -rf "$staging"
}

# assess <execute|open> <file>: asks Gatekeeper whether it would open the file, and requires the
# notarization to be the reason.
assess() {
  local kind=$1 file=$2 verdict
  local -a context
  if [[ $kind == open ]]; then
    context=(--context context:primary-signature)
  fi
  verdict="$(spctl --assess --type "$kind" "${context[@]}" --verbose=4 "$file" 2>&1)" \
    || fail "Gatekeeper rejects ${file:t}: $verdict"
  print -r -- "$verdict" >> "$logs/gatekeeper.log"
  [[ $verdict == *"source=Notarized Developer ID"* ]] \
    || fail "Gatekeeper accepts ${file:t}, but not as notarized: $verdict"
}

# Mounts the disk image and checks what a user drags out of it.
verify_dmg() {
  log "Checking the disk image's contents"
  mount_point="$out/mount"
  mkdir -p "$mount_point"
  run mount hdiutil attach "$dmg" -readonly -nobrowse -noautoopen -mountpoint "$mount_point"
  local copy="$mount_point/$app_name.app"
  [[ -d $copy ]] || fail "the disk image has no $app_name.app"
  [[ "$(readlink "$mount_point/Applications")" == /Applications ]] \
    || fail "the disk image has no Applications shortcut"
  verify_app "$copy"
  if ! $test_build; then
    run staple xcrun stapler validate "$copy"
    assess execute "$copy"
  fi
  run mount hdiutil detach "$mount_point"
  mount_point=""
  rmdir "$out/mount" 2>/dev/null || true
}

# Signs the disk image as a Sparkle update and adds it to the appcast in site/ at the tag, which
# keeps the releases before it. Installed copies see the update once this appcast.xml is on the
# site, and it must go there only after the GitHub release is published (docs/releasing.md).
make_appcast() {
  log "Signing the update and adding it to the appcast"
  local dir="$out/appcast"
  mkdir -p "$dir"
  if [[ -f $out/source/site/appcast.xml ]]; then
    cp "$out/source/site/appcast.xml" "$dir/"
  fi
  cp -c "$dmg" "$dir/"
  run appcast "$sparkle_bin/generate_appcast" --account "$sparkle_account" \
    --download-url-prefix "$releases_url/download/$ref/" --link "$releases_url/tag/$ref" \
    --full-release-notes-url "$releases_url" --maximum-deltas 0 "$dir"
  mv "$dir/appcast.xml" "$out/appcast.xml"
  rm -rf "$dir"
  local item="//item[*[local-name()='version']='$build_number']/enclosure"
  [[ "$(xmllint --xpath "string($item/@url)" "$out/appcast.xml")" == "$releases_url/download/$ref/${dmg:t}" ]] \
    || fail "the appcast doesn't send build $build_number to $releases_url/download/$ref/${dmg:t}"
  [[ -n "$(xmllint --xpath "string($item/@*[local-name()='edSignature'])" "$out/appcast.xml")" ]] \
    || fail "the appcast's update isn't signed, and installed copies would refuse it. See ${logs#$root/}/appcast.log"
}

publish() {
  log "Uploading to a draft GitHub release for $ref"
  (cd "$root" && gh release create "$ref" "$dmg" --draft --verify-tag --title "Live Transcribe $version" \
    --generate-notes) || fail "gh couldn't create the draft release"
  log "Made the draft. Try its download on another Mac, then publish it on GitHub."
}

preflight
log "Building $app_name $version (build $build_number) from $ref, commit ${commit:0:7}"
export_source
resolve_packages
if ! $test_build; then
  check_update_key
fi
build_archive
export_app
verify_app "$app"
if ! $test_build; then
  # Notarize and staple the app before packing it, so a copy dragged out of the disk image
  # carries its own ticket and opens offline.
  ditto -c -k --keepParent "$app" "$out/$app_name.zip"
  notarize "$out/$app_name.zip" app
  rm "$out/$app_name.zip"
  run staple xcrun stapler staple "$app"
fi
make_dmg
if ! $test_build; then
  run sign-dmg codesign --sign "$identity" --timestamp "$dmg"
  notarize "$dmg" dmg
  run staple xcrun stapler staple "$dmg"
  run staple xcrun stapler validate "$dmg"
  assess open "$dmg"
fi
verify_dmg
if ! $test_build; then
  make_appcast
fi
(cd "$out" && shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256")
# The archive stays: its dSYMs symbolicate crash reports from this version.
rm -rf "$out/source" "$out/DerivedData"
log "Built ${dmg#$root/}, SHA-256 $(cut -d ' ' -f 1 "$dmg.sha256")"
if $test_build; then
  log "This is a test build. It isn't notarized, so other Macs won't open it."
fi
if $draft; then
  publish
fi
if ! $test_build; then
  log "Once the release is published, put ${out#$root/}/appcast.xml in site/ to offer it as an update."
fi
