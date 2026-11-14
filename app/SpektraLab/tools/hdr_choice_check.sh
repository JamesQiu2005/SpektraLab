#!/bin/bash
# hdr_choice_check.sh -- Enable HDR remembered, in the running app, across photographs and a relaunch
# (Sources/Mac/Export/MacHDRChoiceCheck.swift; 2.4.0, the owner, 2026-11-13).
#
# The Debug app (a copy with a bundle identifier of the run's own, tools/check_app.sh) is launched twice under one
# scratch home (CFFIXED_USER_HOME: its library and previews) and one UserDefaults suite of its own (`--defaults-suite`,
# deleted at the end: AGENTS.md trap 24) -- the suite holds Settings' Enable HDR by Default, which the relaunch must
# find. `--hdr-headroom 4` makes every screen an HDR one. The fixtures are copied into the home first (a develop
# writes a sidecar): four photographs for the first run, a fifth imported at the relaunch.
#
#   tools/hdr_choice_check.sh [--out DIR] [--app PATH] [--keep]
#
# Exit 0 when both runs pass; every check is counted in each report.json.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/hdr-choice-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"; keep=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    *) echo "unknown: $1"; exit 2 ;;
  esac
done
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
source "$here/tools/check_app.sh"; check_app_isolate "$app"
home=$(mktemp -d "${TMPDIR:-/tmp}/hdr-choice-home.XXXXXX")
suite="spk.hdr-choice-check.$(basename "$home")"
rm -rf "$out"; mkdir -p "$out/run1" "$out/run2" "$home/in" "$home/in2"
pics=("$here/SampleSources/scene_raw_srgb.jpg" "$here/SampleSources/overscan/plain_bund.jpg" "$here/SampleSources/overscan/plain_street.jpg")
n=0
for name in A B C D; do
  cp "${pics[$((n % 3))]}" "$home/in/$name-$(basename "${pics[$((n % 3))]}")"
  n=$((n + 1))
done
cp "${pics[1]}" "$home/in2/E-$(basename "${pics[1]}")"
start=$(date +%s)
set +e
CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --hdr-headroom 4 --import "$home/in" \
  --hdr-choice-check "$out/run1" --hdr-choice-check-exit > "$out/run1.log" 2>&1
s1=$?
CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --hdr-headroom 4 --import "$home/in2" \
  --hdr-choice-check "$out/run2" --hdr-choice-relaunch "$out/run1" --hdr-choice-check-exit > "$out/run2.log" 2>&1
s2=$?
set -e
echo "ran $(( $(date +%s) - start )) s, run 1 exit $s1, run 2 exit $s2"
grep -h "^hdr-choice-check:\|^history-check:" "$out/run1.log" "$out/run2.log" || true
defaults delete "$suite" > /dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/$suite.plist"
if [[ $keep -eq 1 ]]; then echo "home kept: $home"; else rm -rf "$home"; fi
[[ $s1 -eq 0 && $s2 -eq 0 ]]
