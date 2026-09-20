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

---

## 0. Why

`b61282c` fixed a real defect — `alloc` grew the pool while holding 13.1 GB of
dead-but-not-yet-reusable buffers — and took the 101.9 MP peak from **28.9 GB
to 19.1 GB**, bit-identical, measured. That was the free half.

**19.1 GB still does not fit a 24 GB Mac**, and the remaining gap is not a
defect. It is the shape of the pipeline: at the full tier the engine genuinely
holds about nine 1.22 GB planes at once, and nothing about that is wasteful.
You cannot fix it by finding another bug. You fix it by developing the frame in
pieces, or not at all.

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

Two facts about the machine that shaped everything below, both measured:

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

`Diagnostics.forecastBytesPerPixel = 167` under-predicts by ~40 % at 102 MP
(measured 187 B/px after `b61282c`, 284 before), so the Settings warning did
not fire for the user who reported this. That is a one-constant fix in the app
and it belongs in a commit, not an RFC. It is named here only so it is not
lost.

And **Core Image is not implicated.** Measured in a process the engine was
absent from: 101 B/px peak, ~85 B/px retained, and — the load-bearing part —
it is a **high-water mark, not a per-frame addition**: a second decode costs
nothing more, and `CIContext.clearCaches()` frees nothing. `DecodeResidency
.estimatedBytesPerPixel = 90` is a good estimate. The client side of RFC-019 is
working as designed. This RFC is about the other side of the C ABI.

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
| **peak** | **19.1 GB** | **~6 GB, estimated** |

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
those two needs something else, and here is the one genuinely speculative idea
in this RFC, flagged as such:

> **Back `session->source` and the cached negative with a file, not wired
> memory.** `MTLDevice.makeBuffer(bytesNoCopy:)` over an `mmap`'d,
> page-aligned file would let the kernel evict clean pages under pressure and
> fault them back from SSD, instead of the app holding 2.4 GB wired. On Apple
> silicon that is the same unified memory the GPU reads.
>
> **This must be measured before it is designed in.** Two things are unknown:
> whether Metal accepts a no-copy buffer over a file mapping for compute, and
> whether clean pages of such a mapping actually stay out of `phys_footprint`
> — which is the only number that matters here, because it is the one jetsam
> reads. A half-day probe settles both. If either answer is no, this idea is
> dropped and §4.4's table keeps those two rows at 1.22 GB.

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
3. **The `mmap` probe** (§4.7). Half a day, and it decides whether two 1.22 GB
   rows in §4.4's table are movable at all. Do it before designing around them.
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
