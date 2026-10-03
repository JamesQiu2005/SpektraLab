# Windows feature coverage

Verified on 2026-10-03 with MinGW GCC 15.2 / Vulkan / RTX 5070 Ti.
The current `build-windows-raw-headroom` backend has 34 registered kernels,
including two diagnostic probes, and passes CTest 14/14.
This is a record of exercised paths, not a claim that every public API or
stock combination is complete. Shared baked profile/resource files are unchanged.
Whole-image Python/Metal parity remains unverified: the matching external
reference is still unavailable.

| User operation or parameter | Pipeline / kernels | Evidence and boundary |
|---|---|---|
| Linear ProPhoto RGB input, Portra 400 / Portra Endura, encoded sRGB output | Existing spectral, curves, DIR, CAM16, transfer and RGBA16 kernels | 240×180 synthetic, 1172×1757 decoded ARW matrix, and 4688×7028 full ARW baseline/default; deterministic repeated full/reprint agree |
| Default automatic exposure | `node_auto_exposure`, `spk_stride_sample`, CPU meter | Actual default matrix retains `center_weighted`; all other meter methods are not independently validated here |
| Default sublayer grain | `spk_grain_layers`, `spk_grain_layer_one`, affine and blur tail | Actual default RAW renders; local GPU tests cover endpoints, knots, interior interpolation, positive sign and fused-versus-layer result |
| Simple grain (`grain_sublayers_active=false`) | `spk_grain_simple`, affine, FIR | Actual synthetic and RAW matrix; local GPU tests cover streams and sublayer counts |
| Grain microstructure | `spk_lognormal_field`, `spk_mul`, blur | Kernels tested directly; the current RAW size/profile does not prove every microstructure threshold branch |
| Glare | `spk_lognormal_field`, blur, `spk_glare_add` | Default RAW renders with glare enabled; local lognormal mean/std, shared-channel and numerical addition checks |
| Highlight boost | `spk_reduce_max`, `spk_boost` | Actual `halation_boost_ev=1` matrix; reduction includes multiple groups/grid-stride and tail guards |
| Scanner black/white correction | `spk_bw_correct` | Both enabled in actual matrix; local analytic cases include zero denominator NaN/Inf semantics |
| Extended dynamic range | `spk_edr` | Portra Endura actual matrix; local tone-map endpoint/LUT interpolation checks |
| Encoded RGB input | `spk_cctf_decode` | Direct GPU checks for all transfer modes and branch neighbours; RAW fixtures use linear input and do not exercise this branch |
| Larger sigma Gaussian blur | `spk_iir_df_acc` | 576 independent GPU recurrence/constant checks, both axes, accumulation and aliasing; exercised by larger renders |
| FIR mirror/reflect boundaries | Corrected `spk_sep_fir_acc` coordinate mapping | 144 exact boundary cases; archived shader fails and corrected shader passes. Negative-coordinate signed remainder previously gave incorrect edge values; the correction changes some whole-frame pixels as well as stripes |
| Automatic tier downscale during render/open | `spk_sep_fir_acc` mirror mode, `spk_zoom_bilinear_mirror` | Actual RAW input triggered this formerly missing path; 60 independent GPU resample cases include long axes and exact integer coordinates |
| Print-only edits and cached negative | `spk_reprint`, `spk_set_params` | Deterministic unchanged reprint equals full; `print_exposure=1.2` reprint changes pixels and equals subsequent full; cached-negative flag checked |
| Result ownership | `spk_result_free` / C ABI | DLL C++ fixture tests results after session/engine destruction; matrix copies result before freeing and validates dimensions before reading |
| Device-local compute and explicit transfers | `Gpu::copy/read`, upload/fill/staging readback | Transfer CTest, six-case RAW matrix, CPU result ownership preserved. Phase-1 full-frame old/new equality remains historical evidence of the transfer change; current corrected FIR output uses a new baseline |
| Existing striped execution | Offset device copies, FIR halo handling and corrected boundary mapping | 35 deterministic parameter/strip-size combinations pass whole/striped/reprint byte equality; full 4688×7028 ARW with 509-row strips and cached reprint also equals the corrected whole frame. These exact comparisons disable grain, glare and AE; other stochastic strip combinations remain unverified |
| Native RAW input | `spk_raw_render`, LibRaw 0.22.2, `spk_open` | Full Sony ARW decoded float is byte-identical to existing rawpy 0.22.1 fixture; camera WB, black/white, orientation, requested AHD, clipped 16-bit linear ProPhoto compatibility mode. No Python runtime; other camera formats need positive fixtures |
| Opt-in RAW headroom | `decode_raw_headroom`, max-normalised WB, float ProPhoto conversion | Full ARW camera-RGB/NumPy float64 oracle max error 2.31e-7; separately decoded ProPhoto16 differs by at most 1 count after rescaling/quantisation. Output range -0.0132823 to 2.1982729. Still uint16 demosaic; sensor/black-level clipping is not recovered; narrow Bayer-only experimental mode |
| Nikon Z8 HE* NEF | LibRaw metadata + explicit unsupported-format rejection | Supplied 5408x3608 14-bit sample is compression code 14, decoder nikon_he_load_raw. Six tests cover original/Unicode paths and default/explicit modes, with unchanged source and no partial outputs. No Nikon render or speed result is claimed; ordinary lossless NEF still needs a positive fixture |
| Native sRGB TIFF export | Host `image_writer`, fixed ICC resource | RGB16 pixels match direct C ABI output; independent tags/strip/ICC checks, Unicode filenames, no-overwrite and rollback tests. EDR, other colour spaces, DI file packaging and EXIF copying are pending |
| Crop / arbitrary rotation / flips | `spk_geometry_resample_df` | 192 direct GPU cases against independent float64 mapping and exact integer rotations/flips, max error `8.16198319e-7`; full RAW turn/flip equals explicit input transforms. Arbitrary crop/rotation C ABI dimensions, invalidation and cached reprint pass |
| Stock-LUT preview | `spk_lut3d_trilinear` | LUT/DI direct gate: 96 cases, max error `6.96505159e-7`. Eight baked stock tables are byte-identical through the C ABI; all stock synthetic preview calls pass, full RAW Portra Endura passes. Output is encoded Display P3 per catalog, independent of the ordinary render's sRGB setting |
| DI delivery | `spk_di_normalise` | Direct numerical gate and eight-stock synthetic C ABI calls pass; full RAW Portra Endura passes. RGBA16 holds normalized negative density, not display RGB. This does not implement a TIFF writer or complete native image export |
| Windows display and native GPU image | Platform output/display layer | CPU RGBA16 ownership handle only; no drawable `VkImage` or Windows UI |

