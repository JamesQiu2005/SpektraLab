# RAW support on Windows/Linux -- 2026-11-17

Replaces `RAW-SUPPORT-20261029.md`'s claims for the Windows/Linux native host (`spektralab-host`,
`engine/src/io/raw_*`). The macOS app decodes RAW through Core Image and is not covered here.

## The LibRaw pin

| | |
|---|---|
| LibRaw | upstream **master** `42f89c165763272a5482a254c446337f8048e0df` (2026-11-16, the master head on 2026-11-17), git tree `865b3ac461d5b734e5bc54683e914ff8dd82b7da`; reports `0.23.0-Snapshot202611` |
| archive | `https://codeload.github.com/LibRaw/LibRaw/zip/<commit>`, SHA-256 `95a5c092fd12c16359b8a13afac58bf1b4aaad50e27d2c9221f275c496b79ca2` |
| verified by | `engine/setup-libraw.sh` (archive SHA-256 and the tree id recomputed from its entries, or git commit + tree id; every file), `engine/setup-libraw.ps1` (archive SHA-256, every file), `engine/cmake/LibRaw.cmake` (version macros and all 227 files against `engine/third_party/libraw-pin/SHA256SUMS`) |
| patched | nothing. The 0.22.2 overlay (`engine/third_party/libraw-arw6/`, 12 files) is removed: master carries the ARW 6 decoder (identical but for its copyright comment), the A7 V id, crop and matrix, the EOS R6 Mark III matrix and CR3 ColorData 66. SpektraLab's own camera table (`raw_camera.hpp`'s GFX100RF / X-E5 matrices) is removed too: master has both, with the same coefficients |
| licence | LGPL-2.1 option of LibRaw's LGPL-2.1 / CDDL-1.0; `LICENSE.LGPL`, `COPYRIGHT` and `LibRaw-SOURCE.txt` (the commit) are staged with the host |
| previous pin | LibRaw 0.22.2 + the ARW 6 overlay + `raw_camera.hpp`'s matrices (the Windows v1 line, `1aa6f4d8`) |

Why master: release tags stop at 0.22.3. The snapshot's Changelog lists every fix 0.22.1-0.22.3
carry (the TALOS-2026 fixes among them) and adds Nikon HE/HE\* decoding, the Panasonic DC-S1 II, Sony
ILCE-7M5 / 7RM6, Canon EOS R6 Mark III, Fujifilm GFX 100RF / X-E5 and others.

## What was decoded here

Every RAW file of the fixture folder (22 files, ten cameras), through the native host on this Mac
(MoltenVK; `engine/tests/raw_fixtures.py host`: probe, thumbnail, open in `compatible16` and
`headroom`, a `render_view` of each) and through the decoder alone with both pins
(`engine/tests/raw_pin_compare.sh`: the linear frame, every sample). The pixel difference is
`max |old - new|` over every sample of the linear frame, in LibRaw's [0, 1] scale (1/65535 = one
16-bit code); both modes were compared and agree unless noted.

