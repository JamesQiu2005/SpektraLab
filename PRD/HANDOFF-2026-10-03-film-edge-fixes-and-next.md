# Handoff: Film Edge on desktop — the fixes, what the owner saw, what is next (2026-10-03)

**Start here.** Film Edge (RFC-032) and Date Back (RFC-031) are on desktop `main`, with a day of fixes
behind them. This file is the state at the end of 2026-10-03. The previous handoff,
`HANDOFF-2026-10-02-half-frame-pair-and-panoramic.md`, still holds the design, the answer sheet and the
owner's settled decisions; read that one for *why*, this one for *where things stand*.

## 1. Read first

1. `PRD/QUESTIONS-2026-10-02-half-frame-film-edge-panoramic.md` — the owner's answers. Blank = ask.
2. `PRD/HANDOFF-2026-10-02-half-frame-pair-and-panoramic.md` §3 (settled decisions) and §6 (the sync).
3. `API-SPEC-callable-render-service.md` §13 — the wire, the refusals, and the "We assumed it wrong" note.
4. `AGENTS.md` traps, `README.md`, as always.

## 2. What landed today, in order

| commit | what |
|---|---|
| `7ce3334` | the engine sync from `SpektraLab_mobile` `371ad16`, by hunks |
| `7be561b` | engine: the latitude probe switches overscan and the date off |
| `68d249a` | the app: model, session, canvas, the Film Edge and Date Back sections, en + zh-Hans |
| `17f48ed` | **engine: a film canvas reprints.** The live tier after the full one, after a print-layer rebuild, and the DI export all failed with "the negative does not match this pipeline's overscan layout". Each tier keeps the frame its negative was laid out for; `Pipeline::set_overscan_frame` before a print run |
| `7a45fae` | the date alone follows the crop, the turn and the flip: the frame is cut before the engine (`FilmParams.cutsFrame`); pitch kept, the date scaled to the picture |
| `0545ffa` | the data face needs a film edge, and the section says so |
| `544606a` | the canvas decodes the print it shows (by its stamp), not the one the settings ask for |
| `705aa7a` | engine: edge text cut to its slot; the date kept inside the frame; a frame that is not the gate's shape refused (±5 %) |
| `c2120e5` | a crop fitted at the tolerance is snapped onto the frame |
| `c9d2db9` | a film edge loaded from a sidecar holds its crop at the gate before it develops |
| `a919411` | "We assumed it wrong": every Fujifilm stock's film edge carries Kodak's marks (§5) |

Full suite at the end: 509 tests, 1 skipped, 0 failures, ~348 s with fixtures. `overscan_checks.py`: 49/49.
Parity (`parity_schema`, `parity_render`, `parity_session`) green; 18 renders with Film Edge off are
byte-identical to the engine before the sync.

**Three engine fixes were written on desktop and must cross to mobile at the next sync:** `7be561b`,
`17f48ed`, `705aa7a`. The desktop copies of `overscan_checks.py` and `parity_session.py` now send frames
of the gate's shape; the mobile copies must follow, and the mobile UI must be checked for sending an
uncropped picture (it would be refused).

## 3. The owner's observation: the app felt extremely slow — measured, and fixed

**Reported 2026-10-03 on a 16 GB MacBook (Mac18,5, Debug build); measured the same afternoon.** It was
not RAM and not a duplicated develop. It was the overscan node's CPU work running unoptimised: the
Debug build compiles every `engine/src/*.cpp` at `GCC_OPTIMIZATION_LEVEL=0` (`Tools/gen-project.py`),
and `rasterise()` in `overscan.cpp` blurred each mark group's coverage mask with two scalar loops. The
two edge-print bands are full-width boxes (8,189 × 512 px at the full tier of a 45 MP frame, σ ≈ 5 px):
95 ms each at -O2, ~1.2 s each at -O0.

Measured with `SPEKTRAFILM_NODE_TIMINGS=1` through `spk_ctypes.py`, 7831 × 5220 picture → 8189 × 7555
canvas, full tier:

