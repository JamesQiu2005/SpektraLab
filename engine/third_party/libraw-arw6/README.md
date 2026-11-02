# LibRaw ARW 6 overlay

This directory is a small, tracked overlay applied on top of the pinned,
unmodified [LibRaw 0.22.2](https://github.com/LibRaw/LibRaw/releases/tag/0.22.2)
source tree by `engine/setup-libraw.ps1` and `engine/setup-libraw.sh`.

It exists because LibRaw 0.22.2 cannot decode Sony ARW 6.0 lossy RAW, including
the "Compressed" and "Compressed (HQ)" modes used by the Sony A7 V
(`ILCE-7M5`). Apple's Core Image raw support also returns no image for these
files. Upstream LibRaw added the decoder and camera metadata after 0.22.2, but
moving to an upstream snapshot would also drop fixes that are only in 0.22.2.
This overlay backports only the ARW 6 support.

## Contents

Files are stored under `files/` at their path relative to the LibRaw source
root:

| Path | Purpose |
|---|---|
| `src/decoders/sony_arw6.cpp` | Sony ARW 6 lossy CRAW decoder (new file) |
| `internal/libraw_internal_funcs.h` | Declares `sony_arw6_load_raw()` |
| `src/metadata/tiff.cpp` | Selects the decoder for TIFF compression 32766 |
| `src/utils/open.cpp` | ARW 6 black, saturation and linear maximum defaults |
| `src/utils/decoder_info.cpp` | Reports the ARW 6 decoder |
| `internal/libraw_cameraids.h` | Sony `ILCE-7M5` camera id |
| `src/metadata/sony.cpp` | A7 V body features / Sony 0x9050 layout |
| `src/metadata/normalize_model.cpp` | Normalised `ILCE-7M5` model name |
| `src/metadata/identify.cpp` | A7 V crop dimensions |
| `src/tables/cameralist.cpp` | A7 V camera-list entry |
| `src/tables/colordata.cpp` | A7 V colour matrix |

The overlay intentionally does not change LibRaw's version number or public
headers. `LibRaw::version()` still reports 0.22.2, as required by the build
version guard and the reported dependency provenance.

## Upstream provenance

The ARW 6 decoder was backported from upstream LibRaw master, whose relevant
commits include:

- `47ea701a07c5` — Add Jiangtherapee Sony ARW6 CRAW HQ decoder
- `f3c7d070c2bb` — Allow Sony ARW6 stream version 1
- `93b0a2d9366a` — Support tiled Sony ARW6 CRAW HQ streams
- `1fa7855cf2ae` — Match Adobe highlight handling in Sony ARW6 decoder
- `fd71ca742b6d` — Handle non-16-aligned ARW6 heights
- `093cdeaae323` — Do not gate ARW6 streams on sequence value
- `9c039a14bfb1` — Add decoder credit

Sony A7 V identification and colour metadata came from upstream commit
`8eb3433879bd` and its follow-ups. The backport was assembled against the
0.22.2 tree rather than copied wholesale, because 0.22.2 and upstream master
have diverged.

The decoder is Copyright 2026 LibRaw LLC and Jiang Yaogeng, distributed under
LibRaw's LGPL-2.1 / CDDL-1.0 dual licence. The overlay carries the same licence
as the rest of LibRaw; the build deploys `LICENSE.LGPL` and `COPYRIGHT` from
the pinned source tree.

## Validation

The overlaid 0.22.2 tree was compiled with Clang 23.1 (LLVM-MinGW UCRT) and
used to decode:

- Sony A7 V `ILCE-7M5` full-frame "Compressed (HQ)" (`KIN00626.ARW`):
  7040×4688 stored, 7028×4688 cropped, `sony_arw6_load_raw()`, no unpack error;
- Sony A7 V full-frame "Compressed" and APS-C "Compressed"/"Compressed (HQ)";
- Sony A7 V lossless-compressed files through the existing
  `sony_ljpeg_load_raw()` path;
- six Sony A7R VI (`ILCE-7RM6`) ARW 6 samples, including the two files that
  failed with intermediate upstream ARW 6 revisions.

Pixel statistics and rendered output were checked for plausible exposure,
white balance and geometry; the A7 V result was also inspected visually. This
is sample-level validation, not a guarantee for every ARW 6 camera or mode.

## Maintenance

When the pinned LibRaw release is upgraded, re-evaluate this overlay. Remove
any file that is no longer different from the new upstream release, and rerun
both setup scripts plus the Windows RAW tests. The setup scripts verify every
non-overlay file against the pinned archive and every overlay file against this
directory before copying, so a partially applied or locally modified tree is
rejected rather than silently accepted.
