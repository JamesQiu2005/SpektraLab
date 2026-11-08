# v2 engine promotion and performance — 2026-10-24

Implemented on **`mac/engine-performance`**, based on `mac/integration`
`unpublished-revision`, in a separate worktree. No merge or
change to the active `v2-mac` checkout. The owner explicitly approved promoting
the full research v2 engine, including minilab and factory optics.

The 100-field wire and C ABI are unchanged. Decode's new `scene_curve` is
preserved before film exposure and participates in checkpoint invalidation.
API-SPEC §18 records the v2 control semantics.

## Promoted model and optimizations

- The approved r=1 minilab print transform: spectral recovery of the negative,
  curve reversal to log-positive RGB, then a 65³ trilinear lookup to paper CMY.
  These three operations share one Metal kernel, preserving float32 arithmetic.
  One immutable table is uploaded per pipeline, rather than per render.
- The qualified resources currently cover **Portra 400 → Portra Endura** in
  sRGB and ProPhoto. Other output spaces use the ProPhoto calibration before
  their own output transform. Other film/paper pairs keep optical printing;
  unqualified tables are not relabeled or borrowed. Missing/corrupt listed
  tables or changed material profiles fail explicitly. B&W, positive, scan-film
  and DI retain their distinct paths. The calibrated minilab block replaces
  optical enlarger/exposure/print-curve controls; see API-SPEC §18.
- Factory lettering uses the approved separate exposure with fixed 2% factory
  back-return and unit effect multipliers. Camera scene spill and date exposure
  remain. Release the factory plane immediately after halation, and original
  log exposure after DIR's last use. No material profile is altered.
- One process-wide, anonymous pre-grain float32 SSD slot, capped at 1 GiB,
  `F_NOCACHE`, complete write/read checks and automatic fallback. No retained
  checkpoint GPU image. First render never writes a checkpoint; the first
  grain-only edit may probe admission. Measured write/read cost must repay the
  skipped prefix. Source session, tier, dimensions, stage version and all fields
  except the three downstream grain controls identify it. Any non-grain edit
  invalidates conservatively. Session close releases the slot. Striped execution
  bypasses it. `SPK_CHECKPOINT_MODE=off` forces full computation.
- DIR subtraction + curve interpolation fused; XYZ-to-RGB + CAM16 fused. Matrix
  operations retain their original intermediate float32 rounding. Vulkan keeps
  its previous kernels; no reduced precision or approximate grain is enabled.
- Six checked float64 CAM16 setup artifacts. Missing/stale/corrupt artifacts
  compute the same table with invariant work hoisted and at most four joined
  row workers. Ordinary builds need neither Python nor a rebake. Immutable DI
  curves are deinterleaved once instead of allocating vectors for every sample.
- Native Metal archives built and bundled alongside safe-math IR. Exact archive
  hit first, ordinary IR compilation on a missing/incompatible entry. No runtime
  source JIT or archive writer. Each engine owns a finite pipeline map.
- Explicit Metal command-buffer/encoder ownership and local autorelease pools
  bound temporary metadata even on a worker thread without a Cocoa run loop.
  Fix the pre-existing borrowed-`MTLDevice` reference leak: retain at creation,
  release at teardown. Error teardown also releases unsubmitted inline arguments
  before destroying their pool.

## Comparison and measurement limits

The **before** arm is the original full research-v2 renderer, not the optical
app base: minilab enabled, fixed factory exposure at 2%, checkpoint reuse off.
The **after** arm is the integrated product engine with its default v2 behavior.
Both use the same r=1 resources, native exact grain seed, glare off, meter off,
Portra/Endura, ProPhoto input and sRGB output. The synthetic exposure/colour ramp
is identical. `provenance.json` pins source, binary, resource and research-patch
identities. Test photographs stay outside the repository.

Apple M3 Max, 36 GiB, macOS 27.0.1. Three ABBA blocks for each resolution/edge
condition: six fresh processes per arm, **72 processes / 432 renders**. Each
process measures creation, open, first full render, four grain edits and a
cached reprint. First total = create + open + first render. Later-grain medians
include all three subsequent edits, including any cache miss or retirement.
The first-grain column includes full computation and checkpoint admission.

