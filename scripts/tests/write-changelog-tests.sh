#!/bin/zsh
# Tests scripts/write-changelog.sh in a scratch repository with pull request merges, a squash merge,
# commits made on main directly and release tags. make test runs it.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
mkdir -p "$repo/scripts" "$work/bin"
cp "${0:A:h:h}/write-changelog.sh" "$repo/scripts/"

# Stands in for the GitHub CLI: it knows the title of pull request 3 and fails for the others.
cat > "$work/bin/gh" <<'EOF'
#!/bin/sh
case " $* " in *" view 3 "*) echo 'Take the title from GitHub' ;; *) exit 1 ;; esac
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"
export LT_REPO_URL=https://github.com/Example/App
# Leave out your Git configuration, such as commit signing and hooks.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

git() { command git -C "$repo" "$@" }
commit() { git commit -q --allow-empty -m "$1" }
# merge_pr <number> <branch> [title]: merges a branch the way GitHub's merge button does.
merge_pr() {
  local -a message=(-m "Merge pull request #$1 from Example/$2")
  if [[ -n ${3:-} ]]; then message+=(-m "$3"); fi
  git checkout -q -b "$2"
  commit "Work on $2"
  git checkout -q main
  git merge -q --no-ff "$2" "${message[@]}"
}

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
write() {
  out=$("$repo/scripts/write-changelog.sh" "$@" 2>"$work/err") && code=0 || code=$?
  err=$(<"$work/err")
}
# The changelog's releases, from the first section heading on.
sections() { sed -n '/^## /,$p' "$repo/CHANGELOG.md" }

git init -q -b main
commit 'Start the app'
merge_pr 1 first-feature 'Add the first feature'
GIT_COMMITTER_DATE='2026-01-02T10:00:00' git tag -a v0.1.0 -m 'App 0.1.0'
merge_pr 2 second-feature 'Add the second feature'
commit 'Squash a pull request (#4)'
commit 'Fix a typo on main'
merge_pr 3 github-title
merge_pr 5 no-title

pending='- Add the second feature ([#2](https://github.com/Example/App/pull/2))
- Squash a pull request ([#4](https://github.com/Example/App/pull/4))
- Fix a typo on main
- Take the title from GitHub ([#3](https://github.com/Example/App/pull/3))
- no-title ([#5](https://github.com/Example/App/pull/5))

[Every commit since v0.1.0](https://github.com/Example/App/compare/v0.1.0...v0.2.0)'
first='## 0.1.0 - 2026-01-02

- Start the app
- Add the first feature ([#1](https://github.com/Example/App/pull/1))

[Every commit](https://github.com/Example/App/commits/v0.1.0)'

write 0.2.0
check 'writes the changes since the last tag, up to HEAD' "0 ## 0.2.0 - $(date +%Y-%m-%d)

$pending" "$code $(sections)"
check 'starts a new changelog with its title' '# Changelog' "$(head -n 1 "$repo/CHANGELOG.md")"
check 'says which pull request it could only name by its branch' 1 "$(print -r -- "$err" | grep -c '#5')"

before=$(<"$repo/CHANGELOG.md")
write 0.2.0
after=$(<"$repo/CHANGELOG.md")
check "won't write a version twice" "1 $before" "$code $after"

write 0.1.0
check 'puts an older release below a newer one, dated by its tag' "0 ## 0.2.0 - $(date +%Y-%m-%d)

$pending

$first" "$code $(sections)"

GIT_COMMITTER_DATE='2026-02-03T10:00:00' git tag -a v0.2.0 -m 'App 0.2.0'
rm "$repo/CHANGELOG.md"
write 0.2.0
check 'writes a tagged release from the release before it' "0 ## 0.2.0 - 2026-02-03

$pending" "$code $(sections)"

write 0.3.0
check 'stops when nothing has changed since the last tag' '1 changelog: nothing has changed since v0.2.0' "$code $err"

write 1.2
check 'wants a version such as 0.2.0' 2 "$code"

(( failures == 0 )) || { print -r -- "$failures of the changelog tests failed"; exit 1 }
