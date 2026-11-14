# Building a page

For anyone, or any session, adding or changing a page of the Mac app. Rewritten 2026-11-08 to say only
what holds in `app/SpektraLab` today; the window's layout and metrics are `design/MAC-LIBRARY-UI.md`.

## 1. What a page is measured against

- **The window is Capture One's arrangement in v2's language** (`design/MAC-LIBRARY-UI.md` §8): one left
  column whose mode row reads 图库 · 冲洗 · 编辑, the picture at the centre, a browser shared by every mode
  (`MainWindowLayout`). The Light Table, Import, Export and Settings are full-window pages.
- **Two kinds of point** (`Sources/DesignSystem/InterfaceScale.swift`). The app is a Mac Catalyst app at the
  scaled idiom, so a point of the Catalyst scene is drawn at 0.77 of a Mac point (`MacMetric.scale`). The
  library, Settings, Import and Export are written in **Mac points**, `MacMetric.pt(x)` = x / 0.77, the units
  the HIG gives. The develop page, the crop page and the film-edge flow are written in **scene points**. Settings
  › Appearance's interface scale (80, 100, 120, 150 %, kept as `ui.scale`) draws a Mac-point page at
  choice × 10/9 and a scene-point page at choice × `padTarget` / 0.77, so at 100 % a scene point stands at
  0.9625 of a Mac point and the two kinds of page agree. A figure is never converted by hand in a view: write it
  in the page's own kind of point and let `interfaceScaled(_:)` scale the page.
- **Type is never below 11 Mac points**: "shrink the gaps, never the type" (the owner, 2026-09-28).
- **Weights:** 400 regular, 500 medium, 600 semibold, 700 bold. `Theme.Font.ui(size, weight)`, or
  `MacMetric.font(size, weight)` on a Mac-point page.
- **Colours and sizes come from `Theme`** (`Theme.panel`, `Theme.card`, `Theme.secondaryText`, `Theme.dim`,
  `Theme.accent`, `Theme.selection`, …). A colour only one page uses may be a private constant there.
- **Place a part where it goes, not by a stack of paddings.** `DrawnBand` (`DesignSystem/DrawnLayout.swift`) is a
  strip whose children say where their `baseline(_:)`, `top(_:)` or `centreY(_:)` goes from the strip's top. A
  line of type is not the same height in every font fallback, and stacked paddings drift by a point or two.

## 2. The shared parts: use them, do not redraw them

`Sources/DesignSystem` for every page; `Sources/Mac/Settings/MacSettingsParts.swift` for the Mac-point pages.

| part | use |
|---|---|
| a round or capsule button, a close button, a word that is a button | `RoundButton`, `CapsuleButton`, `CloseButton`, `TextButton` |
| a chip, a row of chips with one on, tabs | `Chip`, `ChipRow`, `TabStrip` |
| a segmented choice | `SegmentedSwitch` |
| a slider with its editable number | `ValueSlider`: fixed track, moving knob, Capture One's row. Never a scale that slides under a fixed mark |
| a ruler, the Film Exposure dial | `TickRuler`, `RulerRow` |
| the Latitude card | `LatitudePlot`, `LatitudeCard`; its reading is `LatitudeReadout` (`Engine/SceneLatitude.swift`) |
| a grouped list, its rows and labels | `GroupBox`, `RowSeparator`, `SectionLabel`, `Chevron`, `ValueRow` |
| a Settings group, row, value row, checkbox | `MacSettingsGroup`, `MacSettingsRow`, `MacSettingsValueRow`, `MacSettingsCheckbox` |
| the CINE pill, a tag | `CinePill`, `TagPill` |
| a develop's progress, the status line | `ProgressRing`, `DevelopProgressBar`, `StatusLine` |
| a toggle, a tick box, a pick circle | `SpkToggle`, `TickBox`, `PickCircle` |
| a film strip, the date back's digits | `FilmStripView`, `SevenSegment` |
| an icon | `Icon(.share)` from `SpkIcon`: the app's own strokes (`DrawnIcons.swift`, written by `tools/gen_icons.py`). For a new glyph, add it to the tool's list and run it; never hand-edit the generated file |
| a frame's picture | `FrameView(frame:pointSize:)`; a bare picture `FramePicture` |
| a keyboard shortcut | `MacShortcutButton(.crop) { … }`: the key is `MacShortcut`'s (Capture One's defaults), the action the page's (`design/MAC-LIBRARY-UI.md` §5) |

