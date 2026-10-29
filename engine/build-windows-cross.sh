#!/usr/bin/env bash
# build-windows-cross.sh -- spektralab-host.exe for Windows x64, from Linux or macOS.
#
#   engine/build-windows-cross.sh [--test] [--no-deps]
#
# MinGW-w64 (posix threads) through cmake/toolchain-mingw-w64.cmake; Vulkan
# through volk, so no SDK import library -- the exe opens vulkan-1.dll at run
# time; LibRaw 0.22.2 cross-built from the same pinned tree as Linux;
# libstdc++, libgcc and winpthread linked statically, so the exe depends only
# on system DLLs. Stages build/host-win-x64/ (HOST-PROTOCOL.md §4).
#
# macOS (verified 2026-10-29, Homebrew mingw-w64 14.0.0 = GCC 15, posix
# threads): brew install cmake ninja nasm pkg-config mingw-w64 glslang, and
# meson 1.9.2 importable by python3 (a venv on PATH). Homebrew's MinGW ships
# no libgomp, so LibRaw is built without OpenMP there (serial decode, same
# pixels); the Ubuntu CI build keeps OpenMP. --test needs wine and is
# Linux-only; on macOS run engine/tests/host_smoke.py against a native
# MoltenVK host instead (engine/LINUX_WINDOWS.md §7).
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
deps="${SPEKTRALAB_DEPS_DIR:-$repo/build/deps}"
input_prefix="${SPEKTRALAB_INPUT_CODEC_PREFIX:-$deps/input-codecs/install-win-cross}"
lens_prefix="${SPEKTRALAB_LENS_PREFIX:-$deps/lens-codecs/install-win-cross}"
if [[ $fetch == 1 ]]; then
  "$here/setup-deps.sh" "$deps" >/dev/null
  python3 "$here/setup-input-codecs.py" --sources "$deps/input-codecs" \
    --build "$build/input-codecs" --install "$input_prefix" --generator Ninja \
    --toolchain "$here/cmake/toolchain-mingw-w64.cmake"
  python3 "$here/setup-lens-codecs.py" --sources "$deps/lens-codecs" \
    --build "$build/lens-codecs" --install "$lens_prefix" --generator Ninja \
    --toolchain "$here/cmake/toolchain-mingw-w64.cmake" --meson-cross-file "$here/cmake/meson-mingw-w64.ini"
fi

version="$(git -C "$repo" describe --always --dirty 2>/dev/null || echo unknown)"
glslang="$(command -v glslangValidator || true)"
# LibRaw's OpenMP needs the cross compiler's static libgomp.a (Ubuntu's MinGW
# has it; Homebrew's does not). Without it, build LibRaw serially rather than
# fail -- or link a libgomp DLL the exe must not import.
openmp=ON
gxx="$(command -v x86_64-w64-mingw32-g++-posix || command -v x86_64-w64-mingw32-g++ || true)"
if [[ -n "$gxx" ]]; then
  gomp="$("$gxx" -print-file-name=libgomp.a)"
  if [[ "$gomp" != /* || ! -f "$gomp" ]]; then
    echo "note: $gxx has no static libgomp.a; LibRaw is built without OpenMP (serial RAW decode)" >&2
    openmp=OFF
  fi
fi
cmake -S "$repo" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$here/cmake/toolchain-mingw-w64.cmake" \
  -DSPEKTRALAB_GLSLANG="$glslang" \
  -DSPEKTRALAB_INPUT_CODEC_PREFIX="$input_prefix" \
  -DSPEKTRALAB_LENS_PREFIX="$lens_prefix" \
  -DSPEKTRALAB_VULKAN_HEADERS="$repo/build/deps/Vulkan-Headers/include" \
  -DSPEKTRALAB_BUILD_NATIVE_RAW=ON -DSPEKTRALAB_BUILD_HOST=ON -DSPEKTRALAB_BUILD_DESKTOP=OFF \
  -DSPEKTRALAB_REQUIRE_VULKAN=ON -DSPEKTRALAB_STATIC_RUNTIME=ON -DBUILD_TESTING=OFF \
  -DSPEKTRALAB_LIBRAW_OPENMP="$openmp" \
  -DSPEKTRALAB_HOST_VERSION="0.1.0+$version"
ninja -C "$build" spektralab-host spektralab_vulkan_resources

"$here/stage-host.sh" "$build" "$stage" spektralab-host.exe

# Nothing but system DLLs may be imported.
# A missing objdump fails the build: a skipped check reads like a passed one.
command -v x86_64-w64-mingw32-objdump >/dev/null || { echo "x86_64-w64-mingw32-objdump not found; cannot check the exe's imports" >&2; exit 1; }
if true; then
  imports="$(x86_64-w64-mingw32-objdump -p "$stage/spektralab-host.exe" | awk '/DLL Name/ {print $3}' | sort -u)"
  echo "imports: $(echo $imports)" >&2
  if echo "$imports" | grep -qiE 'libstdc|libgcc|libwinpthread|libgomp|vulkan-1'; then
    echo "spektralab-host.exe imports a non-system DLL" >&2
    exit 1
  fi
  # And an allowlist, so a DLL nobody thought to forbid fails too. The C
  # runtime is msvcrt (Ubuntu's MinGW) or the Universal CRT's api-ms-win-crt-*
  # forwarders (Homebrew's MinGW 14 defaults to UCRT; part of Windows 10+).
  # vulkan-1.dll is never imported: volk opens it at run time.
  unexpected="$(echo "$imports" | grep -viE '^(kernel32|shell32|ws2_32|msvcrt|ucrtbase|advapi32|user32|ole32|bcrypt|api-ms-win-crt-[a-z0-9-]+)\.dll$' || true)"
  if [[ -n "$unexpected" ]]; then
    echo "spektralab-host.exe imports DLLs outside the system allowlist: $(echo $unexpected)" >&2
    exit 1
  fi
fi

if [[ $run_tests == 1 && "$(uname -s)" == Darwin ]]; then
  echo "--test runs the host under wine, which this script supports on Linux only" >&2
  exit 2
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
