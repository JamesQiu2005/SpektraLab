#!/bin/bash
# import_c1_check.sh -- a Capture One catalog or session is never an import destination, and Remove from SpektraLab
# works on a picture 2.4.0 imported into one (2026-11-16, Round 4b E2; Sources/Mac/Import/MacImportC1Check.swift).
#
#   tools/import_c1_check.sh [--out DIR] [--app PATH] [--sdk DIR] [--keep]
#
# --sdk: SpektraLab_library's checkout, for its Capture One 16.8 schema (tests/fixtures/capture_one_16_8_schema.sql),
#   on which tools/variant_c1_fixture.py builds a three-picture catalog (read only; default $SPKLIB_SOURCE, else
#   ../../../SpektraLab_library). Without it the check cannot run and says so: exit 2, never a green.
# The fixtures are made in a scratch folder: a Capture One catalog and its pictures, and a Capture One session folder
# (`<Name>.cosessiondb` and a picture in Capture/). The app is a copy with a bundle id of the run's own
# (tools/check_app.sh) under a scratch home, launched in the background (`open -g -n`: never activated, the cursor
# never moved); the owner's library and Capture One catalogs are never read, nor anything under ~/Documents. Exit 0 when every step held.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/import-c1-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"; keep=0
sdk="${SPKLIB_SOURCE:-$here/../../../SpektraLab_library}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --sdk) sdk=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    *) echo "unknown: $1"; exit 2 ;;
  esac
done
schema="$sdk/tests/fixtures/capture_one_16_8_schema.sql"
[[ -f "$schema" ]] || { echo "import-c1-check: no SDK schema at $schema (--sdk or SPKLIB_SOURCE): not run"; exit 2; }
mkdir -p "$out"; out=$(CDPATH= cd -- "$out" && pwd)
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
source "$here/tools/check_app.sh"; check_app_isolate "$app"
home=$(mktemp -d "${TMPDIR:-/tmp}/import-c1-home.XXXXXX")
fixtures=$(mktemp -d "${TMPDIR:-/tmp}/import-c1-fixtures.XXXXXX")
suite="spk.import-c1.$(basename "$home")"
pid=""
cleanup() {
  [[ -n "$pid" ]] && kill "$pid" 2> /dev/null || true
  defaults delete "$suite" > /dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$suite.plist"
  if [[ $keep -eq 1 ]]; then echo "kept: $home $fixtures"; else rm -rf "$home" "$fixtures"; fi
  check_app_cleanup
}
trap cleanup EXIT INT TERM
catalog=$(python3 -I "$here/tools/variant_c1_fixture.py" "$schema" "$fixtures/c1" \
  "$here/SampleSources/scene_raw_srgb.jpg" "$here/SampleSources/overscan/plain_bund.jpg")
session="$fixtures/Shoot"
mkdir -p "$session/Capture" "$session/Selects" "$session/Output" "$session/Trash" "$session/Capture/CaptureOne/Cache"
: > "$session/Shoot.cosessiondb"
cp "$here/SampleSources/scene_raw_srgb.jpg" "$session/Capture/S1.jpg"
cp "$here/SampleSources/overscan/plain_bund.jpg" "$fixtures/picture.jpg"
# The app reads and writes only the scratch folders (the fixtures, its own out, the scratch home): an app copy with a
# bundle id of its own that reads under ~/Documents (the repository) raises a privacy prompt on the owner's screen
# (2026-11-16). This script copies the report and the log into --out after.
run="$fixtures/out"; mkdir -p "$run"
rm -rf "$out/work" "$out/report.json"
log="$run/run.log"
start=$(date +%s)
check_app_open_background "$log" "CFFIXED_USER_HOME=$home" -- \
  --library real --defaults-suite "$suite" --import-c1-check "$run" \
  --import-c1-check-catalog "$catalog" --import-c1-check-session "$session" \
  --import-c1-check-picture "$fixtures/picture.jpg" --import-c1-check-exit \
  || { echo "import-c1-check: FAIL the app did not start"; exit 1; }
size=0; quiet=0
while kill -0 "$pid" 2> /dev/null; do
  sleep 1
  now=$(wc -c < "$log")
  if [[ $now -ne $size ]]; then size=$now; quiet=0; else quiet=$((quiet + 1)); fi
  if [[ $quiet -ge 120 ]]; then echo "import-c1-check: FAIL silent for 120 s: killed"; kill "$pid" 2> /dev/null || true; fi
done
pid=""
cp "$log" "$out/run.log"; [[ -f "$run/report.json" ]] && cp "$run/report.json" "$out/report.json"
code=1; grep -q "^import-c1-check: passed" "$log" && code=0
grep "^import-c1-check:" "$log" || true
echo "import-c1-check: ran $(( $(date +%s) - start )) s, exit $code"
exit $code
