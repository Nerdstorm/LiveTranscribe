#!/usr/bin/env bash
# Puts the OpenVINO runtime the Windows installer carries in FOLDER (by default
# target/openvino-runtime): the DLLs of Intel's OpenVINO 2026.2.1 wheel for Windows from PyPI,
# unmodified and checked against its SHA-256. The installer puts them in an openvino folder beside
# the app, which loads them from there (see crates/app/src/paths.rs).
#
# The wheel is Apache-2.0, and on Windows it has every DLL the app needs, the NPU's compiler too;
# they're the DLLs of Intel's archive for Windows, signed apart, which is under Intel's EULA. (On
# Linux only the archive has the NPU's compiler: packaging/linux/fetch-openvino.sh.) Any of the
# wheel's Python versions has the same DLLs.
#
# Only what the app uses is kept, as on Linux: the C API, the core library and its IR reader, the
# CPU and NPU plugins with the NPU's compiler, and TBB with tbbbind, which finds the CPU's core
# types. The DLLs need Microsoft's C++ runtime, which the installer carries beside the app (Tauri's
# bundleVCRuntime, in tauri.installer.conf.json). The wheel's licence (Apache-2.0) and its
# third-party notices go in FOLDER/licenses.
#   packaging/windows/fetch-openvino.sh [FOLDER]
# In Git Bash on Windows, or on Linux and macOS to see what it keeps. The wheel is kept in
# target/downloads (or $OPENVINO_DOWNLOADS) for the next run.

set -euo pipefail

VERSION=2026.2.1
WHEEL=openvino-$VERSION-21919-cp312-cp312-win_amd64.whl
SHA256=6928a707c447dbd43dab62c8bbc24a7953fd1b5e1fbea0f89a4135ca1ee4083b
URL=https://files.pythonhosted.org/packages/93/81/f4605ab2bdbb3daff7cadf7d5265e87c4fe95d01af00ae8e1638b9a4abe9/$WHEEL

# The DLLs kept, in the wheel's openvino/libs.
LIBRARIES=(
    openvino.dll
    openvino_c.dll
    openvino_ir_frontend.dll
    openvino_intel_cpu_plugin.dll
    openvino_intel_npu_plugin.dll
    openvino_intel_npu_compiler.dll
    openvino_intel_npu_compiler_loader.dll
    tbb12.dll
    tbbmalloc.dll
    tbbbind_2_5.dll
)
# The licence and the notices, in the wheel's dist-info/licenses.
NOTICES=(
    LICENSE
    licensing/runtime-third-party-programs.txt
    licensing/onetbb_third-party-programs.txt
    licensing/onednn_third-party-programs.txt
)

fail() {
    echo "fetch-openvino: $*" >&2
    exit 1
}

# Whether FILE has the wheel's SHA-256: sha256sum in Git Bash and on Linux, shasum on macOS.
has_checksum() {
    local sum
    if command -v sha256sum >/dev/null; then
        sum=$(sha256sum "$1")
    else
        sum=$(shasum -a 256 "$1")
    fi
    [ "${sum%% *}" = "$SHA256" ]
}

here=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$here/target/openvino-runtime}
downloads=${OPENVINO_DOWNLOADS:-$here/target/downloads}
wheel=$downloads/$WHEEL

mkdir -p "$downloads"
if [ ! -f "$wheel" ] || ! has_checksum "$wheel"; then
    echo "Downloading $WHEEL" >&2
    curl --fail --location --retry 3 --silent --show-error --output "$wheel.part" "$URL"
    has_checksum "$wheel.part" || fail "$WHEEL doesn't have the SHA-256 it should; it was left in $wheel.part"
    mv "$wheel.part" "$wheel"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
licenses=openvino-$VERSION.dist-info/licenses
members=()
for library in "${LIBRARIES[@]}"; do
    members+=("openvino/libs/$library")
done
for notice in "${NOTICES[@]}"; do
    members+=("$licenses/$notice")
done
unzip -q "$wheel" "${members[@]}" -d "$work" || fail "$WHEEL lacks a file it should have"

rm -rf "$out"
mkdir -p "$out/licenses"
for library in "${LIBRARIES[@]}"; do
    [ -f "$work/openvino/libs/$library" ] || fail "$WHEEL has no $library"
    cp "$work/openvino/libs/$library" "$out/"
done
for notice in "${NOTICES[@]}"; do
    cp "$work/$licenses/$notice" "$out/licenses/" || fail "$WHEEL has no $notice"
done

echo "OpenVINO $VERSION's runtime for Windows is in $out ($(du -sh "$out" | cut -f1))" >&2