Timings exclude RAW decode, Python startup, UI display and host output copies.
They use the existing Metal driver cache: **fresh process is not cold boot or a
fresh shader cache**. `/usr/bin/time -l` peak physical footprint includes host
input and driver memory; it is not RSS or just the engine pool ledger.

Storage-management and WindowServer activity was substantial and variable.
Raw samples include load/process snapshots. These are interleaved measurements
on a shared machine, not guaranteed throughput or clean isolated GPU timings.
Peak RAM ranges retain transient allocation variation. The first grain edit can
be slower because it pays for admission, and cached reprints do not show a
consistent improvement. Small frames can carry modest fixed memory overhead.

<!-- BEGIN RESULTS -->
All times below are medians in milliseconds; RAM is the measured MiB range.

| Input | Edges | First total, before → after | First grain edit, before → after | Later grain edits, before → after | Reprint, before → after | Peak MiB, before → after |
|---|---|---:|---:|---:|---:|---:|
| 4.37 MP | off | 428.2 → 272.2 | 81.2 → 104.8 | 70.3 → 62.8 | 14.2 → 15.3 | 620–656 → 629–661 |
| 4.37 MP | on | 739.9 → 521.3 | 198.1 → 232.2 | 209.8 → 100.6 | 32.5 → 35.0 | 1034–1084 → 1005–1011 |
| 24 MP | off | 768.2 → 597.6 | 301.6 → 377.1 | 319.5 → 196.1 | 75.7 → 64.0 | 2431–2615 → 2167–2347 |
| 24 MP | on | 1140.9 → 961.2 | 652.6 → 708.2 | 675.3 → 277.3 | 141.8 → 105.9 | 4629–4908 → 4217–4492 |
| 45.45 MP | off | 1118.6 → 886.9 | 633.6 → 703.5 | 598.2 → 340.3 | 148.2 → 117.1 | 4395–4741 → 3886–4228 |
| 45.45 MP | on | 2176.2 → 1949.1 | 1562.8 → 1767.9 | 1528.4 → 598.3 | 300.3 → 324.3 | 8572–9096 → 7797–8318 |

At 45.45 MP with edges, first total improves by 10.4%, later grain edits by 60.9%, and median peak footprint falls by 775 MiB. The checkpoint is admitted on all six edge-on 45 MP processes; smaller/cheaper prefixes sometimes decline or retire it. Those misses remain in the reported medians.

After 40 complete engine lifetimes, the final ten physical-footprint samples are 67 MiB with required archives and 75–76 MiB with IR compilation. FD counts remain fixed at 7 and 6. The pre-cleanup archive run ended around 238 MiB. These are native harness measurements; an app may already drain some temporary objects through its own autorelease pools.
<!-- END RESULTS -->

`benchmark.json` holds individual samples and `benchmark-summary.json` their
medians, RAM ranges and checkpoint events. `summarize.py` regenerates the latter.
The earlier comparison before the final ownership fixes is retained separately,
so the final source identity is not conflated with an earlier measured binary.

## Precompilation versus JIT

The preceding GPU study forced shader-identity misses with newly named kernels,
without purging the global driver cache. At 4.37 MP with edges, runtime pipeline
compilation took median 393.44 ms versus 2.21 ms with a native archive; first
total was 739.08 versus 325.35 ms (two identities per arm, excluding archive
construction). This is a separate shader-cache-miss experiment, not an OS reboot
or the integrated benchmark above. Raw results are `research-fresh-compile.json`.

Source JIT for the two fusion kernels cost 233.52 ms on first compilation; a
matching archive took 0.77–1.00 ms to create those pipeline states. IIR function
specialization gained only about 1% in isolation. Neither source JIT nor IIR
specialization is enabled. `research-source-compile.json` retains that probe.

The native builder enumerates all **46** kernels. Required-archive checks confirm
hits for the exercised pipelines on this M3 Max. Other GPU/OS/toolchain pairs
may compile the bundled macOS-15 safe-math IR instead. A research `metal-tt`
macOS-15-target archive missed this macOS-27 runtime while a target-27 archive
hit; that does not qualify target-27 native code for macOS 15.

