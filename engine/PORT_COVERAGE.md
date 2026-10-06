# Engine coverage on Linux / Windows (Vulkan) vs macOS (Metal)

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
| **tested** | implemented, and a test on this branch exercises it on lavapipe (named) |
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
| `spk_warm_up` | untested | untested | |
| `spk_open` | tested (Windows) | tested (`spk_vulkan_smoke`, `spk_windows_c_abi`) | |
| `spk_open_device` | refused | refused | device-buffer input is Metal-only; pass `null` |
| `spk_set_params` / `spk_get_params` | tested (Windows) | tested (`spk_windows_feature_boundaries`) | unported deltas rejected before mutation |
| `spk_solve` | untested | untested | portable (setup only) |
| `spk_render` (live/preview/full) | tested (Windows) | tested (`spk_windows_c_abi`) | |
| `spk_reprint` | tested (Windows) | untested here | |
| `spk_contrast_mask_field` | refused | refused | RFC-024, see §2 |
| `spk_scene_latitude` (analysis) | tested (Windows) | untested here | the *analysis* runs; *applying* the mapping is refused |
| `spk_overscan_geometry` | missing (link error) | returns `{"valid":false}` | the merge left the symbol undefined; stubbed so the engine links |
| `spk_print_lut_catalog` / `spk_print_lut_table` | tested (Windows) | untested here | portable core |
| `spk_preview_stock_lut` | tested (Windows) | untested here | `spk_lut3d_trilinear` |
| `spk_export_di` | tested (Windows) | untested here | normalised-density tap |
| `spk_render_digital_intermediate` | refused | refused | Cineon DI (`spk_di_encode`) unported |
| `spk_output_transform` | untested | untested | portable core |
| `spk_memory_report` | untested | untested | |
| `spk_cancel` / `spk_progress` | untested | untested | |
| `spk_result_free` / `spk_session_release` / `spk_string_free` | tested (Windows) | tested | Vulkan result owns a CPU copy |

## 2. API-SPEC wire fields

| section | fields | Windows_Port | Now |
|---|---|---|---|
| §1–§10 core render, tiers, reprint, live-mutable set | every field in `params_schema` predating RFC-024 | implemented; whole-image Metal parity unverified | same |
| §11 contrast mask (RFC-024) | `contrast_mask_{active,highlights,shadows,core,scale,scheme}` | **refused** when `active` | refused |
| §12 Scene Latitude (RFC-023) | `scene_latitude_{active,norm,shadow_knee,highlight_knee,shadow_room,highlight_room,max_lift,rolloff}` | **refused** when `active` (analysis call works) | refused |
| §13 overscan / film edge (RFC-031/032) | `overscan_{active,mode,format,gate,holes,carrier,edge_text,frame_number,frame_seed,camera_seed,f_number,fog,leaks,pair}` | **refused** when `active` | refused |
| §13 date back | `date_imprint_{active,text,text_b,data_text,style,corner,placement,size,ev,inset_x,inset_y}` | **refused** when `active` | refused |
| §14 `filter_shift_scale` | `filter_shift_scale` | implemented (portable `printing.cpp`) | implemented, untested here |
| `io.digital_intermediate` (Cineon DI file) | | refused | refused |
| anti-halation switch, highlight boost (9fa3b0d) | `halation`/`boost` fields | implemented via `spk_boost` | implemented, untested here |

## 3. Kernels: Metal vs Vulkan

| Metal kernel (`src/shaders/*.metal`) | Vulkan (`src/shaders/vulkan/*.comp`) | Windows_Port | Now |
|---|---|---|---|
| `spk_take_rgb`, `spk_affine3`, `spk_mul`, `spk_glare_add`, `spk_reduce_max`, `spk_to_rgba16`, `spk_stride_sample` | same names | tested (Windows) | tested (`spk_vulkan_pointwise`, `_transfer`) |
| `spk_zoom_bilinear_mirror` | same | tested | tested (`spk_vulkan_resample`) |
| `spk_math_probe` | same | tested | tested; lavapipe reports *unfused fma*, accepted only on a CPU device |
| `spk_lut3d_trilinear`, `spk_di_normalise` | same | tested | tested (`spk_vulkan_lut_di`) |
| `spk_sep_fir_acc` | same | tested | tested (`spk_vulkan_smoke` FIR oracle) |
| `spk_iir_df_acc` | same | tested | see §5: precision gate fails on lavapipe (unfused fma) |
| `spk_lincomb3` | same | tested | tested |
| `spk_log10_guarded`, `spk_boost`, `spk_curves`, `spk_matmul3`, `spk_tc_b`, `spk_lut2d_cubic`, `spk_couplers_correction`, `spk_spectral_epilogue`, `spk_print_exposure`, `spk_cctf_decode`, `spk_cctf_encode_matrix`, `spk_bw_correct`, `spk_edr` | same | tested (Windows) | tested (`spk_vulkan_pointwise`, `spk_windows_c_abi`) |
| `spk_geometry_resample_df` | same | tested | see §5: precision gate fails on lavapipe |
| `spk_cam16ucs_compress` | same | tested | tested |
| `spk_grain_layers`, `spk_grain_simple`, `spk_lognormal_field`, `spk_grain_layer_one` | same (+ `spk_rng_probe`) | tested | tested (`spk_vulkan_grain`) |
| `spk_di_encode` (Cineon DI) | **missing** | refused | refused |
| `spk_mask_reduce`, `spk_mask_epilogue` (contrast mask) | **missing** | refused | refused |
| `spk_scene_latitude` | **missing** | refused | refused |
| `spk_overscan_canvas`, `spk_overscan_add_mask`, `spk_overscan_film_present`, `spk_overscan_light` | **missing** | refused | refused |

Host-side (C++) dependencies of the unported features: `contrast_mask.cpp`
uses GCD (`dispatch_apply`); `overscan.cpp` uses CoreText/CoreGraphics for the
edge print and date back, and vImage for a convolution.

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

## 5. Current state (2026-10-06)

- Linux build (gcc 13, Ninja, volk, pinned Vulkan-Headers + LibRaw 0.22.2)
  builds the engine, the shared test library, the LibRaw decoder and every
  test. CTest on lavapipe: 12/14 pass.
- `spk_vulkan_smoke`: the FMA known-bit vectors now accept the reported
  unfused mode. Its IIR precision gate then fails on lavapipe: without a fused
  `fma` the double-float `two_prod` loses its low word, and the Young–van Vliet
  recurrence amplifies that (0.4 % on a 257-px constant row). This is a real
  rendering error on any unfused device, not a test artefact; fix in progress
  (exact Dekker `two_prod` when the device does not fuse).
- `spk_vulkan_geometry`: same root cause (double-float coordinates).
