#!/bin/zsh
# Tests scripts/check-swift-runtime.sh with small C programs that take symbols from the Swift
# runtime, compared with made-up SDKs of an earlier macOS. make test runs it.
set -euo pipefail
autoload -Uz is-at-least

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
check_runtime="${0:A:h:h}/check-swift-runtime.sh"
sdk=$(xcrun --sdk macosx --show-sdk-path)

# program <path> <C source>: builds a program for macOS 14 that links the Swift runtime of Xcode's SDK.
program() {
  mkdir -p "${1:h}"
  print -r -- "$2" | xcrun clang -x c - -o "$1" -mmacosx-version-min=14.0 -L"$sdk/usr/lib/swift" -lswiftCore
}

# library <sdk> <name> <symbols> [re-exported library]: adds a library's .tbd file to a made-up SDK.
library() {
  mkdir -p "$1/usr/lib/swift"
  plutil -create xml1 "$1/SDKSettings.plist"
  plutil -insert Version -string 14.0 "$1/SDKSettings.plist"
  {
    print -r -- "--- !tapi-tbd"
    print -r -- "tbd-version:     4"
    print -r -- "targets:         [ arm64-macos, arm64e-macos ]"
    print -r -- "install-name:    '/usr/lib/swift/$2.dylib'"
    if [[ -n ${4:-} ]]; then
      print -r -- "reexported-libraries:"
      print -r -- "  - targets:         [ arm64-macos, arm64e-macos ]"
      print -r -- "    libraries:       [ '/usr/lib/swift/$4.dylib' ]"
    fi
    print -r -- "exports:"
    print -r -- "  - targets:         [ arm64-macos, arm64e-macos ]"
    print -r -- "    symbols:         [ $3 ]"
    print -r -- "..."
  } > "$1/usr/lib/swift/$2.tbd"
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
# with <sdk> <app or program>: checks it against the SDK, into $out and $code.
with() { out=$(LT_BASELINE_SDK=$1 "$check_runtime" "$2" 2>&1) && code=0 || code=$? }

# swift_retain is in every macOS's Swift runtime, and swift_initBorrow only from macOS 27's.
program "$work/old" 'void *swift_retain(void *); int main(void) { return swift_retain(0) != 0; }'
program "$work/new" 'void swift_initBorrow(void); int main(void) { swift_initBorrow(); return 0; }'
program "$work/weak" 'void swift_initBorrow(void) __attribute__((weak_import));
int main(void) { if (swift_initBorrow) swift_initBorrow(); return 0; }'

earlier="$work/Earlier.sdk"
library "$earlier" libswiftCore _swift_retain
moved="$work/Moved.sdk"
library "$moved" libswiftCore _swift_retain libswift_Moved
library "$moved" libswift_Moved _swift_initBorrow

with "$earlier" "$work/old"
check 'passes a program that takes only what the earlier runtime has' 0 "$code"
with "$earlier" "$work/new"
check 'stops a program that needs a symbol the earlier runtime lacks' '1 1' \
  "$code $(print -r -- "$out" | grep -c 'new: _swift_initBorrow (libswiftCore.dylib)')"
with "$earlier" "$work/weak"
check 'passes a program that links that symbol weakly' 0 "$code"
with "$moved" "$work/new"
check 'finds a symbol in a library that the runtime re-exports' 0 "$code"

app="$work/Example.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
plutil -create xml1 "$app/Contents/Info.plist"
plutil -insert CFBundleExecutable -string Example "$app/Contents/Info.plist"
cp "$work/old" "$app/Contents/MacOS/Example"
cp "$work/new" "$app/Contents/Helpers/helper"
with "$earlier" "$app"
check "looks through an app, at its helpers too" '1 1' \
  "$code $(print -r -- "$out" | grep -c 'Contents/Helpers/helper: _swift_initBorrow (libswiftCore.dylib)')"

with "$sdk" "$work/old"
check "won't compare with the SDK the program was built with" 3 "$code"
with "$earlier" "$work/missing"
check 'wants an app or a program' 2 "$code"

# Which SDK a release is checked against depends on this Mac, so this one only runs with one.
if found=$("$check_runtime" --sdk 2>/dev/null); then
  version=${${found#macOS }%%,*}
  check 'finds an SDK older than the one Xcode builds with' older \
    "$(is-at-least "$(xcrun --sdk macosx --show-sdk-version)" "$version" && print same-or-newer || print older)"
else
  print -r -- "skip  finds an SDK older than the one Xcode builds with: this Mac has none"
fi

(( failures == 0 )) || { print -r -- "$failures of the Swift runtime check's tests failed"; exit 1 }
