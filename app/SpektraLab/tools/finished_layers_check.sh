#!/bin/bash
# finished_layers_check.sh -- PRD-E's 成片 layers on every surface that shows the frame, in the running Debug app
# (Sources/Mac/Layers/MacFinishedLayersCheck.swift; RFC-052 §10 gate 7, traps 33 and 34): one photograph with a layered
# edit through four framings (as it is, Edit's crop, a quarter turn with a flip, a film edge with Edit's crop), its page,
# histogram, zoom, tile copy and export held to the export. The app runs under a scratch home (CFFIXED_USER_HOME) and a
# defaults suite of its own (`--defaults-suite`, deleted at the end: AGENTS.md trap 24) -- never the person's library
# or settings -- with a copy of the photograph imported.
#
#   tools/finished_layers_check.sh PHOTO [--out DIR] [--app PATH]
#
# Exit 0 when every step did what it should. A 45 MP RAW takes a few minutes (four develops, four full renders and
# four exports); under a minute means nothing developed (read run.log before believing it).
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[[ $# -ge 1 ]] || { echo "usage: tools/finished_layers_check.sh PHOTO [--out DIR] [--app PATH]"; exit 2; }
photo=$1; shift
out="$here/build/finished-layers-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    *) echo "unknown: $1"; exit 2 ;;
  esac
done
home=$(mktemp -d "${TMPDIR:-/tmp}/finished-layers-home.XXXXXX")
suite="com.spektralab.check.finished-layers.$$"
mkdir -p "$out" "$home/Desktop" "$home/in"
cp "$photo" "$home/in/$(basename "$photo")"
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
# A copy with a bundle identifier of this run's own: the build's preferences are never reachable (tools/check_app.sh).
source "$here/tools/check_app.sh"; check_app_isolate "$app"
start=$(date +%s)
set +e
CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --import "$home/in" --finished-layers-check --out "$out" > "$out/run.log" 2>&1
status=$?
set -e
echo "ran $(( $(date +%s) - start )) s, exit $status"
grep "^finished-layers-check:" "$out/run.log" || true
defaults delete "$suite" > /dev/null 2>&1 || true
rm -rf "$home"
exit "$status"
