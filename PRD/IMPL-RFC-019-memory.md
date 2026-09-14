# IMPL — RFC-019: the arena, the enforced cap, the residency, the print cache, the pool

**Companion to** `rfc/RFC-019-memory-management.md` (the design, the numbers and
the decisions) and `PRD/BUG-DIAGNOSIS-2026-09-14-export-and-decode.md` §1.
**Hard prerequisite:** `PRD/IMPL-decode-pipeline.md` **step 1**. Nothing here
can be accounted while uncancellable detached tasks hold unowned frames — you
would be counting objects whose lifetime nobody controls.

**This document is implementation logic, not a patch.**

---

## 1. Rules for whoever implements this

1. **Accounting before policy.** Land the arena with *no eviction* first, run a
   session, and compare its total against `phys_footprint` in the log. RFC-019
   §2.4 names one unknown — how much of a decode's 4.1 GB Core Image retains —
   and this step is what collapses it. Evicting on a wrong number makes the app
   worse, not better.
2. **Never fail a user operation for memory.** RFC-016 §11.5 settled it: a frame
   that does not fit gets a dismissible warning, never a refusal. The arena
   refuses to *cache*; it never refuses to *render*.
3. **Do not change any pixel.** Pooling a texture, evicting a cache, restoring a
   print and downsampling a preview must all be invisible in output. The parity
   and export suites are the check and they stay unmodified.
4. **`MemorySampler` stays the only thing that asks the kernel** (RFC-016 §8.5).
   The arena does not read `phys_footprint`; it is handed the sample.
5. **One priority function.** The RAM heap and the SQLite index must rank
   entries by the same formula, from the same source file. Two rankings will
   diverge and then the tiers will fight.
6. **`AGENTS.md`, `ARCHITECTURE.md`, `API-SPEC-*` and `CONTRACT-*` belong to
   nobody in particular** — say so before editing one.
7. One commit per step in §2, each with its §10 verification recorded.

---

## 2. Order of work

| step | what | ships what | risk |
|------|------|-----------|------|
| 1 | `MemoryArena`, accounting only | a truthful `memory` record; §2.4's unknown answered | low |
| 2 | Enforce the reserve; add the working-set cap | the Settings cap means something | medium |
| 3 | `DecodeResidency` (RAM, capacity 2) | the decoded RAW is managed | medium |
| 4 | The disk store: SQLite index, the value heap, decode entries | revisits cost 15 ms, not 485 ms + 4 GB | medium |
| 5 | Print entries + writeback queue | the finished picture survives a frame switch | medium |
| 6 | Scratch texture pool | ~1.5 GB → ~0.7 GB per export | **high** (touches every kernel call site) |
| 7 | `ThumbnailCache` cap and key fix | ~1 GB on a big folder | low |

Step 6 is late on purpose: it is the only one that can change output if a kernel
turns out to read its destination.

---

## 3. Step 1 — the arena, accounting only

### 3.1 Where it lives

Beside `MemorySampler`, inside `Diagnostics` (RFC-019 §11 Q1). `Diagnostics`
already owns the sampler and both settings, and RFC-016 §8.5 made "one place
asks, one place answers" a rule. Splitting the number from the decision is the
failure that rule was written against.

```swift
// Diagnostics/MemoryArena.swift
final class MemoryArena: @unchecked Sendable {
    enum Class { case pinned, evictable }
    struct Handle: Hashable { fileprivate let id: UUID }

    /// Register an allocation. Returns nil when it cannot fit even after
    /// eviction — the caller then does not cache. **A nil is never an error
    /// the user sees.**
    ///
    /// `costMs` is what this entry actually cost to produce, measured. It is
    /// the numerator of the value function (§6.3) and the app already has it:
    /// `LoadClock` laps the open path, every render record carries elapsed_ms.
    func admit(bytes: Int, cls: Class, kind: String, costMs: Double,
               evict: @escaping @Sendable () -> Void) -> Handle?
    func release(_ h: Handle)
    func touch(_ h: Handle)                    // a hit; feeds the value function

    var totalBytes: Int { get }
    var evictableBytes: Int { get }
    func breakdown() -> [(kind: String, bytes: Int, count: Int)]

    /// Called from MemorySampler.sample. Step 1: records only. Step 2: evicts.
    func enforce(sample: MemorySample, reserve: UInt64, cap: UInt64) -> Int
}
```

