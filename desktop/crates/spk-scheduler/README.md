# spk-scheduler

The Mac v2 app's render scheduler (RFC-036) in Rust, for SpektraLab 2 on Windows, and the engine
conformer that drives v1's C++/Vulkan engine through its host process (`desktop/HOST-PROTOCOL.md`).
A standalone package in phase 1 (no workspace; `Cargo.lock` not committed); the Tauri layer wires it in
phase 2. **`WIRE.md` is the webview's contract** and is held to the code by `tests/wire.rs`.

```
webview ─ Tauri commands ─ Scheduler (facade) ─ RenderQueue ─ Planner / CostModel / MemoryBudget
                                                     │
                                              DevelopEngine
                                     ┌───────────────┴───────────────┐
                              SimulatedEngine                    HostEngine ─ HostLink ─ spektralab-host
                                                                            (the app's HostManager,
                                                                             or ProcessHostLink)
```

## What was ported (R1)

From `ref-mac-v2/app/SpektraLab/Sources/Scheduler/` at `13af8fd2` (2.4.1), rule for rule, the Swift
names in snake_case and the Swift spellings on the wire:

| Rust | Swift | notes |
|---|---|---|
| `types` | `SchedulerTypes.swift`, `PixelSize`, `ParamLayer` | every type, `RenderJob`'s every field and helper |
| `cost_model` | `CostModel.swift` | seeds, `ComposedOpen`, `RawOpen`, `BandGeometry`, key, learn; `CorrectionStore` for `UserDefaults` |
| `budget` | `MemoryBudget.swift` | `BudgetTuning`, `MemoryBudget.compute/fits` |
| `device_policy` | `DevicePolicy.swift` | plus the desktop PC (R2, below) |
| `planner` | `Planner.swift` | ladder, gate, plan |
| `prefetch` | `PrefetchPolicy.swift` | |
| `queue` | `RenderQueue.swift` | submit, coalesce (canvas, import, cards by slot), supersede, yield, cancel, pump, reclaim rungs, forced and anyway starts, watch, derate, cadence hold, idle trim, records |
| `engine` | `DevelopEngine.swift` | the trait, `RenderResult`, `RunMeasurement`, `BandsRan`, `EngineError` |
| `simulated` | `SimulatedEngine.swift` | on the queue's clock |
| `memory_probe` | `MemoryProbe.swift` | a trait: injected, macOS, Windows (R3) |
| `job_log` | `JobLogFile.swift` | an injected `JobSink`; `JobLogFile` writes the Mac's line (R7) |
| `host::HostEngine` | `SpkEngine.swift`'s role | over HOST-PROTOCOL, not the C ABI (R5) |
| `selftest` | `tools/scheduler_selftest.swift` | every check (301), the 26 mutations |

**The phone and camera rules are ported** (capture rules, camera reserve and warmth, the closed darkroom,
`shot`, the background gate): the queue's logic depends on them and the selftest checks them. A desktop
simply never sends a camera (`FrontendStateMsg.cameraPhotoMegapixels`).

**Concurrency.** The Swift queue is a `@MainActor` class. Here its state is one mutex, never held across
an `await` nor while anything outside the queue runs: an operation collects what it must do outside
(publish a snapshot, write a record, wake waiters, cancel on the engine, call a hook, spawn a task, pump)
and does it after unlocking, so a hook may call back into the queue. All intervals are tokio time (R4):
under a paused runtime the rules run in virtual time.

## What was left out, and why

| Swift | why |
|---|---|
| `SchedulerSignals.swift` (UIKit memory warning, `DispatchSource` pressure, thermal and Low Power notifications) | platform signal sources: the Tauri layer delivers them through `Scheduler::memory_pressure` and `set_frontend_state` (`thermal`, `lowPower`) |
| `SpkEngine`'s Metal specifics: `FrameSource` decode/deliver, the print layers' cut, a slide's HDR rendition, Enable HDR's curve, scene layers, the Cineon view, `keepsEverySession`, the in-process footprint sampler (`RunWatch`) | the v1 host does these itself (or not at all) behind its own methods; `HostEngine` maps a job to host calls instead. The cost model still prices them (`printLayers`, `hdrRendition`, `scenePlanes` …) so a job that asks for them is priced as on the Mac |
| `Notification.Name.spkReclaim`, `os.Logger` | `Hooks::on_reclaim`; the `log` crate |
| `PrefetchPolicy`'s callers (`MacRenderCache`) | not scheduler code; the policy is here for the page that prefetches |

## Deviations from the Swift, each deliberate

- `FrameId` is a string the webview chooses (Swift: `UUID`); `JobId` stays a UUID, written upper-case as Swift does.
- `RenderJob.request` (new): the host calls the job is made of (`wire::JobRequest`), which the Mac keeps in
  its `FrameSource`. `RenderResult.delivery` (new): the host reply's `result` and payload for the submitter.
- Outcomes keep the Swift's 100; their payloads are kept up to `KEPT_PAYLOAD_BYTES` (1 GiB) and handed over
  once (`Scheduler::outcome`), because here the pixels travel with the outcome.
- `force_anyway_after` is 5 s on every desktop (Swift: the Mac only, nil on a phone): Windows, like macOS,
  frees nothing for the app under pressure. Unmeasured on Windows.
- `MemoryReading.gpu_available` / `Binding::Gpu` (new, PC only): a third budget side. Absent everywhere
  the GPU's memory is unknown — which is every v1 host — so the budget is then exactly the Swift's.
