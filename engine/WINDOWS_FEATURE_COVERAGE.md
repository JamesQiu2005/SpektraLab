# Windows feature coverage

This table describes the port rooted at upstream `8a318743` and integrated
with the author's `Windows_Port` starting point `61bfc49`. The acceptance hardware
was Windows, MinGW GCC 15.2, Vulkan and RTX 5070 Ti. It does not imply that
every stock, camera, parameter combination or later upstream feature is
supported. Later features require explicit porting and validation.

The backend contains 34 kernels, including two diagnostic probes. The full
Win32 integration passed 16 CTests and 47 Python tool tests. Original baked
profile/resource files were unchanged; native TIFF export adds a separate
provenance-described sRGB ICC resource. Whole-image Metal/Python film-model
parity remains unverified.

| Operation | Implemented path | Exercised scope and remaining boundary |
|---|---|---|
| Linear RGB film/print render | Existing spectral/curve/DIR/CAM16 pipeline on Vulkan | Synthetic frames, small RAW matrix and full 4688×7028 ARW; baseline and default effects exercised |
| Automatic exposure | Existing meter with GPU sampling | Default `center_weighted` exercised; every other method is not independently accepted |
| Sublayer and simple grain | Original Philox/Poisson model, grain and blur kernels | Integer vectors, interpolation, mean/variance/skew and real renders; no claim of every seeded Metal draw matching |
| Grain microstructure | Lognormal field, multiplication and blur | Direct kernel coverage; real-camera tests do not prove every threshold branch |
| Glare | Lognormal field, blur and addition | Default RAW rendering and local distribution/numerical checks |
| Highlight boost and black/white correction | Reduction, boost and scanner correction kernels | Small RAW matrix and analytic boundary cases |
| EDR | EDR computation in pixel API | Direct numerical gate and Portra Endura matrix; not available through the SDR TIFF host/viewer |
| Encoded input | Transfer decoding kernel | Direct transfer-function checks; native RAW supplies linear input |
| IIR blur | Double-float recurrence, float storage | 576 independent recurrence/constant cases; both axes, aliasing and accumulation |
| FIR blur | Corrected mirror/reflect mapping | 144 exact boundary cases; old negative-coordinate signed remainder fails the gate |
| Tier resampling | FIR and bilinear-mirror kernels | 60 independent cases including long-axis coordinates, plus real RAW execution |
| Crop, rotation and flips | Geometry resampling kernel | 192 float64/exact-transform cases; full RAW turn/flip compared with explicitly transformed input; arbitrary geometry checks dimensions and cache behavior |
| Stock-LUT preview | Trilinear LUT application | Eight baked stock tables byte-identical through C API, synthetic calls and one full-RAW stock; preview contract is encoded Display P3 |
| DI pixel delivery | Normalised negative-density output | Direct LUT/DI numerical gate and eight-stock calls; values are density, not display RGB; file packaging remains incomplete |
| Cached print-side edits | C API reprint and negative cache | Deterministic full/reprint equality and actual cache flags; film-side edits invalidate the negative |
| GPU memory and transfer | Device-local computation, staged upload/readback, device copy | Range/alignment/overlap tests, dependency checks and result lifetime; synchronous scheduling retained |
| Striped processing | Existing stripe algorithm with corrected FIR boundaries | 35 deterministic configurations and full ARW with 509-row strips agree with whole-frame/reprint; broader stochastic combinations remain unverified |
| C API result lifetime | Independent CPU RGBA16 ownership | Earlier results survive later renders and session/engine destruction; result is not a drawable VkImage |
| Native RAW `compatible16` | LibRaw 0.22.2 and linear ProPhoto float storage | Full Sony ARW matches rawpy/LibRaw reference fixture; integer RGB clipping remains; broader camera acceptance pending |
| Native RAW `headroom` | Max-normalised WB, uint16 demosaic, unclipped float matrix conversion | Restricted Bayer mode; full ARW camera-RGB/float64 oracle max error `2.31e-7`; sensor and black-level clipping are not recovered |
| Nikon HE/HE* | Explicit rejection by bundled decoder | Tested Z8 HE* metadata and clean rejection in both modes/Unicode paths; no positive Nikon decode or timing claim |
| Native TIFF | Uncompressed RGB16 with pinned sRGB ICC | Independent tags, strips, all samples, ICC, no-overwrite and failure cleanup; no HDR, other TIFF colour spaces or EXIF copying |
| Minimal Win32 viewer | Serial worker and immutable RGBA16/BGRA8 frames | Full RAW open, film/paper/brightness edits, fit/100% pan, same-frame export and failed-open preservation |
| Qt Quick editor | Shared native host, three-panel layout and single-photo strip | Full RAW/controller/offscreen scene regression; physical 100% samples, repeated texture updates and failure recovery; live display validation pending |
| Window drawing | sRGB-labelled bitmap and requested GDI ICM | Offscreen handlers/layout and 1:1 BGR pixel checks; visible gestures, calibrated monitor ICC, HDR and multi-monitor acceptance remain pending |
| Scene latitude analysis | Existing pipeline and explicit probe readback | Real C ABI analysis test; applying scene latitude mapping remains unsupported |
| New upstream effects | Explicit Windows capability and request rejection | Cineon DI, scene latitude mapping, contrast mask, film edge and date imprint are refused before session mutation; the old normalised-density DI tap remains available |