`Guarded`/`NSLock` for state, as `MemorySampler` already does — this is called
from the render path and must not be an actor hop.

The arena **does not own the objects**. It owns the accounting and the policy;
the `evict` closure drops the caller's reference. That is what lets one policy
cover `MTLTexture`, `CIImage` and `CGImage` — three unrelated types with three
lifetimes — without a wrapper for each.

### 3.2 What registers, in this step

Only the holdings that already have an owner, so nothing's lifetime changes:

| holder | file | class | bytes |
|---|---|---|---|
| `TextureStore.sources` / `.prints` | `Canvas/TextureStore.swift:44-45` | evictable | `w*h*8` |
| `TextureStore.full` | `:50` | pinned | `w*h*8` |
| `Renderer.original` | `Canvas/Renderer.swift:164` | pinned | `w*h*8` |
| `Renderer.adjusted` | `:165` | pinned | `w*h*8` |
| `Renderer.maskRasters` | `:170` | pinned | array size |

`TextureStore.touch(_:)` (`:87-96`) already implements an LRU with capacity 8;
in this step it keeps doing so and merely reports. In step 2 it delegates.

**Do not register the engine frame** (`ImageDecoder.EngineFrame`, 727 MB). It
lives for one `spk_open_device` call, its doc comment explains why it must be
dropped immediately, and `testTheEngineKeepsNothingOfTheCallersBuffer` pins the
contract. Registering it would add a failure mode to the one allocation that is
already correct.

**Do report the engine session** (~1.2 GB per open 45 MP frame) as a counted,
never-evicted line in the breakdown. Without it the arena's total will look
1.2 GB short of `phys_footprint` and someone will go hunting for a leak that is
the engine doing its job.

### 3.3 What the log gains

`MemorySampler.sample` (`Diagnostics/MemorySampler.swift:80-100`) appends to its
existing record:

```
.init("arena_mb", arena.totalBytes / 1e6)
.init("arena_evictable_mb", arena.evictableBytes / 1e6)
.init("arena_kinds", "prints:610,original:364,full:364,thumbs:210,engine:1200")
```

Keep every existing field exactly as it is — `PRD/BUG-DIAGNOSIS-2026-09-14` is
written against them and a before/after must be a diff of two log files.

### 3.4 Verification for step 1

Run a normal session (open a folder, develop three frames, export one). For each
`memory` record, `arena_mb` should track `mb` with a **stable** gap — Core
Image, Metal's allocator and SwiftUI. A gap that grows monotonically is an
unregistered holder and must be found before step 2.

**Record the gap after a decode specifically.** That number is RFC-019 §2.4's
unknown, and it decides whether the residency stays at capacity 2 (§5) or drops
to 1.

---

## 4. Step 2 — make the Settings numbers enforce something

### 4.1 What the Reserve is today

`Diagnostics.memoryReserveMegabytes` (`Diagnostics/Diagnostics.swift:134-142`),
default 2000, range 0…32768, key `diag.memoryReserveMB`. Its own doc comment
says it is "read on every forecast — a persisted number nothing consulted would
be the guard-that-cannot-fire shape with a settings row on top".

It *is* consulted — in exactly one place, `Diagnostics.projection(pixels:)`
(`:405-417`) — and the only thing that happens is a **sentence**:

```swift
let fits = allowOverReserve || forecast + reserve <= free
… message: fits ? nil : format(...)
```

Two callers ask for it (`Session.swift:1444` develop, `:2161` full). Nothing is
refused, deferred, shrunk or evicted. The user's instruction is that this stops
being true.

