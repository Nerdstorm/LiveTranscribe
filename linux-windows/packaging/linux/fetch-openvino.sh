#!/usr/bin/env bash
# Puts the OpenVINO runtime the Linux packages carry in FOLDER (by default target/openvino-runtime):
# Intel's prebuilt OpenVINO 2026.2.1 for Ubuntu 22.04, whose glibc (2.35) the packages are built
# against, unmodified and checked against its SHA-256. The deb and rpm install it in
# /usr/lib/live-transcribe/openvino, and the AppImage carries it in usr/share/live-transcribe/openvino
# (see crates/app/src/paths.rs); the app loads it from there.
#
# Only what the app uses is kept: the C API, the core library and its IR reader, the CPU and NPU
# plugins with the NPU's compiler, and TBB with what finds the CPU's core types (tbbbind, hwloc).
# Each library is one file, named as the dynamic linker, OpenVINO and TBB look for it (its soname,
# where it has one; Intel's archive links that name to the file): Tauri's bundler would copy each of
# the archive's symlinks as another whole file. Intel's licence for the runtime (EULA.txt), its list
# of what may be redistributed (redist.txt) and the third-party notices go in FOLDER/licenses.
#   packaging/linux/fetch-openvino.sh [FOLDER]
# The archive is kept in target/downloads (or $OPENVINO_DOWNLOADS) for the next run.

set -euo pipefail

VERSION=2026.2.1
# The libraries' soname version.
SO=2621
ARCHIVE=openvino_toolkit_ubuntu22_2026.2.1.21919.ede283a88e3_x86_64.tgz
SHA256=48f36fd469c62b0482bd5c86ad760dfad14f8748921c789ad4b047a8437d6951
URL=https://storage.openvinotoolkit.org/repositories/openvino/packages/$VERSION/linux/$ARCHIVE

# The libraries kept, by their paths in the archive.
LIBRARIES=(
    runtime/lib/intel64/libopenvino.so.$SO
    runtime/lib/intel64/libopenvino_c.so.$SO
    runtime/lib/intel64/libopenvino_ir_frontend.so.$SO
    runtime/lib/intel64/libopenvino_intel_cpu_plugin.so
    runtime/lib/intel64/libopenvino_intel_npu_plugin.so
    runtime/lib/intel64/libopenvino_intel_npu_compiler.so
    runtime/lib/intel64/libopenvino_intel_npu_compiler_loader.so
    runtime/3rdparty/tbb/lib/libtbb.so.12
    runtime/3rdparty/tbb/lib/libtbbmalloc.so.2
    runtime/3rdparty/tbb/lib/libtbbbind_2_5.so.3
    runtime/3rdparty/tbb/lib/libhwloc.so.15
)
NOTICES=(EULA.txt redist.txt readme.txt Apache_license.txt runtime-third-party-programs.txt onetbb_third-party-programs.txt)

fail() {
    echo "fetch-openvino: $*" >&2
    exit 1
}

here=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$here/target/openvino-runtime}
downloads=${OPENVINO_DOWNLOADS:-$here/target/downloads}
archive=$downloads/$ARCHIVE

mkdir -p "$downloads"
if ! echo "$SHA256  $archive" | sha256sum --check --status 2>/dev/null; then
    echo "Downloading $ARCHIVE" >&2
    curl --fail --location --retry 3 --silent --show-error --output "$archive.part" "$URL"
    echo "$SHA256  $archive.part" | sha256sum --check --status ||
        fail "$ARCHIVE doesn't have the SHA-256 it should; it was left in $archive.part"
    mv "$archive.part" "$archive"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$archive" -C "$work" --strip-components=1

rm -rf "$out"
mkdir -p "$out/licenses"
for library in "${LIBRARIES[@]}"; do
    [ -e "$work/$library" ] || fail "$ARCHIVE has no $library"
    # The file the name links to, under that name.
    cp --dereference "$work/$library" "$out/"
done
for notice in "${NOTICES[@]}"; do
    cp "$work/docs/licensing/$notice" "$out/licenses/" || fail "$ARCHIVE has no $notice"
done

echo "OpenVINO $VERSION's runtime is in $out ($(du -sh "$out" | cut -f1))" >&2
