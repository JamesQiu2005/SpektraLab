#!/usr/bin/env bash
# build-android.sh -- build spektralab-host for Android arm64 (compile/link proof, then the APK's host).
#
#   engine/build-android.sh [--jobs N]
#
# No CMake: plain clang, with the source lists read out of engine/CMakeLists.txt and
# engine/host/CMakeLists.txt so they cannot drift from the Linux build.
#
# Toolchain (defaults: the ones inside a Chromium checkout at ~/Documents/chromium; override with env):
#   ANDROID_CLANG    a clang++ that knows --target=aarch64-linux-android (Chromium's llvm-build has the
#                    aarch64-android compiler-rt builtins)
#   ANDROID_SYSROOT  an NDK sysroot (libc++ headers in usr/include/c++/v1, libs in usr/lib/aarch64-linux-android)
#   ANDROID_API      minimum API level (default 31)
# Dependencies: engine/setup-deps.sh (LibRaw 0.22.2, Vulkan-Headers) in build/deps.
# lensfun is not built for Android yet: lens_correct.cpp compiles its no-lensfun branch.
# It also stages the host's resources (engine/resources + the 65 SPIR-V kernels, compiled with
# glslangValidator as the Linux build does) in build/android-arm64/engine: see the end of this file.
#
# Output: build/android-arm64/spektralab-host (a PIE executable; the APK ships it as
# lib/arm64-v8a/libspektralab_host.so so Android installs it executable in nativeLibraryDir).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
E="$here"
deps="$repo/build/deps"
out="$repo/build/android-arm64"
jobs=$(nproc)
[[ "${1:-}" == "--jobs" ]] && jobs="$2"

CHR="$HOME/Documents/chromium/src"
CXX="${ANDROID_CLANG:-$CHR/third_party/llvm-build/Release+Asserts/bin/clang++}"
SYSROOT="${ANDROID_SYSROOT:-$CHR/third_party/android_toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot}"
API="${ANDROID_API:-31}"
LIBRAW="$deps/LibRaw-0.22.2"
VKH="$deps/Vulkan-Headers/include"
for f in "$CXX" "$SYSROOT/usr/include/c++/v1" "$LIBRAW/libraw/libraw.h" "$VKH/vulkan/vulkan_core.h"; do
  [[ -e "$f" ]] || { echo "missing $f (see the header of $0)" >&2; exit 1; }
done

TARGET=(--target="aarch64-linux-android$API" --sysroot="$SYSROOT")
COMMON=("${TARGET[@]}" -O2 -g0 -fPIC -ffunction-sections -fdata-sections -pthread)
CXXF=("${COMMON[@]}" -std=c++20 -stdlib=libc++)

