# RFC-017 — Apply to all images, and who is allowed to start work

| | |
|---|---|
| **Status** | Proposed 2026-09-12. Nothing implemented. |
| **Date** | 2026-09-12 |
| **Author** | Orchestrator session, at the user's request. |
| **Depends on** | RFC-016 (every record this writes is defined there), RFC-014 (the engine is in-process), RFC-015 P.1 (one meter per frame — a batch must not re-decide exposure per frame differently from the canvas) |
| **Scope — engine** | admission control, a cost estimate, cancellation and progress that actually work under load |
| **Scope — app** | the queue, the button, the per-frame outcome list, and the job log |
| **Out of scope** | rendering more than one frame at a time (§5), resuming a job across app launches (§8 Q3) |

---

## 0. The feature, and the question it forces

A folder is open, one frame is graded, and the user wants the rest to have the
same recipe: **Apply to all images**. Optionally, export them.

That is a small button over a large question: *who decides when work starts?*
Today the answer is "whoever asked" — a slider edit, a frame switch, an export
each begin work directly, and nothing above them knows the machine's state.
That is survivable for one frame at a time and it is not survivable for
forty-seven, because the failure is not a slow app; it is a wedged machine
(2026-09-12, watchdog panic, 38 swapfiles).

---

## 1. Where the scheduling belongs

**The user's instinct is right — the frontend must not be the thing enforcing
it — but a queue that lives entirely in the engine cannot work here, and the
reason is structural.**

One batch item is three stages in two languages:

| stage | who | why it cannot move |
|---|---|---|
| decode | Swift, Core Image | the engine has no decoder; intake is Core Image (`ImageDecoder`) |
| render | C++ engine | the GPU, the arena, the tiers |
| write | Swift, ImageIO | **the engine has no file writer** — it returns pixels and `Exporter.swift` writes the TIFF |

A scheduler inside the engine would sequence the middle stage while being
blind to the two that bracket it — including the decode, which is where the
151 MP wall actually is (Core Image: no open in 240 s; the engine renders that
size in 4.84 s).

So the split is:

- **The engine owns the mechanism and the veto.** *May this start now?* is its
  question to answer, because only it knows the arena, the tier sizes and what
  a render of this frame will really cost. It also owns cancellation and
  progress, since both are properties of a running render.
- **The app owns the policy.** Which frames, in what order, what happens when
  one fails, whether to stop or continue, and what the user sees.

The rule that follows, and the one this RFC is really about: **no code path
starts a render without asking.** Not the batch queue, not a slider, not an
export. One gate, for everything.

---

## 2. What the engine gains

Three additive calls. None changes an existing one.

| call | shape | why |
|---|---|---|
| `spk_estimate` | frame dimensions + tier → `{bytes_peak, ms_estimate}` | so a queue can say "47 frames, ~9 minutes, 9.2 GB peak" before starting, and so the app stops guessing at costs it cannot see |
| `spk_admit` | `{bytes_peak}` → `{admitted, headroom_bytes, reason}` | the veto. Refuses when the projected peak would leave less than the reserve free (RFC-016 §11.5). The engine asks the OS for free memory; the app does not |
| `spk_cancel` (exists) | — | **currently written and never exercised** (`engine-open-items`). A batch job is the first thing that will really use it, so it must be tested before it is trusted: a cancel mid-render must unwind at a node boundary and free the arena |

`spk_progress` already reports `pct`, `node_times` and (RFC-015 P.1)
`auto_exposure_ev`. Batch needs one addition: **a job id**, so progress can be
asked for "the queue" rather than for one render.

**The estimate must be measured, not modelled.** Seed it from the numbers we
have (7.6 GB at 45 MP, 9.7 at 60 MP, 11.4 at 151 MP; full render 0.88 s /
1.25 s / 4.84 s) and make the harness assert the estimate is within a stated
factor of the truth on those three points. An estimate nobody checks is a
number that drifts until it is a lie.

---

## 3. What the app gains

- **A queue** with one job at a time and an ordered list of items, each with a
  state: `waiting`, `running`, `done`, `failed`, `refused`, `cancelled`.
- **The button**: *Apply to all images* — the current frame's recipe onto every
  frame in the folder, writing each one's sidecar. Optionally *and export*.