- `DevelopEngine::close_editing` is on the trait (Swift: `SpkEngine` only), so the facade can close the
  editing session when `openFrame` changes.
- `effect_versions` falls back to `build=<engine build>`: the v1 capabilities have no `effect_versions`.
- A record's `at` is the queue's clock mapped to a wall date (virtual in tests).
- The simulated engine's ±8 % spread is derived from the job id (reproducible), not `random`.
- `HostEngine` reports no measured peak (0: the host gives a ledger, not a footprint), so the cost model
  learns time from the host but never a peak; a banded plan is run whole and recorded `ran: "whole"`.

## The desktop PC policy (R2) — unmeasured on Windows

`DevicePolicy::desktop_pc(installed_ram, GpuMemory)`. Every number below is a named constant marked
unmeasured, and `DevicePolicy::unmeasured()` (shown in `scheduler_budget().policy.unmeasured`) lists them:
`PC_ALLOWANCE_SHARE_OF_RAM` (0.5), `PC_MIN_ALLOWANCE_MB` (4 GB), `PC_GPU_RESERVE_BYTES` (768 MB),
`PC_GPU_BYTES_PER_PIXEL` (72), `PC_TIME_RATIO` (1.0). The budget tuning (floors, margins) is the
reference phone's, as it is on the Mac. **The v1 host does not report the GPU's memory**: `GpuMemory::
from_hello` reads `hello.backend.device_local_bytes` / `unified_memory` where a host sends them, and
today always finds `Unknown`. Reporting them needs the engine's `Gpu` interface (`engine/src/gpu`), which
is outside this workstream.

## Platform readings (R3)

`MemoryProbe` is a trait. `InjectedProbe` (tests), `MacProbe` (`host_statistics64`, `proc_pid_rusage`
footprint; may read the host process's pid), `WindowsProbe` (`GlobalMemoryStatusEx`: available physical
memory and available commit; `K32GetProcessMemoryInfo` private commit). **The Windows probe has never run**:
it is compile-checked for `x86_64-pc-windows-gnu` and its mapping onto the Mac's reading
(`MemoryReading::windows`: free = available physical, allowance = min(available physical, available
commit)) is unmeasured.

## The host

- `HostLink` (`host/mod.rs`): `request(method, params, payload, timeout) -> Result<(header, payload), HostError>`
  — v1's `HostManager::request` shape, the header the full `{ok, result | error}` — and `subscribe()` to
  the host's events. W2 implements it over the app's `HostManager`.
- `ProcessHostLink`: spawns `spektralab-host --resources …`, HOST-PROTOCOL §1 framing (copied from v1's
  `framing.rs`). For tests and tools.
- `HostEngine`: sessions, cancel, errors, bands — WIRE.md "Sessions" says the rules.
- **R8:** the host gained one additive method, `trim` (`engine/host/main.cpp`, HOST-PROTOCOL.md, listed in
  `hello.methods`): the scheduler's trims (a job waiting for memory, pressure, the idle spell) would
  otherwise free nothing until the host's own 5 s timer. An older host without it: `trim` returns 0.

## Tests — macOS only, by design

The whole suite (the ported selftest and its mutation run, T3–T5) runs on this Mac and is **never built
for Windows**: `#![cfg(target_os = "macos")]` on every file under `tests/`, `cfg(all(test, target_os =
"macos"))` on unit tests, the selftest module and its mutation switches behind `cfg(test)` or the dev-only
`selftest` feature on macOS. The port is verified where it was ported, against the Swift's own numbers and
the real host built on the Mac; Windows-side testing is out of scope (PRD-W0 §1.1), and a test that
cannot run where it is built would only be a test that silently does not run. Windows is checked by
compiling the library: `cargo check --lib --target x86_64-pc-windows-gnu`.

No test asserts on wall-clock time: scheduling rules run on tokio's paused clock (virtual time), and the
real-host test asserts on pictures (size, opaque, not constant) and on outcomes.

```sh
desktop/crates/spk-scheduler/tools/build-host-mac.sh        # once: build/host-mac/spektralab-host (MoltenVK)
SPEKTRALAB_RAW_FIXTURES=/path/to/RAW_decode_tests desktop/crates/spk-scheduler/gate.sh
```

| | where |
|---|---|
| T1 the selftest's checks | `src/selftest.rs` (`selftest::tests::every_check_passes`) |
| T2 every mutation caught | `selftest::tests::every_mutation_is_caught`, and `scheduler-selftest --self-test` |
| T3 wire round-trips, WIRE.md's examples, a Swift-shaped `JobRecord` | `tests/wire.rs` |
| T4 `HostEngine` on a scripted link | `tests/host_engine.rs` |
| T5 the real host on a RAW | `tests/real_host.rs` (`SPK_HOST_BIN`, `SPEKTRALAB_RAW_FIXTURES`; `gate.sh` requires both and also shows it fails without its fixture) |
| T6 Windows | `cargo check --lib --target x86_64-pc-windows-gnu` |

`tools/build-host-mac.sh` says why it builds from a scratch copy (engine.cpp's `#ifndef __APPLE__` guard
breaks the Vulkan-on-Apple configuration) and why it must not take Vulkan headers from
`/opt/homebrew/include` (Homebrew's `jpeglib.h` then breaks every JPEG export).
