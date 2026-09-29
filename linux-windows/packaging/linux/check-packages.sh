#!/usr/bin/env bash
# Checks that the deb, rpm and AppImage in PACKAGES carry the OpenVINO runtime as
# fetch-openvino.sh left it in RUNTIME (by default target/openvino-runtime): every library, byte
# for byte, as Intel's licence requires, and nothing else. It guards against a bundler that changes
# them, as linuxdeploy did (it set their RUNPATH) and as the deb and rpm did (they stored each
# symlink as another copy).
#
# And that each carries the sherpa-onnx libraries fetch-sherpa-onnx.sh left in SHERPA_ONNX (by
# default target/sherpa-onnx), with their licences, and that the app finds them: it starts each
# package's app, as installed, to list the speech models, with nothing pointing it at the libraries.
# (linuxdeploy copies them into the AppImage's usr/lib, and may change them there: they're Apache-2.0
# and MIT, which allow that.)
#   packaging/linux/check-packages.sh PACKAGES [RUNTIME [SHERPA_ONNX]]

set -euo pipefail

fail() {
    echo "check-packages: $*" >&2
    exit 1
}

[ $# -ge 1 ] || fail "usage: check-packages.sh PACKAGES [RUNTIME [SHERPA_ONNX]]"
here=$(cd "$(dirname "$0")/../.." && pwd)
packages=$(cd "$1" && pwd)
runtime=$(cd "${2:-$here/target/openvino-runtime}" && pwd)
sherpa_onnx=$(cd "${3:-$here/target/sherpa-onnx}" && pwd)

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

# Checks that LABEL's FOLDER has the files fetch-sherpa-onnx.sh left in FETCHED, byte for byte,
# and nothing else.
fetched() {
    local label=$1 fetched=$2 folder=$3 bad=0 file
    [ -d "$folder" ] || { echo "$label: has no $folder" >&2; return 1; }
    for file in "$fetched"/*; do
        if ! cmp -s "$file" "$folder/$(basename "$file")"; then
            echo "$label: its $(basename "$file") isn't the one fetched, or is missing" >&2
            bad=1
        fi
    done
    for file in "$folder"/*; do
        if [ ! -e "$fetched/$(basename "$file")" ]; then
            echo "$label: $(basename "$file") isn't one of those fetched" >&2
            bad=1
        fi
    done
    [ $bad = 0 ] && echo "$label: its $(basename "$fetched") are those fetched"
    return $bad
}

# Checks that LABEL's app, BINARY in the package unpacked in ROOT, finds the sherpa-onnx libraries
# in the package, and starts: `livetranscribe models` lists the catalog's models, the default one
# among them.
starts() {
    local label=$1 root=$2 binary=$3 bad=0 library line listed
    for library in "$sherpa_onnx"/lib/*.so; do
        line=$(env -u LD_LIBRARY_PATH ldd "$binary" | awk -v name="$(basename "$library")" '$1 == name')
        [ -n "$line" ] || line="ldd doesn't list it"
        case $(awk '{ print $3 }' <<<"$line") in
            "$root"/*) ;;
            *)
                echo "$label: the app doesn't find $(basename "$library") in the package: $line" >&2
                bad=1
                ;;
        esac
    done
    [ $bad = 0 ] || return 1
    if ! listed=$(env -u LD_LIBRARY_PATH -u XDG_DATA_HOME -u XDG_CACHE_HOME HOME="$work/home" \
        "$binary" models 2>"$work/models.log"); then
        echo "$label: \`livetranscribe models\` failed:" >&2
        cat "$work/models.log" >&2
        return 1
    fi
    if ! grep -q "(default" <<<"$listed"; then
        echo "$label: \`livetranscribe models\` didn't list the default model:" >&2
        echo "$listed" >&2
        return 1
    fi
    echo "$label: the app finds sherpa-onnx's libraries in the package, and lists $(grep -c . <<<"$listed") speech models"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0

dpkg-deb --extract "$(package deb)" "$work/deb"
compare deb "$work/deb/usr/lib/live-transcribe/openvino" || status=1
fetched deb "$sherpa_onnx/lib" "$work/deb/usr/lib/live-transcribe/sherpa-onnx" || status=1
fetched deb "$sherpa_onnx/licenses" "$work/deb/usr/share/doc/live-transcribe/sherpa-onnx" || status=1
starts deb "$work/deb" "$work/deb/usr/bin/livetranscribe" || status=1

# bsdtar reads an rpm's payload itself. (Ubuntu 22.04's rpm2cpio, from rpm 4.17, copies all of it
# but then fails: the rpm crate's packages have no ARCHIVESIZE to compare with. Fedora's doesn't.)
mkdir "$work/rpm"
bsdtar --extract --file "$(package rpm)" --directory "$work/rpm"
compare rpm "$work/rpm/usr/lib/live-transcribe/openvino" || status=1
fetched rpm "$sherpa_onnx/lib" "$work/rpm/usr/lib/live-transcribe/sherpa-onnx" || status=1
fetched rpm "$sherpa_onnx/licenses" "$work/rpm/usr/share/doc/live-transcribe/sherpa-onnx" || status=1
starts rpm "$work/rpm" "$work/rpm/usr/bin/livetranscribe" || status=1

appimage=$(package AppImage)
(cd "$work" && "$appimage" --appimage-extract >/dev/null)
compare AppImage "$work/squashfs-root/usr/share/live-transcribe/openvino" || status=1
fetched AppImage "$sherpa_onnx/licenses" "$work/squashfs-root/usr/share/doc/live-transcribe/sherpa-onnx" || status=1
starts AppImage "$work/squashfs-root" "$work/squashfs-root/usr/bin/livetranscribe" || status=1

exit $status
