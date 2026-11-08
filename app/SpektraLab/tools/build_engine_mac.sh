#!/bin/bash
# build_engine_mac.sh -- the SpektraLab engine (engine/) for the Mac app, which is built with
# Mac Catalyst. The app's only engine build.
#
#   app/SpektraLab/tools/build_engine_mac.sh
#
# Leaves build/engine-macosx/{libspektralab_engine.a, EngineResources/}, which gen_project.py
# links and copies into the app.
#
# It compiles engine/ exactly as engine/build.sh does -- the same sources, -O2, and the kernels
# with safe math (engine/build.sh's trap 1; spk_engine_create refuses a fast-math metallib) --
# only for the *-apple-ios18.0-macabi targets, because a Mac Catalyst app cannot link a plain
# macOS object. Nothing in engine/ is changed for it, and the app calls the engine's own C ABI
# (engine/include/spektralab/spk_engine.h) with nothing in between. The resources are
# engine/build.sh's `bundle_resources`, verbatim.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
eng="$root/engine"
out="$here/build/engine-macosx"   # $PLATFORM_NAME of a Catalyst build
obj="$out/obj"
rm -rf "$out"; mkdir -p "$obj" "$out/air"

sdk=$(xcrun --sdk macosx --show-sdk-path)
cxx=$(xcrun --sdk macosx --find clang++)
# The app's floor is macOS 15, which a Mac Catalyst target spells ios18.0-macabi. Both
# architectures, as the DMG ships: a Release build of the app is universal.
includes=(-I"$eng/include" -I"$eng/src" -I"$eng/src/core" -I"$eng/third_party/metal-cpp")
shopt -s nullglob
sources=("$eng"/src/core/*.cpp "$eng"/src/gpu/*.cpp "$eng"/src/pipeline/*.cpp)
shopt -u nullglob
slices=()
for arch in arm64 x86_64; do
  target=$arch-apple-ios18.0-macabi
  cxxflags=(-target "$target" -isysroot "$sdk" -std=c++20 -O2 -Wall -Wextra)
  mkdir -p "$obj/$arch"
  pids=(); objs=()
  for src in "${sources[@]}"; do
    o="$obj/$arch/$(basename "$src" .cpp).o"
    objs+=("$o")
    "$cxx" "${cxxflags[@]}" "${includes[@]}" -c "$src" -o "$o" 2> "$o.log" &
    pids+=($!)
  done
  failed=0
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then echo "FAIL ${objs[$i]}"; cat "${objs[$i]}.log"; failed=1; fi
  done
  [[ $failed == 0 ]] || exit 1
  xcrun --sdk macosx libtool -static -o "$obj/$arch/libspektralab_engine.a" "${objs[@]}" 2>/dev/null
  slices+=("$obj/$arch/libspektralab_engine.a")
done
xcrun lipo -create "${slices[@]}" -output "$out/libspektralab_engine.a"
echo "static lib -> $out/libspektralab_engine.a"

# The kernels: macOS 15 metal, as engine/build.sh builds them (MACOS_MIN), safe math.
airs=()
for m in "$eng"/src/shaders/*.metal; do
  a="$out/air/$(basename "$m" .metal).air"
  xcrun -sdk macosx metal -fmetal-math-mode=safe -fmetal-math-fp32-functions=precise \
    -mmacos-version-min=15.0 -Werror -c "$m" -o "$a"
  airs+=("$a")
done

res="$out/EngineResources"
mkdir -p "$res"
rsync -a --exclude '*.metallib' --exclude '*.metalar' "$eng/resources/" "$res/"
if [[ -d "$eng/resources_product/profiles" ]]; then
  cp "$eng/resources_product/profiles/"*.json "$res/profiles/"
  cp "$eng/resources_product/NOTICE.md" "$res/PRODUCT_PROFILES_NOTICE.md"
fi
cp "$root/license/SPEKTRAFILM_LICENSE.txt" "$res/LICENSE-PROFILES.txt"   # the CC BY-SA 4.0 notice of the profiles
xcrun -sdk macosx metallib "${airs[@]}" -o "$res/spektralab.metallib"
"$eng/tools/build_metal_archive.sh" "$res/spektralab.metallib" "$res/spektralab.metalar" "$out"
git -C "$root" log -1 --format='%h %cs' -- engine > "$res/ENGINE-COMMIT.txt"
echo "resources  -> $res ($(du -sh "$res" | cut -f1)), engine $(cat "$res/ENGINE-COMMIT.txt")"