### 4.2 The Reserve, enforced

Keep the name, the key, the range, the default, the Settings row, the caption's
promise ("never a refusal") and `allowOverReserve`. Add one behaviour, in
`MemoryArena.enforce`, called from `MemorySampler.sample` — so every RFC-016
boundary is an eviction opportunity, in the one place that already has the
numbers:

```
if sample.freeBytes < reserve:
    evict lowest-priority evictable entries until free >= reserve
    (re-read free after each batch; never evict on a stale reading)
if arena.evictableBytes > cap:
    evict lowest-priority until under
```

Record it: the `memory` record gains `evicted_mb` and `evicted_kinds`. An
eviction no record mentions is an eviction nobody can debug.

**Admission** (new): `admit` returns nil when the entry would push free under
the reserve and eviction cannot recover it. The caller does not cache. It never
tells the user and never fails the operation.

`allowOverReserve` continues to suppress the **warning**. It does **not**
suppress eviction — different questions. Say so in the caption, in one clause.

### 4.3 The working-set cap (new setting)

```swift
var memoryCapMegabytes: Int          // key: "diag.memoryCapMB"
nonisolated static let memoryCapRange = 2_048...131_072      // + "Unlimited"
static var defaultMemoryCapMB: Int { min(8_192, Int(0.4 * physicalRAM_MB)) }
```

Caption, in the house idiom:

> How much Filmify may hold in caches and scratch buffers. The frame you are
> looking at is never evicted, whatever this says. Free memory is set by the
> other applications on the machine; this is the part Filmify decides.

The row goes directly under Reserve in `memorySection`
(`Windows/SettingsWindow.swift:120-150`), same `intRow` helper, followed by the
arena readout:

```
Held by Filmify   2.1 GB      (breakdown on hover)
Evictable         1.4 GB
```

Reading it must **not** take a sample — RFC-016 §8.5. It reads
`arena.totalBytes`, a counter, not a syscall.

### 4.4 Verification for step 2

- Set Reserve above current free from the Settings window. Within one sample
  (2 s with the page open), `evicted_mb` appears and `arena_evictable_mb`
  drops. **This is the test that the setting is real.**
- Set the cap to 2048 MB and export a 45 MP frame. It completes. Nothing is
  refused. The log shows `admit` returning nil and the export taking longer.
- A test that fabricates a sampler reading below the reserve and asserts
  eviction ran — then break the comparison operator and watch it go red.

---

## 5. Step 3 — the decoded frame becomes a managed residency

### 5.1 Today

`Session.decoded: DecodedImage?` — one bare `var` holding two `CIImage`s. The
log: one decode takes footprint from 274 MB to **4364 MB**. Nothing owns it,
nothing counts it, and (before `IMPL-decode-pipeline.md` step 1) several could
be live at once inside uncancellable detached tasks.

### 5.2 `DecodeResidency`

```swift
struct DecodeKey: Hashable { let url: URL; let settings: DecodeSettings }

@MainActor final class DecodeResidency {
    private var current: (key: DecodeKey, image: DecodedImage, handle: MemoryArena.Handle)?
    private var previous: (key: DecodeKey, image: DecodedImage, handle: MemoryArena.Handle)?

    func image(for key: DecodeKey) -> DecodedImage?
    func adopt(_ image: DecodedImage, for key: DecodeKey)   // current → previous
    func clear()
}
```

- **Capacity 2, fixed.** Current (pinned) and previous (evictable) — what an A/B
  comparison needs, and nothing more (RFC-019 §11 Q4). **If step 1's measurement
  shows Core Image retains more than ~1.5 GB per decode, drop to 1** and let the
  disk cache serve the previous frame. That is one constant, not a redesign.
- Keyed on `(URL, DecodeSettings)` — a white-balance change is a different
  entry, which is already how `decodeIsStale` reasons (`Session.swift:700-704`),
  so the existing logic maps over unchanged.
