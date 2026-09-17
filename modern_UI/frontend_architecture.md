# Frontend architecture — Spektrafilm Desktop

| | |
|---|---|
| **What this is** | The record of what the interface *is*: its geometry, its tokens, its view tree, and how a pixel gets from a RAW file to the canvas. |
| **What it is not** | A task list. Open work is in `../HANDOFF-FRONTEND-POLISH.md` and `../HANDOFF-MASKS.md`; how to build and test is in `Spektrafilm/README.md`. |
| **Authority** | The drawing, `reference_layout/Main/sample_frontend.svg` (2026-09-17). Where this document and the drawing disagree, the drawing wins and this document is stale. Its tokens are derived one by one in `design/TOKENS-main-2026-09-17.md`. |
| **Date** | 2026-09-17 |

---

## 1. The window

Three flush regions, separated by a **1 pt hairline**. Nothing is nested
inside anything else and nothing floats except the tool bar, which is why the
layout survives every window size: the two rails have a width the user picks
inside a range, and the centre column absorbs the remainder.

```
 ┌───────────────────────────── 1920 × 1080 pt ──────────────────────────────┐
 │ ┌──────────┬────────────────────────────────────────┬──────────────────┐  │
 │ │ header 38│           ▁▁▁▁ bar 31 ▁▁▁▁             │ header 38        │  │
 │ ├──────────┤                                        ├──────────────────┤  │
 │ │   left   │                                        │      right       │  │
 │ │   rail   │                 canvas                 │      rail        │  │
 │ │   254    │            (fills the rest)            │      288         │  │
 │ │          ├────────────────────────────────────────┤                  │  │
 │ │          │             filmstrip 132              │                  │  │
 │ └──────────┴────────────────────────────────────────┴──────────────────┘  │
 └───────────────────────────────────────────────────────────────────────────┘
```

Every number is the SVG's, divided by two — the drawing is a 3840 × 2160
canvas, which is this window at 2×.

| region | SVG rect (x, y, w, h) | points |
|---|---|---|
| left rail | −2.6, 0.6, 509.9 × 2160 | x 0, **254 × full height** |
| right rail | 3263.9, 0, 576.1 × 2160 | x 1632, **288 × full height** |
| filmstrip | 507.4, 1895.3, 2756.5 × 264.7 | y 948, **132 tall**, centre column only |
| tool bar | 529, 9.4, 2721 × 61.8, `rx 28` | y 5, **31 tall**, r 14, inset 9 either side |

**No outer margin, no gutter, no card radius.** A region flush with the
window's edge has nothing to be inset by, so `outerX`, `outerY` and `gutter`
are not tokens any more; `cardRadius` survives only because the export page
still draws rounded cards with it.

`swift Spektrafilm/Tools/measure-layout.swift design/snapshots/window-16x9.png 2`
measures a capture against this table. The checked-in captures are **exact**
at all three display shapes.

### Behaviour of the frame

- **The hairline is only where two surfaces of the same colour meet.** The
  drawing puts none between a rail and the canvas — the ground colour already
  separates them — and two beside the filmstrip, where rail and strip are both
  `Theme.card`. A rule with an inset reads as a list separator; these run edge
  to edge, and read as a wall.
- **The bar floats, and belongs to the centre column.** It is a rounded pill on
  the ground over the canvas, so it is as wide as the picture is. The column
  reserves its strip (`barStrip` = 41), which is the drawing and is also the
  only arrangement in which a maximised frame is never partly under a toolbar.
- **The rails are the user's**, between bounds (`PanelResize.swift`): left
  232…380, right 268…364, each standard at the drawing's own width, so a fresh
  install measures the drawing. Snapshot mode holds both at `standard` — a rail
  dragged wide in an earlier session used to be what every capture measured.
- **The window buttons sit on the rail header's row**, `y 0…38`, centre 19,
  leading 20. That row is also where the bar's centre falls (20.5), which is
  why folding the left rail does not move them: one centreline serves both,
  and all that changes is which view reserves the space
  (`trafficLightClearance` in the header, `barLeadingWithButtons` on the bar).
  The window server draws the buttons, so no offscreen capture can see this
  row — `Tools/capture-live.sh` is the check.
