# RFC-W01 — Memory, caches and RAM↔VRAM transfer on Windows (2026-11-17)

**Status: a reference design. Nothing in this document is implemented, and nothing in it was measured
on Windows.** It was written on a Mac, from the Mac app's source and the Windows engine's source, with
no Windows machine and no access to a Windows file system. Every number that is not marked *measured
(Mac)* or *measured (Windows, 2026-10-18)* is a starting value to be replaced by a measurement, and is
named as such. It is for whoever builds this on Windows.

It covers four things the Mac app does that the Windows app should come to do, and one thing the Mac
never had to do:

- **A.** the scheduler's behaviour (already ported as `desktop/crates/spk-scheduler`; what is still unwired);
- **B.** RAM control — the budget, the pressure signal, and one word for "give memory back";
- **C.** preview-cache control and the LRU stack around the scheduler;
- **D.** on a PC without unified memory (a discrete GPU — most of them), moving render intermediates
  between RAM and VRAM efficiently. **Design only.**

Sources read: the Mac app at private `main` `13af8fd2` (`app/SpektraLab/Sources/Scheduler/*`,
`Mac/Render/MacRenderCache.swift`, `Services/{WorkingCopies,ThumbnailStore,MemoryRelease,StorageTidy}.swift`);
this branch's `engine/src/gpu/vulkan_gpu.cpp`, `engine/src/pipeline/engine.cpp` (residency),
`engine/WINDOWS_MEMORY.md`, `engine/host/main.cpp`, `desktop/src-tauri/src/{scheduler,frame_cache}.rs`,
`desktop/src/state/displayCache.ts`, `desktop/crates/spk-scheduler/{README,WIRE}.md`.

---

## 1. Where Windows is today

| | today (this branch) | from |
|---|---|---|
| queue, planner, cost model, budget, prefetch policy | ported 1:1 in Rust, tested on the Mac only (301 checks, 26 mutations) | `spk-scheduler` |
| the PC's policy numbers | `DevicePolicy::desktop_pc`: RAM share 0.5, 4 GB minimum allowance, 768 MB GPU reserve, 72 B/pixel on the GPU, time ratio 1.0 — **all unmeasured**, listed by `DevicePolicy::unmeasured()` | `spk-scheduler` |
| the PC's memory reading | `WindowsProbe` (`GlobalMemoryStatusEx`, the host process's private commit): compiled, never run | `spk-scheduler` |
| the GPU's memory | **unknown to the scheduler**: `hello.backend` reports no heap size, so the budget's GPU side is never used and the budget is the Mac's one-sided formula | `engine/host`, `vulkan_gpu.cpp` |
| the engine's own memory rules | one serial worker; idle trim after 5 s and on `trim`; trim under pressure (available physical < max(512 MiB, 10 %), or available commit < 512 MiB); a 3 GiB commit reserve refused at allocation; planes device-local; upload and readback through two host staging buffers of ≤ 64 MiB each, **every chunk submitted and waited for**; a whole session's planes can be *suspended* to a temporary file and resumed, byte-exact (`residency`) | `WINDOWS_MEMORY.md` (*measured (Windows, 2026-10-18)*: full-source preview peak 4.46 GB commit on a 33 MP ARW, RTX 5070 Ti) |
| pictures the app keeps | in the webview: 128 MB of display pictures (`displayCache.ts`); on disk: the frame cache, display pictures only, 16 GB default cap, 64 GB maximum (`frame_cache.rs`); thumbnails as jobs | v1 |
| RAW proxies, kept full-size renders, neighbour prefetch | **none**. Every open decodes the whole RAW; a full view is rendered when asked and kept only as a display picture | — |
| the display path of one edit | the picture is rendered in VRAM, read back to RAM, written down a pipe to the app, sent over IPC to the webview, and uploaded to the GPU again by the webview | v1 |

The last row and the GPU row are the two that matter most on a discrete-GPU PC, and neither exists on
the Mac: there the app and the engine share one device and one memory.

