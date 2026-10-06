#!/usr/bin/env bash
# build-linux.sh -- build spektralab-host for Linux x64 and stage it.
#
#   engine/build-linux.sh [--test] [--no-deps]
#
# 1. engine/setup-deps.sh: pinned LibRaw 0.22.2 + Vulkan-Headers into the
#    gitignored build/deps (verified; skipped with --no-deps).
# 2. CMake + Ninja in build/linux: the engine (Vulkan backend, kernels to
#    SPIR-V), LibRaw, spektralab-host, and the tests. libstdc++/libgcc are
#    linked statically so the binary needs only glibc and a Vulkan loader.
# 3. --test: CTest (on whatever Vulkan device is present -- lavapipe on CI)
#    and engine/tests/host_smoke.py against the staged host.
# 4. Stages build/host-linux-x64/ in the layout desktop/HOST-PROTOCOL.md §4
#    names: spektralab-host, engine/ (baked resources, vulkan/*.spv,
#    io/sRGB.icc) and licenses/.
#
# The macOS build (engine/build.sh, Xcode) does not read anything here.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
build="${SPEKTRALAB_BUILD_DIR:-$repo/build/linux}"
stage="$repo/build/host-linux-x64"
run_tests=0
fetch=1
for arg in "$@"; do
  case "$arg" in
    --test) run_tests=1 ;;
    --no-deps) fetch=0 ;;
    *) echo "usage: $0 [--test] [--no-deps]" >&2; exit 2 ;;
  esac
done

if [[ $fetch == 1 ]]; then "$here/setup-deps.sh" >/dev/null; fi

version="$(git -C "$repo" describe --always --dirty 2>/dev/null || echo unknown)"
cmake -S "$repo" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DSPEKTRALAB_BUILD_NATIVE_RAW=ON -DSPEKTRALAB_BUILD_HOST=ON \
  -DSPEKTRALAB_REQUIRE_VULKAN=ON -DSPEKTRALAB_STATIC_RUNTIME=ON \
  -DSPEKTRALAB_HOST_VERSION="0.1.0+$version"
ninja -C "$build"

"$here/stage-host.sh" "$build" "$stage" spektralab-host

if [[ $run_tests == 1 ]]; then
  (cd "$build" && ctest --output-on-failure)
  python3 "$here/tests/host_smoke.py" --host "$stage/spektralab-host" --resources "$stage/engine"
fi
echo "staged $stage" >&2