| engine | wall | `filming.expose.overscan` |
|---|---|---|
| edge off, -O2 | 1,007 ms | — |
| edge on, -O2, before | 1,735 ms | 218 ms |
| edge on, **-O0** (Debug), before | **4,323 ms** | **2,745 ms** |
| edge on, -O2, after | 1,813 ms | 36 ms |
| edge on, -O0, after | 1,770 ms | 160 ms |

Every GPU node is identical between -O2 and -O0. The app log's 5.3–6.2 s full renders with the edge
on (vs 1.5–2.5 s off) match the -O0 row. Edge + date costs 10–20 ms over edge alone: the stage table
pastes the picture into the canvas once (`film_overscan`) and everything downstream runs once on it.

**The fix:** the mask blur goes through vImage (`vImageConvolve_PlanarF`, separable, edges extended),
which is optimised whatever the build setting; `Accelerate` is linked in `build.sh` and
`gen-project.py`. Against the old loops: max 1 code of 65,535 on < 0.04 % of pixels (summation
order). `overscan_checks.py` 54/54, `parity_schema`, `parity_render` (27) green.

**What is still true:** with the edge on the footprint reaches 11 GB on this frame (6.4 GB off) and
"projected peak does not fit" fires on every render — a second factor on a 16 GB machine, not the
time. The time "outside any node" also doubles at -O0 (135 → 232 ms live): host copies and the meter.
An option not taken: compiling the engine's C++ at -O2 in Debug (one line in `gen-project.py`), which
would make the Debug app perform like Release — the owner's call.

**Log trap:** the `develop` record's `frame_ms` (`Session.LoadClock`) laps from the *previous lap* and
the clock lives across re-develops of one frame, so a second develop reports idle time (40–48 s in the
12:33 log) and `total_ms` is cumulative. Only the `render` records' `ms` are per-event truth.

## 4. Still open from the bug hunt

- **Metering under a cut.** With the date on over a cropped picture the engine meters the crop, so auto
  exposure can shift when the date goes on. Needs a meter input the engine does not have. Not measured.
- **Compare, Space-original and the white-balance picker are off** while the canvas shows a cut print
  (film edge, or the date under a crop/turn/flip): the engine cannot yet say where the picture sits
  (`spk_overscan_geometry`). The histogram counts the rebate.
- **Slide films:** the film edge draws the marks as exposure through the reversal curves (black rebate,
  light marks), and the app always scans a positive. Unverified against a real E-6 strip: the edge
  print's colour (olive-yellow in the render) and the date's (dim yellow-grey; a real one is orange-red).

## 5. We assumed it wrong — every Fujifilm stock's film edge (done 2026-10-03, `4fbbe96`, `653fe52`)

The owner, 2026-10-03: the Fujifilm stocks' film edges were copied straight from Kodak. The owner then
supplied 16 scans in `reference_film/` (135: RVP50, RDPIII, X-Tra 400, C200, Portra 160/800, UltraMax,
Gold 200, 5207; 120: RVP50 6x6, Pro 400H 6x7, RDPIII 645, E100/Portra 400/Ektar 6x6, Gold/Portra 160 6x7;
**untracked**, the owner's to commit or not). Measured as RFC-032 §29.2 measured Kodak (px/mm from the
4.75 mm perforation pitch, or the 61 mm film), and the edge is now the stock's own (`kEdgeLooks`,
`overscan.cpp`):