---

## 2. A — The scheduler's behaviour

The rules are already the Mac's (RFC-036; `spk-scheduler/README.md` says what was ported). What the Mac
has around them that Windows does not yet:

1. **The pressure signal.** On the Mac the queue hears the operating system (`SchedulerSignals`: a
   memory-pressure dispatch source) and its own watch. On Windows the facade's `memory_pressure(level)`
   exists and nothing calls it. Proposed sources, in the app's Rust layer:
   - `CreateMemoryResourceNotification(LowMemoryResourceNotification)` waited on a thread → `Warning`;
   - a poll of `GlobalMemoryStatusEx` on the queue's own watch cadence: available commit or available
     physical under the floor (§3) → `Critical`;
   - the GPU side: the device-local heap's *budget* falling under its *usage* plus the reserve (§3, §5.5)
     → `Warning`. On Windows a GPU over its budget does not fail; it is demoted to shared system memory
     and becomes slow. The budget shrinking is therefore the signal, not an allocation error.
2. **The frontend's caches behind the queue's hooks.** `Scheduler::set_cache_hooks(trim, reclaim)` exists;
   nothing is behind it. §3.3 is the list of holders.
3. **A full view on the editing session.** The Mac opens a canvas session at canvas size, so a full view
   needs its own decode and is one-shot. The Windows host opens the whole decode for every tier, so a full
   view of the open frame can run on the editing session with no second decode (v1 did). The engine
   conformer should borrow the editing session when the source key is the same.
4. **Calibration.** The cost model learns times; on Windows it cannot learn peaks, because the host
   reports a ledger and not a footprint. To calibrate: a tool (not a test) that runs fixed jobs from rest
   on a named machine and records, per job, peak process commit, peak working set, the device-local heap's
   peak usage, and the host's ledger high-water mark — the same quantities `WINDOWS_MEMORY.md` already
   measured by hand. Its output replaces the unmeasured constants one at a time, each with its machine
   and date. **No gate asserts on time or on these numbers.**

---

## 3. B — RAM control

### 3.1 The budget has two sides on a PC

The Mac's rule (`MemoryBudget.swift`):

    budget = min(app headroom − app reserve, reclaimable pages − reserves) × (1 − margin)

with `appReserve` 150 MB (a guess), `floorReserve` 600 MB (*measured (Mac reference device)*: where the
system declared critical pressure), `margin` 0.15 (*measured*: every peak from rest within 8 % of its
prediction). On a PC with a discrete GPU a render takes from **two** pools, and either can be the one
that runs out:

    system side = min(available commit − commit reserve, available physical − floor) × (1 − margin)
    GPU side    = (device-local heap budget − heap usage − GPU reserve) × (1 − margin)
    a job fits when its system price ≤ system side AND its GPU price ≤ GPU side

- *Commit, not only physical.* On Windows a driver's device allocations also consume commit
  (`vulkan_gpu.cpp` already refuses an allocation that would leave under 3 GiB of commit). The system
  side must read `ullAvailPageFile` as well as `ullAvailPhys`.
- *The GPU side needs the host to say what the GPU has.* Additive, in `hello.backend` and
  `memory_report` (§6): the device type, whether memory is unified, the device-local heap's size, and its
  current budget and usage from `VK_EXT_memory_budget` (to be confirmed present on the drivers we meet;
  where it is absent, the heap size minus the engine's own ledger is the fallback, and it cannot see other
  programs).
- *A job has two prices.* The cost model prices a job in bytes; on a PC it needs the bytes that live on
  the GPU (planes: `GPU_BYTES_PER_PIXEL`, 72 B/pixel unmeasured) apart from the bytes that live in RAM
  (the decode, staging, the readback, the encoder). `WINDOWS_MEMORY.md`'s table is the first data.
