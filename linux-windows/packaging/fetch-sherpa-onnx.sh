#!/usr/bin/env bash
# Puts the sherpa-onnx libraries the app links in FOLDER (by default target/sherpa-onnx/lib, where
# .cargo/config.toml points the sherpa-onnx crate's build script): k2-fsa's prebuilt shared
# libraries without text to speech, for this system, unmodified and checked against their SHA-256.
# sherpa-onnx's default libraries link espeak-ng, which is GPL-3.0; these don't.
#
# Only what speech to text needs is kept: sherpa-onnx's C API and ONNX Runtime (on Windows, their
# DLLs, the import libraries the linker reads, and ONNX Runtime's loader for execution providers).
# On Linux x64, on Windows x64 in Git Bash, and on Apple silicon Macs for development.
#   packaging/fetch-sherpa-onnx.sh [FOLDER]
# The archive is kept in target/downloads (or $SHERPA_ONNX_DOWNLOADS) for the next run.

set -euo pipefail

# The sherpa-onnx crate's version in Cargo.toml: the crate's C structs must be these libraries'.
VERSION=1.13.8

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

# Whether FILE has the archive's SHA-256: sha256sum on Linux and in Git Bash, shasum on macOS.
has_checksum() {
    local sum
    if command -v sha256sum >/dev/null; then
        sum=$(sha256sum "$1")
    else
        sum=$(shasum -a 256 "$1")
    fi
    [ "${sum%% *}" = "$SHA256" ]
}

here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$here/target/sherpa-onnx/lib}
downloads=${SHERPA_ONNX_DOWNLOADS:-$here/target/downloads}
archive=$downloads/$ARCHIVE

mkdir -p "$downloads"
if [ ! -f "$archive" ] || ! has_checksum "$archive"; then
    echo "Downloading $ARCHIVE" >&2
    curl --fail --location --retry 3 --silent --show-error --output "$archive.part" "$URL"
    has_checksum "$archive.part" || fail "$ARCHIVE doesn't have the SHA-256 it should; it was left in $archive.part"
    mv "$archive.part" "$archive"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xjf "$archive" -C "$work"

rm -rf "$out"
mkdir -p "$out"
for library in "${LIBRARIES[@]}"; do
    [ -f "$work/sherpa-onnx-v$VERSION-$PLATFORM/lib/$library" ] || fail "$ARCHIVE has no lib/$library"
    cp "$work/sherpa-onnx-v$VERSION-$PLATFORM/lib/$library" "$out/"
done

echo "sherpa-onnx $VERSION's speech-only libraries are in $out ($(du -sh "$out" | cut -f1))" >&2