- **Folding is the two `sidebar` buttons**, one at the far end of each rail's
  header, and each moves onto the bar when its rail folds — the PRD requires
  both to be on screen at every moment. `Tools/snapshot.sh` takes a fourth
  capture, `--folded both`, which is the only way to see that. The hover tabs
  on the canvas's vertical edges are gone with them; the **bottom** one is
  unchanged. `⌘\` folds both rails; `⇧⌘F` the filmstrip.
- **Minimum window 1100 × 700**, which leaves the canvas 558 pt wide.
- Collapse state persists under `ui2.`-prefixed `UserDefaults` keys. The
  prefix is load-bearing: the previous version of this app shipped under the
  same bundle identifier and its leftover `leftCollapsed`, `filmstripCollapsed`,
  `dock.*` and `panel.*` values opened this one with everything folded away.

---

## 2. Tokens

All of them live in `Theme/Theme.swift`, each quoting the SVG value it came
from. No view file carries a literal colour or metric that could have come
from there — that is what keeps the interface matching the drawing when one
number moves.

The palette got *smaller* with the 2026-09-17 drawing: one grey does the work
four tokens used to. A control is a lighter shape on a darker rail —
elevation, not hue — and the hairline does what a gutter used to.

| role | value | from |
|---|---|---|
| ground — canvas surround **and** every well, pill and slider track | `#5F5F5F` | `.st13` |
| card — the two rails and the filmstrip | `#2C2D2B` | `.st15` |
| rule — the 1 pt hairline | `#B5B5B6` | `.st1` stroke |
| text and glyphs | `#FAF8F4` | `.st12` |
| knob | `#FBF8F3` | `.st18` |
| dim (captions) | `#898989` | — |
| plot ground / grid | `#1E1F1E` / `#3A3B39` | — |
| accent | `#ECA650` | `.st17` / `.st3` / `.st2` |
| selection — a band, with its text inverted | `#C9CACA` / `#0E0E0E` | `.st16` |

**Selection in a list is a band, not a frame**: the full width of the well,
one row tall, with the row's text turning from white to black. The filmstrip
keeps the white frame, because a light band behind a photograph is not a mark
you can see.

There are exactly **two wells** in the whole interface — the film list and the
print list — and a well now holds a *choice from a set*, not a group of
controls. Everything else sits directly on a rail. That is also what makes the
sliders legible: a track is the ground colour at 1.5 pt, and a ground-coloured
track on a ground-coloured well is not a track at all.

The type ramp is 12 pt bold for section titles, 10.5 pt semibold for labels
and list rows, 10.5 pt monospaced-digit values, 9 pt sublabels and captions,
11.5 pt for the two actions under the print list. Everything is semibold or
heavier: the drawing sets every string in a bold face, and at 10.5 pt on a
dark ground a regular weight disappears.

A control that cannot be used is greyed **as a row** — label and pill together
— through `View.rowEnabled(_:)`. The PRD makes that one rule for the whole
app, and a rule spelled once cannot be applied to half of a row.

The only colour in the interface besides the accent is the filter-pack and
white-balance slider tracks, which take the drawing's own gradient stops.

---

## 3. View tree