- **`Session.decoded` stays**, as a computed property returning `current`'s
  image. `setWhiteBalance` and `pickNeutral` read it and the panel must not
  blank mid-drag — that is what `decodeIsStale` is for and it does not change.

### 5.3 The invariant that matters

**A `DecodedImage` may be reachable only through the residency.** No detached
task may capture one and outlive its entry. That is why
`IMPL-decode-pipeline.md` step 1 is a hard prerequisite: today the decode is
handed to a detached closure (`Session.swift:1289`) whose lifetime nobody
controls, so "the residency holds two" would be a claim about two of an unknown
number.

Debug-build assertion: the residency counts live `DecodedImage`s through a
class-backed token and asserts the count never exceeds its capacity.

---

## 6. Step 4 — the disk store

### 6.1 Read this first

`Session.swift:1680-1700`. There **was** a 4 GB on-disk LRU of linear TIFFs.
RFC-014 retired it — the engine moved in-process and takes pixels, so every
entry was a 363 MB file this process wrote only to read back at 6.4–7.1 s per
frame. `removeLegacyLinearCache()` deletes what it left behind and **stays**.

What is proposed here is different in kind:

| | retired linear cache | this store |
|---|---|---|
| holds | linear decode, full resolution | display decode (38 MB) **and** finished prints (38 / 364 MB) |
| read by | the engine | the canvas |
| existed to | hand a file to an out-of-process engine | avoid a 485 ms + 4 GB decode, and a 1188–1860 ms re-develop |

Do not resurrect the old one. Do not cache the linear decode. Do not cache the
engine's working negative.

### 6.2 Layout

`Session.cacheRoot` already exists (`Session.swift:732`,
`~/Library/Caches/com.hanze.filmify`). Add:

```
com.hanze.filmify/
  store/
    index.sqlite
    <first 2 hex of key>/<key>.bin
```

**One store, two kinds** (RFC-019 §8.6). Two caches with two policies would
eventually argue about which may evict the other, and that argument has no
correct answer.

Entry file: a 64-byte header (magic, format version, kind, width, height, pixel
format, key hash) followed by raw rgba16, top row first — the layout
`TextureStore.uploadRGBA16` already reads (`TextureStore.swift:100-113`), so the
load path is one existing function plus a header skip.

### 6.3 The key, and the value function

**Key** — SHA-256 of, in this order:

| field | source | why |
|---|---|---|
| volume id + inode + size + mtime | `URLResourceValues` | path would break on a rename; identity without mtime would serve a stale picture after an edit elsewhere |
| `DecodeSettings` | JSON-encoded | white balance changes the pixels |
| `FilmParams` (print entries) | the existing stamp | Layer 1 only — Layer 2 and geometry are applied at draw time, so they must **not** be in the key |
| tier | `"live"` / `"full"` | |
| `previewLongEdge` | live entries only | |
| **engine version string** | `Diagnostics.engineVersion` | *the one people forget* — a rebuilt engine or a changed LUT makes every cached print silently wrong |
| container format version | constant | |

`TextureStore.FullRenderEntry.stamp` (`TextureStore.swift:46-52`) already exists
and is described as "the Layer 1 parameters it was rendered from, which is what
makes a lookup a cache hit rather than a coincidence". This is that stamp,
extended and hashed. `CryptoKit` is already imported in `Sidecar.swift`.

**Value function** — one implementation, used by both the RAM heap and the
SQLite index (rule 5). GDSF-shaped:

```swift
// Diagnostics/CacheValue.swift — the only place this formula exists.
func priority(hits: Int, costMs: Double, bytes: Int, clock: Double) -> Double {
    clock + Double(max(1, hits)) * costMs / (Double(bytes) / 1_000_000)
}
```

`clock` is the aging term: set it to the priority of the last entry evicted.
Without it, pure value density starves — an old high-value entry becomes
immortal and a new entry is evicted before it has been used twice. This is the
standard fix and it is one line; do not omit it and do not invent a different
one.

`costMs` is measured at admission, never a constant:

