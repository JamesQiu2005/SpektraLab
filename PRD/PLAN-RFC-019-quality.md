# Plan — RFC-019 memory subsystem quality

**Status:** implementation plan, 2026-09-14
**Authority:** PRD/IMPL-RFC-019-memory.md and rfc/RFC-019-memory-management.md
**Scope:** Swift ownership and memory accounting seams, RFC-019 steps 1–7.

This plan preserves pixels, kernels, the engine ABI, export formats, and parity/export
suites. It does not refactor all of Session, add dependencies, edit engine/, or create
a new cache hierarchy. Commit each completed package after its named gate and push at
integration boundaries only with explicit owner approval.

## Current state

The path is Session → FramePipeline/ImageDecoder → Renderer/TextureStore →
EngineClient and the compiled engine. Diagnostics owns MemorySampler and MemoryArena.
The arena receives samples from the sampler and never queries phys_footprint itself.
Cache admission may fail, but a user render never does. Pinned holdings are always
registered and never refused. Eviction callbacks run after releasing the arena lock.

The private step-2 accounting cleanup is **completed**. Its prior validation was 30
DiagnosticsTests with zero failures and no skips; tests resolved to ../spektrafilm/tests.
That remains a historical helper-test result. Q1 is **completed**: the typed registration
batch passed 31 DiagnosticsTests plus 25 RendererTests/OpenPathTests with zero failures;
the pinned guard was also deliberately broken and seen red before restoration. Q2 is
**completed**: concurrent admission and shared-arena guards were seen red, then the
combined gate passed 33 DiagnosticsTests plus 25 RendererTests/OpenPathTests. Q3 is
**completed**: the signed gap is logged at every boundary, and the 24 MP `DSC03710.ARW`
decode measured 2608.5 MB footprint against 69.9 MB arena (a -2538.6 MB gap) from a
401.4 MB frame-switch baseline. That selects DecodeResidency capacity **1**. Q4 is
**completed**: the residency owns one decode behind a releaseable lease, publishes it
only after the preview lands, and passed its 57-test focused gate. Q1–Q4 are committed
locally; the push is pending explicit owner approval. Do not infer physical ownership
from arena_mb versus phys_footprint: shared textures and Core Image references make that
gap diagnostic only. costMs remains a future GDSF input.

## Work packages

### Q1 — typed registration and engine estimate — **completed**

Edit Diagnostics/MemoryArena.swift, Renderer.swift, TextureStore.swift, Session.swift,
DiagnosticsTests.swift, and affected construction wiring. Regenerate the project only
if source membership changes.

Use these paths while retaining current policy and threading:

~~~swift
registerPinned(bytes: Int, kind: String) -> Handle
admitCache(bytes: Int, kind: String, costMs: Double,
           evict: @escaping @Sendable () -> Void) -> Handle?
wouldAdmitCache(bytes: Int) -> Bool
~~~

Pinned registration has no eviction closure and cannot return nil. Cache admission
remains failable and keeps measured costMs. Prediction is stale and non-reserving.
Migrate every call site in MemoryArena, Renderer, TextureStore, Session, and diagnostics
tests. Keep kind strings and injection semantics unchanged.

Record the engine-session line as an approximate **1.2 GB** counted pinned estimate
from IMPL §3.2/RFC §2.4. It does not uniquely explain RSS or Core Image retention.
The borrowed per-call engine frame remains unregistered.

Acceptance: DiagnosticsTests proves typed distinction, unconditional pinned
registration, failable cache admission, and nonmutating prediction. The narrow gate ran
as `xcodebuild ... -only-testing:SpektrafilmTests/DiagnosticsTests test`: 31 tests, zero
failures. The wiring gate ran as
`xcodebuild ... -only-testing:SpektrafilmTests/RendererTests -only-testing:SpektrafilmTests/OpenPathTests test`:
25 tests, zero failures. The new pinned registration test was deliberately broken by
registering pinned bytes as evictable, failed both expected assertions, then passed
after restoration. The `tests` symlink was verified before testing. The API/call-site
batch landed together with no adapter overloads or empty pinned closures.

### Q2 — reproduce and address admission publication races — **completed**

Edit MemoryArena.swift, Renderer.swift, TextureStore.swift, Session.swift, and focused
tests. First use barriers to reproduce concurrent admissions oversubscribing the same
room, or stale Handle/eviction publication after replacement. Change synchronization
only after deterministic reproduction. Keep callbacks outside the arena lock; do not
start a speculative locking redesign. Wire one immutable owner arena through Session,
Renderer, and TextureStore, preserving test injection without silent nil accounting.

