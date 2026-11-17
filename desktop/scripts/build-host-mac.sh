#!/usr/bin/env bash
# build-host-mac.sh -- the one MoltenVK spektralab-host the phase-2 gate builds, staged for T5a/T5b and
# the scheduler gate (SPK_HOST_BIN), and reused by the RAW gate.
#
#   desktop/scripts/build-host-mac.sh        -> build/host-mac/spektralab-host (+ engine/, licenses/)
#
# It configures build/raw-gate-mac exactly as engine/tests/raw_gate.sh does (same pin, codec prefixes,
# Vulkan headers and options, BUILD_TESTING on), builds only the host target, and stages it with
# engine/stage-host.sh. When raw_gate.sh runs afterwards it reconfigures the same directory with the
# same arguments (a no-op) and builds the rest incrementally -- one host build serves both, and the RAW
# gate still builds, tests and checks everything it did before. The tree's engine.cpp carries the
# Vulkan-on-Apple guard (merged with W3), so no scratch copy is needed (cf. spk-scheduler's
# tools/build-host-mac.sh, which still works on either state).
#
# Needs Homebrew's cmake, ninja, glslang, meson, nasm, molten-vk and vulkan-loader. The first run builds
# the native codecs into build/deps/*/install-mac (several minutes); later runs reuse them.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
engine="$repo/engine"
deps="${SPEKTRALAB_DEPS_DIR:-$repo/build/deps}"
mac="${SPEKTRALAB_RAW_GATE_BUILD:-$repo/build/raw-gate-mac}"
stage="$repo/build/host-mac"
[[ "$(uname -s)" == Darwin ]] || { echo "build-host-mac.sh runs on macOS" >&2; exit 1; }
"$engine/setup-deps.sh" "$deps" >/dev/null
libraw="$("$engine/setup-libraw.sh" "$deps" 2>/dev/null | tail -n 1)"
if [[ ! -f "$deps/input-codecs/install-mac/include/lcms2.h" ]]; then
  python3 "$engine/setup-input-codecs.py" --sources "$deps/input-codecs" --build "$mac/codecs/input" \
    --install "$deps/input-codecs/install-mac" --generator Ninja
fi
if [[ ! -f "$deps/lens-codecs/install-mac/include/lensfun/lensfun.h" ]]; then
  python3 "$engine/setup-lens-codecs.py" --sources "$deps/lens-codecs" --build "$mac/codecs/lens" \
    --install "$deps/lens-codecs/install-mac" --generator Ninja
fi
cmake -S "$repo" -B "$mac" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DSPEKTRALAB_VULKAN_ON_APPLE=ON -DSPEKTRALAB_REQUIRE_VULKAN=ON \
  -DSPEKTRALAB_VULKAN_HEADERS="$deps/Vulkan-Headers/include" \
  -DSPEKTRALAB_BUILD_NATIVE_RAW=ON -DSPEKTRALAB_BUILD_HOST=ON -DSPEKTRALAB_LIBRAW_OPENMP=OFF \
  -DSPEKTRALAB_LIBRAW_SOURCE="$libraw" \
  -DSPEKTRALAB_INPUT_CODEC_PREFIX="$deps/input-codecs/install-mac" \
  -DSPEKTRALAB_LENS_PREFIX="$deps/lens-codecs/install-mac" -DBUILD_TESTING=ON >/dev/null
ninja -C "$mac" spektralab-host spektralab_vulkan_resources
SPEKTRALAB_DEPS_DIR="$deps" "$engine/stage-host.sh" "$mac" "$stage" spektralab-host
echo "staged $stage" >&2
