# RFC-027 — The settings clipboard: seven groups, copied by choice, solved on the target

| | |
|---|---|
| **Status** | **Implemented 2026-09-28** on branch `recipe-clipboard`. |
| **Decision** | ⌘⇧C / ⌘⇧V become a clipboard of **seven groups ticked at copy time**. A paste writes **settings**, and the target solves its own numbers. The clipboard is pasted onto every picked frame. |
| **Product** | `PRD/PRD-settings-clipboard.md` |
| **Also fixes** | The develop race behind the user report "it copied, but not really" (§5.1); the pasted Scene Placement curve behind "high-contrast photos blow out" (§5.2). |
| **Not in scope** | Named presets, undo across frames, crop (PRD §7). |
| **Related** | RFC-015 (metering and white balance), RFC-017 (apply to all, still proposed; this is its first slice), RFC-023 (Scene Placement), RFC-024 (Tone Mask), RFC-025 (effect strengths), RFC-026 (the schema this mirrors). |

## 1. What was there

`Session.copySettings` / `pasteSettings` (Session.swift, "undo and the work clock"):

- The clip was `SettingsClip(params:, adjustments:)`, held in memory, all or nothing.
- The paste assigned `sidecar.params = clip.params` whole. That included the **solved** Scene Placement curve (`highlightKnee`, `highlightRoom`, `shadowKnee`, `shadowRoom`), which is the source photograph's fit expressed in absolute scene stops.
- It pasted onto **the frame on the canvas only**.
- It was not gated by `batchExporting`.

## 2. The model: `Model/SettingsClipboard.swift`

```swift
enum ClipboardGroup: String, CaseIterable, Codable, Sendable {
    case filmAndPaper, exposure, whiteBalance, filmEffects, printEffects, scenePlacement, masks
    var paths: [String]            // the stored fields this group owns
    static let notCopied: [String] // stored fields no group owns, each with a reason
}

struct SettingsClip: Equatable, Sendable {
    var groups: Set<ClipboardGroup>
    var settings: Sidecar          // the source frame's settings at copy time
    var sourceName: String
    func applied(to target: Sidecar) -> Sidecar   // pure
}
```

**`applied(to:)` is pure** (Sidecar in, Sidecar out). The whole paste semantics is testable without a window, an engine or a file. The session only decides *how the result reaches the frame* (§4).

### 2.1 Ownership of every stored field

`paths` are prefixes into the encoded sidecar (`params.effects` owns every `params.effects.*`).

| Group | Paths |
|---|---|
| `filmAndPaper` | `params.filmStock`, `params.printStock`, `params.scanFilm`, `params.extendedDynamicRange` |
| `exposure` | `params.autoExposure`, `params.autoExposureMethod`, `params.exposureCompensationEV`, `params.printBrightnessStops` |
| `whiteBalance` | `decode.whiteBalance`, `decode.temperature`, `decode.tint`, `params.yFilterShift`, `params.mFilterShift` |
| `filmEffects` | `params.filmFormatMM`, `params.filmFrame`, `params.filmSide`, `params.sideLengthMM`, `params.grainActive`, `params.halationActive`, `params.glareActive`, `params.effects` |
| `printEffects` | `params.printEffects`, `params.preflashExposure` |
| `scenePlacement` | `params.sceneLatitude`, `placementNeedsFit` |
| `masks` | `params.contrastMask`, `masks` |
| *not copied* | `decode.lensCorrection` (the lens, not the look), `adjustments` (Post-Dev grade, outside the 2026-09-23 positioning), `geometry` (crop, PRD §7), `solvedEV` (a report, see §2.2), `state`, `source`, `schemaVersion`, `decoder` |

**A test enforces this table** (`SettingsClipboardTests.testEveryStoredFieldHasExactlyOneOwner`). It walks every stored field of `Sidecar`, `FilmParams` and `DecodeSettings` with `Mirror`, the way `AgentSchemaTests` does. A new field that nobody owns fails the suite. A field is then either given to a group or added to `notCopied` with a reason.

### 2.2 Settings, not solved numbers (the user's decision, 2026-09-28)