Acceptance: deterministic red reproduction, then green with the smallest fix, plus
DiagnosticsTests and affected RendererTests/OpenPathTests. Roll back Q2 wiring or
synchronization if reproduction is nondeterministic or callbacks re-enter the lock.

Result: a barrier forced two admissions past the same stale room and failed with 120
bytes under a 100-byte cap. Publishing the admitted entry inside the same critical
section as the policy decision fixed it; callbacks still run after unlocking.
`Session` now creates its `Renderer` with `diagnostics.arena`, `Renderer` passes that
same immutable arena to `TextureStore`, and no arena remains optional. The combined
gate ran `DiagnosticsTests`, `RendererTests`, and `OpenPathTests`: 58 tests, zero
failures. Both new guards were deliberately broken and seen red before restoration.

### Q3 — measure decode residency and arena/footprint gap — **completed**

Edit MemorySampler.swift, Diagnostics.swift, Session.swift, and logging/tests. No
capacity or eviction change belongs here. Measure real frames at decode, engine.open,
print, frame switch, and export. Log approximate arena bytes and signed
arena_footprint gap. The 1.2 GB estimate is not unique RSS attribution and the gap is
not exact Core Image attribution. Check system load; do not claim timings from stale
samples. Acceptance is a repeatable same-frame/configuration log and explicit capacity
input, with relevant OpenPathTests/FramePipeline tests. Roll back logging if it alters
behavior or becomes a second kernel sampler.

Result: `MemorySampler` now writes `arena_footprint_gap_mb` as arena bytes minus
`phys_footprint`, plus the frame name, on every footprint sample. The existing sampler
remains the only kernel reader. On the A7 III 24 MP `DSC03710.ARW`, with load average
5.89 during the run but no timing claim made: frame switch 401.4 MB / arena 0; decode
2608.5 MB / arena 69.9 MB; engine.open 3529.7 MB / arena 1269.9 MB; first_print
4474.8 MB / arena 1461.9 MB. The decode gap is -2538.6 MB, above IMPL §5.2's ~1.5 GB
threshold for two decodes, so Q4 uses capacity **1**. The signed-gap guard was seen red
with its subtraction reversed, then restored. The Q3 gate ran `DiagnosticsTests`,
`FramePipelineTests`, and `OpenPathTests`: 54 tests, zero failures.

### Q4 — bounded DecodeResidency — **completed**

Prerequisites: IMPL-decode-pipeline.md step 1 and accepted Q3 measurement. Capacity is
**1**, selected by Q3's 24 MP gap. Edit
Session.swift, a residency type under Model, FramePipeline.swift, ImageDecoder.swift,
and focused session tests.

DecodedImage is a struct containing linear data and a display CIImage; engineFrame and
sampleLinear consume the linear side. Keep Session.decoded as the compatibility
computed property for white balance and neutral picking, while residency becomes the
sole owner. Decode is serial/single-flight, but cancellation only flags work: queued
closures can retain captured images. Test closure lifetime and drain/lease behavior
for completed, canceled, and frame-switched work; single-flight alone is insufficient.

Keep current pinned/previous-evictable semantics. Choose capacity one or two from Q3
(two is ordinary; one if retained decode share exceeds the RFC point near 1.5 GB).
requestNativeOriginal remains a best-effort wouldAdmitCache preflight, never a
reservation; the actual original remains pinned.

Acceptance: capacity bound, canceled-image release, guard red verification, and real
accounting logs. Run focused Session/OpenPath/FramePipeline tests. Roll back to the
compatibility property if lifetime or render correctness fails.

Result: `DecodeResidency` owns one decode, keyed by `(URL, DecodeSettings)`, with a
measured 90-bytes-per-pixel estimate registered as pinned. `DecodeLease` carries the
image across queued preview work; cancellation releases the lease so the queued closure
retains no decode. `Session.decoded` remains the read-only compatibility property, and
publication still happens only after the preview texture lands. The capacity guard was
seen red with two entries and 2.7 MB accounted; after restoration the gate ran
`DecodeResidencyTests`, `DiagnosticsTests`, `FramePipelineTests`, and `OpenPathTests`:
57 tests, zero failures. The full `SpektrafilmTests` suite then passed 309 tests with
zero failures. The Xcode project was regenerated for the two new files.

### Q5 — unified RAM/disk key and GDSF policy — **completed**

Prerequisite: Q4 and accepted measurements. Edit TextureStore.swift, cache key/value
types, disk store/index, and focused cache/renderer tests.

Use one versioned CacheKey and one CacheValue GDSF formula for RAM and SQLite, with real
hits and measured costs. Reconcile local LRU wording with RFC-019 before coding; do
not silently override IMPL §9 or add a second ranking. Local thumbnail byte cap and
central eviction priority are separate constraints.