## Test interpretation

Local mathematical gates use analytic or independently evaluated float64
references. Maximum recorded absolute errors were `1.49e-8` for IIR,
`3.15e-7` for resampling, `8.17e-7` for geometry and `6.97e-7` for LUT/DI.
These are local test results, not whole-image Metal parity tolerances.
Negative controls caught incorrect grain distributions, long-axis rounding,
arithmetic, tail writes and the old FIR mapping.

The FIR repair intentionally changed some whole-frame pixels as well as
stripes. Loading archived shaders with the repaired host reproduced the old
output and isolated the change to that shader. Current output must not be
forced to match an earlier incorrect boundary result. No material profile
was edited to obtain the correction.

Exact full/stripe/reprint image comparisons disable grain, glare and automatic
exposure. Default-effect tests retain those effects and use appropriate
behavioral/distribution checks. A new stochastic render is not a valid
byte-equality reference for an earlier render; TIFF export is instead compared
against the same retained frame being saved.

The CTest count depends on build options: 11 for the backend, 15 with native
RAW and 16 with the minimal desktop host. The default desktop test is a pure
conversion/viewport boundary test. Real-camera host tests and offscreen Win32
tests are additional acceptance runs, not implied by the default CTest count.

## Reproduction and limits

See [WINDOWS.md](WINDOWS.md) for build, CTest, synthetic fixture and feature
commands; [WINDOWS_NATIVE_RAW.md](WINDOWS_NATIVE_RAW.md) for camera decode,
TIFF and timing tools; and [WINDOWS_DESKTOP.md](WINDOWS_DESKTOP.md) for the
offscreen window test. The [Qt frontend guide](../windows_UI/README.md) covers
its independent SDK/build and real-RAW scene test. Camera inputs are supplied by the developer and are
not bundled. Generated output directories must be fresh.

`tools/windows_render_matrix.py` records input/decoder provenance, resolved
parameters, binary/runtime/resource hashes and full-size result hashes. Its
small PNG previews are for inspection, not grain or parity evidence. Use the
complete RGBA16 output for numeric comparisons.

Historical 32.95 MP render-call medians were 871.41 ms first full, 229.30 ms
warm full and 66.72 ms cached reprint, including owned CPU RGBA16 delivery but
excluding RAW decode, engine creation, upload and export. They describe one
recorded machine/input protocol; rerun the supplied performance tools for
your own hardware. A pool ledger is not peak physical VRAM, and a GPU node
sum is not the complete render-call time.

Remaining acceptance work includes external Metal/Python whole-image parity,
Core Image versus LibRaw decode comparison, more cameras and stock/parameter
combinations, live Windows display/colour behavior and additional exports.
Unported later upstream functionality must not be advertised as supported.
