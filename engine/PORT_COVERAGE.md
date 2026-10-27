# Engine coverage on Linux / Windows (Vulkan) vs macOS (Metal)

Windows product B&W integration,2026-10-27: generated resources include the
original five resources_product profiles and notice; base28 material files and
LUTs remain unchanged. The original bw_checks suite passed36 checks on Vulkan,
including grayscale/grade/filter/edge/DX behavior; host tests independently read
12 JPEG/PNG/TIFF16 files. Caller-side Mac stock/paper/grain/filter rules are
ported in desktop; native B&W clicks remain pending.

Windows host addition, 2026-10-26: schema1 half-frame pair decoding now runs
before the unchanged spectral engine. `engine/host/pair_composer.hpp` has
28 independent affine/layout/linear-gain oracle cases (max abs1.49e-8);
`pair_host_checks.py` tests per-hole meter against independently sampled
images, two physical gates/dates, re-decode, source preview/probe, incomplete
export refusal, invalid input and real JPEG/PNG/TIFF files. The authorised
Sony ARW was explicitly referenced twice with independent crops/WB; actual
4078×3769 files with ICC and TIFF16 passed. This is native host/file evidence,
not desktop pair UI acceptance. Per-hole print/Post-Dev now negotiates client
presentation, using atomic same-negative `render_layer` and restoring params
on success/failure. Actual frontend 16-bit composition plus native JPEG/PNG/TIFF
encoders passed on the authorised RAW at4078×3769; no pixel tolerance was widened.
Unnegotiated clients still refuse those objects and direct ordinary exports from
client-presented sessions are blocked to prevent dropping edits. Desktop recipe
controls, per-hole grades/scopes and dual-gate comparison have browser
state/GL tests; native pair clicks remain pending. No core/material/LUT
arithmetic was changed for this host feature.

The owner's question: *does the engine cover everything in the API spec over
C++ and Vulkan on the Windows branch?* This table answers it entry point by
entry point, field group by field group, kernel by kernel. It is kept current
by whoever changes a row (`engine/PORT_NOTES.md` is the running log).

Two columns of status:

- **Windows_Port (28a9d7c)** -- the state the clean textual merge of
  `origin/Windows_Port` onto main 1.3.1 left (before any Linux work).
- **Now** -- this branch, as last updated (date in the heading of §5).

Status words:

| word | means |
|---|---|
| **tested** | implemented, and a named test exercises it; Windows additions below ran on NVIDIA RTX 3070 Ti Laptop, not lavapipe |
| **untested** | implemented, compiles and links, no test exercises it here |
| **refused** | the engine rejects the request by name (`SPK_ERR_USER`, message names the feature); capabilities list it under `backend.unsupported_features` |
| **missing** | absent; a call would fail or the feature is silently not there |

"Tested on lavapipe" is a CPU Vulkan device (Mesa llvmpipe, unfused `fma`).
Nothing here was run on a real GPU or on real Windows unless a row says so;
the Windows_Port branch's own acceptance (RTX 5070 Ti, Windows, MinGW GCC 15.2)
is recorded in `WINDOWS_FEATURE_COVERAGE.md` and predates main's 36 later
commits.

---

## 1. C ABI (`include/spektrafilm/spk_engine.h`)

