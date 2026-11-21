#!/bin/sh
# Copies the baked film list and LUTs into the app's assets (app/src/main/assets, git-ignored).
# Run after bake: sh tools/lut-bake/stage.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
assets="$here/../../app/src/main/assets"
[ -f "$here/out/films.json" ] && [ -d "$here/out/luts" ] || { echo "bake first (tools/lut-bake/build.sh, then bake; see camera/BUILD.md)" >&2; exit 1; }
mkdir -p "$assets/luts"
cp "$here/out/films.json" "$assets/films.json"
cp "$here/out/luts/"*.lut "$assets/luts/"
echo "staged $(ls "$assets/luts" | wc -l) LUTs and films.json into app/src/main/assets"
