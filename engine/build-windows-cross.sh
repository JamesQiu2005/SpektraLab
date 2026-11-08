#!/usr/bin/env bash
# build-windows-cross.sh -- spektralab-host.exe for Windows x64, from Linux.
#
#   engine/build-windows-cross.sh [--test] [--no-deps]
#
# MinGW-w64 (posix threads) through cmake/toolchain-mingw-w64.cmake; Vulkan
# through volk, so no SDK import library -- the exe opens vulkan-1.dll at run
# time; LibRaw 0.22.2 cross-built from the same pinned tree as Linux;
# libstdc++, libgcc and winpthread linked statically, so the exe depends only
# on system DLLs. Stages build/host-win-x64/ (HOST-PROTOCOL.md §4).
#
# --test runs the staged host's smoke test under wine (engine/tests/
# host_smoke.py --wrapper wine), inside xvfb-run when there is no display:
# winevulkan only loads through wine's X11 driver, and then forwards to the
# Linux Vulkan loader (lavapipe). Verified 2026-10-06, wine 9.0.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
build="${SPEKTRALAB_BUILD_DIR:-$repo/build/win-cross}"
stage="$repo/build/host-win-x64"
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
glslang="$(command -v glslangValidator || true)"
cmake -S "$repo" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$here/cmake/toolchain-mingw-w64.cmake" \
  -DSPEKTRALAB_GLSLANG="$glslang" \
  -DSPEKTRALAB_VULKAN_HEADERS="$repo/build/deps/Vulkan-Headers/include" \
  -DSPEKTRALAB_BUILD_NATIVE_RAW=ON -DSPEKTRALAB_BUILD_HOST=ON -DSPEKTRALAB_BUILD_DESKTOP=OFF \
  -DSPEKTRALAB_REQUIRE_VULKAN=ON -DSPEKTRALAB_STATIC_RUNTIME=ON -DBUILD_TESTING=OFF \
  -DSPEKTRALAB_HOST_VERSION="0.1.0+$version"
ninja -C "$build" spektralab-host spektralab_vulkan_resources

"$here/stage-host.sh" "$build" "$stage" spektralab-host.exe

# Nothing but system DLLs may be imported.
if command -v x86_64-w64-mingw32-objdump >/dev/null; then
  imports="$(x86_64-w64-mingw32-objdump -p "$stage/spektralab-host.exe" | awk '/DLL Name/ {print $3}' | sort -u)"
  echo "imports: $(echo $imports)" >&2
  if echo "$imports" | grep -qiE 'libstdc|libgcc|libwinpthread|vulkan-1'; then
    echo "spektralab-host.exe imports a non-system DLL" >&2
    exit 1
  fi
fi

if [[ $run_tests == 1 ]]; then
  # winevulkan needs wine's X11 driver, i.e. a display; Xvfb is enough, and
  # it then forwards to the host's Vulkan loader (lavapipe on CI).
  wrap=()
  if [[ -z "${DISPLAY:-}" ]] && command -v xvfb-run >/dev/null; then wrap=(xvfb-run -a); fi
  WINEDEBUG="${WINEDEBUG:--all}" "${wrap[@]}" python3 "$here/tests/host_smoke.py" --wrapper wine \
    --host "$stage/spektralab-host.exe" --resources "$stage/engine"
fi
echo "staged $stage" >&2
