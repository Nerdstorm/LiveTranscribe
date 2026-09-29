#!/usr/bin/env bash
# Puts the sherpa-onnx libraries the app links in FOLDER (by default target/sherpa-onnx/lib, where
# .cargo/config.toml points the sherpa-onnx crate's build script): k2-fsa's prebuilt shared
# libraries without text to speech, for this system, unmodified and checked against their SHA-256.
# sherpa-onnx's default libraries link espeak-ng, which is GPL-3.0; these don't.
#
# Only what speech to text needs is kept: sherpa-onnx's C API and ONNX Runtime (on Windows, their
# DLLs, the import libraries the linker reads, and ONNX Runtime's loader for execution providers).
# On Linux x64, on Windows x64 in Git Bash, and on Apple silicon Macs for development.
#
# Their licences, which the packages carry, go in FOLDER/../licenses: sherpa-onnx's (Apache-2.0),
# and ONNX Runtime's (MIT) with its third-party notices, at the versions these libraries are.
#   packaging/fetch-sherpa-onnx.sh [FOLDER]
# The archive and the licences are kept in target/downloads (or $SHERPA_ONNX_DOWNLOADS) for the
# next run.

set -euo pipefail

# The sherpa-onnx crate's version in Cargo.toml: the crate's C structs must be these libraries'.
VERSION=1.13.8
# The ONNX Runtime these libraries were built with (sherpa-onnx's cmake/onnxruntime-*.cmake).
ONNXRUNTIME=1.28.2

# Each licence: its name in the licences folder, where it's published, and its SHA-256.
LICENCES=(
    "sherpa-onnx-LICENSE https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v$VERSION/LICENSE cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
    "onnxruntime-LICENSE https://raw.githubusercontent.com/microsoft/onnxruntime/v$ONNXRUNTIME/LICENSE 2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c"
    "onnxruntime-ThirdPartyNotices.txt https://raw.githubusercontent.com/microsoft/onnxruntime/v$ONNXRUNTIME/ThirdPartyNotices.txt 0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2"
)

fail() {
    echo "fetch-sherpa-onnx: $*" >&2
    exit 1
}

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        PLATFORM=linux-x64-shared-no-tts-lib
        SHA256=bf2d998c8b07012cd5098f3b92673bc1333fd9b927767d7cb664be8190d8bc0b
        LIBRARIES=(libsherpa-onnx-c-api.so libonnxruntime.so)
        ;;
    MINGW64*-x86_64 | MSYS*-x86_64)
        # With the C runtime linked in (MT), as the crate itself links on Windows.
        PLATFORM=win-x64-shared-MT-Release-no-tts-lib
        SHA256=a1253e665c4f236119c443c8932a8acfca32a546c78c05962d483c9a0eae21b7
        LIBRARIES=(sherpa-onnx-c-api.dll sherpa-onnx-c-api.lib onnxruntime.dll onnxruntime.lib
            onnxruntime_providers_shared.dll)
        ;;
    Darwin-arm64)
        PLATFORM=osx-arm64-shared-no-tts-lib
        SHA256=f3e0cbd86cc3f38dad30c97921b40e9a8bcc6f2c943777eb76ad77176993e417
        LIBRARIES=(libsherpa-onnx-c-api.dylib libonnxruntime.dylib)
        ;;
    *) fail "there are no speech-only sherpa-onnx libraries for $(uname -s) on $(uname -m)" ;;
esac
ARCHIVE=sherpa-onnx-v$VERSION-$PLATFORM.tar.bz2
URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/v$VERSION/$ARCHIVE

# Whether FILE has the SHA-256 given, or the archive's: sha256sum on Linux and in Git Bash, shasum
# on macOS.
has_checksum() {
    local sum
    if command -v sha256sum >/dev/null; then
        sum=$(sha256sum "$1")
    else
        sum=$(shasum -a 256 "$1")
    fi
    [ "${sum%% *}" = "${2:-$SHA256}" ]
}

# Downloads URL into FILE, unless it's there with SHA256 already, and checks it.
fetch() {
    local file=$1 url=$2 sha256=$3
    if [ ! -f "$file" ] || ! has_checksum "$file" "$sha256"; then
        echo "Downloading $url" >&2
        curl --fail --location --retry 3 --silent --show-error --output "$file.part" "$url"
        has_checksum "$file.part" "$sha256" || fail "$url doesn't have the SHA-256 it should; it was left in $file.part"
        mv "$file.part" "$file"
    fi
}

here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$here/target/sherpa-onnx/lib}
downloads=${SHERPA_ONNX_DOWNLOADS:-$here/target/downloads}
archive=$downloads/$ARCHIVE

mkdir -p "$downloads"
fetch "$archive" "$URL" "$SHA256"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xjf "$archive" -C "$work"

rm -rf "$out"
mkdir -p "$out"
for library in "${LIBRARIES[@]}"; do
    [ -f "$work/sherpa-onnx-v$VERSION-$PLATFORM/lib/$library" ] || fail "$ARCHIVE has no lib/$library"
    cp "$work/sherpa-onnx-v$VERSION-$PLATFORM/lib/$library" "$out/"
done

licences=$(dirname "$out")/licenses
rm -rf "$licences"
mkdir -p "$licences"
for licence in "${LICENCES[@]}"; do
    read -r name url sha256 <<<"$licence"
    fetch "$downloads/$name-$VERSION" "$url" "$sha256"
    cp "$downloads/$name-$VERSION" "$licences/$name"
done

echo "sherpa-onnx $VERSION's speech-only libraries are in $out ($(du -sh "$out" | cut -f1)), their licences in $licences" >&2
