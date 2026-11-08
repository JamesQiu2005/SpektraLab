#!/bin/bash
# Shared by the desktop engine and Catalyst resource builder. The archive is
# optional on headless builders; stale output must never survive a failed bake.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
metallib=$1
out=$2
build=$3
mkdir -p "$build"
cxx=$(xcrun --sdk macosx --find clang++)
"$cxx" -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -std=c++20 -O2 -I"$here/../third_party/metal-cpp" \
    "$here/bake_metal_archive.cpp" -framework Metal -framework Foundation -o "$build/bake_metal_archive"
rm -f "$out" "$out.tmp"
if "$build/bake_metal_archive" "$metallib" "$out.tmp"; then
    mv "$out.tmp" "$out"
else
    rm -f "$out.tmp"
    echo "No native Metal archive built; bundled IR will compile on the device." >&2
fi