A part two pages need belongs in `DesignSystem`. A part one page needs belongs beside that page.

## 3. Where a page's words come from

Every sentence a page shows goes through `L("…")` (`LOCALIZATION.md`). A film's or a paper's name is the
catalogue's (`Stock.name`, `.shortName`, `.edgeName`), never a profile id.

## 4. Rules

1. **Accent is only for actions and state; selection is the white capsule or the white frame.**
2. Physical stages only: film, print, enlarger, scene, effects, frame. No grade after the print: the finished
   picture's own tools are Edit's Layer 2 (Light, Curve, Colour), which follow the print and never reach back into
   the film or the paper (`AGENTS.md`, "Do not pollute the material model").
3. **There is no live render** (RFC-036 §4; `Services/OpenFrameSession.swift`). A control's number follows the
   pointer; a render is a scheduled job. Print-side edits are coalesced reprints; film-side edits develop when
   the drag rests or ends.
4. No "…" and no text outside its frame. A message is never `.fixedSize()`d into overflowing its column.
5. A reduced render is never labelled full; an omitted effect is named.
6. Never written to: the person's own folders, except where Export is told to write. Edits live in the app's
   library and catalogs (`MAC-LIBRARY-DATA.md` §3, §4).
7. No roll: no frame counters, no 36-exposure limit.
8. **A slide film is scanned, never printed.** Load a film with `FilmParams.load(film:)` and choose a paper with
   `print(on:)`, never by setting `filmStock` or `printStock` alone; name a pair with `StockCatalog.pairText(_:)`.
9. **Silver on silver, colour on colour.** The same two functions hold it. A page that offers papers dims the
   ones the film cannot be printed on and says why with `StockCatalog.whyNotPrinted(film:on:)`; a page that
   chooses a pair with no frame to hold it uses `StockPair`. The dimming shows the gate; it is never the gate
   (`ENGINE-WIRING.md` §4.7).

## 5. RAM first, on a page

- **Every render is a job** on `RenderQueue`: through `OpenFrameSession` on the develop page, `AppServices.develop`
  for an import or a library preview, `ExportService` (and `MacExportRun` over it) for an export. A page never
  calls the engine and never loops a render.
- **A waiting job says why** (`WaitReason.text`); show it where the page shows state.
- **Pictures are decoded at the size they are shown** (`FrameView`, `FramePicture`, `ThumbnailStore`). Never a
  `UIImage(contentsOfFile:)` of an original. Grids are lazy.
- **Tell the scheduler what the page is doing**: `scheduler.frontend.interaction` (`OpenFrameSession.began` /
  `.ended` set it), so a job that would compete with a drag waits for it.

## 6. Film Edge and the Date Back; the half-frame pair

Their pages are `Features/FilmEdge`, their model `Sources/FilmEdge` and `Model/FilmEdge.swift`.

- **A page never decides where anything on a film is.** Ask for the film's geometry (`AppServices.filmEdge(for:edit:)`,
  which resolves a frame's settings and lays the film out) and draw it with `FilmCanvasView` — `.guide` over the
  undeveloped picture, `.developed` where the engine's render belongs. A second copy of the arithmetic in a view is
  how a guide comes to disagree with the develop.
