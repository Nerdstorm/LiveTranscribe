#!/usr/bin/env bash
# Checks that the deb, rpm and AppImage in PACKAGES carry the OpenVINO runtime as
# fetch-openvino.sh left it in RUNTIME (by default target/openvino-runtime): every library, byte
# for byte, as Intel's licence requires, and nothing else. It guards against a bundler that changes
# them, as linuxdeploy did (it set their RUNPATH) and as the deb and rpm did (they stored each
# symlink as another copy).
#   packaging/linux/check-packages.sh PACKAGES [RUNTIME]

set -euo pipefail

fail() {
    echo "check-packages: $*" >&2
    exit 1
}

[ $# -ge 1 ] || fail "usage: check-packages.sh PACKAGES [RUNTIME]"
here=$(cd "$(dirname "$0")/../.." && pwd)
packages=$(cd "$1" && pwd)
runtime=$(cd "${2:-$here/target/openvino-runtime}" && pwd)

# The one file in PACKAGES with this extension.
package() {
    local found=("$packages"/*."$1")
    [ ${#found[@]} = 1 ] && [ -f "${found[0]}" ] || fail "$packages should have one .$1"
    echo "${found[0]}"
}

# Compares the runtime in FOLDER, as LABEL has it, with RUNTIME's.
compare() {
    local label=$1 folder=$2 bad=0 library
    [ -d "$folder" ] || { echo "$label: has no $folder" >&2; return 1; }
    for library in "$runtime"/*.so*; do
        if ! cmp -s "$library" "$folder/$(basename "$library")"; then
            echo "$label: $(basename "$library") isn't Intel's file, or is missing" >&2
            bad=1
        fi
    done
    for library in "$folder"/*.so*; do
        if [ ! -e "$runtime/$(basename "$library")" ]; then
            echo "$label: $(basename "$library") isn't one of the runtime's" >&2
            bad=1
        fi
    done
    [ $bad = 0 ] && echo "$label: its $(find "$runtime" -maxdepth 1 -name '*.so*' | wc -l) libraries are Intel's, unmodified"
    return $bad
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0

dpkg-deb --extract "$(package deb)" "$work/deb"
compare deb "$work/deb/usr/lib/live-transcribe/openvino" || status=1

# bsdtar reads an rpm's payload itself. (Ubuntu 22.04's rpm2cpio, from rpm 4.17, copies all of it
# but then fails: the rpm crate's packages have no ARCHIVESIZE to compare with. Fedora's doesn't.)
mkdir "$work/rpm"
bsdtar --extract --file "$(package rpm)" --directory "$work/rpm"
compare rpm "$work/rpm/usr/lib/live-transcribe/openvino" || status=1

appimage=$(package AppImage)
(cd "$work" && "$appimage" --appimage-extract >/dev/null)
compare AppImage "$work/squashfs-root/usr/share/live-transcribe/openvino" || status=1

exit $status
