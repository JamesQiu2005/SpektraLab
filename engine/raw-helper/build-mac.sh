#!/bin/bash
# build-mac.sh -- spkraw-host, the Mac app's optional LibRaw RAW decoder, as a standalone helper.
#
#   engine/raw-helper/build-mac.sh [--check]
#
# LibRaw lives in its own executable the way the library SDK does (vendor/spklib): the app never
# links it, it runs `Contents/Helpers/spkraw-host` as a subprocess (one process per decode) and
# reads back the linear ProPhoto pixels it writes (API-SPEC in engine/raw-helper/README.md). A
# crash or a hostile file takes down the helper, not the app.
#
# The decoder is the Windows/Linux v2 line's, byte for byte: `shared/` holds verbatim copies of
# branch SpektraLab_v2's engine/src/io/raw_* and engine/host/white_balance.*, and setup-libraw.sh
# here is its engine/setup-libraw.sh. They are copies, not main's files, because main still builds
# the 1.x Windows/Linux host from LibRaw 0.22.2 (engine/cmake/LibRaw.cmake, .github/workflows/
# desktop.yml); when SpektraLab_v2 merges into main, its files replace main's and `shared/` and this
# setup-libraw.sh are deleted in that commit. The LibRaw tree is v2's pinned master
# (engine/third_party/libraw-pin, identical to v2's), fetched and verified by setup-libraw.sh,
# checked here again file by file against SHA256SUMS before anything is compiled, never patched.
#
# Output: vendor/libraw/macos/spkraw-host (+ .sha256), universal (arm64, x86_64), macOS 13.0 floor,
# and LibRaw's LGPL-2.1 notices beside it. The binary is committed, as spklib-host is, so a build of
# the app (and CI) needs neither the LibRaw source nor this script. `--check` rebuilds into a
# scratch folder and fails if the result's code differs from the committed one in anything but
# its signature (it is rebuilt deterministically: no timestamps, -ffile-prefix-map).
#
# LibRaw is built without OpenMP: Apple's clang ships none, and a third-party libomp would be one
# more runtime to vendor for both slices at the macOS 13 floor. The decode is therefore serial
# (measured in README.md); the app runs it off the main thread.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
eng=$(cd "$here/.." && pwd)
root=$(cd "$eng/.." && pwd)
check=0; [[ "${1:-}" == "--check" ]] && check=1

src=$("$here/setup-libraw.sh" "$root/build/deps" | tail -1)
manifest="$eng/third_party/libraw-pin/SHA256SUMS"
# Every file of the pinned tree, and nothing else (engine/cmake/LibRaw.cmake's rule, here for clang).
( cd "$src" && shasum -a 256 -c --quiet "$manifest" ) || { echo "LibRaw tree at $src is not the pinned one" >&2; exit 1; }
want=$(wc -l < "$manifest" | tr -d ' ')
have=$(cd "$src" && find . -type f ! -path './.git/*' | wc -l | tr -d ' ')
[[ "$want" == "$have" ]] || { echo "LibRaw tree at $src has $have files, the pin $want" >&2; exit 1; }
grep -q '^#define LIBRAW_VERSION_TAIL Snapshot202611' "$src/libraw/libraw_version.h"

out="$root/build/raw-helper-mac"
rm -rf "$out"; mkdir -p "$out"
sdk=$(xcrun --sdk macosx --show-sdk-path)
cxx=$(xcrun --sdk macosx --find clang++)
map=(-ffile-prefix-map="$src"=LibRaw -ffile-prefix-map="$root"=spektralab)
libraw_sources=()
while IFS= read -r f; do libraw_sources+=("$f"); done < <(find "$src/src" -name '*.cpp' ! -name '*_ph.cpp' | LC_ALL=C sort)
ours=("$here/shared/io/raw_decoder.cpp" "$here/shared/io/raw_headroom.cpp" "$here/shared/white_balance.cpp" "$eng/src/core/json.cpp" "$here/main.cpp")

