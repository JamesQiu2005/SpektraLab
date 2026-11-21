#!/bin/bash
# Builds the LUT baker against this repository's engine (Linux, g++, Vulkan headers on the system), then bakes:
#   bash camera/tools/lut-bake/build.sh            -> out/bake, out/jobs.tsv, out/films.json
#   VK_DRIVER_FILES=<a Vulkan ICD> out/bake ../../app/src/main/assets/engine out/jobs.tsv out/luts
#   sh stage.sh                                     -> films.json + luts/ into the app's assets
# The engine resources come from tools/engine/stage.sh (run it first).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
E="$repo/engine"
out="$here/out"; mkdir -p "$out/obj" "$out/luts"
python3 -I "$here/catalog.py" "$repo" "$out"
CORE="blob cam16 colour curves diffusion_psf digital_intermediate hanatos hdr_curves json latitude_fit minilab
      negative_hue numeric params print_lut printing profile scan_hdr setup_cache spectral"
PIPE="blur disk_checkpoint engine pipeline scene_latitude contrast_mask lens overscan edge_raster scene_layers
      windows_unported"
FLAGS="-std=c++20 -O2 -fPIC -pthread -I$E/src/core -I$E/include -I$E/src -I$E/third_party/stb -I$E/third_party/volk"
objs=()
for f in $CORE; do g++ $FLAGS -c "$E/src/core/$f.cpp" -o "$out/obj/core_$f.o" & objs+=("$out/obj/core_$f.o"); done; wait
for f in $PIPE; do g++ $FLAGS -c "$E/src/pipeline/$f.cpp" -o "$out/obj/pipe_$f.o" & objs+=("$out/obj/pipe_$f.o"); done; wait
g++ $FLAGS -c "$E/src/gpu/vulkan_gpu.cpp" -o "$out/obj/vulkan_gpu.o"; objs+=("$out/obj/vulkan_gpu.o")
gcc -O2 -fPIC -I"$E/third_party/volk" -c "$E/third_party/volk/volk.c" -o "$out/obj/volk.o"; objs+=("$out/obj/volk.o")
g++ $FLAGS "$here/bake.cpp" "${objs[@]}" -ldl -o "$out/bake"
echo "built $out/bake"
