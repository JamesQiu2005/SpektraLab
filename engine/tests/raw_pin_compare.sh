#!/usr/bin/env bash
# raw_pin_compare.sh -- T-A2: the previous LibRaw pin against the current one.
#
#   SPEKTRALAB_RAW_FIXTURES=<folder> engine/tests/raw_pin_compare.sh [work-dir]
#
# Builds raw_pin_compare/ (spk::io's decoder and LibRaw, nothing else) twice
# with the same compiler and flags:
#   old  engine/src/io and engine/setup-libraw.sh + third_party/libraw-arw6 as
#        they were at SPEKTRALAB_RAW_OLD_PIN_COMMIT (default 1aa6f4d8, the
#        Windows v1 line: LibRaw 0.22.2 + the ARW 6 overlay + raw_camera.hpp's
#        matrices), extracted with `git archive` and set up by that commit's
#        own script, which verifies its tree exactly as it always did;
#   new  this checkout's engine/src/io against the tree engine/setup-libraw.sh
#        verifies;
# then runs `raw_fixtures.py compare`, which decodes every fixture with both
# and holds each file to its row's `pin` expectation. Frames are written to
# <work-dir>/frames one at a time and deleted after each comparison.
# Default work dir: <repo>/build/raw-pin-compare. Exit status 0 only if every
# check passed. Needs cmake, ninja, a C++20 compiler and git (for the archive).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="${1:-$repo/build/raw-pin-compare}"
deps="${SPEKTRALAB_DEPS_DIR:-$repo/build/deps}"
old_commit="${SPEKTRALAB_RAW_OLD_PIN_COMMIT:-1aa6f4d8}"
[[ -n "${SPEKTRALAB_RAW_FIXTURES:-}" ]] || { echo "FAIL SPEKTRALAB_RAW_FIXTURES is not set" >&2; exit 1; }
mkdir -p "$work" "$deps"

# The previous pin, from its own commit.
rm -rf "$work/old-src"
mkdir -p "$work/old-src"
git -C "$repo" archive "$old_commit" engine/setup-libraw.sh engine/third_party/libraw-arw6 engine/src/io \
  | tar -x -C "$work/old-src"
old_libraw="$("$work/old-src/engine/setup-libraw.sh" "$deps" | tail -n 1)"
new_libraw="$("$repo/engine/setup-libraw.sh" "$deps" | tail -n 1)"
echo "old pin: $old_libraw" >&2
echo "new pin: $new_libraw" >&2

build() {   # name engine-src libraw
  cmake -S "$here/raw_pin_compare" -B "$work/$1" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DSPK_ENGINE_SRC="$2" -DSPK_LIBRAW_SOURCE="$3" >/dev/null
  ninja -C "$work/$1" >/dev/null
}
build old "$work/old-src/engine/src" "$old_libraw"
build new "$repo/engine/src" "$new_libraw"

python3 "$here/raw_fixtures.py" compare --old "$work/old" --new "$work/new" \
  --scratch "$work/frames" --report "$work/report.json"