Write disk bytes first, then index, using atomic rename. Validate header dimensions,
length, format, and engine/version key. Corrupt/stale rows are misses and are
garbage-collected. Keep display RGBA texture entries distinct from DecodedImage Core
Image graphs and engine linear input: a display hit cannot synthesize decoded data.
White balance and engine operations request RAW/decode data on demand. Define and test
the displayPicture seam.

Acceptance: source/print/disk/full hits share value updates; synthetic ranking,
file-first ordering, corrupt self-healing, version misses, restored bytes, and key
perturbation misses pass. Roll back policy as one unit if data crosses the linear
input contract.

Result: `CacheKey`, `CacheValue`, and one `gdsfPriority` function live in
`Model/CachePolicy.swift`; `MemoryArena` ranks evictable entries through that
function with last-touch only as the deterministic tie break. The SQLite
`DiskCacheStore` writes the complete payload file before its index row, validates
the versioned header and payload, self-heals corrupt/missing rows, garbage-collects
orphans and interrupted temporaries, and evicts by the same GDSF priority. Display
cache entries carry source dimensions separately from preview dimensions, so a disk
hit restores the viewport without inventing linear pixels. `Session.displayPicture`
stops at the cached RGBA texture; `ensureDecoded` performs the real decode only when
develop, Solve, export, neutral picking, or native-original work asks for linear
data. The first implementation exposed a resolved-settings deadlock on A7RV
as-shot metadata, fixed by publishing the residency under the resolved decode
settings and treating a non-stale same-URL residency as current.

The GDSF ranking guard was seen red with `costMs` removed, and the display-only
guard was seen red by falling through from a disk hit into decode (`decodeCount`
became 1). Both were restored. The Q5 focused gate ran `DiskCacheStoreTests`,
`SessionDisplayCacheTests`, `CachePolicyTests`, `DiagnosticsTests`,
`RendererTests`, `OpenPathTests`, `FramePipelineTests`, and
`DecodeResidencyTests`: 76 tests, zero failures.

### Q6 — bounded print writeback — **queued**

Edit disk store/cache and the Exporter seam. Write settled live/full prints through
one consumer with exactly one full staging buffer or four small buffers; drop the
oldest queued item. Preserve output bytes and key every output-affecting input.
Restored bytes equal recomputation; deliberate key perturbations miss. Verify report
draining exactly once across between-sample admissions and multi-batch evictions,
with the next report zero. Run focused export/renderer and frame-switch tests.

### Q7 — completion-safe pool and thumbnails — **queued**

For the scratch pool, edit renderer/texture allocation seams and focused tests.
Default OFF for one release. Audit destination-writing kernels; return storage only
after GPU completion, with explicit borrow/return ownership, and drop idle entries
on frame switch or arena pressure. Keep makeWritable for longer-lived handoff. Use
debug garbage fill and existing parity/export suites; any failure blocks that call
site. The flag is the rollback lever.

For thumbnails, edit ThumbnailCache, folder-open consumer, and tests. Reconcile
IMPL §9 LRU/cap wording with central GDSF first. Key both cache and in-flight work by
(URL, maxPixel), use a generation on folder clear so detached old results cannot
repopulate it, and preserve processed-thumbnail replacement. Test distinct sizes,
cap eviction, reset, canceled/late results, and recomputation after eviction.
Browse deletion is a separate gated UI change.

## Concerns and evidence gates

| concern | evidence/symptom | gate | when |
|---|---|---|---|
| admission concurrency | callers can observe same room | barriered reproduction, then fix | Q2 |
| optional arena drift | nil store arena disables accounting | injected identity test | Q1/Q2 |
| stale sample | prediction is not reservation | nonmutation/TOCTOU test | Q1/Q4 |
| engine estimate | 1.2 GB is not unique RSS ownership | signed real-frame gap log | Q1/Q3 |
| decoded lifetime | canceled closures retain images | cancel/drain/switch lease test | Q4 |
| cache key/data | RGBA cannot stand in for linear RAW | displayPicture + perturbation tests | Q5 |
| report count | evictions span samples | exactly-once drain, next zero | Q6 |
| pool reuse | GPU may read returned storage | completion barrier + garbage fill | Q7 |

## Validation and handoff

Check tests points to ../spektrafilm before fixture tests. Use DiagnosticsTests for
Q1/Q2, RendererTests/OpenPathTests for wiring, and focused FramePipeline/session/
cache/export tests later. Show new guards red against deliberately broken behavior,
restore them, and record the green command. Run Tools/check-bundle-resources.sh only
for bundle changes; regenerate after source membership changes. Engine parity is
required only when the render boundary or engine inputs change. Run full
SpektrafilmTests once at the integration boundary, not after each package.
