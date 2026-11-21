#!/bin/bash
# Stages Develop's engine files into the app: app/src/main/assets/engine/ (git-ignored, ~36 MB) =
# engine/resources + the product profiles + the 65 Vulkan kernels compiled to SPIR-V. The engine's C++ is built
# straight from engine/ by app/src/main/cpp/CMakeLists.txt.
# Needs glslangValidator (GLSLANG=..., else the one on PATH).
#   bash camera/tools/engine/stage.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
camera="$(cd "$here/../.." && pwd)"
E="$(cd "$camera/../engine" && pwd)"
GLSLANG="${GLSLANG:-$(command -v glslangValidator || true)}"
[[ -x "$GLSLANG" ]] || { echo "glslangValidator not found (set GLSLANG)" >&2; exit 1; }
# The Fold's PowerVR skips shaders with function-scope constant arrays: the engine must have the fix.
if grep -q "const float ev\[3\]" "$E/src/shaders/vulkan/spk_lens_pyr_out.comp"; then
  echo "engine/ lacks the PowerVR lens-kernel fix" >&2; exit 1
fi
assets="$camera/app/src/main/assets/engine"
rm -rf "$assets" && mkdir -p "$assets/vulkan"
cp -R "$E/resources/." "$assets/"
cp "$E/resources_product/profiles/"*.json "$assets/profiles/"
cp "$E/resources_product/neutral_print_filters_colour.json" "$assets/"
kernels=$(sed -n '/set(SPEKTRALAB_VULKAN_KERNELS/,/CACHE INTERNAL/p' "$E/CMakeLists.txt" | grep -o 'spk_[a-z0-9_]*')
for k in $kernels; do
  "$GLSLANG" -V --target-env vulkan1.0 -I"$E/src/shaders/vulkan" -o "$assets/vulkan/$k.spv" "$E/src/shaders/vulkan/$k.comp" >/dev/null
done
# A stamp the app compares with what it extracted, so a new engine build replaces the old files.
(git -C "$E" log -1 --format=%H 2>/dev/null; find "$assets" -type f | sort | xargs sha256sum | sha256sum) | sha256sum | cut -c1-16 > "$assets/STAMP"
echo "staged $(ls "$assets/vulkan" | wc -l) kernels, $(ls "$assets/profiles" | wc -l) profiles into app/src/main/assets/engine"