- **After any change to `Sources/FilmEdge` or `Model/FilmEdge.swift`, run the parity check** against a built engine:

  ```bash
  engine/build.sh dylib
  app/SpektraLab/tools/film_edge_parity.py --engine engine            # every case, against the engine's render
  app/SpektraLab/tools/film_edge_parity.py --engine engine --self-test # the check itself: 9 broken layouts, 9 caught
  ```

  `--only id,id` runs some cases; `--keep` writes the engine's renders to `build/film_parity/engine` to look at
  beside the app's masks in `build/film_parity/port`.
- **The half-frame pair** is its own model, pages and wire (`Model/HalfFramePair.swift`, `Features/Pair`,
  `Engine/PairDevelop.swift`). A pair's film edge is the pair's own switch (`HalfFramePair.onStrip`): **its look's
  `filmEdge.active` stays off** (`FrameEdit.asPairLook`), so no page that reads a film edge as one frame in one gate
  ever sees a pair's. Hold an edit as a pair's look wherever one enters a pair, as `held(to:)` is for a frame. What
  the host hands the engine is in `PAIR-WIRING.md`; on the Mac a pair is also a row of the library
  (`MAC-LIBRARY-DATA.md` §2i).
- **The 图层 (Layers) panel** (`Features/Layers`, 2026-11-12; drawings and spec in `design/layers/`): the card
  under the histogram, in 冲洗 and 编辑, with one row per thing the controls can be about — 胶片 first, then a
  pair's frames or a double exposure's exposures. **Its rules have no view in them** (`LayerRules.swift`: the rows,
  the pick, the eye, Balance's place, the card's heights, what a picked row's page holds, which picture 裁剪
  arranges, the refusal; `tools/layers_selftest.swift`), and a double's sections are derived from
  `DoublePanelKind`, so the two cannot drift. A page that shows a pair or a double reads `session.layerPiece` and
  `session.layerPick` and never the pair's or the double's own pick. What is over the page is `LayersStage` (摆放
  open, the sheet that asks for a photograph, the export refusal).