slices=()
for arch in arm64 x86_64; do
  o="$out/obj/$arch"; mkdir -p "$o"
  common=(-arch "$arch" -isysroot "$sdk" -mmacosx-version-min=13.0 -O2 -DLIBRAW_NODLL
          -DSPEKTRALAB_RAW_OPENMP=0 -I"$src" "${map[@]}")
  pids=(); objs=()
  for f in "${libraw_sources[@]}"; do
    obj="$o/libraw_$(echo "${f#$src/src/}" | tr / _ | sed 's/\.cpp$/.o/')"; objs+=("$obj")
    "$cxx" "${common[@]}" -std=c++17 -w -c "$f" -o "$obj" & pids+=($!)
  done
  for f in "${ours[@]}"; do
    obj="$o/spk_$(basename "$f" .cpp).o"; objs+=("$obj")
    "$cxx" "${common[@]}" -std=c++20 -Wall -Wextra -Wno-unused-private-field -I"$here/shared" -I"$eng/src" -c "$f" -o "$obj" & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  "$cxx" -arch "$arch" -isysroot "$sdk" -mmacosx-version-min=13.0 "${objs[@]}" -o "$o/spkraw-host" -Wl,-dead_strip
  slices+=("$o/spkraw-host")
done
xcrun lipo -create "${slices[@]}" -output "$out/spkraw-host"
xcrun strip -x "$out/spkraw-host"
codesign --force --sign - "$out/spkraw-host" 2>/dev/null   # ad hoc, so arm64 can run it here; the app re-signs it
"$out/spkraw-host" version >/dev/null

dest="$root/vendor/libraw/macos"
if [[ $check == 1 ]]; then
  strip_sig() { cp "$1" "$2"; codesign --remove-signature "$2"; }
  strip_sig "$out/spkraw-host" "$out/a"; strip_sig "$dest/spkraw-host" "$out/b"
  cmp -s "$out/a" "$out/b" && echo "spkraw-host: the committed binary is this tree's" && exit 0
  echo "spkraw-host: the committed binary differs from a rebuild of this tree" >&2; exit 1
fi
mkdir -p "$dest"
cp "$out/spkraw-host" "$dest/spkraw-host"
( cd "$dest" && shasum -a 256 spkraw-host > spkraw-host.sha256 )
lic="$root/vendor/libraw"
cp "$src/LICENSE.LGPL" "$lic/LICENSE.LGPL"
cp "$src/COPYRIGHT" "$lic/COPYRIGHT"
commit=$(basename "$src" | sed 's/^LibRaw-//')
cat > "$lic/SOURCE.md" <<EOF
# LibRaw in spkraw-host

\`macos/spkraw-host\` is SpektraLab's RAW decoder helper (engine/raw-helper). It statically links
LibRaw $(sed -n 's/^#define LIBRAW_VERSION_TAIL //p' "$src/libraw/libraw_version.h" | sed 's/^/0.23.0-/'), unmodified, under the LGPL-2.1 option of
LibRaw's LGPL-2.1 / CDDL-1.0 dual licence (\`LICENSE.LGPL\`, \`COPYRIGHT\` here).

- Source: https://github.com/LibRaw/LibRaw, commit \`$commit\`
  (\`engine/third_party/libraw-pin/README.md\` has the tree id and archive checksum).
- Rebuild, with your own LibRaw if you wish: \`engine/raw-helper/build-mac.sh\` (fetches and verifies the
  pinned tree with \`engine/setup-libraw.sh\`; the helper's own source is in \`engine/\`, GPL-3.0-or-later).
- Built universal (arm64, x86_64) for macOS 13.0 and later, without OpenMP.
EOF
echo "spkraw-host -> $dest ($(du -h "$dest/spkraw-host" | cut -f1), $(cat "$dest/spkraw-host.sha256" | cut -c1-16)…)"
