# RFC-019 — Memory that is owned, accounted and capped, so the app cannot eat the machine

| | |
|---|---|
| **Status** | **Proposed 2026-09-14.** Not implemented. No code changed by the session that wrote this. |
| **Date** | 2026-09-14. Revised the same day with §2 (the cost estimate), §8 (the print cache) and §10 (the data structures), at the user's request. |
| **Author** | Diagnosis session, at the user's request, from the 09:44–09:57 freeze on the Nikon Z7 II folder |
| **Depends on** | RFC-014 (the engine is in-process, so its allocations are *this* process's footprint), RFC-016 (`MemorySampler` is the one source of numbers, and the Settings Memory section already exists) |
| **Scope — app** | ownership and accounting of every allocation over ~16 MB; the decoded-frame residency; the print cache; a transient texture pool; making the Settings memory cap enforce something; eviction |
| **Scope — engine** | **none required.** The engine already reports `max_mp` and borrows the caller's frame buffer without keeping it. This RFC is about the client's own holdings. |
| **Out of scope** | RFC-017 batch processing. Chunked / strip rendering (RFC-016 §11.5 ruled it out and that stands). Changing what any render *produces* — this RFC changes who holds it and for how long, never the pixels. |
| **Companion** | `PRD/IMPL-RFC-019-memory.md` — the implementation logic. `PRD/BUG-DIAGNOSIS-2026-09-14-export-and-decode.md` §1 — the evidence. |

---

## 0. Why

`~/Library/Logs/Filmify/filmify-2026-09-14T09-44-15-19555.jsonl`, on a 38.7 GB
M3 Max, browsing 45 MP NEFs:

```
launch          182 MB
frame_switch    274 MB
decode         4364 MB     ← one decode
engine.open    4530 MB
first_print    5725 MB
frame_switch  10680 MB     ← second frame, before it decoded
decode        14765 MB     ← peak. free 13.6 GB
…then 10.5–10.9 GB for the next eleven minutes, with nothing on screen
```

Three things are wrong here and only one of them is a leak in the ordinary
sense.

1. **Nothing large is owned.** The decoded frame is a bare `var decoded:
   DecodedImage?`. The native original is a bare `var original: MTLTexture?`.
   The proof is a bare `@State var proof: SoftProof?` holding a 363 MB
   `CGImage`. Each is dropped when something happens to overwrite it, and
   nothing in the app can answer "how much am I holding, and what would I give
   back if asked".
2. **The Settings memory cap does not cap anything.** `Diagnostics
   .memoryReserveMegabytes` (default 2000) is read in exactly one place —
   `Diagnostics.projection(pixels:)`, `Diagnostics.swift:410` — where it
   produces a **sentence**. Its own note says so: "under it gets a warning you
   can dismiss — never a refusal" (`Diagnostics.swift:154`). Two call sites ask
   for that sentence (`Session.swift:1444`, `:2161`). No allocation is refused,
   deferred, shrunk or evicted anywhere in the app on account of it. The user's
   instruction is that this number must start meaning something.
3. **The decoded RAW is thrown into memory and left there.** The user's words:
   "解码之后的原有 raw 不能直接丢在内存里然后不做管理". Correct — and it is
   worse than a single unmanaged frame, because §1.2 of the diagnosis shows the
   decode runs in uncancellable detached tasks, so several unmanaged frames can
   be live at once with no owner and no way to count them.

RFC-016 gave us the *numbers*. This RFC gives them somewhere to be acted on.

---

## 1. Where the memory actually is

Every holder above ~16 MB in the client, at 45 MP (45,441,024 px), preview edge
2678:

| # | holder | size | owner today | freed when |
|---|--------|------|-------------|-----------|
| 1 | `DecodedImage` (`linear` + `display` `CIImage`s) | ~4.1 GB at decode; how much is *retained* vs pooled is unmeasured — see §2.4 | `Session.decoded`, a bare `var` | overwritten by the next frame — **but only if no detached task still holds one** |
| 2 | Engine frame (`EngineFrame.buffer`, float32 RGBA, `.storageModeShared`) | **727 MB** (log: `"mb": 727.056`) | local, passed to `spk_open_device` which borrows and returns | end of `openInService` — already right, and its doc comment says why |
| 3 | Native original (`Renderer.original`) | **364 MB** rgba16 | `Renderer.original`, a bare `var` | replaced on frame switch |
| 4 | Full render slot (`TextureStore.full`) | **364 MB** | one slot, stamped | `dropFullRender()` |
| 5 | Preview sources + prints (`TextureStore.sources`, `.prints`) | 38 MB each, LRU 8 + 8 = **~610 MB** | `TextureStore`, capacity 8 | LRU |
| 6 | The `apply*` chain (`applyLayer2` → `applyGeometry` → `applyResize` → `applyOutputTransform`) | **364 MB each**, up to ~1.5 GB live at once | nobody — each `store.makeWritable` allocates fresh (`Renderer.swift:811, 832, 613, 587`) | ARC, at the end of the chain |
| 7 | Soft proof / file preview `CGImage` | **364 MB** each (`makeCGImage` copies into a `Data`, `Renderer.swift:902`) | `ExportPage.@State proof`, `@State filePreview` | a new proof, or the page closing |
| 8 | `ThumbnailCache` | unbounded; ~1 GB on a 300-frame folder | `[URL: CGImage]`, **no eviction, key ignores `maxPixel`** | never |
| 9 | Per-render thumbnail copy (`Session.updateThumbnail`, `:1664`) | one full CPU copy per landed print (38 MB) | a detached task | end of task |
| 10 | Engine session (working negative + pipeline buffers) | **~1.2 GB** (log: 4530 → 5725 MB across open + first print) | the engine, per open session | `spk_close` |

Only #2, #4, #5 and #10 have an owner that knows the size. The rest are bare
`var`s and one unbounded dictionary.

`TextureStore.makeWritable` uses `.storageMode = .shared`
(`TextureStore.swift:117-121`). On Apple Silicon that is unified memory counted
against `phys_footprint` — the number the jetsam killer reads. There is no
"GPU memory" hiding these; they are the 10.5 GB.

---

## 2. What this costs and what it buys

All timings below are **measured**, from the log named in §0, on this machine
and this folder. Nothing here is a guess except where it says so.

### 2.1 The measured primitives

| operation | ms | n |
|---|---|---|
| RAW decode, both looks (Core Image) | 162–209 | 3 |
| preview texture render (2678 px) | 276–337 | 3 |
| engine frame render (linear → float32 shared buffer) | 351 | 1 |
| `engine.open` at 45 MP | 150 | 1 |
| solve | 370 | 1 |
| **live** reprint, cold negative | 99–116, median **107** | 5 |
| **live** reprint, warm negative | **12** | 1 |
| **full** render, cold negative | 660–799, median **672** | 5 |
| **full** render, warm negative | 90–157, median **121** | 12 |
| engine warm-up (once per session) | 3752 | 1 |

### 2.2 Live editing: unchanged, and that is the point

The user's assumption is correct. The frame being edited is **pinned** — its
engine session, its live print and its full-render slot are never evictable —
so nothing in this RFC touches the interactive path.

| action | today | after | why |
|---|---|---|---|
| print-layer slider (warm negative) | **12 ms** | 12 ms | untouched |
| film-layer slider (cold negative) | **107 ms** | ~107 ms | untouched |
| full-tier settle after an edit | 672 ms cold / 121 ms reprint | same | untouched |
| **the same, during rapid interaction** | **unbounded** — the log shows 11 min with no render at all | ~the isolated figure | the cooperative pool is no longer saturated by uncancellable stale work |
| thumbnail refresh per landed print | +38 MB CPU copy, every tick | throttled to a settled edit | one copy per edit, not per tick |

So: **best case unchanged, worst case is the entire fix.** The overheads this
RFC adds to the interactive path are an `admit` call per allocation (a lock and
a heap push, microseconds) and an `enforce` per memory sample (O(log n), at
boundaries only, not per draw). Against 12–107 ms these are unmeasurable.

The one way live editing could get *worse* is the print cache's writeback
competing for SSD bandwidth mid-edit. §8.5 bounds that: one entry in flight, at
`.utility`, drop-oldest on backlog.

### 2.3 Frame switching: this is where it improves

Derived recompute costs for a frame whose engine session is gone (which is every
frame but the current one):

| to get | sum of primitives | ms |
|---|---|---|
| a picture on screen (display decode) | 209 + 276 | **485** |
| a live-tier print | 209 + 351 + 150 + 370 + 108 | **1188** |
| a full-tier print | 1188 + 672 | **1860** |

Restore from the SSD instead, at a conservative 3 GB/s plus the texture upload:

| entry | read | upload | total |
|---|---|---|---|
| 38 MB (display decode, live print) | 13 ms | 2 ms | **~15 ms** |
| 364 MB (full render) | 121 ms | 15 ms | **~136 ms** |

| path | today | after |
|---|---|---|
| revisit, print still in the LRU-8 | instant | instant (unchanged) |
| revisit, evicted, **look only** | 485 ms + ~4 GB transient, and still no print | **~15 ms**, no transient |
| revisit, evicted, **then edit** | ~1188 ms | ~1188 ms — *unchanged by design* |
| a frame never opened before | 485 ms | 485 ms (unchanged) |

The third row is the honest one. **The linear decode and the engine session are
deliberately not cached** (§4), so the first edit after a revisit still pays the
full setup. The cache buys looking, comparing and re-exporting; it does not buy
editing. That is the right trade — a 363 MB linear cache is the thing RFC-014
already retired once.

### 2.4 RAM: 10.5 GB → an estimated 2.5–4.5 GB, with one honest unknown

Steady state, one 45 MP frame open and developed, not comparing, not exporting:

| holding | class | MB |
|---|---|---|
| engine session (working negative + pipeline) | engine-side, counted not evicted | ~1200 |
| current display decode | pinned | **unknown, 100–1500** — see below |
| previous frame's decode | evictable | same order |
| source preview texture | pinned | 38 |
| live print | pinned | 38 |
| full render slot | pinned | 364 |
| native original (deferred; only while comparing or zoomed) | pinned when live | 364 |
| `TextureStore` LRU, 8 + 8, at cap | evictable | ≤610 |
| scratch pool, idle | evictable | ≤727 |
| thumbnails, capped | evictable | ≤256 |
| print-cache writeback staging, 1 entry | evictable | ≤364 |
| **sum of the knowns, everything at its cap** | | **~3960** |

Realistically the LRU is not full, the native original is not resident unless
asked for, and the scratch pool is dropped when idle: **2.5–4.5 GB steady**,
against a measured 10.5–10.9 GB today. Peak during a 45 MP export: the scratch
pool in use plus the output `CGImage`, **~5 GB**, against a measured 14.8 GB.

**The unknown, named.** One decode moves `phys_footprint` from 274 MB to
4364 MB. How much of that 4.1 GB is *retained* by the two `CIImage`s and how
much is Core Image's pools and transients is not determinable from the log —
`CIImage` is a recipe, and `.cacheIntermediates: false` is already set
(`ImageDecoder.swift:135`), which argues for "mostly transient"; the footprint
never falling below 10.5 GB argues the other way. This band is the whole
uncertainty in the estimate above.

**This is why §12 sequences accounting before policy.** Step 1 registers what
already has an owner and logs the arena's total beside `phys_footprint`; the gap
between them *is* the answer. If the retained share turns out to be over ~1.5 GB
per frame, the response is already designed for: drop the residency from 2 to 1
and let the disk cache serve the previous frame. No redesign, one constant.

---

## 3. Principles

**P1 — Nothing large is held by a bare `var`.**
Every allocation over a threshold (proposed: 16 MB) is taken from, and returned
to, an accounted arena. "How much is this app holding" becomes a property that
can be read, logged and asserted, rather than inferred from `phys_footprint`.

**P2 — The Settings memory numbers are enforced, not narrated.**
The existing **Reserve** becomes an admission and eviction trigger. It keeps its
meaning and its dismissible-warning behaviour for the case RFC-016 §11.5
reserved it for, and additionally becomes the thing that makes caches give
memory back. See §5.

**P3 — The decoded RAW has an explicit, bounded residency, and disk is the cache.**
The user: "好像不需要高速缓存，反正都在 ssd 里". Agreed. The in-memory residency
is small and fixed; everything else is a file on the SSD. A miss costs a file
read, not a 4 GB re-decode.

**P4 — A finished picture is kept if keeping it is cheaper than making it again,
and dropped otherwise.**
The user: "if they could be fit into the disk cache then they are stored, if not
they're abandoned and recalculated". Exactly — with the refinement that "worth
keeping" is a measured ratio, not a yes/no about space. §8.

**P5 — Transient textures come from a pool, not from `makeWritable`.**
The `apply*` chain allocates and discards ~1.5 GB per export or proof, at the
same sizes every time. §9.

**P6 — A number that is displayed is a number that is enforced, and vice versa.**
RFC-016 §8.5 established "the memory numbers are the same numbers". The Settings
page shows the arena's own accounting beside `phys_footprint`, and the gap
between them is itself diagnostic: if the arena says 3 GB and the process says
11 GB, something outside the arena holds 8 GB and that is a bug with a name.

---

## 4. What is *not* proposed

Written down because a worker session reaching for memory savings will find each
of these attractive, and each is either already settled or already tried and
retired.

- **No chunked or strip rendering.** RFC-016 §11.5 decided this: a frame either
  fits or the user is warned and may proceed.
- **No caching of the linear decode or the engine frame.** There used to be a
  4 GB on-disk LRU of linear TIFFs (`Session.legacyLinearCache`,
  `Session.swift:1682-1700`); it existed because the engine was in another
  process and took a file. RFC-014 retired it and `removeLegacyLinearCache()`
  deletes what it left. **Do not rebuild it.** The caches here hold the
  *display* decode and the *finished print* — 38 MB and 364 MB an entry, read by
  the canvas, not by the engine.
- **No caching of the engine's working negative.** It is the engine's, it is
  ~1.2 GB, and `negative_cached` in the render record already shows the engine
  reusing it within a session. Persisting it would be caching an intermediate
  whose format we do not own.
- **No `NSCache`.** It evicts on the system's schedule, not ours, and reports
  nothing.
- **No lowering of `previewLongEdge` as a memory fix.** It is a quality setting
  the user has already tuned (2678, up from the 2560 default).
- **No engine-side change.**

---

## 5. The budget model

Two numbers, because they answer two different questions.

### 5.1 Reserve — "leave the machine this much" (existing setting, now enforced)

`Diagnostics.memoryReserveMegabytes`, default 2000, range 0…32768. Keep the
name, the storage key (`diag.memoryReserveMB`), the range and the Settings row.

New meaning, in three places:

1. **Admission for a render (unchanged in spirit).** `forecast + reserve <= free`?
   If not, warn. `allowOverReserve` still dismisses it. RFC-016 §11.5, unchanged.
2. **Eviction (new).** On every sample, if `free < reserve`, evict the
   lowest-value evictable entries until `free >= reserve` or nothing evictable
   is left. This is what makes the setting real.
3. **Admission for a cache (new).** The arena refuses to *admit* an entry that
   would push `free` under `reserve`; it evicts first, and if it still does not
   fit, the entry is not cached. A cache that cannot be filled is a slow app; a
   cache that swaps is a hung one.

### 5.2 Working-set cap — "this app may hold this much" (new setting)

`Diagnostics.memoryCapMegabytes`. Default `min(8192, 40 % of physical RAM)` —
8192 on this 38.7 GB machine. Range 2048…131072, plus an explicit "Unlimited".

It bounds the arena's **evictable** total, independent of how much the machine
happens to have free, because "free" is set by the other applications and a
photo app that expands to fill whatever Chrome is not using is the app that gets
killed when Chrome comes back.

Non-evictable holdings (the frame on the canvas, the render in flight) are
counted but never evicted. If pinned alone exceeds the cap, that is a warning
and a log record, not a refusal — the frame on screen is not optional.

---

## 6. The arena

One type, `MemoryArena`, living beside `MemorySampler` in `Diagnostics`
(§11 Q1).

```
final class MemoryArena {
    enum Class { case pinned, evictable }
    struct Handle: Hashable { … }

    func admit(bytes: Int, cls: Class, kind: String,
               costMs: Double, evict: @escaping () -> Void) -> Handle?
    func release(_ h: Handle)
    func touch(_ h: Handle)
    func enforce(sample: MemorySample, reserve: UInt64, cap: UInt64) -> Int

    var totalBytes: Int { get }
    var evictableBytes: Int { get }
    func breakdown() -> [(kind: String, bytes: Int, count: Int)]
}
```

Rules:

- `admit` returns nil when the entry cannot fit even after eviction. Callers
  handle nil by **not caching** — never by failing the user's operation.
- The `evict` closure drops the caller's reference. The arena owns the
  *accounting* and the *policy*, not the object. That is what lets one policy
  cover `MTLTexture`, `CIImage` and `CGImage` — three unrelated types with three
  lifetimes — without a wrapper for each.
- **`costMs` is measured, not guessed.** It is what this entry actually cost to
  produce, and the app already has it in hand: `LoadClock` laps the open path
  and every render record carries `elapsed_ms`. §8.3 is what it is for.
- `enforce` is called from `MemorySampler.sample`, so every RFC-016 boundary is
  also an eviction opportunity, in the one place that already has the numbers.
- `breakdown()` is what Settings shows and what the `memory` record gains.

### 6.1 Who registers

| holder (from §1) | class | notes |
|---|---|---|
| #1 decode residency | current pinned, previous evictable | §7 |
| #3 native original | pinned while it is the canvas's `original` | deferred; see the decode-pipeline IMPL §5.2 |
| #4 full render slot | pinned | one slot, unchanged |
| #5 `TextureStore` LRU | evictable | its LRU becomes the arena's |
| #6 scratch pool | evictable when idle, pinned in use | §9 |
| #7 proof `CGImage` | pinned while displayed | shrinks to pane size — `PRD/IMPL-export-page-v2.md` §4.1 |
| #8 thumbnails | evictable | gains a byte cap |
| #2 engine frame | **not registered** | one call's lifetime; its doc comment explains why, and registering it would add a failure mode to the one allocation that is already correct |
| #10 engine session | counted, not evicted | reported for the breakdown so the arena's total can be compared honestly against `phys_footprint` |

---

## 7. The decoded frame: a managed residency

### 7.1 In memory

`Session.decoded: DecodedImage?` becomes a `DecodeResidency`:

- **Capacity 2**, fixed: the frame on the canvas (pinned) and the one before it
  (evictable). Two because A/B between two frames is the pattern the user has.
  Drop to 1 if §2.4's unknown comes back large.
- Keyed by `(URL, DecodeSettings)` — a white-balance change is a different
  entry, which is already how `decodeIsStale` reasons about it.
- **A `DecodedImage` may only be reachable through the residency.** No detached
  task may capture one and outlive the entry — which is the other half of the
  cancellation work in `PRD/IMPL-decode-pipeline.md` §3, and why that document
  is a prerequisite.

### 7.2 On disk

`~/Library/Caches/com.hanze.filmify/decode/` — `Session.cacheRoot` already
exists (`Session.swift:732`).

- One entry per `(file identity, DecodeSettings)`: the **display** decode
  rendered to `previewLongEdge`, as raw rgba16 (38 MB at 2678). Not the linear
  decode. Not full resolution. See §4.
- Key: SHA-256 of `(volume id + inode + size + mtime, DecodeSettings encoded)`.
  Path would break on a rename; identity without mtime would serve a stale
  picture after an edit in another application.
- Shares one store, one index and one eviction policy with the print cache: §8.

### 7.3 The three-tier read

```
display picture for (url, settings)
  → residency (RAM, ≤2)     hit: instant
  → disk                    hit: ~15 ms
  → CIRAWFilter decode      miss: ~485 ms and a ~4 GB transient
```

**Acceptance:** revisiting a frame performs no `CIRAWFilter` construction.
Assert with a decode counter on the `open` record, not with a stopwatch.

---

## 8. The print cache — where the finished picture goes

The question this section answers is the user's: once caches are capped and
evictable, *where does the finished processed image go?*

### 8.1 What "the finished picture" is, today

Three artifacts, and they are not equal:

| artifact | size | where it lives today | lifetime today |
|---|---|---|---|
| **live print** — the engine's output at `previewLongEdge`, what the canvas shows while editing | 38 MB | `TextureStore.prints`, LRU 8 | survives 8 frame switches, then gone |
| **full render** — the same at the frame's own resolution, what the canvas settles on | 364 MB | `TextureStore.full`, **one slot** | gone the moment another frame is opened |
| the exported file | — | the user's disk | theirs |

So today the answer is already "it is thrown away", and aggressively: the full
render — the most expensive thing the app makes — has a single slot and is
discarded on every frame switch. Capping the caches does not create this
problem; it makes an existing one visible.

Note what is *not* on this list: Layer 2 adjustments and geometry are applied at
draw time (`Renderer.ensureAdjusted`, and `geometryMap` at sample time), not
baked into the stored print. So a curve tweak or a crop **does not invalidate a
cached print** — which makes the cache far more useful than "any edit clears it"
would suggest.

### 8.2 The policy, in the user's words and then in numbers

> "if they could be fit into the disk cache then they are stored, if not they're
> abandoned and recalculated, since it's not too much effort"

Right, with one refinement: entries differ by **10× in size** and **2.5× in
recompute cost**, so "fits" is not enough to decide by. Keep an entry when

```
restoreCost < recomputeCost          — otherwise caching is a pessimisation
```

and, when the store is full, keep the entries with the highest

```
value density = recomputeMs / bytes  — ms of work saved per byte held
```

Both numbers are known, both measured. For a frame whose engine session is gone
(§2.3):

| entry | bytes | recompute | restore | value density |
|---|---|---|---|---|
| live print | 38 MB | **1188 ms** | 15 ms | **31.1 ms/MB** |
| display decode | 38 MB | 485 ms | 15 ms | **12.7 ms/MB** |
| full render | 364 MB | 1860 ms | 136 ms | **5.1 ms/MB** |

Read that ranking: under pressure the store keeps live prints first, display
decodes second, and **sheds full renders first** — the biggest, least
value-dense entry goes, and it is also the one that recomputes into a tier the
canvas only needs once an edit settles. That is exactly the behaviour we want,
and it *falls out of the policy* rather than being hand-coded. A plain LRU would
have done the opposite as often as not.

The rule also produces one useful "do not bother": for the **current** frame,
the live print recomputes in 12 ms with a warm negative, against a 15 ms disk
read. Do not write the current frame's live tier to disk — it is in RAM anyway
and restoring it would be slower than remaking it.

### 8.3 Where `recomputeMs` comes from

Measured, at the moment of admission, at no extra cost:

- render entries: `RenderOutcome`'s `elapsed_ms`, plus the session-setup cost
  the frame would have to pay again — `LoadClock`'s `decode_ms + frame_ms +
  engine_open_ms + solve_ms`, which the `open` record already carries.
- decode entries: `LoadClock`'s `decode_ms + preview_texture_ms`.

Storing the real cost rather than a constant is what makes the ranking in §8.2 a
measurement instead of an opinion, and it adapts for free to a different machine,
a different megapixel count or a faster engine.

### 8.4 The key

An entry is valid only for pixels that would be identical. The key is a hash of:

```
file identity (volume + inode + size + mtime)
DecodeSettings
FilmParams          — Layer 1 only; Layer 2 and geometry are applied at draw
tier                — "live" | "full"
previewLongEdge     — for the live tier
engine version      — the log already records it: "spektrafilm-native 0.1.0 (…, math=safe)"
container format version
```

`TextureStore.FullRenderEntry.stamp` already exists and is described as "the
Layer 1 parameters it was rendered from, which is what makes a lookup a cache
hit rather than a coincidence" (`TextureStore.swift:46-52`). This is that stamp,
extended and hashed. **The engine version is the one people forget**: a rebuilt
engine or a changed LUT makes every cached print silently wrong.

### 8.5 Writeback

Writing a 364 MB texture must never be on the interactive path.

- A **bounded FIFO**, depth 1 full-size entry (364 MB of staging) or 4 small
  ones, single consumer at `.utility`.
- **Drop-oldest on overflow**, and this is safe by construction: an entry that
  is never written is a recompute later, which is precisely the fallback the
  policy already assumes.
- Never during an active edit: the queue drains when the session is idle, the
  same "settled" signal `fullRenderDebounceMs` already uses.
- The staging copy is a `getBytes` into a `Data` (`Renderer.swift:914-921`).
  Making the render targets buffer-backed would let the write go straight from
  the texture's memory with no copy at all — a worthwhile optimisation, not a
  requirement.

### 8.6 One store, one index

The decode cache (§7.2) and the print cache are the same store with two `kind`s.
One directory, one SQLite index, one eviction policy, one cap, one Settings row.
Two caches with two policies would eventually disagree about which is allowed to
evict the other, and that argument has no correct answer.

Default cap 16 GB (up from the 8 GB proposed for decodes alone — a full render
is 364 MB and the point is to hold several). §11 Q3.

### 8.7 What the user sees

Nothing. A restored print and a recomputed one are the same pixels — the key
guarantees it — so there is no badge, no "cached" label and no setting beyond
the size and a Clear button.

This is also why removing the state pip (`PRD/IMPL-export-page-v2.md` §5) helps:
the app currently draws a dot meaning "this frame has a print", which under
eviction would be a claim about residency it cannot keep. Deleting it removes an
inconsistency rather than creating one.

---

## 9. The scratch pool

`TextureStore.makeWritable` (`TextureStore.swift:115`) becomes pool-backed:

- A free list keyed `(width, height, pixelFormat)`, at most 2 per key, total
  registered with the arena as evictable-when-idle.
- Borrow returns a `Scratch` whose `deinit` returns it, so no call site has to
  remember. The `apply*` chain then costs two live full-size textures instead of
  five.
- Dropped entirely on frame switch and when the arena needs room.

**This must not change any pixel.** The kernels write every texel of their
destination; a reused buffer is not observable. If any kernel is found to read
its destination, it does not get a pooled texture — and that finding goes in
`AGENTS.md`'s traps section.

---

## 10. Queues and heaps: which structure, and why

Three places need an ordering, and they are three different problems. Naming
them together so nobody reaches for the wrong one.

| # | problem | structure | why not something else |
|---|---|---|---|
| 1 | **Which frame to decode next** | a **depth-1 replaceable slot** — a degenerate queue | Only the newest request matters; a real queue would faithfully render every frame the user clicked past, which is the freeze in §0. Submitting replaces and cancels. `PRD/IMPL-decode-pipeline.md` §3.2. |
| 2 | **What to evict from RAM** | a **binary min-heap** over the arena's entries, keyed by value density | Called from the render path: must be O(log n) with no I/O. LRU is wrong here because entries differ 10× in size and 2.5× in cost (§8.2) — LRU would evict a 1860 ms full render to keep a 12 ms reprint. |
| 3 | **What to evict from disk** | the SQLite index, `ORDER BY priority LIMIT n`, with an index on `priority` | Same *policy* as #2, different mechanism. A B-tree index already is a heap for this purpose, and keeping a parallel in-memory heap in sync with the on-disk truth is a bug generator. |
| 4 | **What to write back to disk** | a **bounded FIFO ring**, single consumer, drop-oldest | Order does not matter much and freshness does; the bound is the point. A priority queue here would let a backlog grow while it re-sorted. §8.5. |

For #2 and #3 the priority function is **GDSF**-shaped and must be **one
function used by both**, or the two tiers will disagree about what is valuable:

```
priority(e) = clock + hits(e) × recomputeMs(e) / bytes(e)
```

`clock` is the aging term — set it to the priority of the last entry evicted.
That is what stops an old-but-valuable entry from being immortal and a
never-touched new entry from being evicted before it has had a chance. Without
it, pure value density starves; this is the standard fix and it is one line.

---

## 11. Open questions, for the user

**Q1. Where does the arena live — `Session` or `Diagnostics`?**
*Recommendation:* beside the sampler in `Diagnostics`, because enforcement hangs
off sampling and splitting them would put the number and the decision in two
places — the exact failure RFC-016 §8.5 was written against.

**Q2. Does the working-set cap default to unlimited?**
*Recommendation:* no — `min(8192 MB, 40 % of RAM)`, with "Unlimited" available
and the reasoning in the caption. The reserve alone is not enough because free
memory is set by other applications.

**Q3. How big is the disk cache, and is it on by default?**
*Recommendation:* on, **16 GB**, with the size and a Clear button in Settings.
16 rather than 8 because a full render is 364 MB and the cache is worth little
if it holds three of them. The retired linear cache was 4 GB and nobody objected
to its existence — only to its being useless.

**Q4. Is the previous frame's decode worth keeping in RAM,**
given a miss is ~15 ms?
*Recommendation:* keep capacity 2. The before/after split reads the previous
frame during a drag, and a file read per drag frame is not acceptable. Revisit
if §2.4's unknown comes back large.

**Q5. Should the full render be cached to disk at all,**
given it is 364 MB for 5.1 ms/MB — the least value-dense entry?
*Recommendation:* yes, and let the policy decide. It is the entry that
recomputes at 1860 ms, and on a 16 GB cache the heap will hold a handful and
shed them first under pressure. Excluding it by hand would be hard-coding what
the value function already gets right — and would make re-exporting yesterday's
edit slow for no reason.

---

## 12. Sequence

1. **Prerequisite:** `PRD/IMPL-decode-pipeline.md` §3 — cancellation and the
   single-flight pipeline. Nothing here can be accounted while uncancellable
   detached tasks hold unowned frames.
2. `MemoryArena` + registration of what already has an owner. **Accounting
   only — no eviction.** Ship, run a session, compare `arena_mb` against `mb` in
   the log. This is what collapses §2.4's unknown.
3. Enforce the reserve: eviction on sample. Add the working-set cap.
4. `DecodeResidency` (RAM, capacity 2) replacing the bare `decoded` var.
5. The disk store: SQLite index, the value-density heap, decode entries first.
6. Print entries in the same store: live tier, then full renders, then writeback.
7. The scratch pool.
8. `ThumbnailCache`: key on `(url, maxPixel)`, byte cap, arena registration.

---

## 13. Verification

| # | claim | how | today |
|---|-------|-----|-------|
| 1 | 30 rapid frame switches settle to baseline + 500 MB in 5 s | `memory` records | pinned at 10.5 GB for 11 min |
| 2 | Every settled frame produces an `open` record | log | zero after the second frame |
| 3 | The arena's total tracks `phys_footprint` with a *stable* gap | both in one `memory` record, whole session | no accounting exists |
| 4 | Revisiting a frame runs no `CIRAWFilter` | decode counter on the `open` record | full re-decode, ~4 GB |
| 5 | Lowering the Reserve evicts within one sample | `evicted_mb` in the log | the setting does nothing |
| 6 | Restoring a print is bit-identical to recomputing it | render the same frame twice, once from cache, compare | n/a |
| 7 | A changed engine version invalidates every print entry | bump the version string, assert a full miss | n/a |
| 8 | One export of 10 × 45 MP has a flat memory profile | `memory` record per frame index | rising to a stall |
| 9 | Live-edit latency is unchanged | the render records' `ms`, same folder, same sliders: 12 ms warm, ~107 ms cold | 12 / 107 ms |
| 10 | The scratch pool changes no pixel | the parity and export suites, unmodified; then a garbage-fill check | n/a |
| 11 | A cache that cannot be admitted degrades, never fails | force `cap = 2048 MB`, export a 45 MP frame | n/a |
| 12 | **Every check above can fail** | break each on purpose, once | — |

Claim 12 is not ceremony. The repeat defect shape in this repo is a guard that
cannot fire; a green suite that would also be green with the feature removed has
verified nothing.

Claim 6 deserves a note: it is the one that makes the print cache safe to ship.
If a restored print ever differs from a recomputed one, the key in §8.4 is
missing a field, and the symptom will be a photograph that looks different
tomorrow than it did today — the worst class of bug this app can have.

Also: **check the `tests` fixture link exists before believing any green run.**
Without it 25 tests skip silently and the run still reports 0 failures.
