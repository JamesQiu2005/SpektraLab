#!/usr/bin/env bash
# build-host-mac.sh -- v1's spektralab-host, built natively on this Mac against MoltenVK, for T5.
#
#   desktop/crates/spk-scheduler/tools/build-host-mac.sh      -> build/host-mac/spektralab-host
#
# engine/LINUX_WINDOWS.md §7's test configuration (-DSPEKTRALAB_VULKAN_ON_APPLE=ON, native RAW, the host,
# LibRaw without OpenMP), with two things that section does not say:
#
# 1. engine/src/pipeline/engine.cpp chooses its GPU backend with a bare `#ifndef __APPLE__`, so the
#    Vulkan-on-Apple build links the Metal factory and fails ("Undefined symbols: Gpu::create_metal").
#    The build is made from a scratch copy (build/w1-host-src) with that guard widened to the form
#    pipeline.cpp already uses -- `#if !defined(__APPLE__) || defined(SPK_VULKAN_BACKEND)`. The branch's
#    sources are not changed: engine/src is not this workstream's to edit.
# 2. The Vulkan headers must be the pinned ones in build/deps, not /opt/homebrew/include: that directory
#    also holds Homebrew's jpeglib.h (libjpeg 8), which then shadows the bundled libjpeg-turbo (6.2) and
#    every JPEG export fails with "Wrong JPEG library version: library is 62, caller expects 80".
#
# Needs Homebrew's cmake, ninja, glslang, meson, nasm, molten-vk and vulkan-loader (run the host with
# DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib). The first run fetches and builds the pinned
# dependencies into build/deps (network; several minutes); later runs reuse them.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
deps=$repo/build/deps
src=$repo/build/w1-host-src
build=$repo/build/mac-host-w1b
stage=$repo/build/host-mac
if [[ ! -f "$deps/input-codecs/install-mac/include/lcms2.h" || ! -f "$deps/lens-codecs/install-mac/include/lensfun/lensfun.h" ]]; then
  "$repo/engine/setup-deps.sh" "$deps"
  python3 "$repo/engine/setup-input-codecs.py" --sources "$deps/input-codecs" --build "$build/input-codecs" \
    --install "$deps/input-codecs/install-mac" --generator Ninja
  python3 "$repo/engine/setup-lens-codecs.py" --sources "$deps/lens-codecs" --build "$build/lens-codecs" \
    --install "$deps/lens-codecs/install-mac" --generator Ninja
fi
mkdir -p "$src/modern_UI/Spektrafilm/Spektrafilm/Resources" "$src/license"
cp "$repo/CMakeLists.txt" "$src/CMakeLists.txt"
rsync -a --delete --exclude build "$repo/engine/" "$src/engine/"
rsync -a --delete "$repo/modern_UI/Spektrafilm/Spektrafilm/Resources/DI/" "$src/modern_UI/Spektrafilm/Spektrafilm/Resources/DI/"
rsync -a --delete "$repo/modern_UI/Spektrafilm/Spektrafilm/Resources/Licenses/" "$src/modern_UI/Spektrafilm/Spektrafilm/Resources/Licenses/"
rsync -a --delete "$repo/license/" "$src/license/"
sed -i '' 's/^#ifndef __APPLE__$/#if !defined(__APPLE__) || defined(SPK_VULKAN_BACKEND)/' "$src/engine/src/pipeline/engine.cpp"
cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DSPEKTRALAB_VULKAN_ON_APPLE=ON -DSPEKTRALAB_REQUIRE_VULKAN=ON -DSPEKTRALAB_VULKAN_HEADERS="$deps/Vulkan-Headers/include" \
  -DSPEKTRALAB_BUILD_NATIVE_RAW=ON -DSPEKTRALAB_BUILD_HOST=ON -DSPEKTRALAB_LIBRAW_OPENMP=OFF \
  -DSPEKTRALAB_DEPS_DIR="$deps" \
  -DSPEKTRALAB_INPUT_CODEC_PREFIX="$deps/input-codecs/install-mac" \
  -DSPEKTRALAB_LENS_PREFIX="$deps/lens-codecs/install-mac" \
  -DSPEKTRALAB_HOST_VERSION="0.1.0+mac-moltenvk"
ninja -C "$build" spektralab-host
SPEKTRALAB_DEPS_DIR="$deps" "$src/engine/stage-host.sh" "$build" "$stage" spektralab-host
echo "staged $stage" >&2
