# Task B — frontend layout: top bar, traffic lights, collapse tabs, filmstrip, canvas jitter

You are one of three sessions working this repo tonight, in **one shared
working tree**. Read the ownership section before you touch anything.

## Read first, in this order

1. `CLAUDE.md` (repo root) — the short version and the traps.
2. `AGENTS.md` — working rules, and "REGENERATE after adding/removing any
   source file".
3. `PRD/frontend_behavior_improvement.md` — the user's own words. **Your
   items are §1, §2, §5 and §6 only** (traffic light / top bar, the
   collapsing control button, the filmstrip white dot, the canvas jitter).
4. `README.md` build/test section.

Reference images, all under `PRD/`:
- `frontend_bug/traffic_light_overlay.png` — the bug.
- `new_frontend_top_layout.png` — **the target top bar. This drawing is
  authoritative for the layout.**

## The four items

### 1. The top bar, and the traffic lights (PRD §1)

The bug: the traffic lights sit at a fixed position and collide with content.
Today `Windows/TrafficLights.swift` reparents the three standard window
buttons onto the **left panel's** header centreline
(`Theme.Metric.trafficLightCentreY` / `trafficLightLeading`), and
`Theme.Metric.panelHeaderLeading` is a derived number that exists only to
push the left panel's import glyph clear of them. That coupling is the
problem — and it breaks outright when the left panel is collapsed.

The user's proposed fix, which you should implement:

- **The top bar becomes full width and non-collapsible.** It spans the whole
  window, above the left panel, the canvas and the right panel — it "hosts
  everything anyway". In `Windows/EditorWindow.swift` this means the top bar
  moves out of the centre `VStack` and becomes the first row of an outer
  `VStack`, with the three-card `HStack` below it.
- **The traffic lights live on the top bar's centreline**, at its leading
  edge, and the bar's own content starts after them. Since the bar is now
  always present and always full width, the lights always have a home.
- **The top bar can no longer be collapsed.** Remove its collapse tab
  (the `.overlay(alignment: .top) { CollapseTab(...) }` in `CanvasArea`).
  `Session.topCollapsed` is **not yours to delete** — leave the stored
  property alone and simply stop reading it in the view layer. I will clean
  up the dead state at integration.
- **`Theme.Metric.panelHeaderLeading` reverts to the drawing's 12 pt**, since
  the left panel header no longer has to dodge the buttons. Say so in a
  comment — that file's rule is that every number is traceable.

Bar contents, per `new_frontend_top_layout.png`, left to right:

    ● ● ●   [tools…]   [status text]   ←drag surface→   [before/after]
    [zoom in] [100 % pill] [zoom out] [expand]

Two changes from today's `Windows/TopBar.swift`:

- **One expand button, not two.** Today there is a separate "Fit"
  (`arrow.down.right.and.arrow.up.left`) and "Full screen"
  (`arrow.up.left.and.arrow.down.right`). The drawing shows a single
  diagonal-arrows glyph. Make it one button that both expands and shrinks —
  i.e. it toggles fullscreen and its glyph reflects the current state. Fit
  stays reachable from the View menu and from the zoom pill's own menu, so
  nothing is lost.
- **Zoom in / zoom out ordering.** The user wrote "the zoom in and zoom out
  has switched position". Note for your report: the current code is already
  `zoom-in · pill · zoom-out`, which is what the drawing shows, so I read
  this as "no change needed, the drawing is the target". **Match the drawing
  and flag this in your report** rather than inverting it on a guess — if the
  running app disagrees with the source I read, say so.

Traffic lights are drawn by the window server and are **invisible to the
offscreen snapshot harness** (`Tools/snapshot.sh`). `Tools/capture-live.sh`
is the only check that can see them. Use it. The comment block at the top of
`Windows/TrafficLights.swift` documents several traps that cost real
debugging time — AppKit reclaiming the buttons, the theme-frame reparenting,
the non-key-window capture. Read it before changing that file; the
reparenting machinery should survive, only the target centreline changes.

### 2. The collapse control becomes hover-revealed (PRD §2)

Today `Windows/CollapseTab.swift` tabs are always visible on the canvas
edges. The user wants them **hidden by default, appearing when the mouse
comes near where they are** — and, critically, **still appearing on hover
after the panel has collapsed**, so a collapsed panel can be brought back.

Implement with an `onContinuousHover` (or an `NSTrackingArea` if SwiftUI's
hover proves unreliable at the card seam) over a generous strip along each
canvas edge — the strip is the hover target, the tab is what fades in. Fade,
do not pop; the rest of this interface animates at `.easeOut(duration: 0.18)`
and this should match. The hit region must stay live when the neighbouring
panel is collapsed, which is the case that is easy to get wrong.

The top edge's tab is removed entirely (item 1). Leading, trailing and bottom
get the hover behaviour.

### 3. No status dot on the selected thumbnail (PRD §5)

`Panels/Filmstrip.swift` draws a white selection frame **and** a three-state
badge bottom-right (filled circle = processed, stroked = stale). The user:
"只需要有外围的白框代表被选定就行了，不需要其它的" — the outer white frame
is enough to say "selected", nothing else is wanted.

Scope it as the heading says: **for the selected thumbnail**, draw the frame
only and no badge. Unselected thumbnails keep their badge, which is carrying
real information (processed / stale) that nothing else shows. Flag in your
report if you think the user meant to remove the badge everywhere.

