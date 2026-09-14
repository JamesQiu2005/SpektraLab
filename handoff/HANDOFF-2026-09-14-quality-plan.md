# HANDOFF — 2026-09-14 — codebase-quality plan for the RFC-019 memory subsystem

**For:** the incoming planning session (GPT-6 Astra).
**From:** a Claude Code session that cleaned the repo and surveyed the surface.
**State:** RFC-019 is landed through **step 2 of 7**. The working tree is clean.
Your deliverable is a **plan, not an implementation** — see §1.

---

## 1. The mission

Produce a plan that improves the **quality of the RFC-019 memory implementation as
it stands today**, and cleans up the mess that landed with it. The subsystem works
and its tests pass; the problem is shape, not correctness:

- it was built in three days across five parallel agent lanes,
- each lane added its own policy, its own taxonomy and its own registration idiom,
- and **five more steps (3–7) are queued to land on top of it** — a consolidation
  plan written now is worth far more than one written after step 7.

Your plan must therefore do two things:

1. **Consolidate what landed** (steps 1–2) so the base is sound.
2. **Sequence that consolidation against steps 3–7** (§7), so cleanup does not
   collide with work already specified, and so the messy seams get fixed in the
   step that would otherwise deepen them.

Deliverable: a document in this repo, `PRD/PLAN-RFC-019-quality.md`, in the style of
the existing `PRD/IMPL-*.md` notes — authoritative doc sections cited by number,
one section per change, each with a stated verification. **Do not write code.**
The user will take your plan to an implementing session.

### The one rule that constrains everything

**No pixel change, ever.** These are memory-management changes under a rendering
app. Parity and export suites stay green and *unmodified*. Any proposal that
touches a render pass, a colour transform, or a LUT is out of scope by definition.

---

## 2. Read this, and only this

Token economy is the user's explicit goal, so the read set is bounded. In order:

| # | path | why |
|---|---|---|
| 1 | `AGENTS.md` (56 KB) | working notes; the traps section has cost real debugging time |
| 2 | `PRD/IMPL-RFC-019-memory.md` (28 KB) | the implementation authority — **§1 rules, §3 step 1, §4 step 2** are what landed |
| 3 | `rfc/RFC-019-memory-management.md` (34 KB) | the design authority — **§3 principles, §6 the arena, §11 open questions** |
| 4 | `modern_UI/Spektrafilm/Spektrafilm/Diagnostics/MemoryArena.swift` (224 L) | the centre of the mess |
| 5 | `modern_UI/Spektrafilm/Spektrafilm/Diagnostics/MemorySampler.swift` (188 L) | the one kernel reader |
| 6 | `modern_UI/Spektrafilm/Spektrafilm/Canvas/TextureStore.swift` (229 L) | the largest arena consumer; the second policy lives here |
| 7 | `SpektrafilmTests/DiagnosticsTests.swift` **lines 840–1140 only** | the arena tests, appended at the `MARK` on 851 |
| 8 | `CLAUDE.md` (1.7 KB) | repo conventions |

### Do not read

