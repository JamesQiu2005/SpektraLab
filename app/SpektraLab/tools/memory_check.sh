#!/bin/bash
# memory_check.sh -- MacMemoryCheck (Sources/Mac/Render/MacMemoryCheck.swift) in the running Debug app: browsing fresh
# pictures, a full-size inspection and a memory-pressure event, each one's footprint written to <out>/report.json.
#
# The app is a copy with a bundle identifier of the run's own (tools/check_app.sh), under a scratch home
# (CFFIXED_USER_HOME) and a defaults suite of its own (`--defaults-suite`, which the check refuses to run without):
# the build's preferences, library and caches are never reachable.
#
#   tools/memory_check.sh [PICTURES-FOLDER] [--out DIR] [--app PATH] [--preview-edge PX] [--browse-only] [--keep] [--no-grain]
#
# PICTURES-FOLDER: default three of the tree's own pictures (SampleSources), copied into the scratch home first.
# --preview-edge: Settings' Preview size for the run (`settings.previewLongEdge`, written into the run's suite before
# the launch), so two sizes can be measured interleaved (2.4.0's 3,840 px against 2,560). --browse-only: step 1 alone.
# --keep: the browsed frames' kept develops into <out>/developed and the inspected frame's full render into <out>/full.
# --no-grain: every frame developed with grain and glare off (the sharpness comparison).
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/memory-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"; pics=""
edge=""; extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --preview-edge) edge=$2; shift 2 ;;
    --browse-only) extra+=(--memory-check-browse-only); shift ;;
    --keep) extra+=(--memory-check-keep); shift ;;
    --no-grain) extra+=(--memory-check-no-grain); shift ;;
    -*) echo "unknown: $1"; exit 2 ;;
    *) pics=$1; shift ;;
  esac
done
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
# A copy with a bundle identifier of this run's own: the build's preferences are never reachable (tools/check_app.sh).
source "$here/tools/check_app.sh"; check_app_isolate "$app"
home=$(mktemp -d "${TMPDIR:-/tmp}/memory-check-home.XXXXXX")
suite="spk.memory-check.$(basename "$home")"
mkdir -p "$home/pictures"
if [[ -n "$pics" ]]; then cp "$pics"/* "$home/pictures/"
else cp "$here/SampleSources/scene_raw_srgb.jpg" "$here/SampleSources/overscan/plain_bund.jpg" "$here/SampleSources/overscan/plain_street.jpg" "$home/pictures/"; fi
rm -rf "$out"; mkdir -p "$out"
[[ -n "$edge" ]] && defaults write "$suite" settings.previewLongEdge -int "$edge"
start=$(date +%s)
set +e
CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --memory-check "$out" \
  --memory-check-pictures "$home/pictures" ${extra[@]+"${extra[@]}"} --memory-check-exit > "$out/run.log" 2>&1
code=$?
set -e
echo "ran $(( $(date +%s) - start )) s, exit $code"
grep -h "^memory-check:" "$out/run.log" || true
defaults delete "$suite" > /dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/$suite.plist"
rm -rf "$home"
[[ $code -eq 0 ]]