- render entries: `RenderOutcome.elapsed_ms` **plus** the session setup the
  frame would have to pay again — `LoadClock`'s `decode_ms + frame_ms +
  engine_open_ms + solve_ms`, which the `open` record already carries.
- decode entries: `decode_ms + preview_texture_ms`.

On the logged machine that yields, per RFC-019 §8.2: live print 31.1 ms/MB,
display decode 12.7, full render 5.1 — so full renders shed first. **That
ranking is the reason this is a heap and not an LRU**, and it should be asserted
in a unit test with those three synthetic entries.

### 6.4 The index

```sql
CREATE TABLE entries (
  key         TEXT PRIMARY KEY,
  kind        TEXT NOT NULL,        -- 'decode' | 'print_live' | 'print_full'
  source_path TEXT NOT NULL,        -- for the Settings readout, never for lookup
  width       INTEGER NOT NULL,
  height      INTEGER NOT NULL,
  bytes       INTEGER NOT NULL,
  cost_ms     REAL NOT NULL,
  hits        INTEGER NOT NULL DEFAULT 0,
  priority    REAL NOT NULL,
  created_at  REAL NOT NULL,
  used_at     REAL NOT NULL
);
CREATE INDEX entries_priority ON entries(priority);
```

Eviction is `SELECT key FROM entries ORDER BY priority LIMIT n` — a B-tree index
**is** a heap for this purpose, and keeping a parallel in-memory heap in sync
with the on-disk truth is a bug generator (RFC-019 §10, row 3). `priority` is
recomputed on `touch` and on admission, by the same function as §6.3.

System `libsqlite3`, no dependency added.

**Write order: file first** (to a temp name, then `rename`), then the index row.
A file with no row is garbage collected at launch; a row with no file is a miss
that self-heals. Never the other way round.

### 6.5 Policy

- Cap: **16 GB** default (RFC-019 §11 Q3), own Settings row with a size readout
  and a **Clear** button. Disk, not RAM — it does not count against the
  working-set cap.
- `formatVersion` in the header and a `meta` table. On a bump, **delete the
  directory**; do not migrate a cache.
- Garbage collection at launch, off the main thread, quiet on failure — the same
  shape as `removeLegacyLinearCache()`.

### 6.6 The read path (decode entries, this step)

```
displayPicture(url, settings)
  1. residency (RAM)   → hit: instant
  2. store (disk)      → hit: read + uploadRGBA16, ~15 ms
  3. decode            → miss: ~485 ms, ~4 GB transient; populate 1 and 2
```

Steps 1 and 2 run inline — a 38 MB file read does not need a job. Only step 3
goes through the frame pipeline.

**Acceptance:** revisiting a frame constructs no `CIRAWFilter`. Assert with a
counter carried on the `open` record, not with a stopwatch.

---

## 7. Step 5 — print entries, and the writeback queue

This is the answer to "where did the finished processing image go". Read
RFC-019 §8 before implementing; this section is the mechanism, not the argument.

### 7.1 What is stored

| kind | source | size at 45 MP | when written |
|---|---|---|---|
| `print_live` | `applyRender`'s texture, the engine's output at `previewLongEdge` | 38 MB | when the frame stops being the current one |
| `print_full` | `TextureStore.full`'s texture | 364 MB | when the frame stops being the current one, or when the edit settles and the queue is idle |

**Not** the current frame's live tier: it recomputes in 12 ms with a warm
negative against a 15 ms disk read, so caching it is a pessimisation (RFC-019
§8.2). The hook is therefore on *leaving* a frame — in `select`'s teardown,
beside the existing `flushSave()` — not on every landed render.

### 7.2 The writeback queue

```swift
actor PrintWriteback {
    /// Bounded FIFO, single consumer at .utility. Depth: one full-size entry
    /// (364 MB of staging) or four small ones.
    ///
    /// **Drop-oldest on overflow, and that is safe by construction:** an entry
    /// never written is a recompute later, which is exactly the fallback the
    /// policy already assumes. A priority queue here would let a backlog grow
    /// while it re-sorted.
    func enqueue(_ entry: StagedEntry)
}
```

- Drains only when the session is idle — the same "settled" signal
  `Session.fullRenderDebounceMs` (400 ms) already defines. Never during an
  active edit: a 364 MB write competing for SSD bandwidth mid-drag is the one
  way this work could make live editing *worse* (RFC-019 §2.2).
- Staging is a `getBytes` into a `Data` (`Renderer.swift:914-921`). Bound it to
  one full-size entry in flight.
- Optimisation, not a requirement: make the render targets buffer-backed
  (`makeTexture(descriptor:offset:bytesPerRow:)` over an `MTLBuffer`) and the
  write goes straight from the texture's own memory with no copy at all.

### 7.3 The read path (print entries)

On `select(url)`, before the pipeline is asked for anything — this is the branch
that makes a revisit instant:

```
1. TextureStore.print(for: url)          → hit: the existing instant path, unchanged
2. store lookup, key = stamp(url, sidecar, tier: .live)
                                         → hit: uploadRGBA16, setLive, previewSoft = true, ~15 ms