```
SpektrafilmApp                      one Window scene, one Session, dark forced
└── EditorWindow                    Browse or Print, drag-and-drop, export sheet
    ├── BrowseView                  the Browse state: grid, breadcrumb, sort
    ├── LeftPanel                   the darkroom rail
    │   ├── header                  ⟨window buttons⟩ · import · export · sidebar.left
    │   ├── CameraSection           AE Method · Film Exposure · Temperature · Tint
    │   │                           Vignetting · Lens Correction
    │   ├── FilmSection             film list · Film Type · Side · Side Length
    │   │                           Grain · Halation · Glare
    │   ├── PrintProfileSection     papers grouped Still / Cine / Positive
    │   │                           Process · Original
    │   ├── CropSection             Aspect · Straighten · Rotate
    │   └── EnlargerSection         Brightness · Yellow · Magenta  (not drawn; kept)
    ├── CanvasArea
    │   ├── MetalCanvasView         MTKView (SnapshotCanvas in capture mode)
    │   └── HoverEdgeTab            the filmstrip's, and only that one
    ├── TopBar                      select · hand · crop · status · before/after
    │                               zoom · full screen  (+ a folded rail's sidebar)
    ├── Filmstrip                   thumbnails, selection frame
    └── RightPanel                  the grade rail
        ├── header                  adjustments · bypass · sidebar.right
        ├── HistogramSection        live RGB + luma, EXIF caption
        ├── WhiteBalanceSection     Temp. · Tint  (post-print)
        ├── ExposureSection         Exposure · Contrast · Brightness · Saturation
        │                           Highlights · Shadows · Black · White
        ├── CurveSection            5 channels, histogram behind, draggable points
        └── ColorBalanceSection     Master / 3-Way wheels
```

A section is one file in `Panels/Sections/`, added or removed by one line in
its rail, followed by a `Hairline()`. Sections never reference each other;
anything two of them must agree on lives in `Session`. What is **not** safe to
drop when a rail is rebuilt is the short list in `Spektrafilm/README.md` §8.1
— contracts that fail silently.

### The two layers

The panel a control sits in *is* its layer, and that is the whole rule.

- **Left — Layer 1**, the engine. Every control maps to one `params_delta`
  field in `Model/Params.swift`, which mirrors `service/schema.py` and knows
  each field's layer. A shoot-layer change re-runs the film side; a print-layer
  change reprints from the cached negative.
- **Right — Layer 2**, the client. `Model/Adjustments.swift`, applied in the
  `layer2` compute kernel in under a millisecond, reaching no service at all.
  The bypass switch in the right header shows the pure simulation.

**Masks are in the right panel**, and that is a reversal of
`../HANDOFF-MASKS.md` §3.1, which argued for the left. That argument followed
from the dodge-and-burn model — a mask was a value in stops, whose correct
application point is the enlarger, which is Layer 1. The user rejected that
model in favour of Lightroom's, where a mask carries a *set of adjustments*.
That makes masking Layer 2 by construction: it runs in the `layer2` kernel,
costs under a millisecond, and reaches no service. The panel a control sits in
is its layer, and that rule outranks the earlier argument for breaking it.
Selecting a mask opens a **sublayer** inside the section — inset, with an
accent rail — because the local sliders are otherwise identical to the global
ones two sections above, and that is the one way this interface could mislead.

Two controls break the panel rule and say so in their own comments:
**Vignetting** (Layer 2, but placed in Camera where a photographer looks for
it) and the **white balance block** (neither layer — it is a decode setting,
§4).

---

## 4. The data path

```
open a selection
  ├─ one file (Open With / Edit With / one drop)  →  Print, immediately
  └─ a folder or several files                    →  Browse, and render nothing

select(frame)
  ├─ Core Image decode           CIRAWFilter, boost 0, no gamut map,
  │                              lens correction from `decode.lensCorrection`
  │    ├─ preview texture        Display P3, 1600 px  → canvas at once, "preview" badge
  │    └─ half-float TIFF        linear ProPhoto      → ~/Library/Caches/…/linear/
  ├─ service.open(tiff)          film side → live-tier negative
  ├─ service.solve(exposure)     the auto-exposure baseline, per AE Method
  └─ service.reprint(rgba16)     raw 16-bit RGBA → texture → canvas, badge clears

the zoom crosses 100 % / 200 %
  └─ service.reprint(tier: preview|full) → a bigger texture for the same frame
```

The service detects the half-float TIFF as linear ProPhoto, so RAW decode is
Apple's rather than LibRaw's, and white balance becomes a client decision with
a real control instead of a hardcoded `as_shot`. The sidecar records
`decoder: coreimage`.