# Source lists, read from CMake: the lines between "add_library(<name>" and the closing ")".
cmake_list() {  # file target
  sed -n "/add_library($2 /,/^)/p" "$1" | grep -o 'src/[A-Za-z0-9_/]*\.cpp'
}
mapfile -t core < <(cmake_list "$E/CMakeLists.txt" spektralab_core)
mapfile -t pipe < <(cmake_list "$E/CMakeLists.txt" spektralab_pipeline)
pipe+=(src/pipeline/windows_unported.cpp)   # the non-Apple branch of target_sources
mapfile -t host < <(sed -n '/add_executable(spektralab-host/,/^)/p' "$E/host/CMakeLists.txt" | grep -o '[a-z_]*\.cpp')
mapfile -t libraw < <(cd "$LIBRAW" && find src -name '*.cpp' ! -name '*_ph.cpp' | sort)
io=(src/io/raw_decoder.cpp src/io/raw_headroom.cpp src/io/image_writer.cpp)
(( ${#core[@]} > 10 && ${#pipe[@]} > 5 && ${#host[@]} > 5 )) || { echo "source lists not found in CMake files" >&2; exit 1; }

mkdir -p "$out/obj"
jobfile="$out/jobs.txt"; : > "$jobfile"
# No dependency files here, so a changed engine header recompiles every engine object (not LibRaw's): checking
# only the .cpp once left most objects on an old Gpu vtable after gpu.hpp gained a method, and the host failed
# every open with a nonsense "upload size must be 4-byte aligned (9 bytes)" (2026-11-22).
newest_header="$(find "$E/src" "$E/include" "$E/host" -name '*.h' -o -name '*.hpp' -o -name '*.inc' | xargs ls -t | head -1)"
add() {  # obj src flags...
  local obj="$out/obj/$1" src="$2"; shift 2
  objs+=("$obj")
  if [[ "$src" == "$LIBRAW"/* ]]; then
    [[ "$obj" -nt "$src" ]] && return 0
  else
    [[ "$obj" -nt "$src" && "$obj" -nt "$newest_header" ]] && return 0
  fi
  printf '%q ' "$@" -c "$src" -o "$obj" >> "$jobfile"; echo >> "$jobfile"
}
objs=()
INC_CORE=(-I"$E/src/core")
for s in "${core[@]}"; do add "core_$(basename "$s" .cpp).o" "$E/$s" "$CXX" "${CXXF[@]}" "${INC_CORE[@]}"; done
for s in "${pipe[@]}"; do add "pipe_$(basename "$s" .cpp).o" "$E/$s" "$CXX" "${CXXF[@]}" "${INC_CORE[@]}" \
  -I"$E/include" -I"$E/src" -I"$E/third_party/stb"; done
add vulkan_gpu.o "$E/src/gpu/vulkan_gpu.cpp" "$CXX" "${CXXF[@]}" "${INC_CORE[@]}" -I"$E/include" -I"$E/src" \
  -I"$E/third_party/volk" -I"$VKH"
add volk.o "$E/third_party/volk/volk.c" "${CXX%++}" "${COMMON[@]}" -I"$E/third_party/volk" -I"$VKH"
for s in "${io[@]}"; do add "io_$(basename "$s" .cpp).o" "$E/$s" "$CXX" "${CXXF[@]}" -I"$E/src" -I"$LIBRAW" \
  -DLIBRAW_NODLL; done
for s in "${libraw[@]}"; do add "libraw_$(echo "$s" | tr / _ | sed 's/\.cpp$//').o" "$LIBRAW/$s" "$CXX" \
  "${TARGET[@]}" -O2 -g0 -fPIC -std=c++11 -stdlib=libc++ -w -I"$LIBRAW" -DLIBRAW_NODLL -DLIBRAW_NOTHREADS; done
for s in "${host[@]}"; do add "host_$(basename "$s" .cpp).o" "$E/host/$s" "$CXX" "${CXXF[@]}" -I"$E/host" \
  -I"$E/include" -I"$E/src" -I"$E/third_party/stb" "${INC_CORE[@]}" -I"$LIBRAW" -DLIBRAW_NODLL \
  -DSPEKTRALAB_HOST_VERSION="\"0.1.0+android-$(git -C "$repo" describe --always --dirty 2>/dev/null || echo unknown)\""; done

n=$(wc -l < "$jobfile")
echo "compiling $n of ${#objs[@]} objects for aarch64-linux-android$API ($jobs jobs)" >&2
if (( n > 0 )); then
  xargs -P "$jobs" -d '\n' -n 1 bash -c 'eval "$1" || { echo "FAILED: $1" >&2; exit 255; }' _ < "$jobfile"
fi

# libunwind.a: a full NDK has it (lib/clang/*/lib/linux/aarch64); Chromium's trimmed NDK does not, so it
# is built from Chromium's libunwind sources (same LLVM as its clang), with Chromium's own flags.
LINKDIRS=()
if ! "$CXX" "${TARGET[@]}" -print-file-name=libunwind.a | grep -q /; then
  UW="${LIBUNWIND_SOURCE:-$CHR/third_party/libunwind/src}"
  [[ -f "$UW/src/libunwind.cpp" ]] || { echo "no libunwind.a in the toolchain and no sources at $UW" >&2; exit 1; }
  mkdir -p "$out/libunwind"
  if [[ ! -f "$out/libunwind/libunwind.a" ]]; then
    uwf=("${TARGET[@]}" -O2 -fPIC -fstrict-aliasing -funwind-tables -I"$UW/include"
         -D_LIBUNWIND_IS_NATIVE_ONLY -D_LIBUNWIND_DISABLE_VISIBILITY_ANNOTATIONS -Wno-unused-function)
    uo=()
    for s in libunwind.cpp Unwind-EHABI.cpp; do
      "$CXX" "${uwf[@]}" -std=c++20 -stdlib=libc++ -fno-exceptions -fno-rtti -c "$UW/src/$s" -o "$out/libunwind/$s.o"
      uo+=("$out/libunwind/$s.o"); done
    for s in Unwind-sjlj.c UnwindLevel1-gcc-ext.c UnwindLevel1.c UnwindRegistersRestore.S UnwindRegistersSave.S; do
      "${CXX%++}" "${uwf[@]}" -c "$UW/src/$s" -o "$out/libunwind/$s.o"; uo+=("$out/libunwind/$s.o"); done
    "$(dirname "$CXX")/llvm-ar" rcs "$out/libunwind/libunwind.a" "${uo[@]}"
    echo "built libunwind.a from $UW" >&2
  fi
  LINKDIRS=(-L"$out/libunwind")
fi

# Link: static libc++ (no libc++_shared.so to ship), PIE, Android's own libdl/libm/liblog.
"$CXX" "${TARGET[@]}" "${LINKDIRS[@]}" -stdlib=libc++ -static-libstdc++ -fuse-ld=lld -pie -pthread -Wl,--gc-sections \
  -Wl,-z,max-page-size=16384 "${objs[@]}" -ldl -lm -llog -o "$out/spektralab-host"
echo "linked $out/spektralab-host" >&2

# Resources the host reads (--resources): engine/resources plus the SPIR-V kernels, compiled exactly as
# CMakeLists.txt does (SPEKTRALAB_VULKAN_KERNELS, glslangValidator -V --target-env vulkan1.0).
# GLSLANG: a glslangValidator; default build/tools/glslang, e.g. unpacked without root with
#   dpkg-deb -x /var/cache/apt/archives/glslang-tools_*.deb build/tools/glslang (and spirv-tools_*.deb).
G="${GLSLANG:-$repo/build/tools/glslang/usr/bin/glslangValidator}"
if [[ -x "$G" ]]; then
  export LD_LIBRARY_PATH="$(dirname "$G")/../lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  res="$out/engine"
  mkdir -p "$res/vulkan"
  cp -a "$E/resources/." "$res/"
  # Develop's own profiles (the data-sheet films, black and white, Portra NC/VC, CineStill, Multigrade) beside
  # spektrafilm's, as stage-host.sh does for Linux: without them choosing one fails with "no profile '...'".
  if [[ -d "$E/resources_product/profiles" ]]; then
    cp "$E/resources_product/profiles/"*.json "$res/profiles/"
    cp "$E/resources_product/NOTICE.md" "$res/PRODUCT_PROFILES_NOTICE.md"
    cp "$E/resources_product/neutral_print_filters_colour.json" "$res/"
  fi
  mapfile -t kernels < <(sed -n '/set(SPEKTRALAB_VULKAN_KERNELS/,/CACHE INTERNAL/p' "$E/CMakeLists.txt" |
                         grep -o 'spk_[a-z0-9_]*')
  for k in "${kernels[@]}"; do
    src="$E/src/shaders/vulkan/$k.comp" spv="$res/vulkan/$k.spv"
    [[ "$spv" -nt "$src" ]] && [[ -z "$(find "$E/src/shaders/vulkan" -name '*.glsl' -newer "$spv")" ]] && continue
    "$G" -V --target-env vulkan1.0 -I"$E/src/shaders/vulkan" -o "$spv" "$src" >/dev/null ||
      { echo "glslang failed: $k" >&2; exit 1; }
  done
  echo "staged $res (${#kernels[@]} kernels)" >&2
else
  echo "no glslangValidator at $G: resources not staged (set GLSLANG)" >&2
fi
