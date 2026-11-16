#!/bin/bash
# hdr_latch_selftest.sh -- the canvas left on an older picture (issue #123): HDRLatch and Layer2DisplaySizes with
# stand-in passes (tools/hdr_latch_selftest.swift). --self-test also builds the test on 2.4.0's rules
# (tools/hdr_latch_2_4_0.swift, tools/layer2_display_2_4_0.swift, compiled in place of this tree's) and passes only when
# every HELD case is red there and every CONTROL green on both.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/tools"
mkdir -p "$out"
src="$here/Sources"
build() {  # build <latch> <sizes> <binary>
  swiftc -Onone -parse-as-library "$1" "$2" "$here/tools/hdr_latch_selftest.swift" -o "$3" 2> "$3.build.log" \
    || { grep -E "error" "$3.build.log" | head -30; return 1; }
}
build "$src/Features/Develop/HDRLatch.swift" "$src/Engine/Layer2DisplaySizes.swift" "$out/hdr_latch_selftest"
if [[ "${1:-}" != "--self-test" ]]; then
  "$out/hdr_latch_selftest"
  exit $?
fi
"$out/hdr_latch_selftest" > "$out/hdr-latch-now.log" || { cat "$out/hdr-latch-now.log"; echo "hdr latch self-test: this tree's rules fail"; exit 1; }
build "$here/tools/hdr_latch_2_4_0.swift" "$here/tools/layer2_display_2_4_0.swift" "$out/hdr_latch_selftest_2_4_0"
"$out/hdr_latch_selftest_2_4_0" > "$out/hdr-latch-2.4.0.log" || true
status=0; caught=0; held=0
while read -r mark id rest; do
  id=${id%:}
  case "$id" in
    held-*) held=$((held + 1))
            if [[ "$mark" == "FAIL" ]]; then caught=$((caught + 1)); echo "  caught  $id on 2.4.0:${rest:+ $rest}"
            else echo "  NOT CAUGHT  $id: passes on 2.4.0's rules"; status=1; fi ;;
    control-*) [[ "$mark" == "ok" ]] || { echo "  CONTROL $id fails on 2.4.0's rules: the case is wrong, not the rules"; status=1; } ;;
  esac
done < <(grep -E "^(ok|FAIL) " "$out/hdr-latch-2.4.0.log")
echo "hdr latch self-test: $caught of $held held cases red on 2.4.0's rules, all green on this tree's"
exit $status
