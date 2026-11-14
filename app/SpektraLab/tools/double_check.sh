#!/bin/bash
# double_check.sh -- a double exposure of two photographs walked through the Mac app's own path, on the engine
# (Sources/App/DoubleHarness.swift, RFC-048 §7). The Debug app is launched under a scratch home (CFFIXED_USER_HOME:
# its library, previews and the Mac library's records are the scratch's, never the person's), the two photographs
# are copied in, and the harness makes the double, develops it, measures film truth, swaps and balances it, drags
# Balance on the page's session (R2), tries the whole's white balance (R3) and an emptied layer's export (R10), and
# removes it.
#
#   tools/double_check.sh BOTTOM_FILE TOP_FILE [--out DIR] [--app PATH]
#
# While it runs, the app's footprint is sampled with `footprint -p` every 0.2 s (`footprint.tsv`): the number the
# cost model is fitted to (`phys_footprint`, not RSS, which cannot see the Metal pool; AGENTS.md). The harness's
# own `cost.txt` has each composed job's seed against the peak its job record measured.
#
# Exit 0 when every step did what it should. A full run with two RAWs takes about a minute; under ten seconds
# means the library never developed (look at the log before believing it).
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[[ $# -ge 2 ]] || { echo "usage: tools/double_check.sh BOTTOM TOP [--out DIR] [--app PATH]"; exit 2; }
bottom=$1; top=$2; shift 2
out="$here/build/double-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    *) echo "unknown: $1"; exit 2 ;;
  esac
done
home=$(mktemp -d "${TMPDIR:-/tmp}/double-check-home.XXXXXX")
mkdir -p "$out" "$home/Desktop" "$home/in"
cp "$bottom" "$home/in/1-$(basename "$bottom")"
cp "$top" "$home/in/2-$(basename "$top")"
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
# A copy with a bundle identifier of this run's own: the build's preferences are never reachable (tools/check_app.sh).
source "$here/tools/check_app.sh"; check_app_isolate "$app"
start=$(date +%s)
CFFIXED_USER_HOME="$home" "$bin" --library real --import "$home/in" --double-check --out "$out" > "$out/run.log" 2>&1 &
pid=$!
: > "$out/footprint.tsv"
while kill -0 "$pid" 2>/dev/null; do
  f=$(footprint -p "$pid" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}' || true)
  [[ -n "$f" ]] && printf "%s\t%s\n" "$(python3 -c 'import time; print(f"{time.time():.2f}")')" "$f" >> "$out/footprint.tsv"
  sleep 0.2
done
wait "$pid" && status=0 || status=$?
echo "ran $(( $(date +%s) - start )) s, exit $status"
grep "^double-check:" "$out/run.log" || true
awk -F'\t' '{split($2,a," "); v=a[1]; u=a[2]; if (u=="GB") v*=1024; if (u=="KB") v/=1024; if (v>m) m=v} END {printf "footprint -p peak: %.0f MB over %d samples\n", m, NR}' "$out/footprint.tsv"
rm -rf "$home"
exit "$status"
