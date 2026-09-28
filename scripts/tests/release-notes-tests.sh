#!/bin/zsh
# Tests scripts/release-notes.sh with a scratch changelog and install notes. make test runs it.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts" "$work/.github"
cp "${0:A:h:h}/release-notes.sh" "$work/scripts/"

cat > "$work/CHANGELOG.md" <<'EOF'
# Changelog

What changed in each release.

## 0.10.0 - 2026-03-01

- Not the release asked for, though its version starts the same

## 0.1.0 - 2026-02-01


- Add the first feature ([#1](https://github.com/Example/App/pull/1))
- Fix a crash

[Every commit since v0.0.9](https://github.com/Example/App/compare/v0.0.9...v0.1.0)


## 0.0.9

- The last release
EOF
cat > "$work/.github/release-notes.md" <<'EOF'
## Installing

`app_@VERSION@.deb`, or `app-@VERSION@.rpm`
EOF

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
notes() {
  out=$("$work/scripts/release-notes.sh" "$@" 2>"$work/err") && code=0 || code=$?
  err=$(<"$work/err")
}

notes 0.1.0
check "a release's notes are its section, without the blank lines around it, then the install notes" "$out" \
"- Add the first feature ([#1](https://github.com/Example/App/pull/1))
- Fix a crash

[Every commit since v0.0.9](https://github.com/Example/App/compare/v0.0.9...v0.1.0)

## Installing

\`app_0.1.0.deb\`, or \`app-0.1.0.rpm\`"

notes 0.0.9
check "the last section ends at the end of the file, and its heading needn't have a date" \
  "${out%%$'\n\n'## Installing*}" "- The last release"

notes 0.2.0
check "a release the changelog doesn't have fails" "$code" 1
check "and says how to write its section" "$err" \
  "release-notes: CHANGELOG.md has no section for 0.2.0: make changelog VERSION=0.2.0 writes one (docs/releasing.md)"

notes 0.1
check "a version that isn't x.y.z fails" "$code:$err" "1:release-notes: 0.1 isn't a version x.y.z"

notes
check "no version fails" "$code:$err" "1:release-notes: usage: scripts/release-notes.sh <x.y.z>"

(( failures == 0 )) || { print -r -- "$failures failed"; exit 1 }
