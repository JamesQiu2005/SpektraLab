# Task A — implement RFC-016 (diagnostics and logging)

You are one of three sessions working this repo tonight, in **one shared
working tree**. Read the ownership section before you touch anything.

## Read first, in this order

1. `CLAUDE.md` (repo root) — the short version and the traps.
2. `AGENTS.md` — working rules. Note §"REGENERATE after adding/removing any
   source file".
3. `rfc/RFC-016-diagnostics-and-logging.md` — **this is your spec, in full,
   including §11 (the user's decisions) and §8 (verification).**
4. `README.md` build/test section.

## Scope

RFC-016 §9's five steps, all of them:

1. The core: levels, categories, ring buffer, file sink, rotation.
2. The open/render path: `LoadClock` and `canvasLog` become records.
3. The memory sampler.
4. Errors: every `EngineMessage` path writes an `error` record with the raw
   engine text beside the user-facing one.
5. The diagnostic bundle.

Plus, from §11:

- **`os_log` as a second sink** (§11.2). Every field we want readable is
  marked `public`. The file sink remains the complete record.
- **The log destination is settable** (§11.4), default
  `~/Library/Logs/Filmify/`.
- **A job log written beside an export's output** (§11.4) — for a single
  export today; the batch case is RFC-017 and is out of scope.
- **A refusal is a visible event, not just a log line** (§11.5). When a frame
  is refused for size or for memory headroom, the user is told in the window
  (there is already a `session.serviceBlocked` / badge mechanism in
  `Windows/EditorWindow.swift` — use the existing surface, do not invent a
  new one), and the log records why. A projected peak that does not fit gets
  a warning the user can override, and a log record either way.

### Explicitly out of scope

- **RFC-017 / "apply to all" / batch / queue / scheduling. Do not implement
  it and do not touch code related to it.** The user was explicit.
- **The Settings *page* UI.** You build the settings *model* — the stored,
  observable properties the page binds to (log level, per-node GPU timings,
  the three retention numbers, log destination, the live memory readout
  source). I (the orchestrator) build the SwiftUI page on top of it. Give me
  a clean, documented model type and tell me its API in your report.
- Crash reporting, telemetry, anything that leaves the machine.

## Ownership — do not edit files outside this list

Yours:
- **NEW** `modern_UI/Spektrafilm/Spektrafilm/Diagnostics/*` (make the folder;
  put the core, the file sink, rotation, the memory sampler, the bundle and
  the settings model here)
- `modern_UI/Spektrafilm/Spektrafilm/Model/Session.swift`
- `modern_UI/Spektrafilm/Spektrafilm/Service/EngineClient.swift`
- `modern_UI/Spektrafilm/Spektrafilm/Service/Methods.swift`
- `modern_UI/Spektrafilm/Spektrafilm/Service/EngineMessage.swift`
- `modern_UI/Spektrafilm/Spektrafilm/Export/Exporter.swift`
- **NEW** `modern_UI/Spektrafilm/SpektrafilmTests/DiagnosticsTests.swift`

Owned by someone else — **do not edit, even trivially**:
- `Windows/*`, `Panels/*`, `Canvas/*`, `Theme/Theme.swift` (session B)
- `Model/Geometry.swift`, `Panels/Sections/CropSection.swift`,
  `Export/ExportSheet.swift`, `SpektrafilmApp.swift` (me)

`SpektrafilmApp.swift` is mine and you need launch/clean-exit records in it
(§3 `app`). **Do not edit it.** Instead: put the launch and terminate entry
points as methods on your logging core, and tell me in your report the two
exact lines to add to `AppDelegate.applicationDidFinishLaunching` and
`applicationWillTerminate`. I will wire them.

If you believe you must touch a file outside your list, stop and message me
(`filmify-40`) instead of editing it.

## The repo's hard rule on tests

From memory and from `CLAUDE.md`: **a guard that cannot fire is not a guard.**
Three checks passed on broken code in the week before this one. RFC-016 §8
lists six checks and says each must be **seen red first**. Do that literally:
break the thing, run the test, record that it failed, restore, run it green.
In your report, state for each check what you broke to make it red and what
the red output was. A check you did not see fail does not count as done.

## Build and test

```bash
cd modern_UI/Spektrafilm
python3 Tools/gen-project.py     # REQUIRED after adding any new source file
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
           -derivedDataPath build/DerivedData build
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests \
           -derivedDataPath build/DerivedData test
```

`engine/build.sh bundle` has already been run and `engine/resources/` is
current — you should not need to re-run it, and you must not change anything
under `engine/`. This RFC's §"Scope — engine" says **none required**.

Two sessions share this tree. `Tools/gen-project.py` regenerates
`project.pbxproj` from the filesystem, so running it picks up the *other*
session's new files too — that is fine and expected. If a build fails in a
file you do not own, do not fix it: report it to me.

## Performance discipline (§5)

Nothing on a render path may touch the disk. Append on a serial queue, batch,
never `fsync` per record. Formatting is lazy — the `@autoclosure` discipline
`canvasLog` already uses (`Model/Session.swift:2010`). Per-node GPU timings
stay opt-in, because `Progress.detailed` makes each node flush and gives up
the batching the engine depends on.

## Reporting

Message `filmify-40` (me) when:
- the core (§9 step 1) builds and its tests are green — a checkpoint, so I
  know the shape of the settings model early and can start the Settings page;
- you are blocked, or you need a file you do not own;
- you are done.

In the final report: the settings model's API, the two `SpektrafilmApp.swift`
lines I need to wire, the red-then-green evidence for each §8 check, and
anything in the RFC you could not do and why.