**Colour, stated once.** Textures hold Display P3 *encoded* values. The
`CAMetalLayer` colour space is Display P3, the pixel format is never an
`_srgb` one, and the shader applies no transfer curve. Encode happens exactly
once, at texture upload. A washed-out canvas means a second encode crept in.

**Orientation.** Row 0 of every texture is the top of the image: the decoder
preview is rendered with a vertical flip (Core Image's origin is bottom-left),
the service's `rgba16` dump is numpy row-major, and the canvas view is
`isFlipped` so mouse and shader share the top-left origin.

### Buffers

`Canvas/TextureStore.swift`. Sizes are for the 1600 px live tier.

| texture | source | kept |
|---|---|---|
| source preview | Core Image decode | last 8 frames |
| print (live tier) | `reprint` rgba16 | last 8 frames |
| detail (preview/full tier) | `reprint` at the zoom's tier | one frame only — a full-res rgba16 texture is 360 MB |
| adjusted | `layer2` kernel output | one, re-run on edit |
| curve table | CPU, 256 × 5 r32Float | one |

Switching frames shows that frame's last print immediately, flagged
**preview** until the service catches up. The two neighbouring frames are
decoded in the background so their `open` skips the RAW decode.

### Crop and straighten

A crop is an **oriented rectangle** — a normalised rect plus the angle it is
rotated by about its own centre (`Model/Geometry.swift`) — not "rotate the
image, then crop the result". The source never moves, so straightening
resamples nothing twice and setting the angle back to zero restores the
rectangle you had.

Every mutation returns something that **fits**: `fitted(in:)` shrinks the
rectangle about its centre until all four corners are inside the frame. That
is why an 8° straighten costs about 20 % of the frame's width, visibly, in the
Crop section's pixel readout — instead of exporting a picture with transparent
triangles in the corners.

The geometry is applied while *sampling*, both on the canvas
(`canvasFragment` → `geometryMap`) and at export (the `geometryResample`
kernel, deliberately the same function). Before this the crop was a dimmed
overlay that only appeared while the crop tool was active and was applied at
export with `CGImage.cropping`: the canvas showed an uncropped frame, export
wrote a cropped one, and neither could rotate at all.

While the crop tool is up the canvas shows the **whole frame** with the
outside dimmed, and the viewport is expressed against the source; leaving the
tool re-expresses it against the crop and refits. `Renderer.logicalSize(forSource:)`
is the one place that decision is made. The detail tier follows the *cropped*
long edge, so a 20 % crop of a 45 MP frame no longer escalates to a
full-resolution render for detail the crop threw away.

### Masks

A mask is a **region plus its own adjustments** (`Model/Mask.swift`). A region
is a union of `add` components minus `subtract` components — "the sky, minus
the trees" is two components in one mask — and the first component is always
additive because there is nothing to subtract from yet. Four kinds ship:
linear gradient, radial gradient, luminance range and colour range. All four
are **closed-form**, so coverage is evaluated per pixel from parameters at
whatever resolution the canvas is showing: a radial is exact at 400 % zoom and
costs no memory at any tier. `brush` exists in the model and in the shader as
component kind 4, with `MaskUniform.rasterSlice` and a texture-array binding
waiting for it, and is deliberately absent from the add menu until something
rasterises strokes.

A mask's tone controls are the **same** controls, the same ranges and the same
arithmetic as the global panel's — `Layer2Uniforms.tone` is one function with
two callers — so "+1 stop" means one stop wherever it was typed. What a mask
does not carry is as deliberate: no curves, no colour balance, no vignette. A
curve is a global statement about a tone scale and a vignette is a lens.

Coverage is computed against the print *before* the global adjustments, so a
luminance- or colour-range mask selects what the photograph has in it rather
than what the exposure slider just did to it. Masks are anchored to the
**source**, not the crop, so re-cropping leaves a mask on the face; the canvas
shows the crop, so every handle goes source → output → view through
`Geometry.outputPoint(forSource:imageSize:)`. Eight masks, six components
each, one uniform buffer, no allocation.

### Browse and Print

Two states, one window (frontend SPEC §5.1). **Browse** is a grid of the
session — thumbnails only, no decode, no render — and is where a folder or a
multi-file drop lands. **Print** is the three-region layout, entered by clicking a
cell. A single file is a handoff and goes straight to Print. Before this, a
folder open rendered the alphabetically-first frame: ~7 s and a 363 MB TIFF on
a guess the user had not made.

The grid cell has no state badge: selection is the white frame and nothing
else, the same rule the filmstrip follows.

### Resolution follows the zoom

The live tier is 1600 px because a reprint has to fit inside a slider drag.
Past 100 % zoom it is interpolated, and grain and halation — the reasons to
zoom — are exactly what interpolation destroys. So the canvas asks for a
higher tier and swaps it in when it lands:

| zoom | tier | long edge |
|---|---|---|
| below 100 % | live | 1600 |
| 100 % | preview | 3400 |
| 200 % | full | native |

A frame no larger than the live tier never escalates. The request is debounced
180 ms and never starts while the scheduler owes the service a render — the
transport is single-flight (`capabilities` reports `concurrent: false`), so a
detail render sits in front of the user's next slider release.

The debounce was 700 ms, sized against a full render that took 17 s cold and
6 s warm on a 45 MP frame. The GPU-native core (RFC-011) took that to 0.99 s
cold / 0.237 s warm, at which point waiting 700 ms to decide is most of the
cost of just doing it. **The escalation is still two steps, but the reason is
now memory rather than time**: a full-tier rgba16 texture at 45 MP is 360 MB
against the preview tier's ~90 MB, so going straight to `full` at 100 % would
be about as fast and cost four times the resident memory for detail the
viewport cannot show.

Zooming back out is instant: the detail texture stays resident and the live
tier comes back without a render. Zooming back *in* is too — the slot answers
"this tier or sharper" and is stamped with the parameters it was made from, so
it is a cache rather than a coincidence.

The viewport is expressed against the **live** tier's pixel size, not the
texture's. `Renderer.canvasUniforms` scales by `logicalWidth / textureWidth`,
so a 5504 px texture and a 1600 px one occupy the same rectangle on screen.

### The decode cache

`Import/LinearCache.swift` bounds `~/Library/Caches/com.hanze.spektrafilm/linear`
at 4 GB, LRU by modification date, pruned before each write. Each entry is the
source at full resolution (363 MB for 45 MP), so the ceiling is about eleven
frames. The TIFF is written *after* the decode task's cancellation guard, so a
superseded white-balance value leaves no file behind.

### Scheduling

`Service/RenderScheduler.swift` holds *sent* against *wanted* and runs one
loop: debounce (40 ms print, 220 ms shoot), send one delta for the whole
difference, apply the result only if the generation still matches. A slider
drag produces a handful of reprints, never one per tick, and a stale reply can
never overwrite a newer frame.

Layer 2 bypasses all of it. Zoom and pan are a sampling transform
(`ViewportState`) and cost nothing; at 100 % and above the sampler is nearest,
so grain reads as grain.

### The canvas draws on demand

`isPaused` with an explicit `scheduleDraw()` that calls `MTKView.draw()`,
coalesced to one per runloop turn. **Not `needsDisplay`** — the documented
recipe does not fire the delegate in the running app, and the canvas stayed
blank while everything behind it worked. The view is its own `MTKViewDelegate`
so there is no separate object whose lifetime can be got wrong.

`SPEKTRAFILM_CANVAS_LOG=1` prints one line per draw with the base texture, the
viewport and whether a drawable was available, plus one line for any render
dropped before upload.

---

## 5. Files

```
Theme/Theme.swift            every colour, metric and font in the interface
Windows/EditorWindow.swift   Browse or Print; CanvasArea; drop; export sheet
Windows/BrowseView.swift     the Browse grid, breadcrumb and sort
Windows/TopBar.swift         tools, status, zoom, elapsed time, detail tier
Windows/CollapseTab.swift    the filmstrip's hover tab — the one that is left
Panels/LeftPanel.swift       the darkroom rail, and SidebarToggle
Panels/RightPanel.swift      the grade rail
Panels/Filmstrip.swift       library strip
Panels/Sections/*.swift      one file per section
Controls/ScrubSlider.swift   the only slider: drag anywhere, ⌥ fine, ⇧ snap,
                             double-click to zero, editable value
Controls/SectionHeader.swift disclosure header + Well + PanelSection
Controls/CurveEditor.swift   channel tabs, draggable points, readout
Controls/ColorWheel.swift    Master / 3-Way colour balance
Controls/HistogramView.swift Canvas-drawn RGB + luma
Controls/WhiteBalanceRows.swift  Temperature and Tint, each with its As Shot box
Controls/FormatPicker.swift  PillMenu · UnitField · CinePill
Canvas/MetalCanvasView.swift MTKView, gestures, scheduleDraw
Canvas/Renderer.swift        Metal state, Layer 2 pass, histogram, offscreen render
Canvas/TextureStore.swift    the buffer table
Canvas/ViewportState.swift   zoom and pan arithmetic, no view code
Windows/TrafficLights.swift  the window buttons, moved onto the header row
Canvas/Shaders.metal         layer2 · canvas quad · histogram
Model/Session.swift          all state, on the main actor
Model/Params.swift           Layer 1, mirrors service/schema.py
Model/Adjustments.swift      Layer 2 + the shader uniform block
Model/CurveMath.swift        monotone cubic, no view code
Model/Geometry.swift         the oriented crop, straighten, turns and flips
Model/Mask.swift             masks: components, per-mask adjustments, uniforms
Canvas/MaskOverlay.swift     the selected mask's axis, ellipse and grips
Model/Sidecar.swift          <image>.spektra.json (schema 3)
Canvas/CropOverlay.swift     handles, thirds grid, straighten line
Model/StockCatalog.swift     Resources/StockCatalog.json
Import/ImageDecoder.swift    Core Image RAW + flat decode, linear ProPhoto out
Import/Library.swift         one file or one folder, no subfolders
Import/ThumbnailCache.swift  ImageIO previews off the main actor
Import/LinearCache.swift     the bounded on-disk decoded-TIFF cache
Service/ServiceClient.swift  actor, one long-lived python -m spektrafilm.service
Service/Methods.swift        typed requests and responses
Service/RenderScheduler.swift coalescing
Export/Exporter.swift        JPEG · PNG · TIFF · DI package
Tools/gen-project.py         regenerate the pbxproj from the filesystem
Tools/gen-catalog.py         regenerate the stock catalog and covers
Tools/snapshot.sh            offscreen layout captures at three window sizes
Tools/capture-live.sh        the real window, through the window server
Tools/measure-layout.swift   a capture against the drawing: regions, bar, hairlines
Tools/compare-layout.py      superseded — it measured the previous drawing's four cards
```

---

## 6. Renamed from the drawing

| drawing | built | why |
|---|---|---|
| Enlarger: Cyan / Magenta | Brightness / Yellow / Magenta | a dichroic head grades on two axes; the engine has `y_filter_shift` and `m_filter_shift` and no cyan. Brightness (print exposure, in stops, brighter positive) is the enlarger's main control and the drawing omitted it. |
| Curve tabs 亮度 / 红色 / … | RGB · Luma · Red · Green · Blue | the rest of the interface is English |
| checkboxes: hollow squares | hollow off, accent-filled on | it is a state, not a decoration |
| Camera: five rows | the white-balance presets and the neutral picker are in the section's "•••" | the drawing's Camera is five rows and neither of those is one of them. They moved, they did not go |
| no Enlarger section | kept, collapsed, last | the only access to `print_exposure` and the two filter axes |
| bar: gaps of 63.6 and 85.2 | 40 and 46 | the drawing's spacing is 19 pt wider than the bar at the minimum window (1100 pt) |
| Camera section 241.35 tall | 230 | the drawing puts ~5 pt more air around each non-slider block; the rest of the rail is within 2–6 pt, so the row rhythm is left self-consistent |