3. nothing                               → the decode path as today
```

Then, exactly as today, a develop replaces it if the user asks for one.
`previewSoft` semantics do not change: a restored print **is** a print, so it is
not soft — unlike the decode, which is.

### 7.4 The correctness bar

**A restored print must be bit-identical to a recomputed one.** If it is not,
the key in §6.3 is missing a field, and the symptom is a photograph that looks
different tomorrow than it did today — the worst class of bug this app can have.

The test: render a frame, evict it, restore it, render it again from scratch,
compare the two textures byte for byte. Then remove one field from the key (the
engine version is the best one to try) and watch the test go red.

### 7.5 What the user sees

Nothing. No badge, no "cached" label, no setting beyond the size and Clear.

This is also why removing the state pip (`PRD/IMPL-export-page-v2.md` §5) helps:
the dot currently means "this frame has a print", which under eviction is a
claim about residency the app cannot keep. Deleting it removes an inconsistency
rather than creating one.

---

## 8. Step 6 — the scratch pool

### 8.1 The cost today

`TextureStore.makeWritable` (`TextureStore.swift:115-121`) allocates a fresh
`.storageMode = .shared` texture every call — unified memory, counted against
`phys_footprint`. Callers:

| call site | when | size at 45 MP |
|---|---|---|
| `Renderer.applyLayer2` `:811` | every export, every proof | 364 MB |
| `Renderer.applyGeometry` `:832` | same | 364 MB |
| `Renderer.applyResize` `:613` | when the recipe names a size | 364 MB |
| `Renderer.applyOutputTransform` `:587` | same | 364 MB |
| `Renderer.renderOffscreen` `:852` | snapshots | pane-sized |
| `Renderer.ensureAdjusted` | canvas draws | live-tier |

`Exporter.filePixels` runs the first four in sequence: ~1.5 GB live at once,
plus the 364 MB `Data` that `makeCGImage` copies out.

### 8.2 The pool

```swift
extension TextureStore {
    func borrowWritable(width: Int, height: Int, format: MTLPixelFormat) -> Scratch?
}

