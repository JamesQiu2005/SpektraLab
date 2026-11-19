# spkraw-host — the Mac's optional LibRaw decoder

SpektraLab on the Mac decodes RAW with Apple's decoder (Core Image's `CIRAWFilter`) by default.
From 2.4.2 it can use **LibRaw** instead (Settings → RAW decoder). LibRaw is never linked into the
app: it lives in `Contents/Helpers/spkraw-host`, a standalone executable shipped the way the library
helper is (`vendor/spklib`), and the app runs it once per request.

- **Why a separate binary.** LibRaw parses hostile, undocumented file formats; in its own process a
  crash or a runaway allocation costs one decode, not the session, and all of LibRaw's memory goes back
  to the system when the process exits. It also keeps the LGPL-2.1 component a separate, replaceable
  file (`vendor/libraw/SOURCE.md`).
- **The decoder is the Windows/Linux v2 line's** (branch `SpektraLab_v2`): `shared/` is a verbatim copy
  of that branch's `engine/src/io/raw_*` and `engine/host/white_balance.*`, `setup-libraw.sh` here is its
  `engine/setup-libraw.sh`, and the LibRaw tree is the same pin (`engine/third_party/libraw-pin`, upstream
  master `42f89c16`, `0.23.0-Snapshot202611`). They are copies because `main` still builds the 1.x
  Windows/Linux host from LibRaw 0.22.2 out of `engine/src/io` and `engine/cmake/LibRaw.cmake`, which this
  helper leaves untouched. When `SpektraLab_v2` merges into `main`, its files replace those, and `shared/`
  and this `setup-libraw.sh` go in the same commit. Until then a fix to the decoder belongs on both lines.
- **Colour differs from the system decoder, by design.** LibRaw's camera matrices, demosaic (AHD) and
  highlight handling are not Apple's, so the same frame renders differently, and release-gate pictures
  taken with LibRaw do not match those taken with the system decoder. The exposure is the same, give or take
  a few tenths of a stop: the app hands the helper the file's baseline exposure as `--scale`.

## Build

```bash
engine/raw-helper/build-mac.sh          # -> vendor/libraw/macos/spkraw-host (+ .sha256), LibRaw notices
engine/raw-helper/build-mac.sh --check  # rebuild into build/ and compare with the committed binary
```

Universal (arm64, x86_64), macOS 13.0 floor, no OpenMP (Apple's clang has none). Measured 2026-11-18
on the Mac mini (M-series, otherwise idle): a 45.7 MP Nikon Z 7II NEF decodes in **1.27 s** wall,
1.29 GB peak RSS in the helper. The binary is committed, so building the app needs neither LibRaw
nor this script; the app's build phase copies it into `Contents/Helpers` and signs it with the app.

## Protocol (version 1)

Every command prints exactly one JSON object on stdout and exits 0 on success; on failure it prints
`{"ok": false, "error": <code>, "message": <text>}` and exits 2. Codes: `bad_request`, `unsupported`
(LibRaw cannot open this file or this white balance), `decode_failed`, `io`, `internal`. Any other exit
(a signal) is a crash, and the app reports it as a failed decode.

| command | reply |
|---|---|
| `version` | `protocol`, `libraw` (version string), `cameras` (LibRaw's camera count) |
| `probe <raw>` | `width`, `height` (oriented), `camera`, `sizes` (`raw`, `visible`, `margins`, `inset_crops`) |
| `decode <raw> <out.f32> [--mode compatible16\|headroom] [--temperature K --tint T] [--rgba] [--scale s] [--crop camera]` | `width`, `height`, `mode`, `channels`, `scale`, `crop`, `libraw`, `decoder`, `camera`, `white_level`, `black_level`, `calibration`, `timings` |
| `neutral` (stdin: `{"calibration": <a decode's>, "rgb": [r, g, b]}`) | `temperature`, `tint` for that linear ProPhoto pixel |

`camera` is `make`, `model`, `lens`, `iso`, `shutter_s`, `aperture`, `focal_mm`, `colors`,
`orientation` (EXIF 1–8) and, where the camera has an XYZ matrix, `as_shot` `{temperature, tint}`
(the DNG SDK's Kelvin/tint scale, from LibRaw's D65 matrix — `engine/host/white_balance.hpp`).

**`decode`** creates `<out.f32>` (it must not exist: the helper opens it `O_EXCL`) and writes
`width × height × 3` float32 in native byte order, packed RGB, top row first, orientation applied,
**linear ProPhoto RGB** (ROMM primaries, D50, gamma 1). `compatible16` (the default) is LibRaw's 16-bit
output scaled to [0, 1]; `headroom` (conventional Bayer only, refused otherwise) keeps values above 1
and below 0. `--temperature`/`--tint` replace the as-shot white balance with LibRaw multipliers for
that illuminant. `--rgba` writes four floats a pixel (alpha 1: Core Image's RGBAf, which the app maps as
it is), `--scale` multiplies every value (the app's decoder exposure, 2^`sourceOffsetEV`), and `--crop camera`
cuts LibRaw's first inset crop — the camera's default crop, a DNG's DefaultCrop — out of the visible area,
through the frame's orientation (`crop.applied` false where the crop is absent or does not fit). That crop
is Core Image's frame to a pixel or two (all 11 bodies of `RAW_decode_tests`, 2026-11-18); the app makes up
the last pixels (`LibRawDecode.appleSize`). The full decode contract is `engine/WINDOWS_NATIVE_RAW.md` on the
Windows line.

## Checked by

`app/SpektraLab/tools/libraw_decode_check.sh` (a self-test, `libraw_decode_check`): over `RAW_decode_tests`,
every file through the app's own `RawExposure.prepare` with LibRaw chosen — decoded by LibRaw, Core Image's
frame to the pixel, its orientation (log-luminance correlation with Core Image's decode ≥ 0.80; turned over,
every row fails), its exposure within ±0.5 EV of Core Image's (the app applies the file's baseline exposure, which
LibRaw does not: measured −0.44…+0.03 EV, most within 0.15), a custom white balance that warms, the neutral
pick in one decode; Apple's keys unchanged; and with no helper, Core Image's decode. 2026-11-18: 22 of 23 files
(the iPhone's JPEG XL DNG is Core Image's: LibRaw has no JPEG XL).