- **A visible list** of outcomes while it runs and after it ends. A frame that
  was refused for memory says so, on that row, with the number.
- **Cancel**, which stops the queue and cancels the running render.
- **The job log** (RFC-016 §11.4) written into the export destination.

---

## 4. What "apply" means, exactly

This is the part that will be got wrong if it is not written down.

- **Applied:** the film and print recipe — everything in `FilmParams` — and
  the Layer 2 adjustments, exactly as `pasteSettings` copies them today.
- **Not applied:** the decode block (white balance is per-frame: a lens filter
  on *that* exposure), the crop and geometry (framing is per-frame), and masks.
- **Exposure is re-solved per frame, never copied.** Each frame meters itself
  once (RFC-015 P.1) and the Tone travels with the recipe. Copying one frame's
  EV onto forty-seven others would make a batch that looks nothing like the
  canvases it came from. `pasteSettings` already has this rule — "same recipe,
  each frame solves its own exposure" — and the batch must not invent a second
  one.
- **Existing edits are overwritten**, and the user is told how many frames
  already had one before the job starts.

---

## 5. One at a time

`capabilities.backend.concurrent` reports `true`, and two concurrent 45 MP
renders were measured at 1.14× the throughput of sequential — one GPU. So
concurrency buys ~14 % and multiplies the peak memory by the number of
renders in flight, which is the quantity that took the machine down. **The
queue renders one frame at a time.**

The overlap worth having is different: **decode frame N+1 while frame N
renders**, because the decode is Core Image on the CPU and the render is the
GPU. That is the batch equivalent of the open path's own pipelining, it costs
one extra decoded frame in memory (~0.7 GB at 45 MP, and the queue must
admit it like anything else), and it is optional — ship the simple version
first, measure, then decide.

---

## 6. Failure, and what the user sees

- **A frame that will not fit** is refused before it starts, marked on its row
  with the headroom figure, and the queue **continues**. A folder with one
  151 MP frame in it should not lose the other forty-six.
- **A frame that fails mid-render** is marked failed with the engine's message,
  and the queue continues.
- **A cancelled job** leaves every completed frame's work on disk and every
  incomplete one untouched. No half-written export files: write to a temporary
  name and rename on success.
- **Nothing is silent.** Every one of these is a record (RFC-016) *and* a row
  in the list. The purpose of the whole exercise is that the app does not fail
  quietly.

---

## 7. Verification

Each check must be seen red first; three checks passed on broken code in the
week before this RFC.

- **The gate is the only way in.** A test that asserts no render path calls the
  engine's render entry points without going through the gate. Red by having
  one caller bypass it — this is the invariant the whole RFC rests on, so it is
  the one test that must exist even if the others are cut.
- **Admission refuses.** With the reserve set absurdly high, every frame is
  refused, the queue reports it, and nothing is rendered. Red by returning
  `admitted: true` unconditionally.
- **Cancel actually cancels.** A long render cancelled mid-flight returns
  within one node's time, frees the arena (peak drops back), and the item is
  `cancelled`. This is the first real exercise of `spk_cancel`; it is not
  trusted until seen.
- **The estimate is not a fiction.** On the three measured frame sizes, the
  estimate is within a stated factor of the real peak and the real time.
- **Apply copies the recipe and not the framing.** Batch over three frames with
  different crops and white balances: recipes equal, crops and decode blocks
  untouched, and each frame's solved EV is its own.
- **The batch canvas equals the batch export.** One frame from the job,
  exported by the queue, is byte-identical to the same frame exported by hand
  from the canvas. This is RFC-015 P.1's invariant carried into batch, where
  it is easiest to break.

---

## 8. Open questions for the user

1. **Does "apply to all" export, or only grade?** Proposed: two buttons, or one
   with a checkbox — grading forty-seven sidecars takes seconds, exporting
   forty-seven full renders takes minutes.
2. **Does it apply to the frames in the folder, or the selection?** Proposed:
   the selection when there is one, the folder otherwise, with the count on the
   button so it is never a surprise.
3. **Should a job survive quitting the app?** Proposed: no, for the first
   version. Resumable jobs need the queue persisted and every item idempotent,
   which is a second RFC's worth of care.
4. **Overwrite policy for exports** whose destination file already exists:
   skip, overwrite, or number? Proposed: number, and say so on the row.