- *On a unified GPU* (an integrated Intel or AMD GPU: one heap, the system's) the GPU side is the system
  side and the Mac's one-sided formula stands.

### 3.2 What waits, what is refused
As on the Mac: a job that does not fit waits and says why (`memory`); a job someone waits on is forced
after a hold, in a smaller mode where there is one; a job nobody waits on is never forced. Banded
rendering is the Mac's smaller mode; the Windows host renders whole frames, so on Windows the smaller
mode is **a smaller tier** until the engine bands (out of this RFC's scope).

### 3.3 One word for "give it back"
The Mac's `MemoryRelease.post()` reaches every holder of something that can be drawn again, and a check
reads each holder's count before and after, "so each release is seen, not assumed". The Windows holders:

| holder | holds | on the word |
|---|---|---|
| the webview's display pictures (`displayCache.ts`, 128 MB) | decoded RGBA of recent frames | emptied but the one on screen |
| the webview's canvas textures other than the shown one (compare, original) | GPU memory in the browser's process | dropped |
| thumbnails in the filmstrip and the Library beyond the visible range | decoded pictures | dropped |
| the engine's idle pool and staging | VRAM and RAM | `trim` (exists) |
| editing sessions other than the open frame's | VRAM | demoted (§5.4) or closed |
| the library helper's page cache | SQLite pages | `PRAGMA shrink_memory` through a helper call (to add) |

A release must be observable: a `counts()` equivalent the Settings › Engine pane and a check can read.

---

## 4. C — Preview-cache control and the LRU stack

The owner's rule for the Mac (2026-10-24), which this keeps: *the scheduler is left alone; what changes
is the cache system around it, and what is put into the scheduler.* The cache layer decides **what is
submitted, and when**; the scheduler orders it; the book keeps it.

### 4.1 The tiers

| tier | what | where | bound | the Mac's |
|---|---|---|---|---|
| T0 | the picture on screen and a few behind it | the webview (RAM, and the browser's GPU memory) | bytes; emptied on the word | `RenderedPictures`, `ThumbnailStore` (bounded by bytes, not count) |
| T1 | the open frame's engine session: source, negative, print | VRAM (and RAM/disk when demoted, §5.4) | one editing session; the scheduler's budget | the editing session |
| T2a | a RAW's **proxy**: its decode at preview size, made once | disk | under the working-copies limit, one LRU with the copies | `RawProxy` (`.spkraw`) |
| T2b | **full-size renders** of recently viewed frames | disk | their own limit, set by the person (Settings › *Full-Size Renders*) | `.spkfull`, `WorkingCopies.fullLimit` |
| T2c | display pictures (what v1's frame cache holds) | disk | the frame cache's cap | — (v1's own) |
| T2d | thumbnails | disk | by bytes | `ThumbnailStore` |

Windows has T0, T1 and T2c today. **T2a and T2b are the missing ones**, and T2a needs the host: it must
be able to open a session from a decode smaller than the file (the Mac opens a canvas session at canvas
size; the Windows host always opens the whole frame — `WIRE.md`'s pricing note says so). Until the host
can, proxies save nothing and should not be built.

### 4.2 The book's rules (from `WorkingCopies.swift`, kept as they are)

- **By bytes on disk**, never by count: a 100 MP RAW's full render is ~1 GB, a 12 MP JPEG's ~120 MB.
- **Last use is the file's own modification time**, set each time a job is handed the file, so the order
  survives a crash with no index to go stale.
- **Never one in use**: a frame with a develop under way, a page open or an export running; the render
  the page shows or is making; a prefetch under way. The store may stand over its limit by what is in
  use, and by no more.
- **Pinned**: the current frame's full render is never taken by the limit.
- **A proxy is of a file and its decode settings, not of a frame**: two frames (variants) of one RAW with
  one white balance read one proxy. It goes only when no frame names it.
- **Nothing here is the only copy of anything**: every entry can be made again, so the folder is left
  out of backups and *Clear* may take all of it.
- **A file is not an entry until it is whole**: written into an `incoming` folder and renamed into place;
  what a killed run leaves is swept at the next launch.
- **The launch's tidy** removes what the book does not know and what no frame names any more.
- On Windows: the folder under `%LOCALAPPDATA%\SpektraLab\`, movable in Settings as the frame cache is;
  paths through the same long-path/Unicode rules as the host's resources; `SetFileTime` for last use;
  `MoveFileEx(MOVEFILE_REPLACE_EXISTING)` for the rename; a file another process holds open cannot be
  deleted — the book skips it and tries at the next trim (to be checked on Windows).

### 4.3 Neighbours made ahead (from `MacRenderCache.swift`)

While a person inspects a frame at full size, the filmstrip's neighbours are rendered too, so stepping
to one and zooming shows it at once and its export reads it:

- only **after the current frame's own render is kept**, and **one at a time**;
- **below everything a person waits on** (the Mac: an `importDevelop`, priority 5; edits are 1, zoom and
  exports 3, cards 4), so a running prefetch gives way and a queued one waits;
- **the nearest first, the way the person is going**: +1, −1, +2, −2; **with 16 GB of RAM or less, +1
  only** (`PrefetchPolicy`, the owner, 2026-11-13: each is a full-size decode and render, *measured (Mac,
  36 GB)* 75 MB for an 8 MP ORF to 6.3 GB for a 102 MP RAF over rest);
- **only with room**: none where the host's headroom, once the prefetch's price is paid, would be under
  the floor — on the Mac 3 GB = the 600 MB critical level + 2,400 MB for the dearest thing the next step
  asks (*measured (Mac)*); on a PC the floor has a GPU side too, both unmeasured;
- **cancelled when the person moves on**; one for the frame stepped to is taken over, not restarted;
- **never one that would push out the render it was made beside**;
- **only while inspecting**: a person who never zooms past the preview pays for nothing.

On Windows this is a module in the app's Rust layer beside the scheduler hub, submitting ordinary jobs.
It needs T2b first.

---

## 5. D — RAM↔VRAM on a discrete GPU (design, not implemented)

### 5.1 What moves today, and what it costs

| movement | today | cost |
|---|---|---|
| **open**: decode → GPU | LibRaw's 16-bit RGB is widened to float in RAM (12 B/pixel), copied into a host staging buffer 64 MiB at a time, each chunk copied to a device-local plane **and waited for** before the next | two full-frame CPU passes (widen, memcpy); the bus idles while the CPU copies and the CPU idles while the bus copies; a staging buffer that is created, grown and destroyed |
| **show**: GPU → the screen | the view is read back to RAM in chunks, written to the host's stdout, read by the app, sent to the webview over IPC, and uploaded to the GPU again by the webview | the picture crosses the bus twice and is copied in RAM at least four times, for every edit |
| **export**: GPU → file | read back in chunks; TIFF written from the readback in ≤ 1 MiB pieces | already bounded (*measured (Windows, 2026-10-18)*) |
| **make room**: a session's planes → disk | read back 8 MiB at a time and written to a temporary file; resumed lazily, byte-exact | VRAM is freed only through a disk; there is no RAM tier, and it is the whole session or nothing |

### 5.2 Showing a picture without a round trip (the largest win, the largest change)

The backend's own header says it: *"Command batching and native texture export are subsequent steps."*

- **Step 1, small and safe — shared memory in place of the pipe.** The host writes the readback into a
  named file mapping the app has open, and sends only its header down the pipe. Removes the pipe copy and
  the host-side buffering; the picture still crosses the bus twice. No GPU feature is needed. This also
  serves exports and thumbnails.
- **Step 2 — the picture never leaves the GPU.** The host renders the view into an image it presents
  itself: a swapchain on a child window of the app's window, placed where the canvas is, with the webview
  above it for the overlays (crop handles, compare disc, the status line). The webview would no longer
  hold the picture at all; zoom and pan become a viewport the host is told, not pixels the webview is
  sent. What must be checked on Windows before this is designed further: a child window owned by another
  process inside a WebView2 window; WebView2 with a transparent background over it; DPI and multi-monitor
  moves; what a device loss does to the window. An alternative to investigate is a texture shared by
  handle (`VK_KHR_external_memory_win32`) composed by the app — more moving parts, same benefit.
- Either way **the histogram, the latitude meter and the navigator** must then come from the host as
  small results (a 256-bin histogram, a 256 px thumbnail), not from pixels in the webview.

### 5.3 Moving bytes faster when they must move

In order of expected value; each needs its own measurement on a discrete GPU before it is kept.

1. **Upload what the decoder made, and widen on the GPU.** `compatible16` is 16-bit RGB: upload 6–8
   B/pixel and convert to float32 in a compute pass, in place of converting on the CPU and uploading
   12–16. Halves the bus traffic and removes the float copy from RAM. (`headroom` already has float data
   and gains nothing.) Must be bit-identical to today's CPU widening — a parity check, on the Mac too.
2. **Do not wait for each chunk.** Record the chunk copies and submit them with a fence, filling the next
   chunk of a small ring (2–4 × 64 MiB) while the device copies the last. The invariant the backend
   protects — *no staging or pooled buffer is reused while the device still reads it* — is kept by the
   ring's fences instead of by waiting; that is the same care as the Mac engine's "free is not idle" rule
   and needs the same kind of test (a buffer reused early must be caught).
3. **Keep the staging ring** for the life of the device and trim it only on the word, not after each use.
4. **A transfer queue**, where the device offers a queue family for transfers only, so a long upload
   does not sit in front of a render on the compute queue. (The host is one serial worker today, so this
   pays only together with (2).)
5. **Import the decoder's own pages** (`VK_EXT_external_memory_host`): the decode is written into
   page-aligned memory that is then bound as the upload's source, with no memcpy. Only where the driver
   offers it and the alignment rule can be met; otherwise the ring.
6. **Read back less.** For the screen: 8- or 10-bit, at the size shown, and at 1:1 only the part in view
   (`engine/src/desktop/viewport.hpp` already describes a viewport) — until §5.2 step 2 removes the
   readback altogether. Read back from host-cached memory (the backend already chooses it), and never
   read from an upload buffer.

### 5.4 Where intermediates rest

Today a plane is in VRAM or, with its whole session, in a file. On a typical discrete-GPU PC there is
less VRAM than RAM (8 GB against 32), so VRAM is the pool that runs out first and RAM is the natural
place to put what is not being computed on. Three tiers, per plane:

| tier | what it is | to bring back |
|---|---|---|
| hot | device-local VRAM | nothing |
| warm | page-locked RAM, exact bytes | one upload |
| cold | the residency file, exact bytes | a read and one upload |

What goes first when the GPU side is short, by what it costs to have again:

1. scratch and the idle pool (free; `trim` today);
2. view and print tiers (dropped, not kept: they are a reprint away);
3. the negative of a session not on screen (warm: a film stage away, the dearest computation);
4. the source of a session not on screen (warm; or dropped where a proxy or the file can supply it);
5. the open frame's own negative and source — never, short of failing the job.

Warm becomes cold when the system side is short too. **The scheduler decides** (it has both sides of
the budget and knows which frame is open); **the engine executes** and stays byte-exact, as residency is
today. That needs an additive host call that names a session, the planes and the tier (§6), and the
ledger to report what is warm and what is cold. Demotion and promotion are transfers, so they are jobs:
they take the worker and can be priced.

### 5.5 Never spill
On Windows a GPU asked for more than it has does not refuse; the system moves allocations to shared
memory and everything slows by a large factor. So: stay under the device-local heap's budget with a
reserve; treat the budget falling as pressure (§2.1) and demote **before** allocating; and do not use an
allocation failure as the signal, because it will rarely come.

### 5.6 The opposite case: a unified GPU on a PC
An integrated GPU has one heap, the system's. There, staging is waste: allocate the plane host-visible
and device-local, map it, and write the decode straight into it — no copy at all. The backend should
choose by what the device says (its type, and whether a memory type is both), not by vendor.

### 5.7 The order to build in, and what decides each step

| step | needs | decided by (measured on a discrete GPU, a 24 MP and a 100 MP frame, from rest) |
|---|---|---|
| the host reports the GPU's memory; the budget's GPU side; pressure from the budget (§2.1, §3.1, §5.5) | additive host fields | does the budget keep the heap under its limit through a session of opens and full views |
| a full view on the editing session (§2.3) | the engine conformer | decodes per settled edit: 2 → 1 |
| shared memory in place of the pipe (§5.2 step 1) | host + app | copies of the picture per edit |
| 16-bit upload, widened on the GPU (§5.3.1) | a kernel + parity | bytes over the bus per open; peak commit at open |
| the ring and fences (§5.3.2–3) | the backend | wall time of an open's upload — recorded by a tool, asserted nowhere |
| warm tier (§5.4) | host call + scheduler | VRAM held with two frames visited; time to return to a frame |
| T2b and neighbours (§4) | the app | what is on disk; whether a step shows at once |
| the picture stays on the GPU (§5.2 step 2) | a prototype first | whether the window behaves; only then the rest |
| proxies (T2a) | the host opens from a smaller decode | — |

---

## 6. Additions to the host protocol and the wire (all additive)

- `hello.backend`: `device_type` (`discrete` | `integrated` | `virtual` | `cpu`), `unified_memory`,
  `device_local_bytes` (the heap's size). `spk-scheduler` already reads the last two if they are sent.
- `memory_report`: `gpu.budget_bytes`, `gpu.usage_bytes` (from the driver, where it reports them),
  `warm_bytes` beside today's `suspended_bytes`, and per session which planes are hot, warm or cold.
- `residency {session, planes?, tier: "hot" | "warm" | "cold"}` → what moved, in bytes; exact; on failure
  nothing changes (as `redecode` and today's suspend promise).
- `render_view`/`thumbnail`/`render_source`: `transport: "shm"` with a mapping name (§5.2 step 1).
- `histogram {session, …}` and a navigator picture as results (for §5.2 step 2).
- the scheduler's wire: the budget reading gains the GPU side's numbers (it has the fields; they are
  empty today), and `WaitReason::memory` gains which side made it wait, for the status line.

## 7. What can be tested, and where

| | on the Mac (as everything in this branch is) | only on Windows |
|---|---|---|
| the book's rules (§4.2), neighbours' rules (§4.3) | yes: on temp folders and the simulated engine, on a virtual clock — a port of the Mac's `storage_selftest` and `MacRenderCheck`, with mutations | file-in-use deletes, `SetFileTime`, long paths |
| the two-sided budget (§3.1), pressure (§2.1) | yes: injected readings | the real probe, the real heap budget |
| byte-exact demotion and promotion (§5.4) | yes: MoltenVK runs the same kernels (it is unified, so it proves exactness, not benefit) | benefit; spill behaviour |
| 16-bit upload parity (§5.3.1) | yes | — |
| the ring's safety (§5.3.2) | partly (MoltenVK) | under a real discrete driver |
| anything about speed, the bus, WDDM, the window (§5.2) | **no** | yes — and by a measuring tool, never a gate |

A Mac's memory is unified and MoltenVK is a translation layer, so **nothing in §5 can be shown to help
from here**. That is why this is a design and not a patch.

## 8. Open for the owner

1. Whether the canvas may become a native surface under the webview (§5.2 step 2). It changes what the
   webview is: chrome and overlays, not the picture.
2. The Windows default for *Full-Size Renders* and whether the frame cache's 16 GB default stays.
3. Whether 16 GB of RAM is the right line for "+1 only" on a PC, where the GPU's memory is separate.
4. Who measures: every constant here waits for a named machine.