The supplementary `research-cold.json` measures the earlier research candidate
with checkpoints disabled on both arms (72 fresh processes). It supports the
cold-setup investigation; it is not substituted for the integrated-engine data.

## Correctness and lifetime gates

- 16 full-v2 comparisons bit-exact at RGBA16: six output spaces, edges, halation
  zero, DIR off/high, DI, scan-film, positive/unqualified stocks and encoded input.
- 64 checkpoint/full comparisons exact, including `scene_curve`, geometry,
  grain active/sublayers, halation zero and DIR changes. Twelve injected
  write/read/truncation-failure comparisons exact. These correctness tests force
  admission to exercise file reuse even on a slow SSD; production timings use
  measured admission. Traces prove actual hits rather than silently testing
  full recomputation twice.
- Six photographic comparisons exact, including the real 45 MP frame with and
  without edges, plus date exposure and 120 6×7 on the smaller photograph.
- Missing/corrupt calibration and changed profile identity rejected; an
  unqualified film remains independent of the Portra table.
- All six CAM16 artifacts (276,480 doubles) match computation; corrupt metadata,
  payload, truncation and nonfinite data trigger exact fallback. Optional native
  archive off/missing/corrupt/foreign modes render identically; strict mode
  rejects an invalid/incomplete archive.
- Direct DIR and gamut fusion comparisons are float32 bit-exact at 24/45 MP.
  The preceding direct timings measured DIR 6.13→3.87 / 11.07→6.52 ms and gamut
  18.09→15.94 / 34.27→30.49 ms (24 / 45 MP respectively).
- Optical-oracle diagnostic mode (`SPK_V2_REFERENCE_OPTICAL=1`): setup 227
  quantities, schema, 27 render cases, all 100 live fields, nine grain density
  levels and eight print LUT tables passed. This validates common math, not
  minilab appearance. Default-v2 Decode, B&W and striped-executor checks passed.
  GPU smoke and deliberate unsafe-math rejection passed.
- 64 sessions / 192 renders audited: no outstanding pooled images on the new
  engine, no persistent session buffers after close, no ownership-audit errors,
  stable descriptor counts. Engine teardown also has archive-on/off physical
  footprint traces; these include OS/driver caches and are not a proof that
  every driver allocation returns immediately.
- Borrowed-device regression was red at **+32 references / 32 engines**, green
  at **0** after the fix. Unsubmitted rejected dispatch teardown also passes.
- Universal Catalyst static engine and Debug Catalyst app build successfully.
  Bundled CAM16/minilab bytes match the qualified artifacts. No app installation
  or interactive GUI smoke test was performed. CMake/Vulkan builds were not
  run (CMake is unavailable on this host); the core target declares its new
  thread dependency explicitly.

## Reproduce

The original research baseline is reconstructed from `unpublished-revision` and the ordered
patches pinned in `provenance.json`; the ignored research directory is an explicit
offline prerequisite. Product builds use only tracked resources.

```sh
engine/build.sh dylib
engine/build.sh tests
engine/build/device_lifetime_checks engine/resources
engine/build/cam16_bake_checks engine/resources
SPK_METAL_ARCHIVE_MODE=required engine/build/fusion_checks engine/resources 6000
python engine/tests/v2_integration_checks.py check --before "$BEFORE" --research-dir "$RESEARCH" --output check.json
python engine/tests/v2_integration_checks.py bench --before "$BEFORE" --research-dir "$RESEARCH" --output benchmark.json
python engine/tests/v2_integration_checks.py lifecycle --before "$BEFORE" --research-dir "$RESEARCH" --output lifecycle.json
python engine/tests/performance_cache_checks.py --output cache.json
python engine/tests/minilab_resource_checks.py --output resources.json
python engine/tests/performance_engine_lifetime.py --archive required --output engine-lifetime.json
```

Use a Python environment with numpy for these harnesses. The legacy parity
scripts additionally use the external Python oracle via `PYTHONPATH`;
`parity_lut.py` needs `SPEKTRALAB_REFERENCE_ROOT`. The 1 MP smoke fixture must
exist in `tests/Test_image/`; missing fixtures are not counted as passes.
`research-comparison.py` replays the earlier research-only optimization study.