| stock | layout now | reference |
|---|---|---|
| Provia 100F | Fujifilm slide: no DX bars, 5x7 face, bold numbers (caps 1.64) on both edges, name 16 mm on, "36 ▷12A"; 120: Fujifilm 120 | RDPIII 135 + 645 |
| Velvia 100 | the same; host text "RVP100" | **RVP50** only (borrowed) |
| X-Tra 400 | Fujifilm negative: 14.1 mm DX (628), condensed numbers on both edges, "S-400" | X-Tra 400 135 |
| Pro 400H | 120: one edge, "FUJI"/roll no., "13 ◀", "PRO400H", "EFCDCD"; **135 borrows X-Tra's** | 120 6x7 only |
| C200 | Kodak's layout (it is Kodak-made: DX part 1 = Gold's), regular weight, "FUJI 200", DX 1550 | C200 135 |
| Vision3 | one "EASTMAN 52xx" line + dashes, no numbers/bars; the line's period is ≥41.5 mm, 76 assumed | 5207 135 (others borrow) |
| Kodak negatives | fixed: DX 12.7 mm (was 13), sizes/positions, wide numerals, tan colour (was olive), DX numbers read off the strips (Gold 1548, Portra 160 1534) | 4 × 135, 5 × 120 |
| E100 | white marks (was olive); 135 layout still Kodak's, **unverified** | E100 120 only |

