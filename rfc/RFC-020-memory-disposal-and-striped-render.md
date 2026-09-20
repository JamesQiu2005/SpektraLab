# RFC-020 — Memory the engine gives back, and a frame it can develop in pieces

| | |
|---|---|
| **Status** | **Proposed 2026-09-20.** Not implemented. No code changed by the session that wrote this, beyond `b61282c`, which landed first and is this RFC's starting line. |
| **Date** | 2026-09-20 |
| **Author** | Diagnosis session, at the user's request, from a shipped-app report: a Hasselblad X2D 16-bit RAW (11656 x 8742 = 101.9 MP) reaching 23 GB on a 24 GB M5 |
| **Depends on** | RFC-014 (the engine is in-process, so its allocations are *this* process's footprint), RFC-016 (`MemorySampler` is the one source of numbers), RFC-019 (the client arena exists and its accounting is sound), and `b61282c` |
| **Scope — engine** | disposal: trimming the buffer pool, answering memory pressure, reporting holdings to the arena. And within-frame: an **optional** striped execution mode with a **bit-identical** output gate. |
| **Scope — app** | the strip-wise ingestion that feeds it, and the one Settings switch that turns the mode on |
| **Out of scope** | **RFC-021** — choosing the strip height dynamically from free memory and the app's cap. This RFC must make that a policy swap and nothing more; §7 is the contract it owes RFC-021. Also: which *layer* the disk cache should hold (§8.1), RFC-017 batch processing. |
| **Hard gate** | **Zero precision loss.** Every mode this RFC adds produces output bit-identical to today's, or it does not ship. §5.1. |
| **Superseded numbers** | **§1 and §1.1 describe the pre-class-R engine.** The figures to quote are in "Final baseline" at the end: 4.1 / 7.0 / 7.9 / 13.7 GB peak at 24 / 45 / 61 / 102 MP, measured on the packaged 1.0.3 app. |
| **Amended** | **2026-09-20 — §4.2 and P4 were wrong about one node.** `boost` holds an image-global statistic and cannot be striped; §4.4's ~6 GB estimate is now known to be optimistic in two identified places. See the amendment at the end; read it before trusting §4.2's table, P4's headline claim, or §4.4's estimate. |

---

## 0. Why

`b61282c` fixed a real defect — `alloc` grew the pool while holding 13.1 GB of
dead-but-not-yet-reusable buffers — and took the 101.9 MP peak from **28.9 GB
to 19.1 GB**, bit-identical, measured. That was the free half.

§1.1 then measured the app's own path on three real 100 MP cameras, and the
honest picture is better than the synthetic one: **15.6 GB after the fix
against 25.3 GB before**, which means `b61282c` is very probably the whole of
the reported bug. **This RFC is therefore not a rescue.** It is written on the
assumption that "fits a 24 GB Mac with nothing to spare, behind a 12 GB Core
Image decode spike" is not where a 100 MP camera should leave the product.

The remaining gap is not a defect. It is the shape of the pipeline: at the full
tier the engine genuinely holds about nine 1.22 GB planes at once, and nothing
about that is wasteful. You cannot fix it by finding another bug. You fix it by
developing the frame in pieces, or not at all.

There is a second, separate thing wrong, and it is worth naming apart from the
first: **the engine never gives anything back.** The pool is not trimmed at
`end_frame`, not trimmed on a frame switch, not trimmed when the OS asks, and
not reported to the arena RFC-019 built. A 102 MP frame's pool survives a
switch to a 24 MP one. The app has a GDSF eviction policy governing about 2 GB
of client textures while 19 GB sits outside its view — which is exactly the
condition RFC-019 §P6 was written to detect: *"if the arena says 3 GB and the
process says 11 GB, something outside the arena holds 8 GB and that is a bug
with a name."* This RFC gives it the name.

So: **Part A is disposal** (§3) — what the engine keeps and for how long.
**Part B is within-frame** (§4) — how much it holds at once.

---

## 1. Where the 19.1 GB is

Boundary samples, **measured** on a 38.7 GB M3 Max, 11656 x 8742, the engine
driven directly through the C ABI with no Core Image in the process
(`phys_footprint`, the number `MemorySampler` reads):

| boundary | footprint | delta |
|---|---|---|
| engine created + warm-up | 2.14 GB | — |
| `open` | 3.36 GB | **+1.22** — one full plane: `session->source` |
| `solve` | 5.84 GB | +2.48 — the meter tier and its work |
| render live | 6.49 GB | +0.65 |
| **render full** | **18.27 GB** | **+11.78** |
| render full, again | 19.08 GB | +0.82 — the rgba16 result |

A full-frame plane at this size is **1.22 GB** (px x 3ch x f32). Within the
+11.78 GB, tracing the pool gives a **measured live peak of 11.0 GB across 13
buffers**, reached inside the grain and DIR-coupler diffusion stages
(`spk_grain_layer_one`, `spk_sep_fir_acc`, `spk_couplers_correction`).

*Derived, not measured* — the persistent holdings inside that total, from the
code: `session->source` (1.22 GB, `alloc_persistent`, lives as long as the
session), the cached negative at the full tier (1.22 GB, what makes a reprint
12 ms instead of 107), and the rgba16 result (0.82 GB, handed to the caller +1).

### 1.1 The real baseline: three 100 MP cameras, the app's own path

The table above is the engine driven alone on a synthetic frame. **This one is
the app's actual open path** — `CIRAWFilter` for both looks, the canvas preview
texture, `engineFrame`, `spk_open_device`, `solve`, then both tiers — measured
on real files in `spektrafilm/tests/Test_image/large_raws`, one process per
file, 2026-09-20, same machine:

| | GFX100 II | GFX100S | CFV 100C |
|---|---|---|---|
| frame | 11648 x 8736 | 11648 x 8736 | 11664 x 8750 |
| **Core Image transient, at the preview texture** | **11.66 GB** | **12.12 GB** | **8.53 GB** |
| after warm-up (Core Image has given it back) | 1.76 | 1.76 | 5.31 |
| `spk_open_device` | 5.61 | 5.66 | 5.43 |
| solve | 6.45 | 6.50 | 6.27 |
| render live (2678 px) | 7.09 / 155 ms | 7.15 / 171 ms | 6.92 / 179 ms |
| **render full** | **15.55 GB** / 2059 ms | **15.55 GB** / 2216 ms | **15.58 GB** / 2224 ms |
| compressions during the full render | 185,292 | 106,291 | 99,059 |
| **peak** | **153 B/px** | **153 B/px** | **153 B/px** |

Three different cameras, three different RAW formats, **153 bytes a pixel every
time**. That consistency is itself useful: the per-pixel cost is a property of
the pipeline, not of the file.

Two things this baseline says that the synthetic one could not:

- **There are two peaks in a session, not one, and the first one is Core
  Image's.** Making a 2678 px preview of a 102 MP RAW costs a transient of
  8.5–12.1 GB, before the engine has been asked for anything. It is genuinely
  transient — the footprint falls back to 1.8 GB — and it is a high-water mark
  rather than a per-frame addition (§2), but on a 24 GB machine it is a spike
  that has to fit, and it varies by 3.6 GB between two cameras of the same
  resolution. `DecodeResidency.estimatedBytesPerPixel = 90` (9.2 GB here) sits
  inside that range but does not cover the Fuji case.
- **`b61282c` is very likely the whole of the reported bug.** The same
  Hasselblad file, same probe, with the pre-fix engine: **peak 25.31 GB
  (248 B/px), full render 3852 ms, 726,983 compressions** — against 15.58 GB,
  2224 ms and 99,059 after. 25.3 GB is what "23 GB on a 24 GB M5" looks like
  from the other side of the ceiling, and 15.6 GB fits.

That does not retire this RFC. 15.6 GB plus a 12 GB decode spike on a 24 GB
machine is survival, not headroom, and §3's disposal work is unaffected by it.
But it does change the urgency of §4: the striped mode is what makes 100 MP
comfortable, not what makes it possible.

### 1.2 Two facts about the machine

Both measured, and both shaped everything below:

- **Page faults are cheap.** Between the pre- and post-`b61282c` builds, minor
  faults moved only 548,288 -> 473,082, and at 45.4 MP they are *identical*
  (210,792 both) with no speed difference at all.
- **Crossing into the compressor is expensive.** The same A/B shows
  **1,377,634 system compressions during one full render at 28 GB, against 0
  at 19 GB** (`vm_stat`, sampled around the render). ~22 GB compressed is the
  whole of the 4.76 s -> 1.85 s.

This inverts the reasoning in `MetalGpu::end_frame`'s comment, which declines
to trim because "trimming would hand every 540 MB buffer back to the OS and pay
the page faults again on the next render." The page faults are the cheap half.
Residency past the threshold is the expensive half. §3.1.

It also bounds the honesty of any speed claim: **the 2.6x this fix showed at
102 MP is this machine's threshold, not a property of the fix.** On the 24 GB
Mac that reported the bug, 19 GB is still over the line. Nothing in §3 or §4
should be sold as "faster".

---

## 2. What this is not about

**`Diagnostics.forecastBytesPerPixel = 167` needs no change, and an earlier
draft of this section was wrong to say it did.** That draft read 187 and
284 B/px off the *synthetic engine-only* probe, which carries a 1.22 GB host
array the app does not have, and concluded the constant under-predicted by
40 %. §1.1 measures the app's own path instead: **153 B/px** after `b61282c`,
on three cameras, so 167 is conservative and correct today. It was *not*
correct at the time the bug was reported — the pre-fix path measures
**248 B/px**, which is why the Settings warning did not fire for that user —
but the fix moved the truth under the constant rather than the constant under
the truth. Re-validate it at 45 MP before trusting it everywhere; do not
change it.

**Core Image is a bounded high-water mark, not a leak, but it is not nothing.**
Measured in a process the engine was absent from: 101 B/px peak, ~85 B/px
retained, a second decode costs nothing more, and `CIContext.clearCaches()`
frees nothing. At 45 MP that is 4.6 GB and unremarkable. At 102 MP §1.1 shows
it as an 8.5–12.1 GB transient spike that precedes every render — the first of
the session's two peaks. The client side of RFC-019 accounts for it honestly
(`DecodeResidency` estimates 90 B/px against a measured 85), so nothing here is
mis-reported; it is simply larger than a 24 GB machine has room to be relaxed
about. Reducing it is the client's problem and §4.7's striped ingestion is the
lever. This RFC is otherwise about the other side of the C ABI.

---

## 3. Part A — disposal

### 3.1 The pool is trimmed, on the two occasions that are not "between nodes"

`pending_`/`reusable` handles reuse *within* a render, and `b61282c` handles it
within a stretch with no flush in it. Neither returns anything to the OS, ever.

Two trim points, and deliberately not a third:

1. **On a frame switch** — a new `spk_open` on an engine whose previous session
   is gone, or any `open` whose frame differs in size from the pool's buffers.
   Free every pool buffer at `refs == 0`. A 102 MP pool has no business
   surviving into a 24 MP frame, and §1 says the re-fault costs little.
2. **On memory pressure** — §3.2.

**Not** at `end_frame`. Within a session, editing the same frame, the existing
comment is right: the same sizes come back immediately and the pool is exactly
the structure that should hold them. The change is that "keep it" stops meaning
"keep it forever".

### 3.2 The engine answers memory pressure

There is no `DISPATCH_SOURCE_MEMORYPRESSURE` anywhere in the engine. Add one,
owned by `Gpu`, with two levels:

- **warn** — trim the pool to the current frame's live high-water.
- **critical** — trim everything at `refs == 0`, and set a flag the next
  `spk_render` reads. What it does with the flag is §4's mode, if the mode is
  on; if it is off, it does nothing but report, because a render that is
  already encoded cannot be made smaller.

The handler must not free a buffer with `refs > 0` and must not run inside
`pool_lock_`. Both are the ordinary shape of this file's bugs.

### 3.3 The engine tells the arena what it holds

`capabilities` already reports `max_mp` and setup-cache stats. Add a cheap
`spk_memory_report(engine)` returning pool total, live bytes, free bytes,
persistent bytes, and the per-session source/negative sizes. `Diagnostics`
registers it as one `pinned` arena entry per session plus one for the pool, so
`MemoryArena.breakdown()` and the Settings page stop being a readout of 2 GB
next to a 19 GB process.

This closes RFC-019 P6 rather than extending it. The number to watch is the
gap, and the acceptance is that the gap becomes small and stays small.

### 3.4 Two latent defects, found while reviewing `b61282c`

Both belong here rather than in a separate commit, because both are about the
same lifetime:

- In `flush`, the `Clear` destructor that releases `inflight_` runs **after**
  `reclaim()`, so those buffers land in `pending_` already reclaimed and wait
  for the *next* flush to become reusable. Pre-existing; `b61282c` shortens
  that wait rather than lengthening it.
- `reclaim()` drops any `refs > 0` buffer from `pending_` **without** marking
  it reusable, which would strand it for the engine's life. No reachable path
  to that state was found — `release` only pushes at `refs == 0` — so this is
  another instance of the repeat shape in `guards-that-cannot-fire`: before
  fixing it, establish whether it can fire, and if it cannot, say so in the
  code instead of adding a branch nothing reaches.

---

## 4. Part B — the striped render

### 4.1 Strips, not tiles

This is the single most consequential decision in the RFC, and it is forced by
two independent things in the existing code:

**Grain's randomness is keyed on the linear pixel index.** `grain.metal:6`
already says it: *"randomness is Philox keyed on (pixel, stream, seed), which
is tile-invariant"*, and the kernels do `Rng rng(i, streams[col], seed)` where
`i` is the thread's linear index. For a **full-width horizontal strip**, the
global index is the local index plus a single uniform offset `y0 * W` — one
extra `uint` in the meta block and grain is bit-identical. For a rectangular
tile it is a per-row `(x, y) -> y * W + x` remap, which is doable but is a
second indexing convention to keep correct in six kernels forever.

**The blurs recur along an axis.** `spk_iir_vertical_df_acc` marches a
3rd-order forward-then-backward recurrence down a column, one thread per
(column, channel). A horizontal strip cuts that recurrence in exactly one
place per column, which is the case §4.3 can make exact with a carried state.
Rectangular tiles cut it in both axes and multiply the bookkeeping by nothing
useful.

So: **strips are full-width horizontal bands.** Height is a parameter. The last
one is shorter when the count does not divide the height, and §6's verification
requires exactly that case.

### 4.2 The node taxonomy

Every node in `run_film` and `run_print`, and what a strip needs from it.
Classes: **P** pointwise, **I** pointwise-but-index-dependent, **F** FIR
neighbourhood, **R** IIR recurrence, **G** geometric resample, **C** constant
from setup (nothing needed).

| node | class | what a strip needs |
|---|---|---|
| `input_cast`, `decode_input` | P | nothing |
| `geometry` | G | a rotated source rect — **stays whole-frame in v1**, §4.5 |
| `auto_exposure` | C | the EV is **injected** from the solve's 1600 px meter tier |
| `crop_rescale` (pitch) | C | `source_long_edge_` — a trap, §4.5 |
| `upsample` (Hanatos tc/b + 2D LUT) | P | nothing |
| `exposure`, `boost` | P | nothing |
| `lens_blur` | F/R | halo or carried state by sigma |
| `halation` (scatter + N bounces, `Blur::mixture`) | F/R | same |
| `expose_log`, `film_curves` | P | nothing |
| `dir_couplers` (+ diffusion `mixture`) | F/R | same |
| `grain` (incl. dye-cloud blur) | I + F/R | global index offset; one seed per render |
| `enlarger_spectral`, `print_exposure`, `print_curves` | C+P | gains are host constants |
| `scan_spectral`, `bw_correction` | C+P | `correction_line` is host-side |
| `glare` | I + F/R | field is `Rng(i, ...)` — same offset; then a blur |
| `xyz_to_rgb`, `edr`, `gamut_compress` | C+P | all baked tables |
| `scanner_blur`, `unsharp` | F/R | halo or carried state |
| `cctf` | P | nothing |

**The finding that makes this RFC possible: there is no image-global statistic
anywhere in the full-tier render.** Auto exposure is metered once on a 1600 px
tier and injected as one scalar (RFC-015 P.1). The black/white correction line,
the print exposure gains, the CAM16 tables, the EDR LUT — every one of them is
a constant produced by the setup maths, not by looking at the full-resolution
frame. So there is no two-pass "gather statistics, then apply" anywhere, and
the print exposure the user worried about is a host-side gain that does not
know how big the image is.

This is also what makes `export-must-match-canvas` survive striping unchanged:
the stats that must be computed once per frame already are, on a tier that is
never striped.

### 4.3 The four rules, and why there are no seams

Seams are not blended away. **There is no blending anywhere in this design.**
Each class has an exact rule, and a node that cannot be given one does not get
striped — it stays whole-frame and the mode simply saves less (§4.6).

- **P — pointwise.** A strip is a contiguous slice of the same array. Exact by
  construction.
- **I — index-dependent (grain, the glare field).** One extra `uint` of global
  row offset in the meta block; `Rng(i + offset, stream, seed)`. The seed is
  drawn once per render and shared by every strip — today `fresh_seed()` is
  called inside the node, so it must be hoisted to the render, which is a
  change even the un-striped path is better for.
- **F — FIR (small sigma).** The strip is computed with a halo of `R` rows
  above and below, where `R` is the same `gaussian_kernel_1d(sigma, truncate)`
  radius the kernel already uses, and the halo rows are discarded. Exact,
  because every output row sees the same inputs it sees today.
- **R — IIR (large sigma).** The recurrence is **carried, not truncated.** The
  forward pass sweeps strips top to bottom keeping `(w1, w2, w3)` per column
  per channel; the backward pass sweeps them bottom to top keeping
  `(y1, y2, y3)`. That state is `W x 3ch x 3 x 2` floats — **840 kB at
  11656 px wide**, i.e. free. The boundary initialisation (`w1=w2=w3=x0` from
  the global first row, and the backward pass from the global last row) is
  applied once at the true edges and never re-applied at a strip boundary.
  Exact, because it is the same recurrence in the same order.

**The transpose has to go, and that is the price.** The horizontal blur is
currently done by transposing the whole image so the recurrence marches
contiguous memory. A transpose is all-to-all: a strip of the transposed image
draws from every strip of the original, so it cannot be striped at all. The
striped path instead runs the horizontal recurrence **along rows in place**
(stride 3 rather than `W*3`), which makes every row independent and therefore
perfectly strip-local. The arithmetic per row is unchanged — same coefficients,
same `df` double-float ops, same order — so it is **bit-identical**. What
changes is only which addresses the threads touch, and the cost is
uncoalesced reads. That is the largest single component of the slowdown in
§4.6, and it is a real cost paid for a real thing.

An `R` pass therefore needs the whole plane for the axis it recurs along, and
**one plane, not two**: the backward sweep in `spk_iir_vertical_df_acc` reads
`out[idx]` and writes `out[idx]`, so it runs in place over the forward pass's
output (and applies the mixture accumulation on the way). What it cannot do is
start before the forward sweep has finished the whole axis. That is why §4.4's
memory model keeps full-frame planes at the *boundaries* of the strip graph and
strip-sized buffers everywhere inside it.

### 4.4 What it actually saves

The saving is not in the data — a 102 MP frame's input and output are 1.22 GB
and 0.82 GB whatever you do. The saving is in the **intermediates**, which are
the nine planes.

Sketch at 101.9 MP with 8 strips (each ~1275 rows, ~153 MB a plane):

| holding | today | striped |
|---|---|---|
| `session->source` | 1.22 GB | 1.22 GB (or §4.7) |
| cached negative | 1.22 GB | 1.22 GB (or §4.7) |
| render working set | **~11.0 GB** | ~9 x 153 MB = **~1.4 GB** |
| the `R` passes' plane-for-the-axis | — | 1.22 GB, one at a time |
| rgba16 result | 0.82 GB | 0.82 GB |
| **peak** | **15.6 GB measured** (§1.1) | **~6 GB, estimated** |

The "today" column's rows are derived and its total is measured; they agree to
about a gigabyte, which is the pool's high-water above the live set.

**That last number is an estimate and must be labelled one.** It assumes the
`R` passes need one full plane at a time and not two, and it assumes no node
falls back to whole-frame. The first thing step 1 in §8 does is replace it with
a measurement.

Even at the estimate's pessimistic end this is the difference between "cannot
open the file" and "opens, slowly" on a 24 GB machine — which is the outcome
the user who reported this asked for.

### 4.5 Traps, named before anyone hits them

- **`source_long_edge_` must not be derived from a strip.** `node_geometry`
  does `source_long_edge_ = std::max(in.h, in.w)` and `run_film` does
  `if (source_long_edge_ == 0) source_long_edge_ = std::max(cur.h, cur.w)`.
  With strips, `cur.h` is the strip height, so the film's pixel pitch
  (`pixel_size_um_`) would be wrong — and every micrometre-specified effect,
  which is grain, halation, the coupler diffusion and the lens blur, converts
  through it. **The frame's dimensions must be passed down, never inferred**,
  and the same goes for `frame_long_edge_`, which `glare` and `unsharp` use to
  compute their tier ratio.
- **`fresh_seed()` is called inside `node_grain` and `node_glare`.** Hoist it to
  the render, or every strip gets a different grain realisation and the seams
  the user asked about would appear — as the one and only place they could.
- **`geometry` stays whole-frame in v1.** An output strip of a rotated resample
  draws from a rotated source rect whose halo is a function of the angle. It is
  computable, it is exact, and it is not where the memory is (one pass, two
  planes, run once). Striping it is a later increment, not a v1 requirement.
- **A strip's `Image` must carry its origin.** `Image` today is `{buf, h, w, c}`
  with no offset, and `image.hpp` is explicit that there is no stride and no
  padding. A strip type that silently reuses `Image` is how the global-index
  offset gets forgotten in one kernel out of six. Give it a distinct type, or
  a `y0` field that every `I` and `R` node is required to read.

### 4.6 What it costs, and the escape hatch

The user has already accepted that this is slower. Naming where it comes from,
so the measurement in §8 has something to check against:

1. **Uncoalesced horizontal recurrence** (§4.3). Expected to dominate.
2. **Two sweeps per `R` pass** instead of one transposed pass.
3. **Halo recomputation** for `F` nodes: with strip height `h` and radius `R`,
   the overhead is `2R/h`. At the shipped sigmas `R` is small and `h` is
   >1000 rows, so this is low single-digit percent.
4. **More dispatches**, `n_strips` times as many, each with its own encode.

Against that, one thing pushes the other way and should not be forgotten: a
striped render that keeps the process under the compressor threshold avoids the
1,377,634 compressions §1 measured. On a machine where today's render is over
the line, striped may well be *faster* in wall-clock even while being slower in
work done. That is a fact about the user's machine, not a claim about this
design, and it must not be put in a release note.

**The escape hatch is per node, not per render.** A node whose exact strip rule
is not implemented yet declares itself whole-frame; the executor materialises
the full plane for it and strips resume afterwards. This is what lets the mode
ship with `geometry` unstriped, and it is what keeps the zero-loss gate
absolute: there is never a reason to approximate, because "do it whole" is
always available.

### 4.7 Ingestion: not dumping the photo in at once

The user's framing — *不是照片一股脑丢进内存里* — is the input side, and it is
a separate change from the execution side.

Today `ImageDecoder.engineFrame` renders the whole linear decode into one
float32 RGBA `MTLBuffer` (1.63 GB at 102 MP) and `spk_open_device` borrows it;
the engine then makes its own persistent 3-channel copy via `spk_take_rgb`
(1.22 GB). Both exist in full at the same moment.

Core Image renders a sub-rect happily (`bounds:`), so the client can produce
strips. The C ABI needs a pull or push form — `spk_open_begin` /
`spk_open_strip` / `spk_open_end`, additive, exactly as `spk_open_device` was
added additively. That alone removes the 1.63 GB transient.

It does **not** by itself remove `session->source`, because every tier
downscale reads from it and every reprint reads the cached negative. Removing
those two needs something else.

**Back `session->source` and the cached negative with a file, not wired
memory** — `MTLDevice.makeBuffer(bytesNoCopy:)` over an `mmap`'d, page-aligned
file, so the kernel can drop clean pages under pressure instead of the app
holding 2.4 GB. On Apple silicon that is the same unified memory the GPU reads.

This was the one speculative idea in the first draft. **It has been measured**
— `rfc/probes/rfc020-mmap-plane.swift`, 2026-09-20, at the 102 MP plane size —
and it works:

| | ordinary `.storageModeShared` | `bytesNoCopy` over a file |
|---|---|---|
| Metal accepts it for compute | — | **yes**, kernel output correct |
| `phys_footprint` for a 1.22 GB plane | **+1.232 GB** | **+0.135 GB** |
| resident (`mincore`) | 1.22 GB | **1.225 GB** |
| GPU read, alternated, median of 3 | 10 ms | **10 ms (1.01x)** |
| host fill | 139 ms | 175 ms (**1.26x**, ~+34 ms per open) |

The pages are genuinely in RAM — `mincore` says so — and are **about nine
times less charged to the process**. That is the whole of the idea and it
holds. `msync` costs 218–536 ms and is **not** needed: the footprint benefit
applies to dirty file-backed pages as measured, so nothing forces a write-back
and the kernel does it lazily, under pressure, if at all.

So §4.4's two 1.22 GB rows are movable, and moving them takes **~2.4 GB off
the 15.6 GB peak for ~34 ms per open** — before any striping at all, and with
none of §4's complexity. That makes it the cheapest real win in this RFC and
it is sequenced accordingly (§9).

**One thing the probe could not answer, and this RFC must not pretend
otherwise.** `madvise(MADV_DONTNEED)` does not drop residency for a
`MAP_SHARED` file mapping on macOS — measured: still 1.225 GB resident — so an
application cannot force the reclaim, and inducing real system-wide pressure to
watch the fault-back is not something to do casually on a working machine.
**The eviction path is therefore inferred, not measured**: we know the pages
are not charged and we know the kernel *may* drop them, but we have not
observed what a render pays when it has to fault 1.22 GB back from SSD
mid-flight. At ~3 GB/s that is ~400 ms if it happens all at once, which is
survivable, but it is arithmetic and not a measurement. The acceptance test in
§6 should include a machine deliberately squeezed, or the claim stays
qualified.

---

## 5. Principles

**P1 — Bit-identical or it does not ship.** Not "within float32 epsilon", not
"visually identical". The verification in §6 is a hash, and the reason the gate
can be this strict is §4.2: every node has an exact rule or stays whole. This
also protects `export-must-match-canvas`, which is the user's standing hard bar
and which a per-tile approximation would quietly violate.

**P2 — Strips, because the existing code already chose that shape.** §4.1.

**P3 — The mode is optional and off by default.** A wire field and a Settings
switch. The un-striped path is not refactored into a special case of the
striped one; it stays exactly what ships today, and that is what makes the
hash comparison in §6 meaningful.

**P4 — Nothing is measured at the full tier, and nothing may start.** The
absence of image-global statistics is load-bearing. A future node that wants
one must either take it from the meter tier, like auto exposure does, or
declare itself whole-frame.

**P5 — Sizing is a seam, not a policy.** §7.

**P6 — What the engine holds is visible to the arena.** §3.3, closing
RFC-019 P6.

---

## 6. Verification

The mode changes no pixels, so the harness is a hash, and the interesting part
is choosing strip counts that break assumptions:

- `parity_render` gains a strip-count axis. For each existing case, render
  whole and render with `n_strips ∈ {1, 2, 3, 8, 17, H}` and require the
  **sha1 of the rgba16 to be identical in every one**. 1 proves the mode
  degenerates correctly; 3 and 17 do not divide typical heights, so the short
  last strip is exercised; `H` is one row per strip, which is where a carried
  IIR state is either right or obviously wrong.
- The same across both tiers and both `render` and `reprint`, because a reprint
  re-enters at `run_print` with a cached negative and that is the path
  `parity_session` exists for.
- **A grain case with `grain_sampler = "stochastic"`** — whole vs striped with
  the seed hoisted. If the seam problem exists anywhere, it is here.
- A memory assertion, not just a hash: peak `phys_footprint` at 102 MP with
  8 strips must be under a stated bound. `guards-that-cannot-fire` applies —
  the assertion must be shown to fail on the un-striped build before it is
  trusted green.
- The six existing harnesses unchanged, with **freshly built drivers**:
  `build.sh dylib` alone leaves `dump_json`/`dump_setup`/`gpu_smoke` stale, and
  that trap was live as recently as `b61282c`.

---

## 7. What RFC-021 needs from this one

RFC-021 chooses the strip height from free memory and the app's cap at runtime.
It must be able to do that **without touching any node**. So this RFC owes it
exactly three things, and owes it nothing else:

1. **Strip height is a parameter of the execution, not of the graph.** No node
   may cache anything keyed on strip height, and no baked constant may depend
   on it. The setup cache's keys are already the right shape; nothing may be
   added to them here.
2. **A single policy call site.** One function — `choose_strip_height(frame,
   node_graph, budget) -> rows` — with a constant implementation in RFC-020.
   RFC-021 replaces the body. If that function is called from more than one
   place, RFC-021 becomes a refactor instead of a swap.
3. **The engine can be told a budget and can report its holdings**, §3.3. The
   budget is accepted and recorded in RFC-020 even though nothing varies with
   it yet, so RFC-021 does not have to add an ABI field.

Correspondingly, RFC-020 must **not** implement: heuristics, adaptation
mid-render, per-node budgets, or any reading of system memory inside the
engine. `MemorySampler` is the one component that reads the kernel (RFC-016
§8.5) and that does not change.

---

## 8. What is not proposed

- **No halo approximation, no feathering, no overlap blending.** P1.
- **No half precision** in the blur accumulators or anywhere else. It was the
  obvious way to halve the plane size and it is a precision loss.
- **No rectangular tiles.** §4.1.
- **No automatic enabling.** RFC-021.
- **No change to what any render produces**, on either path.
- **No revisiting the disk cache's layer.** Separately: the app caches the
  *finished print*, which by measured cost is the cheapest thing to remake
  (121 ms warm) and the thing invalidated by every slider, while the
  **negative** (~107 ms, invalidated only by film-layer changes) lives and dies
  with a session pointer and RFC-019 §4 explicitly forbids persisting it — on
  reasoning inherited from when the engine was a subprocess and the format was
  not ours. That reasoning expired with RFC-014. **It is a real question and it
  is not this RFC's**, because caching never fixes a peak-footprint problem;
  it belongs in whichever RFC revisits RFC-019 §8.
- **No raising or lowering of `kMaxFramePixels`.** It is 151 MP and it admits
  frames no 24 GB Mac can render. That is the user's standing 2026-09-12
  decision, taken on a 36 GB machine on the premise that nothing above 102 MP
  was realistic; a 102 MP customer now exists, so the premise has changed and
  the decision is the user's to re-take, not this RFC's to assume.

---

## 9. Sequencing

Deliberately ordered so each step is independently valuable and the expensive
step is the last one:

1. **Accounting first** (§3.3). The engine reports; the arena registers; the
   Settings page and the `memory` record show the gap. This is the instrument
   every later step is graded with, and it is the step that replaces §4.4's
   estimate with a measurement. It changes no behaviour.
2. **Disposal** (§3.1, §3.2, §3.4). Trim on frame switch, answer pressure, and
   settle the two latent defects. Measurable on its own: switching from a
   102 MP frame to a 24 MP one must return the pool.
3. ~~The `mmap` probe.~~ **Done, 2026-09-20; the answer is yes** (§4.7,
   `rfc/probes/rfc020-mmap-plane.swift`). What replaces it is the work it
   cleared: **back `session->source` and the cached negative with file
   mappings.** ~2.4 GB off the peak for ~34 ms per open, no striping, no
   pixel change — the cheapest real win here, and it moves ahead of everything
   in §4.
4. **The strip executor with every node whole-frame.** A striped render that
   materialises each node's full plane saves nothing and must be
   bit-identical — which makes it a pure test of the plumbing, the offsets and
   the traps in §4.5, with the hash from §6 as the gate.
5. **Class P and I nodes striped.** Most of the graph, no boundary maths.
6. **Class F, then class R.** In that order: FIR halos are simple and prove the
   halo bookkeeping before the carried IIR state, which is the genuinely subtle
   one.
7. **Striped ingestion** (§4.7), client and ABI.

Steps 1 and 2 are worth doing even if 4 onwards never happens.

---

## 10. Open questions

1. ~~Is one full plane enough for an `R` pass, or two?~~ **Resolved while
   writing this: one.** `spk_iir_vertical_df_acc`'s backward sweep reads and
   writes `out[idx]` in place. §4.3.
2. **Does the dye-cloud accumulation survive striping cheaply?**
   `node_grain`'s sub-layer path accumulates three blurred layers into one
   `grain` buffer via `blur_.gaussian(..., &grain, one)`. Under strips that
   accumulator is strip-sized, which is fine, but the loop currently holds
   `layer` and `accumulated` simultaneously and that is 2 of the 9 planes.
   Worth checking whether it can be one.
3. **What strip height is sane as RFC-020's constant?** It should be chosen
   once, measured, and left alone until RFC-021. A candidate is "whatever makes
   a strip's working set ~512 MB", which at 102 MP is roughly 8 strips.
4. **Does the app want a progress granularity change?** `spk_progress` reads
   between nodes; with strips there are `n_strips` times as many boundaries,
   which is either a nicer progress bar or a noisier one.

---

## Amendment, 2026-09-20 — `boost` is not pointwise, and P4's premise is false for it

Written after step 5 (class P striped, `bfe3b37`) where the §6 hash axis caught
this on its first real run. The body of the RFC above is left as it was
believed; this section is what the code and the gate established.

### What was wrong

**§4.2's table lists `boost` as class P — pointwise, needing nothing from a
strip. It is not.** `node_boost` normalises its highlight lift by
`device_max(in)`: a reduction over every pixel of the frame. On a band it
normalises each strip by that strip's own brightest pixel, which is a different
picture at every strip height — including `n = 1`, which is how the failure was
diagnosed rather than survived.

**The node said so in its own comment.** `pipeline.cpp`'s `node_boost` reads
*"normalised by the frame's own maximum — so it is image-global, which is why it
cannot be baked into a LUT"*, and `git log -S` dates that comment to the
RFC-014 port, long before this RFC was written. So §4.2's taxonomy was built by
reading node bodies and missed one that announces itself. That is the more
useful statement of the error than the misclassification itself.

### What replaces it

§4.2's headline finding — **"there is no image-global statistic anywhere in the
full-tier render"** — is false. There is one: `boost`'s maximum. Everything else
in the finding survives, and it survives differently now: the claim was
*checked*, node by node, instead of inherited from a reading.

**P4 is corrected to:**

> **The engine's image-globals are enumerated and closed.** `boost` holds one:
> the frame's maximum, reduced once per run, because its highlight lift is
> normalised by it. It takes §4.6's escape hatch and declares itself
> whole-frame, so it never sees a band. **A node that acquires another must do
> one of two things, and there is no third**: declare itself whole-frame, or
> take its statistic from the meter tier the way auto exposure takes its EV.
> The second is exact and *changes the picture*, so in a bit-identical step only
> the first is available. What may not happen is a global that reaches a band.

**And P4's enforcement is mechanical now, not editorial.** A rule addressed to
whoever writes the next node with nothing firing if they ignore it is the
"guards that cannot fire" defect this repository keeps finding in its own
tests. §6's hash enforces P4 only when a parity case exercises the new node **at
a non-default parameter** — the precise condition that made `boost` invisible to
`strip_executor.py` at `boost_ev = 0` and visible to `parity_render`'s axis. So
`engine/tests/band_purity.py` walks the call graph from every stage whose table
entry says `band_able` and fails if any path reaches `device_max`, `read_back`
or `exposure_sample_y`. It is a source check: no dylib, no render, no
parameters, so it fires on the *addition*. It also verifies its own sink list
against the tree and pins the stage-table parse, and `--self-test` asserts the
verdict flips — including with `film_boost_and_blurs`'s whole-frame marker
removed in memory, where it reports `film_boost_and_blurs -> node_boost ->
device_max`.

Its documented blind spot, so the guarantee is not read as wider than it is: a
node that reads frame-level state which is not computed from pixels —
`pixel_size_um_`, the tier ratio, the run's seed, a setup table. `unsharp`,
`glare`, `lens_blur`, `grain` and `dir_couplers` all read such state and are
correctly band-able; a band reads the same values. The line P4 draws is
"computed from the plane's pixels".

### The checked classification

Every node in both chains, swept 2026-09-20 for reductions (`device_max`,
`read_back`, `exposure_sample_y`), host reads of device memory, and closures
over state outside the node's own input. Twenty-five nodes: film's `input_cast`,
`decode_input`, `geometry`, `auto_exposure`, `upsample`, `exposure`, `boost`,
`lens_blur`, `halation`, `expose_log`, `film_curves`, `dir_couplers`, `grain`;
print's `enlarger_spectral`, `print_exposure`, `print_curves`, `scan_spectral`,
`bw_correction`, `glare`, `xyz_to_rgb`, `edr`, `gamut_compress`,
`scanner_blur`, `unsharp`, `cctf`.

| verdict | nodes |
|---|---|
| **Disagrees with §4.2** | `boost` — reduction over the frame (§4.2: P) |
| Agrees, reads frame-level **constants** | `lens_blur`, `halation`, `dir_couplers`, `unsharp` (`pixel_size_um_`, the tier ratio), `geometry` (`source_long_edge_`), `grain`, `glare` (both, plus the run seed) |
| Agrees, reads **host constants** baked by its prefix | `enlarger_spectral`, `print_exposure`, `bw_correction`, `gamut_compress`, `auto_exposure` |
| Agrees, and reads nothing outside its input | `input_cast`, `decode_input`, `upsample`, `exposure`, `expose_log`, `film_curves`, `print_curves`, `scan_spectral`, `xyz_to_rgb`, `edr`, `cctf` |

The distinction that matters in that table is not which nodes are "clean" but
which read state that is **frame-level by construction** (`pixel_size_um_`, the
tier ratio, the setup tables, the run's seed) as against state that would have
to be *computed from* a band's pixels. Only the second kind is a
misclassification. `boost` was the only one of those.

Two consequences for step 6, both from the same sweep: `unsharp` and `glare`
read the *frame's* long edges for their tier ratio and are correctly classed
F/R — they need the plane for their halo and field, not for the ratio, so
nothing about them changes when a band arrives. And `auto_exposure`'s class C is
sound because `blur_.affine` is pointwise, unlike `blur_.gaussian`; a future
pointwise node calling `gaussian` would be the same error as `boost`.

### §4.4's estimate is optimistic in two places, both identified

§4.4's peak row reads **"~6 GB, estimated"** and its caveat already says the
estimate "assumes no node falls back to whole-frame". That assumption is now
known to be **violated in two places**, both found while doing the sweep above
and both the size of a full 102 MP plane — **1.22 GB each**:

1. **`boost` is whole-frame**, so a full plane must exist where §4.4 counted a
   band, and it sits *inside* what would otherwise be the film side's first
   band run.
2. **The `log_and_curves → couplers` crossing holds `log_e_film` as a second
   live plane.** `node_dir_couplers` takes both planes, which is why `Chain`
   carries `cur` *and* `log_e_film` and why a crossing between a band run and a
   whole-frame stage must copy every live field. That second plane is live
   across the band run of the stage that produces it.

### Step 6-R: what the transpose removal changed, and the instrument it found broken

**Class R is not opt-in, and that is new for this RFC.** §9's steps 4 to 6-F all
left the un-striped path untouched, so their gate was "striped == un-striped".
R removes the IIR's transpose on the *shipping* path — every render, mode or no
mode — and the gate that can fail is therefore **new engine against old engine,
byte for byte** (`engine/tests/iir_bitexact.py`).

**That gate caught a real defect on its first run, and the parity harnesses
could not have.** The transposed path was horizontal-first and the first draft
of the rewrite ran vertical-first; a separable IIR's two passes commute in exact
arithmetic and *not* in floating point, so every value moved in the last place.
`parity_render` holds the engine to the Python reference at 1e-5 — a bar set by
the reference being a different implementation in a different language — and a
last-place change is invisible to it by construction. **Any future step that
alters the shipping arithmetic needs the byte comparison, and R is the first
that did.**

**And the instrument was broken.** Measuring the saving (45.7 MP for the
preliminary estimate, 102 MP on a clean machine for the replacement of §4.4)
turned up a defect in this RFC's own accounting, §3.3's: `release` subtracted a
**persistent** buffer's bytes from the pool's `live_bytes_`, which had never
counted them, so the `size_t` wrapped to `2^64 - 1` — and `frame_high_water_bytes`
follows that sum, which is what the memory-pressure handler trims to (§3.2). The
effect is that a pressure event arriving after any persistent buffer was released
would have trimmed to eighteen exabytes, i.e. done nothing, silently disabling
the feature this RFC's §3.2 exists to provide. Fixed by counting persistent
buffers in `persistent_bytes_` and nowhere else, and by clamping rather than
wrapping, with a `live_underflows` counter that must stay zero. Found by a
two-session sequence, not by any of the probes written to check that accounting --
and **it shipped in 1.0.2**: `be7705e` and `a9021ff` are ancestors of
`spektralab-v1.0.2`, so on those installs §3.2's warn-level trim has been sized
from a wrapped sum since the first frame switch of a session. Critical still
trims and nothing renders differently; the level below it simply stops doing
anything. Two days of green probes did not see it because every one of them
opened a single session per engine.

**This is not a re-estimate and the ~6 GB is not being defended.** §9 step 1's
promise stands unchanged: the first thing Part B does is replace the estimate
with a measurement, and that measurement is what any later number comes from.
What is recorded here is only what the estimate is now *known* to leave out, so
that nobody quotes ~6 GB as though the sweep had left it untouched. The saving
the section claims — a band's working set against the ~11 GB of intermediates —
is unaffected by either omission.

---

## Final baseline, 2026-09-20 — four resolutions, the shipped app, a continuous probe

**This supersedes §1 and §1.1 as the number to quote.** Those tables were
measured before class R removed the blur's transposes and they describe an
engine that no longer exists. This one is the **packaged 1.0.3 app**, cold-opened
on one frame at a time, sampled by an external probe rather than by the app's
own boundaries.

### Method, and why it is not §1.1's

`proc_pid_rusage` → `ri_phys_footprint` every **25 ms** from a separate process
— the same quantity as `task_vm_info`'s `phys_footprint`, which is what
`MemorySampler` reads and what Activity Monitor's Memory column shows, so the
figures are comparable to both. Driven against
`SpektraLab --snapshot 1400x900 out.png --open FILE --wait 70`.

Two reasons a continuous probe was necessary:

- **The app's own `memory` records under-report the peak by about a gigabyte.**
  On the 102 MP run the highest boundary sample is **12,694 MB** against the
  probe's **13,723 MB**, because `sampleMemory` fires once a phase has settled
  and part of the transient is already given back. Settings ▸ Memory ▸ Session
  peak is sound for comparing two builds and is a **lower bound**, not the peak.
- **Activity Monitor cannot resolve it at all.** It refreshes every 1–5 s
  against phases that last one to three seconds.

### The numbers

| frame | pixels | **peak** | decode peak | peak falls in | full render | open path |
|---|---|---|---|---|---|---|
| 24 MP | 6000 x 4000 | **4,129 MB** | 1,672 MB | `first_print` | 1,120 ms | 2,014 ms |
| 45 MP | 8256 x 5504 | **7,026 MB** | 4,273 MB | `engine.open` | 2,119 ms | 2,744 ms |
| 61 MP | 9504 x 6336 | **7,899 MB** | 3,821 MB | `full_render` | 2,601 ms | 3,167 ms |
| 102 MP | 11664 x 8750 | **13,723 MB** | 8,835 MB | `full_render` | — | — |

Against a 16 GB machine: 26 %, 44 %, 49 % and 86 % of it. **At the mainstream
resolutions the product is comfortable rather than tight** — a 61 MP frame
leaves 8 GB free — and only 102 MP is close to the ceiling, on hardware those
users are unlikely to own.

### What this corrects

**Core Image's decode is *not* the binding peak, and an earlier reading of this
RFC said it was.** The 102 MP run has two humps and the second is far larger:
decode reaches 8,835 MB at t+2.25 s and falls back to ~6 GB, then the full
render reaches **13,723 MB** at t+5.0 s. The render is the peak by **4.9 GB**.
The error came from comparing a user-reported 11.84 GB against §1.1's
8.53–12.12 GB Core Image range and concluding it fell inside — two different
quantities on two different paths. **Striped ingestion (§4.7) would therefore
not move the binding number**, which is worth knowing before anyone spends
§9 step 7 on it.

**`Diagnostics.forecastBytesPerPixel = 167` is now conservative rather than
correct.** Measured here: **172 B/px at 24 MP, 155 at 45 MP, 131 at 61 MP,
135 at 102 MP.** §2 of this RFC measured 153 B/px and concluded 167 was
"conservative and correct"; class R moved the large-frame figure down to about
135, so the constant now over-predicts by roughly a quarter at the sizes where
the warning matters. Over-prediction is the safe direction — the warning fires
early rather than late — so this is a tuning note and not a defect.

**Where the peak falls is not a fixed answer.** At 24 MP it is in the
`first_print` window, at 45 MP in `engine.open` (the decode's output and the
engine's own copy of the frame are both live), and only at 61 MP and above is
it the full render. A reader looking for "the peak" in one place will find it
in the wrong one at three of these four sizes.

### One trap in reading the app's logs

A `decode` record of **12,714 MB** appears in an interactive session on the same
Hasselblad frame, against **8,835 MB** measured cold. That session had already
developed two 45 MP frames and the figure carries their residue. **Cold-open a
frame before quoting its decode cost**, or the number belongs to the session
rather than to the file.
