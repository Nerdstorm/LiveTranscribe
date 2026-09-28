#!/bin/zsh
# Tests scripts/fetch-release.sh against a stand-in for the GitHub CLI. make test runs it.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts" "$work/bin" "$work/artifacts/LiveTranscribe.xcarchive/dSYMs"
cp "${0:A:h:h}/fetch-release.sh" "$work/scripts/"

# The artifacts a release run leaves: the appcast, and the archive zipped as the workflow zips it.
print -r -- '<rss/>' > "$work/artifacts/appcast.xml"
print -r -- 'symbols' > "$work/artifacts/LiveTranscribe.xcarchive/dSYMs/LiveTranscribe.app.dSYM"
(cd "$work/artifacts" && ditto -c -k --keepParent LiveTranscribe.xcarchive LiveTranscribe.xcarchive.zip)

# Stands in for the GitHub CLI: run 42 is the release run of v0.4.0, and each call is logged.
cat > "$work/bin/gh" <<EOF
#!/bin/zsh
print -r -- "\$*" >> "$work/gh.log"
case "\$1 \$2" in
  "run list") [[ " \$* " == *" --branch v0.4.0 "* ]] && print 42 || true ;;
  "run download")
    [[ \$3 == 42 ]] || exit 1
    case \$5 in
      mac-appcast) cp "$work/artifacts/appcast.xml" "\$7/" ;;
      mac-archive) cp "$work/artifacts/LiveTranscribe.xcarchive.zip" "\$7/" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"

failures=0
check() {
  if [[ $2 == "$3" ]]; then
    print -r -- "ok    $1"
  else
    print -r -- "FAIL  $1"
    diff -u <(print -r -- "$2") <(print -r -- "$3") || true
    failures=$(( failures + 1 ))
  fi
}
# Runs the script with the given arguments, into $out, $err and $code.
fetch() {
  out=$("$work/scripts/fetch-release.sh" "$@" 2>"$work/err") && code=0 || code=$?
  err=$(<"$work/err")
}
out_dir="$work/build/release/0.4.0"

fetch 0.4.0
check "it fetches the release run's appcast" "$code:$(<"$out_dir/appcast.xml")" "0:<rss/>"
check "and unpacks the archive where a build on the Mac leaves it" \
  "$(<"$out_dir/LiveTranscribe.xcarchive/dSYMs/LiveTranscribe.app.dSYM")" "symbols"
check "without keeping the zip" "$([[ -e $out_dir/LiveTranscribe.xcarchive.zip ]] && print kept || print gone)" "gone"
check "and says where from" "$out" "Fetched the appcast and the app's archive from release run 42 into build/release/0.4.0/"

rm "$work/gh.log"
fetch 0.4.0
check "fetching again downloads nothing it already has" "$code:$(grep -c 'run download' "$work/gh.log" || true)" "0:0"

fetch 0.5.0
check "a release without a finished run fails" "$code" 1
check "and says what starts one" "$err" \
  "fetch-release: no release run for v0.5.0 has finished: pushing the tag starts one (docs/releasing.md)"

fetch 0.4
check "a version that isn't x.y.z fails" "$code:$err" "2:usage: scripts/fetch-release.sh <x.y.z>"

(( failures == 0 )) || { print -r -- "$failures failed"; exit 1 }