| Field | What is pasted |
|---|---|
| exposure method, auto-exposure, compensation | copied. The target meters itself. `solvedEV` is **cleared** when the method or the auto-exposure switch changed, because it is the source method's report. The develop, or `retargetSolvedEV` on a developed frame, refills it. |
| white balance `.asShot` | `.asShot` only. The target's own `temperature`/`tint` are kept: they are its camera's numbers, not the source's. |
| white balance preset / custom | `whiteBalance`, `temperature`, `tint` copied. For a custom value the number *is* the setting. |
| Y/M filters | copied. They are offsets from the pack the target solves. |
| `filmFormatMM` | copied, then **re-derived** on the target from its own aspect (`recomputeFilmFormat`, and again at the next decode). |
| Scene Placement | the **intent** only: `highlightPullBack`, `shadowPullBack`, both percentiles, `rolloff`, `maxLift`, `norm`. The solved curve is reset to identity (`active = false`, default knees and rooms). `placementNeedsFit = pull-back > 0`. |

### 2.3 `Sidecar.placementNeedsFit`

A new stored field on `Sidecar`, not on `SceneLatitudeSettings`. It is frame state like `solvedEV`, not an edit, and it is not part of the agent schema. It is encoded only when true (as `masks` is only when non-empty) and decodes to `false` when absent, so every existing sidecar reads unchanged.

## 3. The interface

`Panels/Sections/ClipboardSection.swift`, key `"clipboard"`, second in `LeftPanel`'s list (under the Navigator), `initiallyExpanded: false`.

- Seven `ToggleRow`s bound to `Session.clipboardGroups`. That property persists in `UserDefaults` under `Session.uiKey + "clipboard.groups"`, and defaults to all seven.
- One metadata line: `L(.clipboardHolds)` formatted with the source name and group count, or `L(.clipboardEmpty)`.
- Two pills styled like the Navigator's *Fit*: **Copy** (`copySettings()`), and **Paste** / **Paste to N** (`pasteSettings()`).
- The menu commands and the canvas context menu keep their titles and call the same two methods.

## 4. Pasting

```
pasteSettings():
    guard clip, selection, !batchExporting
    targets = selectedFrames            // always contains the open frame
    for url in targets where url != selection:  pasteOffline(url)
    if targets contains selection:              pasteLive()
```

**`pasteLive`** computes `clip.applied(to: sidecar)`. If nothing changes it returns. Otherwise it runs `pushUndo()` once, assigns the sidecar, then follows the same side effects the individual setters have:

- `recomputeFilmFormat(beforeOpen: true)` when Film Effects was pasted;
- `retargetSolvedEV()` when Exposure was;
- `syncMasks()` when Masks was;
- `scheduleReopen()` if the decode changed, else `requestPrint()`;
- `markStale()`, `scheduleSave()`.

One ⌘Z restores the pre-paste sidecar. That snapshot has `placementNeedsFit == false`, so an undo never re-triggers a fit.

**`pasteOffline(url)`** loads the frame's sidecar, applies, and returns if nothing changes. Otherwise it sets `state = .stale` and saves. It also calls `renderer.store.setPrint(nil, for: url)`, because `select` shows a resident print before anything else and that print is the old look (PRD R2). It sets `frameStates[url] = .stale` for the filmstrip badge.

**`select` develops a stale frame.** A frame whose saved state is `.stale` has an edit the engine has not rendered, and that edit is a request for a develop just as a slider move is. `select` sets `wantsDevelop = true` for it. Nothing else persists `.stale` (`markStale` touches only `frameStates`), so this changes no other path. `OpenPathTests.testAnOpenStopsAtTheDecode` keeps holding for every unedited frame.

**`load` skips its two cache shortcuts when a develop is wanted.** The cached-print and display-cache hits both *end* the open at a picture. A frame that had been opened before therefore stopped at its cached decode and never developed, even with `wantsDevelop` set. The test caught this: the rule above alone did not work. The develop needs the decode anyway, so skipping the shortcuts costs nothing that would not be spent.

