#!/bin/bash
# edit_refresh_check.sh -- the develop canvas draws the edit as it stands after each change, in HDR, with nothing
# rebuilding the view (issue #123; Sources/Mac/Render/MacEditRefreshCheck.swift).
#
#   tools/edit_refresh_check.sh [--out DIR] [--app PATH] [--keep] [--self-test]
#
# The app runs under a scratch home (CFFIXED_USER_HOME) and a defaults suite of its own (deleted on every exit), on a
# copy of a picture of the tree's (a develop writes a sidecar), with a forced headroom of 16 (`--hdr-headroom`): the
# HDR path is live on any screen. When the app says FRONT it is brought to the front by its process id (never by name:
# the owner's SpektraLab may be running), since the screen is read only for the scene in front.
# --self-test runs it once per 2.4.0 rule put back (`--edit-refresh-check-break address|sizes`) and passes when every
# one is red; the plain run must be green.
# A run that prints nothing new for 120 s is killed and red.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/edit-refresh-check"; app="$here/build/DerivedData/Build/Products/Debug-maccatalyst/SpektraLab.app"; keep=0; selftest=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    --self-test) selftest=1; shift ;;
    *) echo "unknown: $1"; exit 2 ;;
  esac
done
# The app starts a check only for an absolute folder: a relative one is made absolute here.
mkdir -p "$out"; out=$(CDPATH= cd -- "$out" && pwd)
bin="$app/Contents/MacOS/SpektraLab"
[[ -x "$bin" ]] || { echo "no app at $app (build Debug first)"; exit 2; }
source "$here/tools/check_app.sh"; check_app_isolate "$app"

home=""; suite=""; pid=""; fronter=""
cleanup_run() {
  [[ -n "$pid" ]] && kill "$pid" 2> /dev/null || true
  pid=""
  [[ -n "$suite" ]] && { defaults delete "$suite" > /dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$suite.plist"; }
  if [[ -n "$home" ]]; then
    if [[ $keep -eq 1 ]]; then echo "home kept: $home"; else rm -rf "$home"; fi
  fi
  home=""; suite=""
}
trap 'cleanup_run; check_app_cleanup' EXIT INT TERM

# In the background, for 10 s at most, and never past the app's own exit: System Events can take tens of seconds to
# answer a busy Mac (seen 2026-11-14: one `osascript` 44 s), and a check whose app has ended must not wait on it.
front() {
  local end=$(( $(date +%s) + 10 ))
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $1) to true" > /dev/null 2>&1 || true
  while kill -0 "$1" 2> /dev/null && [[ $(date +%s) -lt $end ]]; do
    [[ "$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2> /dev/null)" == "$1" ]] && break
    sleep 0.2
  done
}

# run <dir> [args…]: one launch; its exit code. Polls its log (no `tail -F` left behind) and kills it when silent.
run() {
  local dir=$1; shift
  home=$(mktemp -d "${TMPDIR:-/tmp}/edit-refresh-home.XXXXXX")
  suite="spk.edit-refresh-check.$(basename "$home")"
  mkdir -p "$home/in" "$dir"
  cp "$here/SampleSources/overscan/plain_bund.jpg" "$home/in/a-plain_bund.jpg"
  local log="$dir/run.log"
  CFFIXED_USER_HOME="$home" "$bin" --library real --defaults-suite "$suite" --hdr-headroom 16 --import "$home/in" \
    --edit-refresh-check "$dir" "$@" > "$log" 2>&1 &
  pid=$!
  local fronted=0 size=0 quiet=0
  while kill -0 "$pid" 2> /dev/null; do
    sleep 1
    if [[ $fronted -eq 0 ]] && grep -q "^edit-refresh-check: FRONT" "$log"; then front "$pid" & fronter=$!; fronted=1; fi
    local now; now=$(wc -c < "$log")
    if [[ $now -ne $size ]]; then size=$now; quiet=0; else quiet=$((quiet + 1)); fi
    if [[ $quiet -ge 120 ]]; then echo "edit-refresh-check: FAIL silent for 120 s: killed"; kill "$pid" 2> /dev/null || true; fi
  done
  local code=0; wait "$pid" || code=$?
  pid=""
  [[ -n "${fronter:-}" ]] && { kill "$fronter" 2> /dev/null; pkill -P "$fronter" 2> /dev/null; } || true
  fronter=""
  grep "^edit-refresh-check:" "$log" | grep -v "FRONT" || true
  cleanup_run
  return $code
}

start=$(date +%s)
if [[ $selftest -eq 1 ]]; then
  caught=0; total=0
  for broken in address sizes; do
    total=$((total + 1))
    code=0; run "$out/self-test/$broken" --edit-refresh-check-break "$broken" > "$out/self-test-$broken.txt" || code=$?
    if [[ $code -ne 0 ]]; then caught=$((caught + 1)); echo "  caught  $broken:"; grep "FAIL" "$out/self-test-$broken.txt" | sed 's/^/      /'
    else echo "  NOT CAUGHT  $broken"; fi
  done
  echo "edit-refresh-check self-test: $caught of $total of 2.4.0's rules caught, $(( $(date +%s) - start )) s"
  [[ $caught -eq $total ]]; exit $?
fi
code=0; run "$out/run" || code=$?
echo "edit-refresh-check: ran $(( $(date +%s) - start )) s, exit $code"
exit $code