CTest covers core schema/setup, Vulkan smoke, grain, pointwise, resample,
transfers, geometry, LUT/DI, the DLL C ABI, TIFF, RAW decode errors, metadata-only
LibRaw linkage and headroom mathematics (14/14). Grain gates use exact Philox integers and independent
distribution moments; they do not assert Metal seeded Poisson draw equality.
The isolated negative controls demonstrate failures for Gaussian substitution,
rounded long-axis coordinates, wrong arithmetic and overwritten tail guards.
The FIR regression additionally fails against the archived shader resources.
`tools/windows_features.py` verifies geometry cache invalidation, LUT pairing
warnings, missing-stock rejection, print-only edit stability and actual retained
LUT/DI allocations after session and engine destruction. Its integration gate
does not claim an external whole-image oracle.

`tools/windows_render_matrix.py` is the execution gate. It binds input SHA,
decoder metadata, DLL/runtime/resource hashes, resolved parameters and output
hashes to `report.json`, checks every returned full image's dimensions before
reading it, and always records external parity as unverified. RGBA16 files
retain the full rendered size. PNG files have an sRGB chunk and are 8-bit,
at most 1280 pixels per edge; they are display previews, not grain or parity
evidence.

RAW compatibility limitation: both rawpy and native 16-bit ProPhoto output clip/quantise RGB.
Normalisation preserves only [0, 1], not negative values or highlights above
one. Decoder provenance records this separately from engine validation.
Core Image versus LibRaw decoding has not been compared.

The current full ARW report is `../validation/migration-phase2/raw-arw-full/report.json`;
the six-case smaller RAW matrix is `../validation/migration-phase2/raw-arw-4/report.json`.
Each full-sized RGBA16 is 263,578,112 bytes. Current feature and lifecycle evidence
is in the same phase directory: `features-synthetic/report.json`,
`features-raw-full/report.json`, `stripe-after.json`, `full-frame-checks.json`
and `lifecycle.json`.

The FIR correctness change deliberately replaces the old deterministic image
baseline: 2,763,447 full-frame pixels / 6,073,521 RGB channel values differ, with
maximum absolute difference 45,058 RGB16 counts and zero alpha changes. This
is not roundoff. Running the new DLL with the archived shaders reproduces the
old full-frame baseline byte for byte, isolating the changed pixels to the FIR
shader repair. Baked material data remains unchanged. Corrected whole/stripe
equality and the independent boundary oracle are established; external
Metal/Python whole-image parity remains unverified.

`../validation/migration-phase2/benchmark/report.json` records 33 complete C ABI
calls across three independent processes. The current first-full median is
871.41 ms (864.83–873.88), warm-full 229.30 ms (227.10–232.89), and cached reprint
66.72 ms (65.33–73.46), with default grain/glare/AE and owned CPU RGBA16 delivery.
RAW decoding, engine creation, input open/upload and file saving are excluded
from this render metric; the worker records engine creation and input open
separately. All agreed first-stage speed targets remain met.

Historical performance-phase1 medians were 837.78 / 219.29 / 64.61 ms before
the FIR correction; pre-optimization first/repeat times were 48.08 / 45.75 s.
Those reports and builds remain preserved and are not the current pixel baseline.
Compute memory is device-local; upload/readback staging remains on the host and
is recorded separately from the existing engine allocation ledger. Neither
ledger is a measurement of physical VRAM peak.

Initial native RAW and sRGB TIFF evidence is in `../validation/native-raw-phase3/`;
current compatibility/headroom and Nikon HE* rejection evidence is in
`../validation/raw-headroom-phase4/`.
Remaining migration work includes external Metal/Python image comparisons,
RAW headroom/negative-value policy and camera coverage, untested parameter
combinations, Windows display/native GPU images and other export formats.