Also: the 135 gate is 36.25 × 24.3 mm (measured mean; it sat 0.70 mm from the perforations, real ones
0.47–0.67), and a 120 gate is centred ±0.45 mm (was ±0.1). Not reproduced, on purpose: the red/green lines
on the X-Tra strip (its camera's), the X-Tra "H74" batch code, Kodak's "KO.DAK" dot, emulsion suffixes
("-7"), and real roll numbers. Colours match the references' hue, not their level (scan-dependent).
Comparison sheets (reference | before | after): the session scratchpad `edge/cmp_*.png`.

**Must cross to mobile at the next sync:** `4fbbe96` (by hunks) and the matching `overscan_checks.py`
hunks. Mobile's host text is display names, so it does not take `653fe52`. API-SPEC §13 needs the edit
listed in that commit's report (36 → 36.25 gate, per-stock edges, the DX numbers); not edited here.

**Later the same day (owner's review of the sheets):** `3a26463` Pro 400H's marker is a stepped tack
(2.09 mm, base 1.17 → 0.9 → 0.55 → 0.25 needle), not a triangle; `1b263d3` the Kodak 120 name is
centred between the numbers (it sat a fixed 10.8 mm on) and 135 prints the suffix where a strip shows it
("KODAK GB 200-7", "KODAK PORTRA 800-3"); `61bfc49` the widened bold numerals are tracked apart (0.30 mm
on 120, 0.25 on 135) — before, every two-digit number developed into one shape ("38"). `2108544` +
the app commit after it: **`overscan_frame_number`** (int 0..99, SHOOT, native-only, after
`antihalation_removed` in both tables; 0 = the seed's draw) — the frame's own mark on every layout that
numbers frames; the app's `filmEdge.frameNumber`, a "Frame no." slider (Auto at 0), defaulting to the
frame's place in the session at first seeding. Kodak 120's counting-edge numbers stay seeded. API-SPEC
§13 needs the field added (not edited). Still open: the 135 name can land across the frame edge in some
camera phases while all five strips have it inside; and the mobile sync of all of the above.

**Evening:** `4a9ea54` a properly behaved camera -- the 135 phase is pinned so the edge print falls
inside the frame (Kodak and X-Tra: "NA" mid, "N" at the right end, name 6 mm in; the slides: "N" at the
left end; Velvia's strip was loaded half a frame off and is not followed). `004b5d7` API-SPEC §13 is
kept and owned by whoever changes the wire (the "belongs to nobody" rule is gone), and carries today's
changes. **Mobile sync:** branch `sync/film-edge-2026-10-03` (34e54d6) on `SpektraLab_mobile`, a
three-way merge against the 7ce3334 sync point onto mobile `52e5967` -- not merged to mobile `main`
because the mobile checkout at `SpektraLab_mobile/` holds an unfinished merge (`UU pipeline.cpp`, 19
staged files: DI, printing, hanatos) that is someone else's. The branch builds, `overscan_checks` 63/63,
`mobile_checks` 0 failures (it now sends gate-shaped frames), `parity_schema` green; not run on a device.
Not taken on mobile: the vImage blur (mobile's softness is on the GPU, `c715d5c`) and the halation switch
`9fa3b0d`. Mobile `API-SPEC.md` §15 still needs §13's text. The worktree is `SpektraLab_mobile-sync/`.

## 6. Waiting on the mobile-first engine work (answer A3)

`spk_overscan_geometry`; `overscan_turn`; holes as a print-layer field; the carrier enum; the data face's
two colours (E12); the panoramic formats and the canvas-trim fix (C2); perforations in a Digital
Intermediate; the Frame / + Overscan scope (B4); then the half-frame pair's E1/E2. The `SpektraLab_mobile`
tree was mid-merge all day (`UU engine/src/pipeline/pipeline.cpp`); nothing here touched it.

## 7. Open with the owner

B17 (turned pairs); E3's "No"; the clipboard group for Film Edge and Date Back (F10); whether cine stocks
belong in the 135 formats (allowed now); the UI placeholder note for Fujifilm edges (§5).

## 8. Next, in the owner's order

The slowness is measured and fixed (§3); the Fujifilm edge layouts are done (§5). Next the
half-frame pair without Film Edge (HFP P1–P4, Swift only), which needs none of §6.

## 9. Late 2026-10-03: panoramic, the pair's engine, the pair in the app (first stage)

The owner moved the engine work to desktop (A3 no longer holds: write here, carry to the mobile sync branch).

| commit | what |
|---|---|
| `122c5fb` | panoramic: `135_xpan`, `120_6x12`, `120_6x17`; the canvas reaches 0.40 mm past the film (`overscan_carrier` black \| open); tilt capped by end travel; leaks per length. Every strip render changed. C11 measured: no banding at 21 µm a pixel |
| `4767b48` | engine: `overscan_pair`, `date_imprint_text_b`, `spk_overscan_geometry` |
| (this one) | the half-frame pair in the app, stage one |

**How the pair is built (it differs from proposal §6a).** A pair is a file (`….spektrapair`, in `Sidecars/Pairs/`) whose URL is a filmstrip item, and whose *decode* is both pictures on one piece of film (`PairComposer`, Core Image). So the engine, canvas, thumbnail, caches and export handle it as one frame, with and without Film Edge: without, the gap is black input and develops to the stock's base; with, it is `overscan_pair`. The proposal's "two renders and a Metal compositor" was not built: the app holds one decode and one engine session at a time.

**What a pair has today:** ⌘J / the filmstrip menu (picked frames fill the holes in filmstrip order), the Half-Frame Pair section (Film / Left hole / Right hole; Add, Replace, Remove, Swap, Open Frame Alone; per-hole Exposure, Scale, Across, Up/down, Turn; Spacing 0.5–2.0 mm), per-hole metering (the engine's meter is exactly a gain on the input, so each hole is metered alone once and the strip develops with the meter off), Film Edge on a pair (one strip, a date per frame), export as one image (refused with an empty hole). `HalfFramePairTests` (8).

**Not built, against the proposal and the answers:**
- Per-hole print and the exposure scope (B1–B3: Frame / + Overscan). The enlarger, paper and effects are the piece's. `spk_overscan_geometry` is there for the per-region reprints.
- Per-hole Post-Dev, masks and Scene Placement (shared).
- The hole's Film Exposure is a plain gain owned by the pair, not the frame's re-timed Film Exposure (B5). White balance and lens correction are the frame's.
- Placement by dragging on the canvas, picking a layer by clicking the canvas, the Add Frame overlay on an empty hole, drag from the filmstrip.
- Undo for the piece's own edits (holes, placement, spacing, exposure). Look edits undo as usual.
- Export *Two halves / Both*; turned pairs (B17 = later); date back on a pair without Film Edge.
- A moved frame is not re-found (the hole reads "Missing").
- Seen in the running app without Film Edge (two NEFs, 83 MP piece). Film Edge on a pair was seen as an engine render and asserted through a session, not in the window.

## 10. Night of 2026-10-03: the pair's UX redone after the owner's review

The owner's verdict on §9's stage one: "it works, with terrible bug, and the UX is shit". Their brief, and what was built for it:

| asked | built |
|---|---|
| the clock counted forever after entering a pair, engine idle | two develops overlapped (Film Edge switched on in a pair asked for one from the `params` setter and one from the pair's own write); each saved and restored `busy`, and the second restore left it set. `openInService` now counts its calls, and the pair's write no longer asks twice. `testOverlappingDevelopsLeaveTheSessionIdle` hangs on the old code |
| the way in under **Half** | *Enter Half-Frame Pair* under Format in Film Edge while it reads Half: the frame becomes the first hole (its half-frame crop becomes its placement), the look and the film edge carry over, the second hole is empty |
| the canvas shows two holes, **both orientations**, a **+** on the empty one | held level (side by side) and turned (stacked): `HalfFramePair.turned`, the engine renders a turned pair, a landscape first frame turns the camera. `PairOverlay` draws the + and the picked hole's frame (on the engine's own gates when the strip is on) |
| right-click a frame to switch it or crop it | a click picks the hole under it; a right click opens that hole's menu: Replace / Add, Crop This Frame, Turn Picture, Reset Crop, Remove, Open Frame Alone, Swap, Level / Turned |
| crop over that frame | the crop tool (button, C) on a pair is the picked frame's crop: drag moves the picture under the fixed hole, scroll scales it, Return / Esc / Done leaves. Committed on release; no live preview while dragging |
| the Navigator | shows the whole piece, strip included; the pair's thumbnail is rebuilt on every change |
| the tool under the Navigator | moved; it holds Camera (Level / Turned), Spacing, Swap, and the picked frame's Exposure and crop numbers |

Also: the piece is capped at one frame's worth of pixels (two 45 MP frames made an 83 MP piece, 127 MP with its edge; now 44 MP), which is what the "low headroom" and the long full renders came from.

Seen in the running app: held level with an empty hole, and turned with Film Edge on (two NEFs). Not seen: the *Enter Half-Frame Pair* row itself, the menu, the crop drag (all exercised through the session in `HalfFramePairTests`, 12 cases). Later the same night: ⌘Z undoes the piece's own edits (a frame added, removed or swapped is a step of its own; a slider drag is one step), a filmstrip thumbnail dragged onto the canvas goes into the hole under it, and the crop drag shows the frame's preview where the drag has it. None of the three was seen in the window; each is exercised through the session in `HalfFramePairTests`.

Still open from §9: per-hole print and scope, per-hole Post-Dev, Two halves / Both.

## 11. 2026-10-04: each frame of a pair is its own

The owner's four, with *Two halves* export dropped by them ("if someone wants to export single ones they would not pair them in the beginning"):

| asked | how |
|---|---|
| per-frame print, and the Frame / + Film scope (B1–B3) | one negative printed up to three times (`EngineClient.renderLayers`, one actor call so no render sees the settings in between), graded, and cut along the frames' rectangles (`Renderer.compositePair`; the engine's gates on a strip). The Enlarger shows the picked frame's value; *Applies to: Frame / + Film* (仅画面 / 含片基) — + Film moves the film's print by the same delta. The Enlarger starts on + Film, the frame's Exposure on Frame. Until a frame is given a print of its own the piece prints as one |
| per-frame Post-Dev | `Hole.adjustments`; the Post-Dev rail edits `Session.layerAdjustments`. A pair's grade is baked into the picture it composes, so the canvas and the export apply none of their own |
| per-frame Scene Placement | engine: `scene_latitude_split` + `scene_latitude_b_*`, and `region` on the Fit. App: `params.sceneLatitude` is always the picked frame's and `sceneLatitudeOther` the other's; picking a frame trades them (`placementIsRight`), which changes nothing on the wire |
| date back with no film edge | engine: `overscan_pair` with the film edge off draws each frame's own date in its own corner |

Seen in the running app: the right frame with a print of its own (+1.5 stops, yellow) beside an untouched left frame, on the strip with two dates and with no film edge. A date over a white part of the picture does not show (the film is saturated there), which is the engine's own behaviour on a frame too.

Not seen in the window: the scope switch being used, a frame's own grade, a frame's own Scene Placement (each is asserted through the session and the engine in `HalfFramePairTests` and `overscan_checks.py`).

Open: roll-off, lift bound and norm are shared by a pair's two placements; the three prints of a full-tier pair cost three reprints; mobile has none of this.

## 12. 2026-10-04, after the owner's second review: speed, the frame's own turn, the rail on a pair

The owner's words: the UX is bad and the app is slow on entering the mode; a frame rotated before pairing came into the pair unrotated; Film Format vanishing on a pair is nonsense — the rail should act on whichever half is picked.

| what | how |
|---|---|
| slow | Every change to a pair re-rendered both RAWs (2–4 s in the owner's log). Each hole is now rendered once and kept (`PairComposer.rendered`, keyed on file, decode, geometry, placement, size); the display is the files' embedded previews; a piece whose frames print alike is one print and is not cut together on the main thread (`pairIsLayered`). |
| the frame's turn | `Hole.geometry`, read from the frame's own sidecar every time the pair is opened, applied before the placement. |
| the rail | Input / Camera and Film Format are back on a pair. Meter, Film Exposure (with its Frame / + Film scope), white balance and lens correction are the picked frame's (`focusSide`); white balance is written to the frame's own sidecar. Film Format describes one frame (24 × 18): a new pair gets Custom / long / 24, and an older pair still at the stock 135 is moved to it on open (it read as a 49 mm piece). |

Measured, two 45 MP NEFs, Debug build, this Mac (M-series, 17 GB): the pair's decode step 1.36 s first, 0.26 s again, 0.26 s after a spacing change, 0.53 s after one picture is moved, 0.60 s after the camera is turned (both holes again). Whole open in the app's own log: 1.4–1.7 s, against 1.56 s for one of those NEFs opened by itself. Not measured on the owner's 16 GB MacBook, and not in a Release build.

Seen in the running app (snapshot): a turned frame in its hole turned; Input / Camera titled with the picked frame and carrying that frame's white balance; Film Format on a bare pair and "set by the film edge" on a strip.

A harness defect found on the way: in a snapshot run the scene's own window hosted a second canvas stand-in on the same renderer, and whichever appeared last took the redraw callback and the viewport. When the scene's won, the capture was a blank canvas at the wrong zoom — it looked exactly like a broken pair. Only the capture's window draws now (`snapshotCapture`).

Not seen in the window, still: the Enter row, the right-click menu, the crop drag, the scope switch, a frame's own grade and Scene Placement. Grain scale is the piece's, not each half's. Mobile has none of this.

Another session commits in this checkout at the same time (the Fujifilm 120 edge fixes landed mid-run): never `git stash` here — it takes the other session's uncommitted files with it.

## 13. 2026-10-04: scroll to scale, the last thing before 1.3.0

The owner: everything else is good enough to ship; 滚动缩放 is "largely unavailable with some terrible bug".

What was wrong: every notch of the wheel wrote the pair file, pushed an undo step and queued a develop, with nothing shown until the develop landed; the zoom was about the cut's middle with `x`/`y` held, so the picture slid as it scaled; the wheel worked only with the pointer on the hole and panned the canvas otherwise; and a zoom shrank the piece's own pixel size, so the canvas refitted and the other frame rendered again.

Now: a scroll, a pinch or a slider drag is one gesture (`PairDrag`, `placementZoomed`, `previewPlacement`) — shown at once from the frame's framed preview (`PairComposer.framedPreview`, any turn, the frame's own geometry), written once when it rests (one undo step, one save, one develop), and its picture stays on the hole until that develop lands. The zoom holds the point under the pointer (`Session.placement(_:zoomedBy:about:…)`). In the crop mode every scroll is the zoom. The piece's size is the frames' fit at scale 1 whatever the zoom.

Seen (snapshot, `--pair-zoom f s`): the gesture's picture and the develop that follows are the same crop. Not driven by hand: a real wheel or trackpad in the window — the direction and the rate (the canvas's own, 1.0025 per point) are the owner's to judge.
