#!/bin/zsh
# Fetches what the release workflow made for release <version> besides its downloads, into
# build/release/<version>/, where a build on this Mac leaves them: the appcast that offers it as an
# update, and the Mac app's archive, whose debug symbols make crash reports from it readable.
# GitHub deletes a run's copies after 90 days. make appcast runs it.
#
#   scripts/fetch-release.sh 0.4.0
set -euo pipefail

root="${0:A:h:h}"

fail() { print -u2 -r -- "fetch-release: $*"; exit 1 }

(( $# == 1 )) && [[ $1 == <->.<->.<-> ]] || { print -u2 -r -- "usage: scripts/fetch-release.sh <x.y.z>"; exit 2 }
version=$1
out="$root/build/release/$version"
cd "$root"

command -v gh >/dev/null || fail "this needs the GitHub CLI, gh"
run="$(gh run list --workflow release.yml --branch "v$version" --event push --status success --limit 1 \
  --json databaseId --jq '.[0].databaseId // empty')" || fail "gh couldn't list the release workflow's runs"
[[ -n $run ]] || fail "no release run for v$version has finished: pushing the tag starts one (docs/releasing.md)"

mkdir -p "$out"
if [[ ! -f $out/appcast.xml ]]; then
  gh run download "$run" --name mac-appcast --dir "$out" || fail "couldn't download the appcast from run $run"
fi
if [[ ! -d $out/LiveTranscribe.xcarchive ]]; then
  gh run download "$run" --name mac-archive --dir "$out" || fail "couldn't download the app's archive from run $run"
  ditto -x -k "$out/LiveTranscribe.xcarchive.zip" "$out"
  rm "$out/LiveTranscribe.xcarchive.zip"
fi
print -r -- "Fetched the appcast and the app's archive from release run $run into ${out#$root/}/"
