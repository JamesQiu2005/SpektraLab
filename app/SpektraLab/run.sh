#!/bin/bash
# run.sh -- build the Mac app (a debug build, signed to run locally) and open it.
#
#   app/SpektraLab/run.sh [--release] [-- <launch arguments>…]
#
# Builds the engine (tools/build_engine_mac.sh), writes the Xcode project (gen_project.py) and
# builds the app for Mac Catalyst into build/DerivedData, then opens it. The arguments after `--`
# are the app's own (`--settings`, `--develop`, `--demo home`, …).
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
config=Debug
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) config=Release; shift ;;
    --) shift; break ;;
    *) echo "usage: run.sh [--release] [-- <launch arguments>]"; exit 2 ;;
  esac
done
out="$here/build"
mkdir -p "$out"
"$here/tools/build_engine_mac.sh" > "$out/engine-build.log" 2>&1 || { tail -20 "$out/engine-build.log"; exit 1; }
python3 "$here/gen_project.py" > /dev/null
xcodebuild -project "$here/SpektraLab.xcodeproj" -scheme SpektraLab -configuration "$config" \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$out/DerivedData" build \
  > "$out/app-build.log" 2>&1 || { grep -E "error:" "$out/app-build.log" | sort -u | head -20; exit 1; }
app="$out/DerivedData/Build/Products/$config-maccatalyst/SpektraLab.app"
echo "built $app"
open -n "$app" --args "$@"