- **`rfc/` beyond RFC-019** — 17 other files, ~370 KB. (Read RFC-016 §3/§6/§8 only if
  your plan touches the log record's shape.)
- **`handoff/HANDOFF-*.md`** — 14 files, ~200 KB of historical session records from
  2026-09-11. They are *cited by name from source comments* (`EngineClient.swift` →
  `HANDOFF-OPEN-PATH`, `Diagnostics.swift` → `HANDOFF-GPU-WIRING`, `Mask.swift` →
  `HANDOFF-MASKS`), so they are live canon — but they describe finished work. Read
  one only to resolve a specific citation.
- **`ARCHITECTURE.md`, `API-SPEC-*.md`, `CONTRACT-*.md`** — ~100 KB. Only relevant if
  your plan crosses into the engine ABI, which steps 1–2 do not.
- **`engine/`** (C++ port) — the arena is Swift-only. Nothing in RFC-019 steps 1–7
  touches `engine/src`.
- **`PRD/IMPL-decode-pipeline.md`, `PRD/IMPL-export-page-v2.md`,
  `PRD/PRD-export-page-v2.md`, `PRD/BUG-DIAGNOSIS-*.md`** — other lanes.
- **`modern_UI/`** — 887 MB, mostly build artifacts. Never traverse it.

Estimated read cost of the allowed set: **~55k tokens.** Wandering the disallowed
set costs **~250k** and buys nothing.

---

## 3. The surface

| file | LOC | role |
|---|---|---|
| `Diagnostics/MemoryArena.swift` | 224 | accounting **+ admission + eviction + reporting**, all in one type |
| `Diagnostics/MemorySampler.swift` | 188 | the one place that asks the kernel; limits; the log record |
| `Canvas/TextureStore.swift` | 229 | capacity-8 LRU; the largest arena consumer |
| `Diagnostics/Diagnostics.swift` | 638 | settings bridge (`applyMemoryLimits` :602), projection (§11.5) |
| `Canvas/Renderer.swift` | — | pinned registrations `original`/`adjusted`/`maskRasters` (:164–179) |
| `Model/Session.swift` | ~2600 | `wouldAdmit` pre-flight (:1305), engine admit (:1640), release (:2550) |
| `Windows/SettingsWindow.swift` | — | Reserve + cap rows, arena readout (:140–180) |
| `SpektrafilmTests/DiagnosticsTests.swift` | 1140 | arena tests appended at :851 |

Lettered authority: `impl` = `PRD/IMPL-RFC-019-memory.md`, `rfc` =
`rfc/RFC-019-memory-management.md`. Cite these by section in your plan.

---

## 4. The mess — verified, not guessed

Each item below was read in the source, not inferred. Line numbers are current at
`38ca687`.

### 4.1 `costMs` is a dead field

`MemoryArena.Entry.costMs` (`MemoryArena.swift:27`) is written by **every** call
site as `0` — `Renderer.swift:166,168,179`, `Session.swift:1640`,
`TextureStore.swift:92,117,134`, and the tests — and read by **nothing**.
`grep -rn costMs` returns only writes.

It is scaffolding for step 4's GDSF value function (`impl` §6.3), which is a real
reason to keep the parameter. But a field no reader consults, threaded through
eight call sites, is dead weight that reads as live. Decide: annotate it as a
declared-for-step-4 seam, or drop it until step 4 introduces it.

### 4.2 Two eviction policies that cannot see each other

- `TextureStore.touch()` (:172–185) keeps its **own** `order: [URL]` array and
  `capacity = 8`, and on overflow releases arena handles directly (:179–180).
- `MemoryArena.removeLowestPriorityLocked` (:205) ranks by `lastTouch` and calls
  back into the store's `dropSource`/`dropPrint` closures.

The store's LRU can free the entry the arena just ranked hottest; the arena can
evict an entry the store believes is fresh. Neither consults the other.

**This one is deliberate, and the plan must respect that.** Step 2's review
recorded it as an intended P2: the GDSF value function lands in step 4 and
replaces the ranking *in one place* (`impl` §6.3), at which point the two
policies merge. So the plan should **not** pre-empt step 4 — it should state the
exact consolidation seam and make sure everything built between now and then
lands on the right side of it.

### 4.3 Pinned entries carry a closure that cannot fire

`evict: {}` is passed for every pinned registration: `Renderer.swift:166,168,179`,
`Session.swift:1640`, `TextureStore.swift:134`. Pinned entries can never be
selected by `removeLowestPriorityLocked`, which filters `cls == .evictable`
(:210) — so these closures are unreachable **by construction**.

This is this repo's signature defect: *a guard that cannot fire*. A reviewer
cannot tell an empty closure that is safe from one that is a bug. The type system
can express this — the evict closure is only meaningful for `.evictable`.

### 4.4 The pre-flight predicts a different class than the registration

`Session.swift:1305` pre-flights the native-original decode:

```swift
guard diagnostics.arena.wouldAdmit(bytes: allocationBytes, cls: .evictable) else { return }
```

The bytes are then registered **as pinned**, on ANOTHER THREAD, three quarters of
the way down `scheduleNativeOriginal`, through a property observer —
`self.renderer.original = tex` (`Session.swift:1387`) → `Renderer.swift:166`,
which admits `cls: .pinned, kind: "original"`. `nativeOriginalAllocationBytes`
(`:1322`) computes the same size the registration will report, so the *number* is
right — but the *class* is not, and the gap is not just temporal:

- The pre-flight asks whether the **evictable** set can absorb the allocation.
- The actual registration is **pinned**, which `admit` never refuses (§1 rule 2:
  refusing a pinned registration would make the accounting lie).
- So the budget the pre-flight protects is never the budget that grows. Pinned
  bytes are outside the evictable set the cap governs, so an admitted native
  original permanently raises the working set above what the check reasoned about.

There is also a genuine TOCTOU window — free memory can move, the cap can be
edited in Settings, another lane can evict between the prediction and the
registration. Both share `admissionNeedLocked`, so the prediction is internally
consistent; it is the *scope* that is wrong.

Decide, explicitly: is this pre-flight a gate that should be conservative, or a
cheap "don't even try when it is hopeless" skip? Today it reads as the former and
behaves as the latter. Note the review discipline this repo enforces — a check
whose failure cannot change behaviour is §4.3's defect wearing different clothes.

### 4.5 `observe` and `enforce` duplicate state assignment

`MemoryArena.swift:109–115` (`observe`) and `:135–138` (`enforce`) perform the same
three assignments — `lastSample`, `lastReserve`, `lastCap`. `enforce` never calls
`observe`; it re-implements it. Two copies of one invariant.

### 4.6 The arena is nullable in TextureStore, and nil silently zeroes accounting

`TextureStore.arena` is `MemoryArena?` (:58) with `arena?.` at ten call sites, plus
a null-aware branch at :94 and :119 (`if arena != nil, admitted == nil`). With a
nil arena the store behaves differently *and* reports nothing — no log, no error.

The type is optional so tests can construct a store without diagnostics. That is a
legitimate need; a nullable dependency that degrades silently is not the way to
meet it.

### 4.7 A magic constant for the engine session

`Session.swift:1640` admits a hardcoded `1_200_000_000` bytes for the engine
session. Nothing derives it, nothing checks it against reality, and it is the
single largest pinned entry in the arena. The comment above it explains *lifetime*
correctly but not this number.

### 4.8 Three overlapping taxonomies for one entry

One registered allocation carries `cls: Class` (`.pinned`/`.evictable`),
`kind: String` (`"sources"`, `"prints"`, `"full"`, `"original"`, `"adjusted"`,
`"maskRasters"`, `"engine"`), and a `Handle`. `Class` is also an unfortunate name
to nest inside a type. The `kind` strings are the ones that reach the log
(`arena_kinds`, `evicted_kinds`) and the Settings readout — so they are a
user-visible contract, not just labels.

### 4.9 The eviction report is drained twice per sample

`MemorySampler.sample` (:100, :107) calls `takeEvictionReport()` before the loop
and again inside it. The comment explains why, and it is defensible — but it is
the subtlest control flow in the file, and it is what makes the logged
`evicted_mb` mean "everything since the previous record" rather than "this pass".

### 4.10 The tests are one 1140-line file

Arena tests were appended to `DiagnosticsTests.swift` at :851. The diagnostic
suite now covers logging, retention, projection *and* arena policy in one file.

---

## 5. Gates every change must pass

These are the repo's standing rules; a plan that does not name them will produce
work that gets rejected.

- **Guards must be red-verified.** Every guard test must be broken on purpose,
  watched to fail, then restored. This repo's repeat defect is a check that cannot
  fail — §4.3 is a live example. A green test that has never been red is not
  evidence.
- **Fixture link, or the run lies.** `tests` must be a symlink to
  `../spektrafilm/tests` at the repo root — it is **gitignored and untracked**.
  Without it **25 tests skip silently while the run still reports 0 failures.**
  Verify it exists *before* believing any green run.
- **Test cadence.** Full suite is ~7 min — build + only the touched test classes
  per commit; full suite only at step boundaries and before any push.
- **One commit per step/section**, with its verification recorded in the message.
- **Comments are paid-for knowledge.** Move them with the code; prove a comment
  obsolete before deleting it.
- **Never commit `modern_UI/reference_layout/Export_Page/export_page.ai`** — the
  user's own file.
- **Do not implement RFC-017** anywhere.

Commands (from `modern_UI/Spektrafilm`):

```
xcodebuild build -scheme Spektrafilm -configuration Debug -destination 'platform=macOS'
xcodebuild test  -scheme SpektrafilmTests -destination 'platform=macOS'
# targeted:  add  -only-testing:SpektrafilmTests/DiagnosticsTests
```

**A new worktree lacks two things and both fail confusingly.** The bundled engine
resources (gitignored, at
`modern_UI/Spektrafilm/Spektrafilm/Resources/engine/`) — symptom: the build's
"Check bundled resources" script phase fails and every test error is downstream
noise; fix by copying them from this checkout, or `engine/build.sh bundle`.
And the `tests` symlink above. There is **no worktree provisioned right now** —
see §6.

---

## 6. Repo state — what was cleaned before you arrived

This session did the following, and it is all committed at `38ca687`:

- **Six linked worktrees removed** (`filmify-colour`, `filmify-export`,
  `filmify-meter`, `filmify-wt-arena`, `filmify-wt-badge`, `filmify-wt-export-v2`).
  All were clean, and every branch tip was verified an ancestor of HEAD first —
  no commits were orphaned. ~2 GB freed.
- **Nine merged local branches deleted** (`meter-once`, `rfc015-exposure-intents`,
  `rfc018-colour-pipeline`, `rfc018-export-page`, `rfc019-arena`,
  `rfc019-arena-cap`, `rfc019-badge`, `rfc019-export-proof`, `rfc019-export-v2`).
  `main` was kept — it is the trunk and the PR base, 83 commits behind HEAD.
- **Archived out of the tree** to `../filmify-archive/`: three finished task briefs
  (`PRD/TASK-A-rfc016.md`, `PRD/TASK-B-layout.md`,
  `PRD/frontend_behavior_improvement.md`) and four reference captures no source
  comment cites. Every one is recoverable from both the archive folder and git
  history. **The 2026-09-11 handoffs were deliberately NOT archived** — they are
  cited by name from source (§2).
- **Five `.DS_Store` files deleted** (gitignored, never tracked).

Current state:

- **Branch:** `rfc019-decode-export-memory` @ `38ca687`, working tree clean,
  **one commit ahead of `origin`** — the cleanup commit is not pushed. Pushing is
  the user's call.
- **One worktree**, the main checkout. If your plan calls for parallel lanes, they
  must be provisioned (§5).
- **Archive:** `../filmify-archive/` — `session-handoffs-2026-09-14/` (the pi /
  codex / kimi orchestrator handoffs), `prd-finished-tasks/`, `orphaned-images/`.

---

## 7. What is queued — so your plan does not collide with it

RFC-019 is **step 2 of 7**. `PRD/IMPL-RFC-019-memory.md` §2 fixes the order; the
compressed version, which is all you need:

| step | what lands | why it matters to your plan |
|---|---|---|
| **3** | `DecodeResidency`, capacity 2 (or 1, pending a hand measurement of the arena gap after a decode — `impl` §3.4) | the first *new* consumer of the arena's admission path |
| **4** | the disk store: `store/index.sqlite` + `store/<2hex>/<key>.bin`, SHA-256 key **including the engine version string**, 16 GB cap, launch GC. Also decode-lane step 4 | **the GDSF value function lands here and merges the two eviction policies (§4.2). This is the seam.** |
| **5** | print entries + `PrintWriteback` actor (drop-oldest bounded FIFO) | restored print must be byte-identical to a recomputed one |
| **6** | scratch texture pool behind `FeatureFlags`, **default OFF** | `impl` §11 rollback path |
| **7** | `ThumbnailCache` + delete the Browse page (also decode-lane step 5) | last consumer to register |

Also queued from other lanes: export §4.2/§4.3 (viewer tools, zoom) and export §3
(the straight route — largest, lands last, schema 3→4). Not memory work.

**A measurement is owed to the user before step 3 can be sized**: the stable gap
between `arena_mb` and `phys_footprint` after a real decode. It requires driving
the app by hand and is not delegable. If your plan sequences anything against
step 3, say so explicitly rather than assuming capacity 2.

---

## 8. What a good plan looks like here

- **Cite authority by section.** `impl §6.3`, `rfc §6.1`. Every proposal should
  trace to a doc section or to a named defect in §4.
- **State the seam, not just the fix.** For §4.2 especially: the plan should say
  where consolidation happens and what must *not* be built before then.
- **One section per change**, each naming its verification and whether that
  verification can be red-verified.
- **Say what you are deliberately not fixing**, and why. A plan that touches
  everything is a plan that will not be executed.
- **Respect the sequencing.** The highest-value cleanup is often the one folded
  into the step that would otherwise deepen the mess — not a big-bang refactor
  that stalls steps 3–7.

Write to `PRD/PLAN-RFC-019-quality.md`. Do not implement it.