*Observed, not changed:* a develop requested on frame A that is still in flight when the canvas moves to B follows the newest load (`ensureDeveloped`'s loop) and develops B. It hid the defect above in the first version of the test, which switched frames within milliseconds of an edit.

### 4.1 The re-fit

`Session.resolvePendingPlacement()` (Model/Latitude.swift) runs from `applyRender`, after `scheduleLatitudeRefresh()`. It requires:

- `sidecar.placementNeedsFit`;
- `!scheduler.pending`, so the engine already has every pasted field, which the fit reads;
- a developed session;
- no placement already in flight.

It probes the Fit at the stored pull-backs:

- **valid:** the curve is applied;
- **refused, or the probe fails:** both pull-backs go to 0 and `latitude` keeps the reason, which the section already shows.

Either way the flag clears. The commit writes `sidecar.params` directly (`requestPrint`, `scheduleSave`) and deliberately does **not** push undo. The fit is the completion of the paste, not a separate edit.

## 5. The defects

### 5.1 An edit during a develop never reaches the engine

`openInService`: the open's delta is built from the sidecar before `await client.open(…)`. After the open returns, the scheduler was reset with `sidecar.params`, **the current value**:

```swift
serviceGeneration = scheduler.reset(sessionID: r.sessionID, params: sidecar.params)
```

The scheduler's `sent` therefore recorded any edit made during the open, a second or more on a large RAW, as already on the engine. The trailing `scheduler.request(sidecar.params)` ("the user may have moved a slider while the film side was running") then found no difference and sent nothing.

The interface showed the new film while the print was the old one. Choosing another film and back produced a real delta, which is the user's "再次选择胶片" observation. Pasting right after opening a frame is the most common way to land in that window, and that is how the user met it. **Any** edit in the window had the same fate.

**Fix:** reset with the params the open actually carried, `let opened = sidecar.params`, captured with the delta. The trailing `request` then sends the difference.

**Test:** `SettingsClipboardSessionTests.testAnEditDuringTheOpenReachesThePrint` makes an edit at the exact point of the race, through a test hook called between building the delta and awaiting the open (`Session.afterOpenDeltaForTesting`). It then checks the **print**: the mean luminance is compared with a control frame developed with the edit from the start. It was run against the unfixed code first and failed there.

### 5.2 The pasted Scene Placement curve

Fixed by §2.2 and §4.1: the curve is never pasted, only the intent, and the target fits its own.

**Test:** `testAPastedPlacementIsFittedOnTheTarget` pastes a placement from the 1 MP smoke frame onto a RAW. The RAW's resulting curve must equal the curve `placeSceneNow` fits on that RAW at the same pull-backs, and must differ from the source's curve.

### 5.3 A paste during a batch export

It was not gated. It is now, like `undo`.

## 6. Tests

`SpektrafilmTests/SettingsClipboardTests.swift`: pure, no engine, no fixtures.

- every stored field has exactly one owner or a `notCopied` reason;
- each group, pasted alone from a source that differs in every field, changes exactly its own paths (and `solvedEV` only under §2.2's rule);
- no groups changes nothing;
- `.asShot` does not carry the source's Kelvin; a custom white balance does;
- Scene Placement pastes the intent and never the curve, and sets the flag iff a pull-back is non-zero;
- `placementNeedsFit` round-trips through JSON, and a sidecar without it decodes to `false`.

`SpektrafilmTests/SettingsClipboardSessionTests.swift`: needs the fixtures (skips without them) and copies every frame to a temporary directory:

- the develop race (§5.1), checked on the print;
- a paste onto picked frames writes their sidecars, drops their resident print, marks them stale, and opening one develops it with the pasted film;
- one undo restores the whole paste on the open frame;
- paste is refused during a batch export;
- the re-fit (§5.2), checked against a direct fit.

## 7. Files

| File | Change |
|---|---|
| `Model/SettingsClipboard.swift` | new: the model in §2 |
| `Model/Sidecar.swift` | `placementNeedsFit` |
| `Model/Session.swift` | clipboard state, `copySettings`/`pasteSettings`, `select`'s stale rule, `load`'s cache shortcuts, the §5.1 fix and its hook, the `applyRender` call |
| `Model/Latitude.swift` | `resolvePendingPlacement` |
| `Panels/Sections/ClipboardSection.swift` | new |
| `Panels/LeftPanel.swift` | one line |
| `Localization/Strings.swift` | the section's strings, en and zh-Hans |

A concurrent crop session edited `Session.swift` around "the physical frame" (`recomputeFilmFormat`, `filmFormatMM`). This RFC calls `recomputeFilmFormat(beforeOpen:)` and `retargetSolvedEV()` but changes neither.
