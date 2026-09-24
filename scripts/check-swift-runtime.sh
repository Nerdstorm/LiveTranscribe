#!/bin/zsh
# Checks that an app doesn't need anything from the Swift runtime that an earlier macOS lacks. The
# compiler links a runtime symbol weakly when the app's oldest macOS might not have it, but not
# always: Swift 6.4 links swift_initBorrow, which only macOS 27 has, strongly into code that uses
# Ref. With swift-collections 1.7.0 in it, the app didn't launch on any earlier macOS
# (https://github.com/apple/swift-collections/issues/733).
#
#   scripts/check-swift-runtime.sh <app or program>   checks every program and library in it
#   scripts/check-swift-runtime.sh --sdk              says which SDK a check would compare with
#
# It compares with the oldest macOS SDK on this Mac that is older than the one the app was built
# with, and not older than the app's minimum macOS: an SDK's .tbd files list what its Swift runtime
# has. Command Line Tools keeps the previous macOS's SDK next to the current one. release.sh runs
# it on every build, and before the build checks that there's an SDK to compare with.
#
# Settings, from the environment:
#   LT_BASELINE_SDK   the SDK to compare with, instead of the oldest one found
#
# Exits 1 when the app needs something that SDK's runtime lacks, and 3 when there's no SDK to
# compare with.
set -euo pipefail
autoload -Uz is-at-least

usage() {
  print -u2 -r -- "usage: scripts/check-swift-runtime.sh <app or program> | --sdk"
  exit 2
}

fail() { print -u2 -r -- "check-swift-runtime: $*"; exit 1 }

sdk_version() { plutil -extract Version raw -o - "$1/SDKSettings.plist" 2>/dev/null }

# baseline_sdk <minimum macOS> <built with>: sets $baseline and $baseline_version to the SDK to
# compare with, or exits 3.
baseline_sdk() {
  local minimum=$1 built_with=$2 sdk version
  baseline="" baseline_version=""
  if [[ -n ${LT_BASELINE_SDK:-} ]]; then
    baseline=${LT_BASELINE_SDK:A}
    baseline_version="$(sdk_version "$baseline")" || fail "LT_BASELINE_SDK, $baseline, isn't a macOS SDK"
  else
    # The SDKs themselves: MacOSX.sdk and MacOSX26.sdk are links to them, which (N/) leaves out.
    for sdk in "$(xcrun --sdk macosx --show-sdk-platform-path)"/Developer/SDKs/MacOSX*.sdk(N/) \
      /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk(N/); do
      version="$(sdk_version "$sdk")" || continue
      is-at-least "$minimum" "$version" || continue
      if [[ -z $baseline_version ]] || ! is-at-least "$baseline_version" "$version"; then
        baseline=$sdk baseline_version=$version
      fi
    done
  fi
  if [[ -z $baseline_version ]] || is-at-least "$built_with" "$baseline_version"; then
    print -u2 -r -- "check-swift-runtime: there's no macOS SDK older than $built_with on this Mac to compare with." \
      "Command Line Tools keeps the previous macOS's SDK (xcode-select --install), or set LT_BASELINE_SDK to one."
    exit 3
  fi
}

# exports <install name>: every symbol the library has in the SDK to compare with, with those of the
# libraries it re-exports, where dyld looks too. Fails when the SDK doesn't have the library.
exports() {
  local -a queue=("$1") seen=()
  local name tbd
  while (( ${#queue} )); do
    name=${queue[1]}
    shift queue
    (( ${seen[(Ie)$name]} )) && continue
    seen+=("$name")
    tbd="$baseline${name%.dylib}.tbd"
    if [[ ! -f $tbd ]]; then
      [[ $name == "$1" ]] && return 1
      continue
    fi
    nm -gj "$tbd"
    queue+=(${(f)"$(awk '/^reexported-libraries:/ { inside = 1; next } /^[^ ]/ { inside = 0 } inside' "$tbd" \
      | { grep -oE "/(usr|System)/[^]'\", ]+" || true } | sort -u)"})
  done
}

(( $# == 1 )) || usage
if [[ $1 == --sdk ]]; then
  baseline_sdk 0 "$(xcrun --sdk macosx --show-sdk-version)"
  print -r -- "macOS $baseline_version, $baseline"
  exit 0
fi
[[ -e $1 ]] || usage
target=${1:A}

# The programs and libraries to check, and the one whose build says which macOS it's for.
if [[ -d $target ]]; then
  main="$target/Contents/MacOS/$(plutil -extract CFBundleExecutable raw -o - "$target/Contents/Info.plist")"
  binaries=()
  for file in "$target"/**/*(N*); do
    lipo -archs "$file" >/dev/null 2>&1 && binaries+=("$file")
  done
else
  main=$target
  binaries=("$target")
fi
build="$(vtool -show-build "$main" 2>/dev/null)" || fail "can't read which macOS ${main:t} was built for"
minimum="$(print -r -- "$build" | awk '$1 == "minos" { print $2; exit }')"
built_with="$(print -r -- "$build" | awk '$1 == "sdk" { print $2; exit }')"
[[ -n $minimum && -n $built_with ]] || fail "can't read which macOS ${main:t} was built for"
baseline_sdk "$minimum" "$built_with"

problems=()
for binary in $binaries; do
  imports="$(nm -m -u "$binary" 2>/dev/null)" || continue
  weak_libraries=(${(f)"$(otool -l "$binary" | awk '$2 == "LC_LOAD_WEAK_DYLIB" { weak = 1 } weak && $1 == "name" { print $2; weak = 0 }')"})
  for library in ${(f)"$(otool -L "$binary" | awk 'NR > 1 && $1 ~ /^\/usr\/lib\/swift\// { print $1 }' | sort -u)"}; do
    # What it takes from the library without weak linking. dyld stops the launch if one is missing.
    needed="$(print -r -- "$imports" | awk -v from="(from ${${library:t}%.dylib})" '
      $1 == "(undefined)" && !/ weak external / && index($0, from) {
        for (i = 2; i < NF; i++) if ($i == "external") { print $(i + 1); break }
      }' | LC_ALL=C sort -u)"
    [[ -n $needed ]] || continue
    if has="$(exports "$library")"; then
      missing="$(LC_ALL=C comm -23 <(print -r -- "$needed") <(print -r -- "$has" | LC_ALL=C sort -u))"
    elif (( ${weak_libraries[(Ie)$library]} )); then
      continue
    else
      missing=$needed
    fi
    for symbol in ${(f)missing}; do
      problems+=("${${binary#$target/}:-${binary:t}}: $symbol (${library:t})")
    done
  done
done

if (( ${#problems} )); then
  print -u2 -r -- "check-swift-runtime: ${target:t} wouldn't launch on macOS $baseline_version or earlier. It needs" \
    "these from the Swift runtime, which macOS $baseline_version doesn't have, without linking them weakly:"
  print -u2 -rl -- "  "${^problems}
  print -u2 -r -- "To find the code that needs one, search the build's object files, for example" \
    "nm -A -u DerivedData/Build/Intermediates.noindex/**/*.o | grep <symbol>, and hold back or update its package."
  exit 1
fi
print -r -- "${target:t} needs nothing from the Swift runtime that macOS $baseline_version lacks (${#binaries} files checked)."
