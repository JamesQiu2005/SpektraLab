# RFC-016 — A log worth reading, so a diagnosis does not start with Instruments

| | |
|---|---|
| **Status** | Proposed 2026-09-12. Nothing implemented. |
| **Date** | 2026-09-12 |
| **Author** | Orchestrator session, at the user's request. The implementing session is a later one. |
| **Depends on** | RFC-014 (the engine is in-process, so there is no second process to tail), the Settings page the user is designing (§6 is its diagnostics column) |
| **Scope — app** | a logging core and its file store, instrumentation of the open/develop/render/export path, the memory sampler, the diagnostic bundle |
| **Scope — engine** | **none required.** The engine already returns `elapsed_ms`, `node_times`, `auto_exposure_ev` and `spk_last_error`; this RFC only writes down what the app already receives |
| **Out of scope** | crash reporting (a crash log is Apple's, not ours), telemetry of any kind, anything that leaves the machine on its own |

---

## 0. Why

Every real defect found in the week of 2026-09-05..12 was found by someone
writing a bespoke script, not by the app telling anyone anything:

- the `EngineClient` leak (~458 MB per dropped client) — found by a C probe
  written for the occasion, after a watchdog panic gave no attribution;
- the export metering the wrong pixels (up to 0.070 EV against the canvas) —
  found by a 13-frame sweep built for one question;
- Core Image failing to decode a 151 MP TIFF in 240 s while the engine renders
  that size in 4.84 s — found by trying it;
- an export comparison that silently compared one binary with itself.

The app's own diagnostics today are: `canvasLog`, which writes to **stderr**
and only when `SPEKTRAFILM_CANVAS_LOG=1` was set **before launch**
(`Session.swift:2011`); `SPEKTRAFILM_NODE_TIMINGS=1`, which makes the engine
flush per node; and ten `print` calls. A user running the built app sees none
of it. "It was slow" and "it crashed" therefore arrive with no evidence, and
the answer is always "run it again from a terminal", which nobody will.

**The goal is narrow:** the questions we actually ask, answerable after the
fact, from a file, without a terminal, without Instruments, and without asking
the user to reproduce anything.

---

## 1. The questions the log must answer

Instruments answers "where did these 900 ms go, by call site". It is the right
tool for that and stays. The questions below are the ones asked ten times a
week, which Instruments answers slowly and awkwardly:

| # | question | what answers it |
|---|---|---|
| 1 | **Which engine am I actually running?** | version, resources directory, render core, `max_mp`, `max_texture_dimension_2d`, at startup. A day was lost once to an app rendering on an engine nobody had chosen (`HANDOFF-GPU-WIRING` §0) |
| 2 | **Where did the open go?** | the stages `LoadClock` already laps: decode, preview-texture, warm-up, frame, engine.open, solve, reprint |
| 3 | **Why is this edit slow?** | per-render: tier, pixels, `elapsed_ms`, whether it was a reprint or a full render, whether it was superseded |
| 4 | **What did auto exposure do?** | the cached EV per frame, the method, and `auto_exposure_ev` from `spk_progress` — the number the export will also use (RFC-015 P.1) |
| 5 | **How much memory, and when?** | `phys_footprint` sampled at boundaries, plus the session peak. Measured points today: 7.6 GB at 45 MP, 9.7 at 60 MP, 11.4 at 151 MP |
| 6 | **What failed?** | `spk_last_error` and the `EngineMessage` the user was shown, with the call that produced it |
| 7 | **Did it exit cleanly?** | a session-end record. Its **absence** is how a hang, a jetsam kill or a panic shows up on the next launch |
| 8 | **What machine is this?** | RAM, GPU family, macOS version, app and engine build, once per session |

Anything that does not serve one of these eight does not belong in the log.

---

## 2. Shape

**One file per app session**, newline-delimited JSON, in
`~/Library/Logs/Filmify/`, named `filmify-<ISO8601>-<pid>.jsonl`, with
`latest.jsonl` a symlink to the current one. JSONL because the consumers are a
human with `grep`, a script, and eventually a test — not a log viewer.

Every record carries the same five fields, then whatever its category adds:

```json
{"t":"2026-09-12T11:04:21.114+08:00","lvl":"info","cat":"render",
 "msg":"reprint","ms":8.4,"tier":"live","px":1707200,"frame":"DSC03710.ARW"}
```

`cat` is one of `app`, `engine`, `open`, `render`, `export`, `memory`,
`canvas`, `error`. `lvl` is `error`, `warn`, `info`, `debug`, `trace`.

**Two sinks, always:**

1. **A ring buffer in memory**, ~2000 records at `debug` and above, always on,
   costing nothing but a preallocated array. It exists so that when something
   goes wrong the last few seconds are *already* recorded — the alternative is
   "turn logging on and reproduce it", which is the thing this RFC exists to
   delete.
2. **The file**, `info` and above by default, `debug`/`trace` only when asked.

A record is written to the ring buffer synchronously and appended to the file
on a serial background queue, batched. **Nothing on a render path may touch
the disk** (§5).

---

## 3. What each category records

- **`app`** — launch (build, machine, RAM, GPU family, macOS), the settings
  that affect rendering (preview resolution, frame cap, memory reserve), and
  a clean-exit record.
- **`engine`** — the `capabilities` block at startup (§1.1), and every
  `warm_up`/`open`/`set_params` with its elapsed time.
- **`open`** — one record per frame open carrying the `LoadClock` stages as
  fields rather than a prose line, plus the frame's pixel dimensions and
  whether it was a develop or decode-only.
- **`render`** — one per render: tier, pixels, `elapsed_ms`, reprint or full,
  superseded or applied, and the generation. Per-node times **only** when the
  user has asked for them (§5).
- **`export`** — destination format, bit depth, colour space, pixels, elapsed,
  and the applied EV, so an export can be reconciled with the canvas that was
  approved (the RFC-015 P.1 invariant, in the field).
- **`memory`** — `phys_footprint` at boundaries: after decode, after
  `engine.open`, after the first print, after an export, on frame switch. Plus
  the session peak. This is the same source the Settings page reads (§6).
- **`canvas`** — what `canvasLog` prints today, at `debug`.
- **`error`** — the raw engine message, the `EngineMessage` shown to the user,
  and the operation. Always written, always flushed.

---

## 4. Retention, and cleaning

The user asked for this explicitly, and it is the half that keeps the feature
from becoming a disk leak.

| setting | default | note |
|---|---|---|
| keep logs for | 7 days | by file mtime |
| keep at most | 100 MB total | oldest first |
| keep at most | 20 files | oldest first |
| file level | `info` | `debug`/`trace` are opt-in and self-expire (§6) |

Cleaning runs **at launch**, on the background queue, before the session's own
file is opened, and never during a render. "Clear logs now" is a button that
deletes everything except the current file. A log the app cannot delete is a
support problem, so cleaning must also work when the directory has been moved
or made read-only: it fails quietly, into the ring buffer, and the Settings
page shows the failure rather than the app pretending.

---

## 5. The rules that keep it honest

1. **Nothing on the render path waits on I/O.** Append on a serial queue,
   batch, and never `fsync` per record. Flush on: an `error` record, app
   resign-active, and session end.
2. **Per-node GPU timings stay opt-in.** `Progress.detailed` makes each node
   flush before its timer stops (`pipeline.hpp`), which gives up the batching
   the whole engine depends on. It is a debugging mode, never a default, and
   the Settings toggle must say so in the same sentence.
3. **Formatting is lazy.** The record is built only if some sink will take it
   — the same `@autoclosure` discipline `canvasLog` already uses.
4. **No pixels, ever.** Sizes, times, parameters and file *names*; never image
   data, and never the contents of a sidecar.
5. **The log is not the status bar.** The status line is for the user; the log
   is for whoever is diagnosing. Neither is written in terms of the other.
6. **A record that nobody has asked a question about does not exist.** §1 is
   the list; growing the log means adding a question to that table first.

---

## 6. The Settings page's diagnostics column

The user is designing this page separately; these are the controls this RFC
needs to exist there, and nothing more:

- **Log level** (Normal / Detailed / Verbose) → `info` / `debug` / `trace`.
  Detailed and Verbose **revert to Normal on next launch**, so a user who
  turned them on to capture something does not run at `trace` forever.
- **Per-node GPU timings** — a checkbox, with the cost stated inline.
- **Retention** — the three numbers in §4, and **Clear logs now**.
- **Reveal logs in Finder**, and **Save diagnostic bundle…** (§7).
- **A live memory readout** — current footprint, session peak, free RAM —
  fed by the §3 `memory` sampler, not by a second mechanism.

---

## 7. The diagnostic bundle

One button, one `.zip`, saved where the user chooses; nothing is transmitted.
It contains: the last N log files, the startup `capabilities` JSON, the app
and engine versions, the machine block, the current settings, and the last
error. It exists because "send me your logs" must be one action, and because
a bundle assembled by the app cannot omit the file the user forgot.

**File names are included** — this is a single-user desktop app and the paths
are the user's own — but the bundle dialog says so plainly before saving, and
the user can untick it, which replaces basenames with `frame-0001.NEF` style
placeholders consistently across the whole bundle.

---

## 8. Verification

The repo's rule applies: a check that cannot fail is not a check
(`guards-that-cannot-fire`), and three checks passed on broken code this week
alone. So each of these must be **seen red first**:

- **A develop emits the expected records.** Open the smoke frame, develop it,
  and assert one `open` record with all the `LoadClock` stages present and
  non-zero, one `render`, one `memory`. Red by deleting a single lap.
- **Logging off costs nothing measurable.** N reprints at `info` versus with
  the file sink disabled; assert the difference is under a stated bound.
  Negative control: insert a synchronous write per record and watch the same
  test go red — otherwise the bound is decoration.
- **Rotation actually deletes.** Plant files past each of the three limits and
  assert what survives. Red by disabling one limit at a time.
- **An unclean exit is visible.** A log with no session-end record is reported
  as such on the next launch. Red by writing the end record unconditionally.
- **The memory numbers are the same numbers.** The Settings readout and the
  `memory` records come from one sampler; assert they agree within a sample
  interval, so the page cannot drift from the log.
- **No pixels leak.** A property test over a developed frame's records: no
  field longer than a stated length, no base64, no path outside the user's
  own selection.

---

## 9. Sequence

1. **The core**: levels, categories, ring buffer, file sink, rotation. Nothing
   instrumented yet. Ships with §8's rotation and cost tests.
2. **The open/render path**: convert `LoadClock` and `canvasLog` to records.
   `canvasLog`'s call sites stay as they are — they become `debug` records.
3. **The memory sampler**, and the Settings readout that reads it.
4. **Errors**: every `EngineMessage` path writes an `error` record with the
   raw engine text beside the user-facing one.
5. **The bundle**.

Steps 1–3 are what make the next "it was slow" answerable; 4–5 are what make
it answerable *by the user*, without this project's authors present.

---

## 10. Open questions for the user

- **Retention defaults** (§4): 7 days / 100 MB / 20 files, or tighter?
- **Console.app.** Should records also go to `os_log`, so Console and
  `log stream` see them live? It is free to add, and it is the only way to
  watch the app from outside while it runs. The cost is that `os_log` redacts
  dynamic strings by default, so the two sinks would disagree unless every
  field is marked public — which then also makes them visible to any other
  process on the machine.
- **The bundle's file names** (§7): included by default, as proposed?
- **Does a slow render deserve a visible warning**, or only a log record? A
  toast that says "this frame is 151 MP; a full render will take ~5 s" is a
  product decision, not a diagnostic one, and belongs to the user.