- **Mask layers in the 图层 panel** (PRD-E M1a, 2026-11-13; drawings and spec in `design/masks/`, MASKS-SPEC §12
  steps 1–3): a single photograph's panel unfolds with 主体 · 背景 · 人, the tool row, its mask layers newest first,
  不透明度 and 组合蒙版 · 完善蒙版…; a mask row picked, the column is that layer's page in both modes (`MaskPage`:
  作用于, 蒙版, 调整, the foot back to 胶片). The rules are `LayerRules` (mask rows, heights, the page per pick) and
  `MaskRules` (names, 8 a stage, each stage's controls), held by `tools/masks_selftest.swift`; every act is the session's
  (`OpenFrameSession.makeLayer`, `removeLayer`, `switchStage`, … — one step of Undo each; a slider's drag through
  `beganLayer` / `moveLayer` / `endedLayer`, never a commit per tick). **The tools on the picture** (M1b, MASKS-SPEC §6,
  §8): a slot lights 画笔, 线性渐变, 径向渐变 or 橡皮 (`MaskTools`, the page's state; the brushes' settings kept in the
  app's defaults, `masks.brushes.v1`); the pill at the tool row's leading end says the lit tool and opens 大小 · 硬度 ·
  流量 (`MaskPopovers.swift`, SwiftUI's own popover from the pinned card); `MaskStage` over the canvas maps the pointer
  to S through the view's one matrix (`MaskFrame.view` over `AppServices.finishedToSource`), draws a gradient's lines
  and handles and the brush's cursor, and lays the overlay or the mask alone from the canonical plane
  (`MaskOverlay`, off the main actor, the red converted to the page's space). A press-to-release is one step; with 胶片
  picked the first stroke or drag makes the layer. Keys `M` `⌥M` `B` `E` `[` `]` `⇧[` `⇧]` Esc ⌫ (`MaskKey`,
  registry entries). **Finding** (M1c, MASKS-SPEC §4.3, §6.4, §6.5, §7): 主体 · 背景 · 人 ask Apple's Vision on this Mac
  through `MaskFinding` (the page's state; `SubjectFinder`, an actor of its own, on the frame's own file and decode,
  `OpenFrameSession.findSource`) — 正在查找 on the button at its width, then a new layer picked (or, from 组合蒙版, a
  part of the picked one with its join), one step; 人's menu with its people's squares, the row under the pointer lit on
  the picture; "not available on this Mac" stands the buttons down. The found masks are the edit's files
  (`FoundMaskFiles`): the page's open adopts a clone's and marks a missing one, its close sweeps (`FoundMaskKeeping`,
  called from `DevelopPane`), a frame removed and the launch's tidy from `AppServices`. 组合蒙版 and 完善蒙版… are
  popovers (`MaskCombinePopover`, `MaskRefinePopover`: 羽化, the mask alone while it is open); the geometry mark
  (镜头校正 switched after a mask was made) on the row and the 蒙版 section's first line with 重新查找 and 保持现状.
  On in every build since M1c (`FeatureFlags.maskLayers`). `tools/masks_check.sh` holds it in the running window
  (`MacMasksCheck`, `MacMaskToolsCheck`, `MacMaskFindCheck`, `MacMaskFlatCheck`).
- A format a stock was never made in is shown and cannot be chosen; a date face a camera never printed likewise, and
  the page says why. The edge's words are `Stock.edgeText`.

## 6a. The develop page

`Features/Develop`. What goes where:

- **`DevelopLayout.swift` has every number and every word that decides where something is in a panel**, and
  nothing of SwiftUI: each panel's y (`PanelY`), the notes' lines (`PanelNotes`), and each panel's parts as rows of
  ink (`PanelState`). A part added to a panel is added there too, or the check that holds the panels apart does not
  know of it.
- **A note's line is one line.** `panelNote` sets each element of a `PanelNotes` list on a line of its own, smaller
  if it must and never wrapped. Write a note as the lines it should take, and run `tools/selftest.sh`: it measures
  every line, with every stock's name in it, in the page's own type against the narrowest page it is set on
  (375 points less the margins, `tools/develop_selftest.swift`).
- **The column, top to bottom**: the histogram's card, the 图层 card (`LayersPanel`; a photograph's
  card unfolds with its mask layers in every build since M1c, `FeatureFlags.maskLayers`;
  `LayersPanel.height` is what the column reserves, its foot line measured where it is drawn), Develop's two steps,
  and the panel — or, with a picture's row picked, that picture's page with no steps over it; with a mask layer's
  row picked, that layer's page (`MaskPage`) with no steps, in 冲洗 and 编辑 alike; or 摆放's controls
  (`ArrangeColumn`).
- **The column and the picture side** are placed by `DevelopRegions`: the column stands at the window's left, as
  Capture One's tools do, and is dragged between `PaneDividers.minColumn` and half the window; the width is kept and is
  the library's sidebar width too (`design/MAC-LIBRARY-UI.md` §6, §8).
- **Another photograph or variant is the same page** (2.4.0 A2b): one session per frame, but the page is kept and handed
  the next frame's session (`DevelopPane.switchSession`), so only what depends on the frame updates. A view that holds
  a frame's state of its own therefore says what becomes of it on another frame: made again with the frame
  (`.id(frame.id)`: the canvas, the histogram's card), reset in an `onChange(of: frame.id)` (the page's alerts,
  Compare, Decode's channel, the curve's chosen point, the stock strips' shelves), or carried on purpose (the
  column's scroll, the lit mask tool, a fold). A view that registers with the session or the frame's strip on
  appearing registers again on a change of session. Where something is held — a control's drag, a field being
  typed in, a popover, the crop, a sheet — the page is made again instead (`DevelopWorkspace.pageHolds`).

- **编辑 › 镜头 opens with 镜头校正** (2.4.0, `LensCorrectionPart.swift`; Capture One's tool, its drawings in
  `PRD/lens-correction-2026-11-13/`): 配置文件, 隐藏畸变区域, 畸变 (`ValueSlider` 0–100, rest 100), 光衰减 (0–100, greyed
  while `LensResolver.lightFalloffVerified` is false) and one line saying who corrects and why, in the page's words
  (`LensWords`), never `LensResolution.why.text` raw. No 色像差, 衍射校正 or 锐度衰减 rows: nothing true stands behind them.
  A control is live only where the resolution says (`adjustsDistortion`, `adjustsHideDistortedAreas`,
  `adjustsLightFalloff`); a JPEG or HEIC, a pair, a double and an original that is away get the heading and one line.
  While the resolution has not settled the last settled answer stays, so nothing flickers. **The 配置文件 popup is a
  real menu** (`LensProfilePopUp`, a `UIButton` whose menu is its primary action): Manufacturer Profile — the lenses the
  database recommends — one row per maker, its lenses read only when the row opens (`UIDeferredMenuElement`) — Add .lcp
  File… and None; the whole menu is made as it opens, from the state then (`tools/lens_check.sh` measures it). The
  section's ↺ and its at-rest dot include 镜头校正 (on, automatic, 100, 0, hidden: `OpenFrameSession.lensRest`). The
  database's own page is Settings › Develop › Lens Profiles (`MacSettingsDevelop`, over `LensLibrary`).

### Black and white on the pages (2026-10-09)

| where | what a black-and-white film changes |
|---|---|
| Film & Paper, the paper cards | a paper of the other kind is dimmed, **that card alone**, takes no click, and gives the reason in its accessibility label (`CardRow(waits:)`, `PaperCard(waits:)`) |
| the enlarger's two shifts on a silver print | `Yellow → softer`, `Magenta → harder` (`EnlargerScales.grade`); the tool reads `Grade` where it reads `Colour` |
| Effects, Grain | Sub-layers stands down and reads `one layer` (`DevelopLayout.swift`) |
| Settings › Develop › New frames | a paper of the other kind is greyed in the Paper pop-up and takes nothing (`MacSettingsPopUp(allowed:)`); the group's footer says why (`StockPairPicker.papersNote`) |
| Settings › General › Licences and credits | says whose the black-and-white profiles are |

## 7. The loop

```bash
app/SpektraLab/tools/snapshot.sh --only ID,ID --size 1440x900    # draw pages offscreen, Mac Catalyst
app/SpektraLab/tools/same_snapshots.sh <before> <after>          # which pages moved, and by how much
app/SpektraLab/tools/selftest.sh                                 # the self-tests (no Xcode project)
```

- `snapshot.sh` builds the app and runs it with `--snapshot`: every page in `SnapshotHarness.pages` is hosted in a
  window that is never shown and written to `build/snapshots/<id>.png`. A wide `--size` is the Mac's window.
  `--language zh-Hans|zh-Hant|ja` draws the pages in that language. `tools/measure.swift` (compiled to
  `build/tools/measure <png> x0 x1 y0 y1`) reads the rows of ink in one strip of a snapshot, in points, when a
  number is needed.
- **Two runs of the snapshot harness are nearly always the same files, and not always**: a page now and then
  differs by a few hundred pixels at up to 8 of 255 with nothing moved. Draw again before believing a difference;
  `same_snapshots.sh` says which kind it is, and is how a change that must not move a page is held.
- **An offscreen snapshot is not the window.** It cannot see a Metal layer, a stall or the window's own chrome. The
  Mac's own checks drive the real window from a launch argument and write a report: `--mac-drive`,
  `--library-check`, `--import-check`, `--export-check`, `--render-check`, `--settings-check`, `--lighttable-check`,
  `--catalog-check`, `--clipboard-check`, `--drop-check` (`Sources/Mac/MacDriver.swift` and the `Mac*Check.swift`
  files beside each page). A report with 0
  failures that a person has not clicked through is said to be so.
- Build Release as well as Debug before calling a change done (`AGENTS.md`): a path that reaches code under
  `#if DEBUG` compiles in Debug and fails in Release.