final class Scratch {                       // returns itself on deinit
    let texture: MTLTexture
    deinit { pool.give(back: texture) }
}
```

- Free list keyed `(width, height, format)`, at most 2 per key, total registered
  with the arena as **evictable-when-idle**.
- Dropped entirely on frame switch and whenever the arena needs room.
- `makeWritable` **stays** for callers that hand the texture onward and outlive
  the call (`applyOutputTransform` returns its `dst`). Being explicit at each of
  the six call sites about which it is *is most of the work in this step*.

### 8.3 The correctness argument, and its limit

Reusing a buffer is unobservable **iff** every kernel writes every texel of its
destination and never reads it. Check all six pipelines before pooling any of
them. If one reads its destination (a blend, an accumulate), it does not get a
pooled texture — and that finding belongs in `AGENTS.md`'s traps section.

Verification: the existing suites, unmodified and green — `RendererTests`,
`SoftProofParityTests`, `ColourManagementTests`, `ExportPreviewChainTests`,
`ExportRecipeTests`, `PrintLUTTests`, `MaskTests`. Then, in a debug build, fill
every pooled texture with garbage before handing it out and confirm they are
*still* green. If they are not, a kernel reads its destination and you have just
found it.

---

## 9. Step 7 — the thumbnail cache

`Import/ThumbnailCache.swift`, 34 lines:

```swift
private var cache: [URL: CGImage] = [:]                 // :9  — no eviction, ever
if let c = cache[url] { return c }                      // :13 — key ignores maxPixel
func store(_ image: CGImage, for url: URL) { … }        // :33 — stores at any size
```

Four call sites, three sizes: 320 (`Filmstrip.swift:125`), 512
(`BrowseView.swift:152`, going away with Browse), 1024 (`ExportPage.swift:1376`,
`:1470`). Whichever lands first wins for all of them.

- Key `(url, maxPixel)`.
- Byte cap (default 256 MB), LRU, registered with the arena as evictable.
- Cleared in `Session.open(urls:)` — a new folder is a new set, the same reason
  `picked` is cleared there (`Session.swift:985`).
- `store(_:for:)` records the size it stored at.

While here: `Session.updateThumbnail` (`:1664-1677`) runs on **every** landed
print and begins with `makeCGImage()` — a full CPU copy of the texture, 38 MB at
the preview tier, per slider tick, uncancelled and unthrottled. Downsample on
the GPU first, or throttle to the last render of a settled edit (the same signal
§7.2 uses).

---

## 10. Verification

| # | claim | method | today |
|---|-------|--------|-------|
| 1 | The arena's total tracks `phys_footprint` with a stable gap | one `memory` record per boundary, whole session | no accounting exists |
| 2 | 30 rapid frame switches settle to baseline + 500 MB in 5 s | `memory` records | pinned at 10.5 GB for 11 min |
| 3 | Lowering the Reserve evicts within one sample | `evicted_mb` in the log | the setting does nothing |
| 4 | A 2048 MB cap does not fail a 45 MP export | run it | n/a |
| 5 | Revisiting a frame builds no `CIRAWFilter` | decode counter on the `open` record | full re-decode, ~4 GB |
| 6 | At most 2 `DecodedImage`s are live | debug assertion in the residency | unbounded |
| 7 | **A restored print is byte-identical to a recomputed one** | §7.4, verified by removing a key field | n/a |
| 8 | Under pressure, full renders are shed before live prints | unit test on the value function with the three synthetic entries of §6.3 | LRU would do the opposite |
| 9 | Live-edit latency unchanged | render records: 12 ms warm reprint, ~107 ms cold, same folder | 12 / 107 ms |
| 10 | Pooling changes no pixel | the seven suites, then the garbage-fill check | n/a |
| 11 | 10 × 45 MP export has a flat memory profile | `memory` record per frame index | rising to a stall |
| 12 | **Every check above can fail** | break each on purpose, once | — |

Item 12 is not ceremony. The repeat defect shape in this repo is a guard that
cannot fire; a green suite that would also be green with the feature removed has
verified nothing.

Also: **check the `tests` fixture link exists before believing any green run.**
Without it 25 tests skip silently and the run still reports 0 failures.

---

## 11. Rollback

Steps 1, 2, 4, 5, 7 revert cleanly — the store is a cache, and deleting the
directory is a complete rollback of steps 4 and 5.

Step 3 changes `Session.decoded` from a stored to a computed property:
mechanical, but it touches the white-balance panel, so revert it as a unit.

Step 6 is the one with a correctness surface: put the pool behind a
`FeatureFlags` entry (`Model/FeatureFlags.swift` is how masks were withdrawn)
defaulting **off** for one release, so it can be turned on for measurement and
off for a release build without a revert.
