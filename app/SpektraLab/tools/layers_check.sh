#!/bin/bash
# layers_check.sh -- the 图层 panel's live check (Sources/Mac/Layers/MacLayersCheck.swift, LAYERS-SPEC §11, §15):
# a double exposure of two photographs made in the order they were picked, opened as a page takes it, and walked
# -- the panel's rows and the pick, the canvas against the export (trap 33), one exposure alone, 摆放's one step
# of Undo, 漏光 · 片边 · 日期后背 · Edit's crop on a double, and the one refusal of an emptied layer. The Debug app
# runs under a scratch home (CFFIXED_USER_HOME: its library and the Mac library's records are the scratch's,
# never the person's) with the two photographs imported.
#
#   tools/layers_check.sh FIRST_FILE SECOND_FILE [--out DIR] [--app PATH]
#
# Exit 0 when every step did what it should. Two RAW files take about 20 s; under ten seconds means the library
# never developed (read run.log before believing it).
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[[ $# -ge 2 ]] || { echo "usage: tools/layers_check.sh FIRST SECOND [--out DIR] [--app PATH]"; exit 2; }
first=$1; second=$2; shift 2
out="$here/build/layers-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    *) echo "unknown: $1"; exit 2 ;;
  esac
done
home=$(mktemp -d "${TMPDIR:-/tmp}/layers-check-home.XXXXXX")
mkdir -p "$out" "$home/Desktop" "$home/in"
cp "$first" "$home/in/1-$(basename "$first")"
cp "$second" "$home/in/2-$(basename "$second")"
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
# A copy with a bundle identifier of this run's own: the build's preferences are never reachable (tools/check_app.sh).
source "$here/tools/check_app.sh"; check_app_isolate "$app"
start=$(date +%s)
CFFIXED_USER_HOME="$home" "$bin" --library real --import "$home/in" --layers-check --out "$out" > "$out/run.log" 2>&1 && status=0 || status=$?
echo "ran $(( $(date +%s) - start )) s, exit $status"
grep "^layers-check:" "$out/run.log" || true
rm -rf "$home"
exit "$status"