### 4. The canvas twitches on layout change (PRD §6)

"显示的图像…在延展/收缩两侧control的时候，还有改变app窗口大小的时候都会抽动" —
the displayed image jitters both when the side panels animate open/closed and
when the window is resized.

This is a real bug and the most valuable item on your list; budget for it.
Where to look:

- `Canvas/MetalCanvasView.swift` and `Canvas/ViewportState.swift` — the
  viewport is resized from a SwiftUI layout pass, and the panel collapse is
  an **animation**, so the canvas gets a stream of intermediate sizes. If a
  fit-scale or a centring offset is recomputed per intermediate size and the
  drawable is resized on a different schedule than the layout, the picture
  will walk.
- `Canvas/Renderer.swift` — `fitRotatedPhoto` and the zoom/fit arithmetic.
- Check the `CAMetalLayer`'s `drawableSize` vs the view's bounds ×
  `backingScale`, and whether the layer has implicit CoreAnimation actions
  running during the resize (`layer.actions = ["bounds": NSNull(), ...]` and
  `autoresizingMask` / `needsDisplayOnBoundsChange` are the usual culprits on
  macOS — an implicit bounds animation on the layer fights the SwiftUI
  animation and that reads exactly as a twitch).

**Diagnose before you fix.** Say in your report what the mechanism actually
was; a fix with no mechanism behind it is the thing this repo's memory keeps
warning about. `ViewportStateTests` and `CanvasViewTests` exist — extend
them, and make any new assertion **fail on the unfixed code first** so we
know it can fire.

## Ownership — do not edit files outside this list

Yours:
- `modern_UI/Spektrafilm/Spektrafilm/Windows/TopBar.swift`
- `modern_UI/Spektrafilm/Spektrafilm/Windows/TrafficLights.swift`
- `modern_UI/Spektrafilm/Spektrafilm/Windows/EditorWindow.swift`
- `modern_UI/Spektrafilm/Spektrafilm/Windows/CollapseTab.swift`
- `modern_UI/Spektrafilm/Spektrafilm/Panels/Filmstrip.swift`
- `modern_UI/Spektrafilm/Spektrafilm/Canvas/MetalCanvasView.swift`
- `modern_UI/Spektrafilm/Spektrafilm/Canvas/ViewportState.swift`
- `modern_UI/Spektrafilm/Spektrafilm/Canvas/Renderer.swift`
- `modern_UI/Spektrafilm/Spektrafilm/Theme/Theme.swift`
- `modern_UI/Spektrafilm/SpektrafilmTests/ViewportStateTests.swift`,
  `CanvasViewTests.swift`, `LayoutTests.swift`

Owned by someone else — **do not edit, even trivially**:
- `Model/Session.swift`, `Service/*`, `Export/Exporter.swift`,
  **NEW** `Diagnostics/*` (session A)
- `Model/Geometry.swift`, `Panels/Sections/CropSection.swift`,
  `Canvas/CropOverlay.swift`, `Export/ExportSheet.swift`,
  `SpektrafilmApp.swift` (me)

`SpektrafilmApp.swift` is mine, and item 1 probably wants a change there (the
View menu's "Toggle Side Panels", and the removal of a top-bar toggle).
**Do not edit it.** Tell me the exact change you want in your report and I
will make it.

If you believe you must touch a file outside your list, stop and message me
(`filmify-40`) instead of editing it.

## Build, test, and look at it

```bash
cd modern_UI/Spektrafilm
python3 Tools/gen-project.py     # REQUIRED after adding any new source file
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
           -derivedDataPath build/DerivedData build
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests \
           -derivedDataPath build/DerivedData test
```

The baseline as of the start of your work **builds clean** — I verified it.
So a build failure is something one of us introduced.

`engine/build.sh bundle` has already been run; `engine/resources/` is current
and **nothing under `engine/` is yours to change.**

This is visual work and it must be looked at, not just compiled:

- `Tools/snapshot.sh` — offscreen captures at three window sizes. Sees the
  cards, the tabs and the filmstrip. **Cannot see the traffic lights.**
- `Tools/capture-live.sh` — photographs a real window. The **only** check for
  item 1. Note the trap already documented in `TrafficLights.swift`: it
  captures a window that is *not key*, and AppKit reclaims the buttons on
  `didResignKey` — which is precisely why an earlier version measured correct
  in a log and captured wrong.
- `Tools/compare-layout.py` — measures the built interface against the
  drawing. Item 1 moves a card, so expect this to need its expectations
  updated; update them deliberately and say what you changed and why.

Attach or reference your captures in your report. For the jitter (item 4), a
still cannot show a twitch — describe how you verified it, and if you can,
capture during a resize.

Two sessions share this tree. `Tools/gen-project.py` regenerates
`project.pbxproj` from the filesystem, so running it also picks up the other
session's new files — expected and fine. If a build fails in a file you do
not own, do not fix it: report it to me.

## Reporting

Message `filmify-40` (me) when:
- item 1 builds and captures clean — a checkpoint, since it is the one that
  moves a card and I want to see it early;
- you are blocked, or need a file you do not own;
- you are done.

In the final report: what the jitter's mechanism actually was, the
`SpektrafilmApp.swift` changes you want from me, the `compare-layout.py`
expectation changes, the two flags requested above (zoom ordering, filmstrip
badge scope), and anything you could not do and why.