| file | camera | decoder | previous pin | this pin | pixel difference |
|---|---|---|---|---|---|
| A7m3/DSC03710.ARW, DSC03733.ARW | Sony ILCE-7M3 | `sony_arw2_load_raw` | decoded | decoded, 6024x4024 | 0 (bit-identical) |
| A7V/5676846937.arw | Sony ILCE-7M5 (A7 V), lossless | `sony_ljpeg_load_raw` | decoded (overlay) | decoded, 4688x7028, orientation 8 | 0 |
| A7V/9218571104.arw | Sony ILCE-7M5 (A7 V), ARW 6 "Compressed" | `sony_arw6_load_raw` | decoded (overlay) | decoded, 4688x7028, orientation 8 | 0 |
| DNG RAW/IMG_9826.DNG | Apple iPhone 17 Pro (`iPhone18,1`), ProRAW: DNG 1.7, JPEG XL (compression 52546) | -- | **refused** | **refused**: `decode_failed`, "RAW unpack: Unsupported file format or not RAW file (-2)". LibRaw decodes JPEG XL DNG only when built with Adobe's DNG SDK, which this build is not. Probe and the embedded preview work | -- |
| DNG RAW/R0030139.DNG | Ricoh GR II | `lossless_dng_load_raw` | decoded | decoded, 4944x3280 | 0 |
| EOS R6iii/8153398483.cr3 | Canon EOS R6 Mark III | `crxLoadRaw` | decoded (overlay), 4639x6959 | decoded, **4664x6986**, orientation 8 | the crop changed: master keeps 25 x 27 more of the sensor (visible area at margins 158,96 instead of 172,108). The old frame sits at (12, 13) inside the new one, and that overlap (less an 8 px band) is bit-identical in both modes; the extra border is picture, not masked pixels |
| GFX100RF/DSCF1220.RAF | Fujifilm GFX100RF, 102 MP | `unpacked_load_raw` | decoded (raw_camera.hpp's matrix) | decoded, 11662x8746, upstream's matrix | 0 -- the reason the override could go |
| Leica Q3/L1026319, L1026321 .DNG | Leica Q3 | `lossless_dng_load_raw` | decoded | decoded, 9536x6344 | 0 |
| Leica Q3/L1026367, L1026368 .DNG | Leica Q3 | `lossless_dng_load_raw` | decoded | decoded, 6344x9536, orientation 6 | 0 |
| Lumix S1/2186891362.rw2 | Panasonic DC-S1 | `panasonicC6_load_raw` | decoded | decoded, 6024x4016 | 0 |
| Lumix S1/P2319446.RW2 | Panasonic DC-S1 II (`DC-S1M2`) | `panasonicC8_load_raw` | decoded with the **DC-S1's matrix** (0.22.2 has no S1 II entry and matched "DC-S1" by prefix) | decoded, 6008x4008, with the S1 II's own matrix | **upstream colour data**: camera_from_xyz row 1 0.9744, -0.3905, -0.0779 -> 1.073, -0.4442, -0.0922 (sensor data, levels and WB unchanged). compatible16: mean 1.16e-4 (~7.6 codes), max 0.208, 64 % of samples differ, 34.8 % by more than one code, 99.9th percentile 451 codes; headroom: mean 1.45e-4, max 0.132. The large differences are in highlights near clipping (the window); the frame looks the same at a glance |
| Nikon Z6iii/9143972759.nef | Nikon Z6III, HE\* | `nikon_he_load_raw` | **refused**: "Nikon HE/HE\* compression is not supported by bundled LibRaw 0.22.2-Release" | **decoded**, 6064x4040, every sample finite, a correct picture on inspection | -- (new) |
| Nikon Z7ii/_DSC0897, 2439, 2663, 2704, 2715, 8127, 8683 .NEF | Nikon Z 7II | `nikon_load_raw` | decoded | decoded, 8288x5520 (orientation 1) or 5520x8288 (orientation 8) | 0 |
| Olympus E300/sample1.orf | Olympus E-300 | `packed_load_raw` | decoded | decoded, 3340x2504 | 0 |

So, with this pin: **21 of 22 files decode** in both `compatible16` and `headroom` (every one of them
qualifies for headroom), including the A7 V (both compressions), the EOS R6 Mark III, the Nikon Z6III
HE\*, the GFX100RF and the Leica Q3; 18 are bit-identical to the previous pin, one is the previous
frame plus a wider crop (R6 III), one changed by upstream's colour matrix (S1 II), one is new (Z6III).
One file, the iPhone 17 Pro JPEG XL DNG, is refused with an exact error by both pins.

The expected outcome of every file -- make, model, displayed size, EXIF orientation, decoder, decode or
the exact refusal, and the pin difference -- is the table in `engine/tests/raw_fixtures.py`; a file
that should decode and does not fails `engine/tests/raw_gate.sh`. Run against the previous pin's host
the same table fails 5 checks (the R6 III's size three times, the Z6III's two opens), which is how it
was shown able to fail.

## Behaviour kept (R-A5)

`compatible16` and `headroom` are unchanged in what they do: the same LibRaw parameters, the same
headroom checks and float conversion, white balance at decode (as-shot and custom), orientation from
LibRaw, the metadata the host reads (probe's EXIF and as-shot WB), and embedded previews for
thumbnails. Every camera the previous pin decoded gives the same frame or the differences above. The
one code change in `engine/src/io/raw_*`: the explicit Nikon HE/HE\* refusal is removed (it guarded a
LibRaw stub that is now a decoder). LibRaw's new constructor ABI check (`LIBRAW_ABI_VERSION`) needed
nothing: the library and the host are built from the same headers.

## Known limits

- **JPEG XL DNG** (DNG 1.7, e.g. iPhone 16 Pro/17 Pro ProRAW) is refused: it needs the Adobe DNG SDK,
  which is not built in. Probe and the camera's preview work.
- **Nikon HE/HE\***: one Z6III HE\* file decoded here. Z8, Z9 and Zf HE/HE\* files are untested on this
  pin. The decoder holds about 8 bytes per pixel of intermediate buffers while it runs, and is serial
  here (no OpenMP on the Mac host or in the Homebrew MinGW cross-build).
- `headroom` remains limited to conventional three-colour Bayer with square pixels and unapplied WB
  (no X-Trans, Foveon, floating-point, sRAW, rotated Fuji).
- A missing camera-to-ProPhoto matrix, invalid WB or corrupt data is an explicit error, never
  uncalibrated camera RGB.
- **Windows**: the cross-built `spektralab-host.exe` carries this LibRaw (its version string, the
  staged notices); nothing has been decoded on Windows itself.

## Where

- Pin and its proof: `engine/third_party/libraw-pin/` (`SHA256SUMS`, `README.md`), `engine/setup-libraw.sh`,
  `engine/setup-libraw.ps1`, `engine/cmake/LibRaw.cmake`.
- Decoder: `engine/src/io/raw_decoder.cpp`, `raw_camera.hpp`, `raw_headroom.cpp`.
- Gate: `engine/tests/raw_gate.sh` (T-A1 `raw_fixtures.py`, T-A2 `raw_pin_compare.sh` + `raw_pin_compare/`,
  T-A3 `raw_pin_guard.sh`, T-A4 the Windows cross-build), with `SPEKTRALAB_RAW_FIXTURES`.
- The Windows host's RAW contract: `engine/WINDOWS_NATIVE_RAW.md`.
