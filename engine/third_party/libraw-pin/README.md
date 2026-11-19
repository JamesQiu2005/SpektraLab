# The LibRaw pin

The Windows/Linux native RAW path (`engine/src/io/raw_*`, through `spektralab-host`) compiles LibRaw
from one exact upstream tree. Nothing of LibRaw's is vendored in this repository: the setup scripts
fetch it into the gitignored `build/deps/`, and this folder holds only what proves it is the right tree.

| | |
|---|---|
| upstream | <https://github.com/LibRaw/LibRaw>, branch `master` |
| commit | `42f89c165763272a5482a254c446337f8048e0df` ("Planebuf limit: change bytes to items", 2026-11-16), the master head on 2026-11-17 |
| tree | `865b3ac461d5b734e5bc54683e914ff8dd82b7da` |
| reports itself as | `0.23.0-Snapshot202611` (`LibRaw::version()`) |
| archive | `https://codeload.github.com/LibRaw/LibRaw/zip/<commit>`, SHA-256 `95a5c092fd12c16359b8a13afac58bf1b4aaad50e27d2c9221f275c496b79ca2` (downloaded twice on 2026-11-17, identical) |
| licence | LGPL-2.1 or CDDL-1.0; SpektraLab takes the LGPL-2.1 option and stages `LICENSE.LGPL`, `COPYRIGHT` and a `LibRaw-SOURCE.txt` naming this commit |

## Why master and not a release

LibRaw's release tags stop at 0.22.3 (bug fixes cherry-picked onto the 0.22 branch). Every body the
product needed for modern cameras is only on master: the Sony ARW 6 lossy decoder and the A7 V
(`ILCE-7M5`), the Canon EOS R6 Mark III colour data and CR3 ColorData 66, the Fujifilm GFX 100RF and
X-E5 tables, the Panasonic DC-S1 II, and a Nikon HE/HE\* decoder (`src/decoders/nikonhe.cpp`, new in
snapshot 202611). The snapshot's Changelog lists every fix the 0.22.1, 0.22.2 and 0.22.3 releases
carry (the TALOS-2026 fixes included), so taking master gives up none of them.

## What this folder holds

- `SHA256SUMS` -- the SHA-256 of every file of the pinned tree (227 files), in `sha256sum` format.
  `engine/cmake/LibRaw.cmake` checks the tree it is pointed at against it at configure time and stops on
  any missing, extra or edited file, before a single LibRaw object is compiled. A git checkout's own
  `.git/` is not part of the comparison.
- This README.

The setup scripts check the tree independently: `setup-libraw.sh` checks the archive's SHA-256 *and*
recomputes the git tree id from the archive's entries before extracting (or, without codeload.github.com,
fetches the commit with git and checks commit and tree id), then compares every extracted file with the
archive; `setup-libraw.ps1` checks the same archive SHA-256 and compares every file. Both refuse an
existing tree that differs and never repair it. `engine/tests/raw_pin_guard.sh` shows each of those
refusals happening (T-A3) and that the four places naming the pin agree.

## The overlay that was here

Until 2026-11-17 the pin was the 0.22.2 release plus a tracked overlay, `engine/third_party/libraw-arw6/`:
twelve files backporting the Sony ARW 6 decoder, the A7 V camera id, crop and colour matrix, the EOS R6
Mark III matrix and the Canon CR3 ColorData subversion 66 white balance. The pinned master carries all
of it (the decoder differs from the backport only in its copyright comment), so the overlay was removed
whole, and with it the CMake guard that refused a tree without it. Nothing of LibRaw is patched now.

SpektraLab's own camera table (`engine/src/io/raw_camera.hpp`, an `adobe_coeff` override lending the
GFX100RF the GFX 100 II matrix and the X-E5 the X-H2 one) went the same way: master has both entries
with those coefficients. `engine/tests/raw_camera.cpp` now holds the pinned LibRaw to them.

The evidence -- every fixture through both pins, pixel by pixel -- is in `RAW-SUPPORT-20261117.md`.

## Moving the pin

1. Pick the new commit; download its zip twice and compare the SHA-256; compute its tree id.
2. Change the commit, tree and SHA-256 in `setup-libraw.sh`, `setup-libraw.ps1` and
   `cmake/LibRaw.cmake` (and the version macros there if they moved), and the directory name in
   `build-windows.ps1`, `windows_UI/build.ps1` and `.github/workflows/desktop.yml`.
3. Regenerate `SHA256SUMS` from the verified tree:
   `(cd build/deps/LibRaw-<commit> && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"; done) > engine/third_party/libraw-pin/SHA256SUMS`
4. Run `engine/tests/raw_gate.sh` with `SPEKTRALAB_RAW_FIXTURES` set, update the expected-outcome table
   in `engine/tests/raw_fixtures.py` and the pin comparison in `engine/tests/raw_pin_compare.sh` with
   what changed and why, and write the dated RAW note.
