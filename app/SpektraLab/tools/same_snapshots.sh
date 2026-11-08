#!/bin/bash
# same_snapshots.sh -- two folders of snapshots, held against each other: are the pages the same pictures?
#
#   tools/same_snapshots.sh <before-dir> <after-dir> [ID ...]
#
# For a change that must not move a pixel of a page (the landscape plumbing, 2026-10-09: the harness
# learnt a window on its side and its safe area, and no upright page may show it). Each PNG the two
# folders share -- or each ID named -- is compared byte for byte; where the bytes differ,
# `tools/exactdiff.swift` counts every pixel that differs at all and by how much at most.
#
# **Two runs of one build are nearly always the same files, and not always.** Measured on 2026-10-09 over
# some twenty-five batches of seven pages, in one simulator:
#   - the first batch drawn after the simulator booted (the unchanged build, 6608783) differed from every
#     later run of that build where a photograph is scaled into the page: B2 in 16 to 34 px of a million
#     and C1 in 5, each by 1 of 255;
#   - C1 with its panel folded came out with 390 px of 1.3 million (397 at 375 x 667) differing by up to 8
#     of 255, spread over the photograph, in three batches: once on the unchanged build and twice on the
#     one after it. No part of the page moves there -- `imgdiff` finds no pixel past its own threshold --
#     and the next batch was byte for byte the usual one. Which decode of the photograph the page is
#     caught with is the likely cause; it was not run down.
# So: a page that differs by one level in no more than 100 pixels is said to differ as a cold run does,
# and is not held to be another picture. Anything more is reported as another picture, with
# `tools/imgdiff.swift`'s |a - b| written to <after-dir>/diff-<id>.png, and this exits 1 -- **draw the
# batch again before believing it**: a part that has really moved is there every time.
#
# Draw the pages with `tools/snapshot.sh --out <dir>` before the change and after it, at the same
# `--size`, in the same simulator.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[[ $# -ge 2 ]] || { echo "usage: same_snapshots.sh <before-dir> <after-dir> [ID ...]"; exit 2; }
before="$1"; after="$2"; shift 2
tools="$here/build/tools"
mkdir -p "$tools"
for t in imgdiff exactdiff; do
  if [[ ! -x "$tools/$t" || "$here/tools/$t.swift" -nt "$tools/$t" ]]; then
    swiftc -O "$here/tools/$t.swift" -o "$tools/$t" 2> "$tools/$t.log" || { cat "$tools/$t.log"; exit 1; }
  fi
done
ids=("$@")
if [[ ${#ids[@]} -eq 0 ]]; then
  while IFS= read -r f; do ids+=("$(basename "$f" .png)"); done < <(find "$before" -maxdepth 1 -name '*.png' ! -name 'diff-*' | sort)
fi
same=0; near=0; differ=0
for id in "${ids[@]}"; do
  a="$before/$id.png"; b="$after/$id.png"
  if [[ ! -f "$a" || ! -f "$b" ]]; then
    echo "$id: missing $([[ -f "$a" ]] && echo "after" || echo "before")"
    differ=$((differ + 1))
    continue
  fi
  if cmp -s "$a" "$b"; then
    echo "$id: the same file, byte for byte"
    same=$((same + 1))
    continue
  fi
  line=$("$tools/exactdiff" "$a" "$b") && rc=0 || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "$id: the same picture ($line)"
    same=$((same + 1))
  elif [[ $rc -eq 1 && "$line" =~ ^([0-9]+)\ of\ [0-9]+\ px\ differ,\ by\ ([0-9]+)\  && ${BASH_REMATCH[2]} -le 1 && ${BASH_REMATCH[1]} -le 100 ]]; then
    echo "$id: $line -- as a simulator's first run after it boots differs from its later ones"
    near=$((near + 1))
  else
    echo "$id: ANOTHER PICTURE: $line"
    "$tools/imgdiff" "$a" "$b" "$after/diff-$id.png" | sed "s/^/$id:   /"
    differ=$((differ + 1))
  fi
done
echo "same snapshots: $same the same to the pixel, $near a level apart in a few pixels, $differ another picture ($before | $after)"
[[ $differ -eq 0 ]] || echo "another picture: draw the batch again before believing it (this tool's own header says why)"
[[ $differ -eq 0 ]]
