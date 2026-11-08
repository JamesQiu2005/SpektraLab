# CAM16 setup artifacts

These six native-endian float64 C_max tables were generated from this engine's
unchanged profile/colour constants and the 64 × 720 × 18 bisection. They contain
276,480 cells in total, not approximations or lower-precision LUTs. Metadata in
each file covers the output space, matrices, viewing conditions, grids, search
bounds, tolerance and algorithm revision; the payload carries an FNV-1a checksum.
Unsupported metadata/architecture, missing files and damaged files fall back to
computing exactly the same table. No runtime writes occur.

Regenerate explicitly with `engine/build.sh cam16`. Ordinary builds simply copy
the tracked files. `engine/tests/cam16_bake_checks.cpp` compares every loaded cell
against computation and exercises invalid metadata, checksum, length and values.
Update the format/algorithm revision in `src/core/cam16_bake.hpp` whenever the
inverse, gamut test or search semantics change. Rebuild after changing the colour
constants; runtime metadata validation prevents stale artifacts being used.