| entry point | Windows_Port (28a9d7c) | Now | notes |
|---|---|---|---|
| `spk_build_info` | untested | tested (`spk_windows_c_abi`, host `hello`) | reports `math=probed` off Apple |
| `spk_last_error` | tested | tested | |
| `spk_engine_create` / `_destroy` | tested (Windows) | tested (`spk_vulkan_smoke`) | |
| `spk_capabilities` | tested (Windows) | tested (`spk_windows_feature_boundaries`) | `render_core: native-vulkan`; lists `unsupported_features` |
| `spk_params_schema` | tested | tested (`spk_core_schema`) | portable core |
| `spk_warm_up` | untested | untested | the host does not call it |
| `spk_open` | tested (Windows) | tested (`spk_vulkan_smoke`, `spk_windows_c_abi`) | |
| `spk_open_device` | refused | refused | device-buffer input is Metal-only; pass `null` |
| `spk_set_params` / `spk_get_params` | tested (Windows) | tested (`spk_windows_feature_boundaries`) | unported deltas rejected before mutation |
| `spk_solve` | untested | tested (host smoke `solve`) | portable (setup only) |
| `spk_render` (live/preview/full) | tested (Windows) | tested (`spk_windows_c_abi`) | |
| `spk_reprint` | tested (Windows) | tested (host smoke: `reprinted: true` after a print-side delta) | |
| `spk_contrast_mask_field` | refused | Windows tested | public field, Gaussian boundary oracle, finite gain, negative/cache invariants and stripe equality; see contrast_mask_checks.py |
| `spk_scene_latitude` (analysis) | tested (Windows) | tested (host smoke, feature boundary) | analysis and mapping implemented on Windows; no Mac whole-image oracle yet |
| `spk_overscan_geometry` | missing (link error) | tested: real layout when enabled, invalid when off | original portable layout; Windows DLL export added; feature boundary and real host export |
| `spk_print_lut_catalog` / `spk_print_lut_table` | tested (Windows) | tested (host smoke `export_cube`) | portable core |
| `spk_preview_stock_lut` | tested (Windows) | tested (host smoke) | `spk_lut3d_trilinear` |
| `spk_export_di` | tested (Windows) | tested (host smoke `export_di`) | normalised-density tap |
| `spk_render_digital_intermediate` | refused | Windows tested (C ABI, original overscan suite) | Cineon encoded pixels/metadata; preserves canvas params; slide film still refused; host view/raw export tested by cineon_host_checks.py |
| `spk_output_transform` | untested | tested (every host `rgba8`/display render and export; a P3 export converted by lcms lands within MAE 0.6 % of the host's sRGB export) | portable core |
| `spk_memory_report` | untested | tested (host smoke) | |
| `spk_cancel` / `spk_progress` | untested | tested (host smoke: a full render cancelled mid-flight returns `SPK_ERR_CANCELLED` and the session renders again) | |
| `spk_result_free` / `spk_session_release` / `spk_string_free` | tested (Windows) | tested | Vulkan result owns a CPU copy |

## 2. API-SPEC wire fields

| section | fields | Windows_Port | Now |
|---|---|---|---|
| §1–§10 core render, tiers, reprint, live-mutable set | every field in `params_schema` predating RFC-024 | implemented; whole-image Metal parity unverified | same |
| §11 contrast mask (RFC-024) | `contrast_mask_{active,highlights,shadows,core,scale,scheme}` | **refused** when `active` | Windows tested: both kernels, original host Gaussian with non-Apple static jthreads, exact zero/off and band identity |
| §12 Scene Latitude (RFC-023) | `scene_latitude_{active,norm,shadow_knee,highlight_knee,shadow_room,highlight_room,max_lift,rolloff}` | **refused** when `active` (analysis call works) | Windows tested: 24 float64 oracle cases, all norms, rolloff 1/2/1.5/3, split/band offsets, pathological values; C ABI render |
| §13 overscan / film edge (RFC-031/032) | `overscan_{active,mode,format,gate,holes,carrier,edge_text,frame_number,frame_seed,camera_seed,f_number,fog,leaks,pair}` | **refused** when `active` | Windows tested: original layout/exposure/DX, analytic kernels, real RAW full JPEG/PNG/TIFF; original full overscan suite (0 failures after Cineon port) |
| §13 date back | `date_imprint_{active,text,text_b,data_text,style,corner,placement,size,ev,inset_x,inset_y}` | **refused** when `active` | Windows tested: portable coverage rasterisation, C ABI and real RAW full export |
| §14 `filter_shift_scale` | `filter_shift_scale` | implemented (portable `printing.cpp`) | implemented, untested here |
| §15 `camera_filter` (2026-10-07) | `camera_filter` | — | implemented (portable `hanatos.cpp`, `params.cpp`; table in `camera_filters.hpp`), untested here; `desktop/mock-host/schema-fields.json` does not list it yet |
| `io.digital_intermediate` (Cineon DI file) | | refused | Engine and image host tested; shared original DI-view table, dedicated raw export with no main-page ICC |
| anti-halation switch, highlight boost (9fa3b0d) | `halation`/`boost` fields | implemented via `spk_boost` | implemented, untested here |

## 3. Kernels: Metal vs Vulkan

| Metal kernel (`src/shaders/*.metal`) | Vulkan (`src/shaders/vulkan/*.comp`) | Windows_Port | Now |
|---|---|---|---|
| `spk_take_rgb`, `spk_affine3`, `spk_mul`, `spk_glare_add`, `spk_reduce_max`, `spk_to_rgba16`, `spk_stride_sample` | same names | tested (Windows) | tested (`spk_vulkan_pointwise`, `_transfer`) |
| `spk_zoom_bilinear_mirror` | same | tested | tested (`spk_vulkan_resample`) |
| `spk_math_probe` | same | tested | tested; lavapipe reports *unfused fma*, accepted only on a CPU device, and selects the Dekker path |
| `spk_lut3d_trilinear`, `spk_di_normalise` | same | tested | tested (`spk_vulkan_lut_di`) |
| `spk_sep_fir_acc` | same | tested | tested (`spk_vulkan_smoke` FIR oracle) |
| `spk_iir_df_acc` | same | tested | tested on lavapipe at the original bound (exact Dekker product on an unfused device, §5) |
| `spk_lincomb3` | same | tested | tested |
| `spk_log10_guarded`, `spk_boost`, `spk_curves`, `spk_matmul3`, `spk_tc_b`, `spk_lut2d_cubic`, `spk_couplers_correction`, `spk_spectral_epilogue`, `spk_print_exposure`, `spk_cctf_decode`, `spk_cctf_encode_matrix`, `spk_bw_correct`, `spk_edr` | same | tested (Windows) | tested (`spk_vulkan_pointwise`, `spk_windows_c_abi`) |
| `spk_geometry_resample_df` | same | tested | tested on lavapipe at the original bound (§5) |
| `spk_cam16ucs_compress` | same | tested | tested |
| `spk_grain_layers`, `spk_grain_simple`, `spk_lognormal_field`, `spk_grain_layer_one` | same (+ `spk_rng_probe`) | tested | tested (`spk_vulkan_grain`) |
| `spk_di_encode` (Cineon DI) | same name | missing | Windows tested: independent double oracle (144 new cases; compensation off/on and fitted parameter limits), abs 1e-6, guards; original equations evaluated with compensated float pairs |
| `spk_mask_reduce`, `spk_mask_epilogue` (contrast mask) | same names | refused | Windows tested: double exposure/grid/preflash/branch oracles and full-vs-band coordinates, guards; same tolerance as original pointwise tests |
| `spk_scene_latitude` | same | missing | tested (`spk_vulkan_pointwise`, Windows NVIDIA): original equations, compensated float-pair arithmetic to preserve log-axis precision; no shaderFloat64 required |
| `spk_overscan_canvas`, `spk_overscan_add_mask`, `spk_overscan_film_present`, `spk_overscan_light` | same names | missing | Windows tested (`spk_vulkan_pointwise`, positive feature boundary, real host); FMix endpoints explicitly preserve opaque film identity |

Host-side adapters: `contrast_mask.cpp` keeps GCD on Apple and uses bounded
C++20 static line workers elsewhere, with bit-identical per-line accumulation.
`overscan.cpp` keeps CoreText/CoreGraphics/vImage on Apple; the non-Apple
adapter uses embedded TeX Gyre Heros, stb_truetype and portable convolution.
Font substitution remains a documented visual difference.

## 4. What main added after 61bfc49 that Vulkan lacks

36 commits; the engine ones, and their state off Apple:

| commit(s) | what | off Apple |
|---|---|---|
| 9fa3b0d | anti-halation switch, highlight boost | portable (existing kernels) |
| 2108544, 4a9ea54, 122c5fb, 4767b48, a2f7acb, abc55d5, 8179327, 9cc53c2, 3fe47b5, 079ec29, 25fe66f, b97b7fa, e985110, 75d8eb5, da9ae19 | film edge / overscan: frame number, panoramic formats, carrier, half-frame pair, perforation softness, Fujifilm/Kodak edge print | refused (overscan) |
| abc55d5, 079ec29 | a pair's second Scene Placement | refused (scene latitude) |
| 3ec73b2 | date back: date + shooting data, date on 120 | refused (date imprint) |
| f8223db | Enlarger filters move the print | portable (`printing.cpp`) |

The merge is textual; semantic reconciliation of `pipeline.cpp`/`engine.cpp`
between the two lines is verified only by the CTests named above.

## 5. Earlier acceptance (2026-10-06; superseded for Windows below)

**The five refused features stay refused, by the owner's decision**
(2026-10-06); `engine/PORT_PLAN.md` is the handoff for porting them.
Everything else in the API spec runs on Vulkan.

The Windows restoration authorised on 2026-10-25 supersedes that earlier
scope. All five pipeline feature groups are now implemented on Vulkan.
Windows NVIDIA CTest covers 242 pointwise cases, 240 LUT/DI cases, host
filter/cache/stripe checks and the original full overscan suite. The image
host samples the Mac's unchanged half-float 65-cube DI view for ordinary
images; `export_cineon` writes raw 16-bit codes, a viewed preview page and
both original LUTs. No whole-image comparison against Metal has run here.
The Mac's withdrawn tone-mask UI stays withdrawn. Half-frame readings now persist
with decoder-specific invalidation keys and do not pump on placement edits. A
3-entry/192MiB native float bitmap LRU reuses unchanged source holes without
retaining full RAW decodes; oversized entries can be uncached. Native Windows
visual/click acceptance and direct placement gestures remain incomplete.

Verified on lavapipe (Mesa 25.2, llvmpipe LLVM 20, a CPU device):

- `ctest`: **14/14** at the original tolerances (IIR max abs error 1.49e-8 --
  the figure the Windows port recorded on an RTX 5070 Ti -- geometry 5.0e-7,
  resample 2.8e-7).
- `engine/tests/host_smoke.py` against `spektralab-host` on Linux: every
  host method, synthetic PNG and 16-bit TIFF, non-ASCII paths, a 12 MP NEF and
  a 21 MP CR2.
- The same smoke against `spektralab-host.exe` under wine 9 + Xvfb
  (winevulkan forwarding to lavapipe), including the NEF and a non-ASCII
  install folder.

Changes to the Vulkan backend made by this port (all behaviour-identical on
a GPU that already worked):

| change | why | where |
|---|---|---|
| dispatches past `maxComputeWorkGroupCount[0]` fold into 2D; shaders take `spk_global_index()` | 65535 groups x 256 = 16.7 M threads: every frame over 16.7 MP failed on lavapipe, and on Intel (same limit) | `src/gpu/vulkan_gpu.cpp` `dispatch`, every `src/shaders/vulkan/*.comp` |
| on a CPU device only, a start-up probe lifts `maxStorageBufferRange` (128 MiB on lavapipe) after proving larger SSBOs read and write correctly | nothing over ~11 MP rendered on the CPU fallback | `vulkan_gpu.cpp` `probe_cpu_storage_range`; off with `SPEKTRAFILM_VULKAN_STRICT_LIMITS=1` |
| exact Veltkamp/Dekker `two_prod` when `fma` is unfused (specialization constant 0) | lavapipe's `fma` is mul+add: the IIR blur lost its low word and erred by 0.4 % | `spk_iir_df_acc.comp`, `spk_geometry_resample_df.comp` |
| resources and SPIR-V opened through UTF-8 wide paths on Windows | an install folder under a non-ASCII user name would not start | `src/core/file_path.hpp`, four `ifstream` sites |

Not verified: any real GPU on Linux, real Windows (only wine), Intel/AMD
drivers, whole-image parity against Metal (needs a Mac; see PORT_PLAN §0),
cameras beyond one NEF and one CR2 (raw.pixls.us is blocked by this
environment's proxy).
