#!/usr/bin/env bash
# raw_pin_guard.sh -- T-A3: the LibRaw pin guards can fire.
#
#   engine/tests/raw_pin_guard.sh [work-dir]      (default <repo>/build/raw-pin-guard)
#
# 1. The four places that name the pin agree: setup-libraw.sh, setup-libraw.ps1,
#    cmake/LibRaw.cmake (commit, tree, archive SHA-256) and the directory the
#    Windows build scripts expect.
# 2. setup-libraw.sh, on scratch copies of the verified tree and archive:
#    accepts the untouched copy (the control), and refuses an edited file, an
#    added file, a removed file, an archive with one byte changed, and a git
#    checkout of another commit -- each with its own message.
# 3. cmake/LibRaw.cmake, configured against scratch trees: accepts the untouched
#    tree (the control), and refuses another version (libraw_version.h says
#    0.22.2), an edited file, an added file and a removed file.
# Nothing here touches the real build/deps tree. setup-libraw.ps1 is checked
# for its pin only: there is no PowerShell on this Mac to run it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
engine="$(cd "$here/.." && pwd)"
repo="$(cd "$engine/.." && pwd)"
work="${1:-$repo/build/raw-pin-guard}"
deps="${SPEKTRALAB_DEPS_DIR:-$repo/build/deps}"
failures=0
ok()   { echo "ok   $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }

# --- 1. one pin, everywhere -----------------------------------------------------------------
value() { sed -n -E "s/^$2=([0-9a-f]+)\$/\\1/p" "$1" | head -n 1; }
commit="$(value "$engine/setup-libraw.sh" git_commit)"
tree="$(value "$engine/setup-libraw.sh" git_tree)"
zipsha="$(value "$engine/setup-libraw.sh" zip_sha256)"
[[ ${#commit} == 40 && ${#tree} == 40 && ${#zipsha} == 64 ]] && ok "setup-libraw.sh names a commit, a tree and a SHA-256" \
  || fail "setup-libraw.sh pin unreadable ($commit / $tree / $zipsha)"
ps1="$engine/setup-libraw.ps1"
grep -q "^\$commit = '$commit'\$" "$ps1" && grep -q "^\$tree = '$tree'\$" "$ps1" && grep -q "^\$expected = '$zipsha'\$" "$ps1" \
  && ok "setup-libraw.ps1 has the same commit, tree and SHA-256" || fail "setup-libraw.ps1 pin differs from setup-libraw.sh"
cm="$engine/cmake/LibRaw.cmake"
grep -q "^set(SPEKTRALAB_LIBRAW_COMMIT $commit)\$" "$cm" && grep -q "^set(SPEKTRALAB_LIBRAW_TREE $tree)\$" "$cm" \
  && ok "cmake/LibRaw.cmake has the same commit and tree" || fail "cmake/LibRaw.cmake pin differs from setup-libraw.sh"
for f in "$engine/build-windows.ps1" "$repo/windows_UI/build.ps1" "$repo/.github/workflows/desktop.yml"; do
  if grep -q "LibRaw-0\.22" "$f" || ! grep -q "LibRaw-$commit" "$f"; then
    fail "${f#$repo/} does not name LibRaw-$commit"
  else
    ok "${f#$repo/} names LibRaw-$commit"
  fi
done

# --- 2. the setup script --------------------------------------------------------------------
source_dir="$("$engine/setup-libraw.sh" "$deps" | tail -n 1)"
archive="$deps/LibRaw-$commit.zip"
[[ -f "$archive" && -d "$source_dir" ]] || { fail "the verified LibRaw tree and archive are not in $deps"; exit 1; }
rm -rf "$work"
mkdir -p "$work"
fresh() {   # a scratch deps dir holding a copy of the verified tree and archive
  rm -rf "$work/deps"
  mkdir -p "$work/deps"
  cp "$archive" "$work/deps/"
  cp -R "$source_dir" "$work/deps/"
}
refuses() {   # label expected-message: setup-libraw.sh must fail and say why
  local out
  if out="$("$engine/setup-libraw.sh" "$work/deps" 2>&1)"; then
    fail "setup-libraw.sh accepted $1"
  elif grep -q "$2" <<<"$out"; then
    ok "setup-libraw.sh refuses $1 ($(grep "$2" <<<"$out" | head -n 1 | sed "s|$work/||g"))"
  else
    fail "setup-libraw.sh refused $1 for another reason: $out"
  fi
}
fresh
if out="$("$engine/setup-libraw.sh" "$work/deps" 2>&1)" && [[ "$(tail -n 1 <<<"$out")" == "$work/deps/LibRaw-$commit" ]]; then
  ok "setup-libraw.sh accepts an untouched copy (control)"
else
  fail "setup-libraw.sh rejected an untouched copy: $out"
fi
victim="src/decoders/sony_arw6.cpp"
fresh; printf '\n// local patch\n' >> "$work/deps/LibRaw-$commit/$victim"
refuses "an edited file" "Modified LibRaw source file"
fresh; echo x > "$work/deps/LibRaw-$commit/src/extra.cpp"
refuses "an added file" "Unexpected file in pinned LibRaw source"
fresh; rm "$work/deps/LibRaw-$commit/src/decoders/nikonhe.cpp"
refuses "a removed file" "Incomplete LibRaw source tree"
fresh; rm -rf "$work/deps/LibRaw-$commit"
python3 - "$work/deps/LibRaw-$commit.zip" <<'PY'
import sys
p = sys.argv[1]; b = bytearray(open(p, 'rb').read()); b[len(b) // 2] ^= 0x01; open(p, 'wb').write(bytes(b))
PY
refuses "an archive with one byte changed" "checksum mismatch"
[[ ! -e "$work/deps/LibRaw-$commit" ]] && ok "nothing was extracted from the bad archive" || fail "the bad archive was extracted"
# A git checkout of another commit: the same commit id check the git fallback uses.
fresh; rm -rf "$work/deps/LibRaw-$commit"; mkdir -p "$work/deps/LibRaw-$commit"
cp -R "$source_dir/." "$work/deps/LibRaw-$commit/"
(cd "$work/deps/LibRaw-$commit" && git init -q && git add -A && git -c user.name=guard -c user.email=guard@invalid commit -qm other)
refuses "a git checkout of another commit" "is not the pinned commit"

# --- 3. the CMake check ---------------------------------------------------------------------
mkdir -p "$work/cmake"
cat > "$work/cmake/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.20)
project(libraw_pin_guard CXX)
set(SPEKTRALAB_DEPS_DIR "\${CMAKE_CURRENT_BINARY_DIR}/unused")
set(SPEKTRALAB_LIBRAW_OPENMP OFF CACHE BOOL "" FORCE)
include("$engine/cmake/LibRaw.cmake")
EOF
tree_copy() {
  rm -rf "$work/tree"
  cp -R "$source_dir" "$work/tree"
}
configure() { cmake -S "$work/cmake" -B "$work/cmake-build" -DSPEKTRALAB_LIBRAW_SOURCE="$work/tree" 2>&1; }
cmake_refuses() {   # label expected-message
  local out
  rm -rf "$work/cmake-build"
  if out="$(configure)"; then
    fail "cmake/LibRaw.cmake accepted $1"
  elif grep -q "$2" <<<"$out"; then
    ok "cmake/LibRaw.cmake refuses $1"
  else
    fail "cmake/LibRaw.cmake refused $1 for another reason: $(grep -A3 'CMake Error' <<<"$out" | head -n 6)"
  fi
}
tree_copy; rm -rf "$work/cmake-build"
if out="$(configure)"; then ok "cmake/LibRaw.cmake accepts the pinned tree (control)"; else fail "cmake/LibRaw.cmake rejected the pinned tree: $out"; fi
tree_copy
sed -i.bak -e 's/^#define LIBRAW_MINOR_VERSION 23$/#define LIBRAW_MINOR_VERSION 22/' \
           -e 's/^#define LIBRAW_PATCH_VERSION 0$/#define LIBRAW_PATCH_VERSION 2/' \
           -e 's/^#define LIBRAW_VERSION_TAIL Snapshot202611$/#define LIBRAW_VERSION_TAIL Release/' "$work/tree/libraw/libraw_version.h"
rm -f "$work/tree/libraw/libraw_version.h.bak"
cmake_refuses "a tree that says it is 0.22.2" "is a different version"
tree_copy; printf '\n// local patch\n' >> "$work/tree/$victim"
cmake_refuses "an edited file" "differs from the pinned"
tree_copy; echo x > "$work/tree/src/extra.cpp"
cmake_refuses "an added file" "Unexpected file in the pinned LibRaw tree"
tree_copy; rm "$work/tree/src/decoders/nikonhe.cpp"
cmake_refuses "a removed file" "is missing src/decoders/nikonhe.cpp"

rm -rf "$work"
echo
echo "$failures failure(s)"
[[ $failures == 0 ]]
