#!/usr/bin/env bash
# Writes the notes for release VERSION to stdout: its section of CHANGELOG.md, then how to install
# it on each system (.github/release-notes.md, with @VERSION@ filled in). The release workflow
# drafts the release with them, and checks before building that the changelog has the section.
#   scripts/release-notes.sh 0.4.0

set -euo pipefail

fail() {
    echo "release-notes: $*" >&2
    exit 1
}

[ $# = 1 ] || fail "usage: scripts/release-notes.sh <x.y.z>"
version=$1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$version isn't a version x.y.z"
root=$(cd "$(dirname "$0")/.." && pwd)

# The section runs from its heading, "## x.y.z - date", to the next heading, without the blank
# lines around it.
changes=$(awk -v heading="## $version" '
    /^## / {
        if (inside) exit
        inside = ($0 == heading || index($0, heading " ") == 1)
        next
    }
    inside { lines[++count] = $0 }
    END {
        first = 1
        while (first <= count && lines[first] ~ /^[[:space:]]*$/) first++
        last = count
        while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
        for (i = first; i <= last; i++) print lines[i]
    }' "$root/CHANGELOG.md")
[ -n "$changes" ] ||
    fail "CHANGELOG.md has no section for $version: make changelog VERSION=$version writes one (docs/releasing.md)"

printf '%s\n\n' "$changes"
sed "s/@VERSION@/$version/g" "$root/.github/release-notes.md"
