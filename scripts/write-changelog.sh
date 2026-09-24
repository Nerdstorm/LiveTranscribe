#!/bin/zsh
# Adds a release's section to CHANGELOG.md, summarising what changed since the release before it:
# a line for each pull request merged into main, with its title and a link, and a line for each
# commit made on main directly.
#
#   scripts/write-changelog.sh 0.2.0   summarises the newest release tag to HEAD, where v0.2.0 will
#                                      be tagged, or once v0.2.0 exists, the release before it to it
#
# Run it on main before tagging the release, edit what it wrote, and merge it into main
# (docs/releasing.md). It won't write a version twice: delete that section to write it again.
#
# Settings, from the environment:
#   LT_REPO_URL   the GitHub repository the links point at. Default:
#                 https://github.com/Nerdstorm/LiveTranscribe
set -euo pipefail

root="${0:A:h:h}"
repo_url="${LT_REPO_URL:-https://github.com/Nerdstorm/LiveTranscribe}"
changelog="$root/CHANGELOG.md"
header='# Changelog

What changed in each release of Live Transcribe, newest first. Before a release,
`make changelog VERSION=x.y.z` summarises what was merged since the last one
([Releasing](docs/releasing.md)).'

fail() { print -u2 -r -- "changelog: $*"; exit 1 }

usage() {
  print -u2 -r -- "usage: scripts/write-changelog.sh <x.y.z>"
  exit 2
}

(( $# == 1 )) && [[ $1 == <->.<->.<-> ]] || usage
version=$1
tag="v$version"
cd "$root"

[[ -f $changelog ]] && current=$(<"$changelog") || current=$header
if print -r -- "$current" | awk -v v="$version" '$1 == "##" && $2 == v { found = 1 } END { exit !found }'; then
  fail "CHANGELOG.md already has $version. Delete its section to write it again."
fi

# The title of pull request $1 on GitHub, for a merge commit whose message doesn't carry it.
github_title() {
  (( $+commands[gh] )) || return 1
  gh pr view "$1" --repo "$repo_url" --json title --jq .title 2>/dev/null
}

# The release ends at its tag once it's tagged, and otherwise at HEAD, where it will be tagged. It
# starts after the newest release tag before that.
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  end=$tag
  since=$(git describe --tags --abbrev=0 --first-parent --match 'v[0-9]*' "$tag^" 2>/dev/null) || since=""
  date=$(git for-each-ref --format='%(creatordate:short)' "refs/tags/$tag")
else
  end=HEAD
  since=$(git describe --tags --abbrev=0 --first-parent --match 'v[0-9]*' HEAD 2>/dev/null) || since=""
  date=$(date +%Y-%m-%d)
fi

# main's own history, so that each pull request is its merge commit rather than its many commits.
commits=$(git log --first-parent --reverse --format='%h %s' "${since:+$since..}$end")
[[ -n $commits ]] || fail "nothing has changed since $since"

entries=()
for line in "${(@f)commits}"; do
  sha=${line%% *}
  subject=${line#* }
  if [[ $subject =~ '^Merge pull request #([0-9]+) from [^/ ]+/(.+)$' ]]; then
    number=$match[1]
    branch=$match[2]
    # GitHub's merge button puts the pull request's title in the body of the merge commit.
    title=$(git log -1 --format=%b "$sha" | awk 'NF { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }')
    [[ -n $title ]] || title=$(github_title "$number") || title=""
    if [[ -z $title ]]; then
      title=$branch
      print -u2 -r -- "changelog: #$number's merge commit has no title and GitHub gave none, so it's listed by its branch, $branch. Edit that line."
    fi
    entries+=("- $title ([#$number]($repo_url/pull/$number))")
  elif [[ $subject =~ '^(.+) \(#([0-9]+)\)$' ]]; then
    # A squash merge's subject is the pull request's title and number.
    entries+=("- $match[1] ([#$match[2]]($repo_url/pull/$match[2]))")
  else
    entries+=("- $subject")
  fi
done

if [[ -n $since ]]; then
  link="[Every commit since $since]($repo_url/compare/$since...$tag)"
else
  link="[Every commit]($repo_url/commits/$tag)"
fi
section="## $version - $date"$'\n\n'"${(pj:\n:)entries}"$'\n\n'"$link"

# Releases are newest first, so the section goes above the first older release, or at the end.
updated=$(print -r -- "$current" | section=$section awk -v v="$version" '
  function older(heading,   a, b, i) {
    if (heading !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) return 0
    split(heading, a, "."); split(v, b, ".")
    for (i = 1; i <= 3; i++) if (a[i] + 0 != b[i] + 0) return a[i] + 0 < b[i] + 0
    return 0
  }
  !done && $1 == "##" && older($2) { print ENVIRON["section"]; print ""; done = 1 }
  { print }
  END { if (!done) { print ""; print ENVIRON["section"] } }')
print -r -- "$updated" > "$changelog"

print -r -- "$section"
print
if [[ $end == HEAD ]]; then
  print -r -- "Wrote $version to CHANGELOG.md: ${#entries} changes since ${since:-the first commit}. Edit it, and merge it into main before make tag VERSION=$version."
else
  print -r -- "Wrote $version to CHANGELOG.md: ${#entries} changes since ${since:-the first commit}, up to $tag."
fi
