# Main editor v3: token translation and Claude Code handoff

Status: design specification only. No application implementation. Read this
before the historical `TOKENS-main-2026-09-17.md` when implementing v3.
The companion `tokens-main-v3.json` is an inactive, machine-readable token
set, not a resource loaded by the application.

## 1. Sources and authority

- Geometry: `../reference_layout/Main/sample_frontend_v3.ai`, one
  PDF-compatible Illustrator page, 3840 × 2160 artboard units.
- Appearance: `../reference_layout/Main/layout_screenshot.png`, 2754 × 1550.
- Current implementation inspected at commit `eda971b`: `Theme.swift`,
  `EditorWindow`, `TopBar`, both panels, Filmstrip, Camera/Film/Print/right
  sections, WhiteBalanceRows, SectionHeader, BeforeAfterIcon, and Session.
- Current behavior contracts: `../Spektrafilm/README.md` §8.1 and
  `../../PRD/Frontend_Rework_2026-09-17.md`. Older architecture prose is not
  evidence of the v3 layout or even of every current view implementation.
- The checked-in `../../screenshots/SpektraLab_main.png` was inspected as
  a historical appearance reference; no fresh running-app capture was made.

Use **artboard units / 2 = macOS points**, yielding 1920 × 1080 pt. This is
the translation scale, consistent with the current rail widths. PDF points
here are Illustrator drawing units, not literal macOS layout points.
Coordinates below use top-left origin. Do not measure dimensions from the
rescaled screenshot. Do not restore the deleted old Main SVG/PNG files.

Evidence labels: **M** = measured in PDF vector/text data; **S** = sampled
from supplied screenshot; **D** = deliberate normalized design choice;
**P** = preserved application policy; **U** = unresolved behavior/appearance.
The JSON records target values, with status per group or token.

## 2. Frame and toolbar

| Existing token / proposed role | Current | v3 target (pt) | Evidence |
|---|---:|---:|---|
| `Metric.leftPanelWidth` | 254 | 254 | M: rail fill ends x 507.36 / 2 = 253.68; divider x 254.41; D: normalize 254 |
| `Metric.rightPanelWidth` | 288 | 288 | M: x 3263.86 / 2 = 1631.93, width 288.07 |
| `Metric.filmstripHeight` | 132 | 132 | M: y 1895.30 / 2 = 947.65, height 132.35 |
| `Metric.panelHeaderHeight` | 38 | 38 | M: y 75.59 / 2 = 37.795 |
| `Metric.topBarHeight` | 31 | 38 | M: rectangle y .59…75.59 / 2; D: align to header |
| `Metric.barTop`, `barInset`, `barRadius` | 5, 9, 14 | **0, 0, 0** | M: flush rectangular toolbar fills center column |
| `Metric.barStrip` | 41 | 38 | D: toolbar's own height, no surrounding ground strip |
| `Metric.rule` | 1 | 1 | M: 2-unit strokes |
| `Metric.zoomPill` | 105 × 20.7 | **41.29 × 20.69** | M: rect x 2769.98…2852.56, y 17.63…59.01, divided by 2 |
| `Metric.minWindow`, rail resize ranges | 1100 × 700; 232…380 / 268…364 | preserve initially | P: drawing specifies only one window size |

The toolbar is flush with both rails and the top edge. Rail dividers now
extend **the full window height**, including beside the canvas; the older
rule that only the filmstrip needs vertical dividers is superseded. Keep
dividers as overlays so they do not add width to the three-column geometry.
The canvas occupies y 38…948 at the reference size; photo aspect-fit and
zoom remain dynamic, not the fixed rectangle occupied by the example photo.

Toolbar order, left to right:
`Select · Pan · Crop … Before/After · percentage · Zoom out · Zoom in · Fullscreen`.
The current toolbar has Zoom in before percentage and Zoom out after it.

Reference glyph centers (M, pt): Select x 303.12; Pan about 363;
Crop 425.22; Before/After divider x 1330.58; percentage plate center
x 1405.64; Zoom out 1478.38; Zoom in 1541.06; Fullscreen 1601.37.
Use these as optical anchors at 1920 pt, not absolute window coordinates in
views. Proposed toolbar content inset is 32 pt; tool-center pitch 61 pt.
The right cluster has roughly 60–75 pt center pitches. At narrow widths,
reduce inter-control spacing before shrinking glyphs or clipping controls;
retain at least the existing 28 × 28 pt toolbar hit regions. The mockup does
not define a responsive spacing algorithm. Keep status/progress/error and
full-resolution indicators accessible; the blank center is not permission
to remove them or the window drag surface.

Top-left rail reads **Develop**, with import and export at the trailing end;
top-right reads **Edit**, replacing its inert adjustment glyph. Both are
labels, not mode buttons. Window traffic lights and sidebar toggles are
absent from the artwork: see §8 before placing that header in a real window.

## 3. Rail rhythm and controls

Reference section boundaries (M, pt; visual anchors, not hardcoded heights):

| Rail | Rule y positions | Reference expanded state |
|---|---|---|
| Left | 37.79, 241.23, 589.74, 800.49 | Input / Camera, Film, Print open; Crop shut |
| Right | 37.81, 130.62, 159.67, 190.68, 443.71 | Histogram and Curve open; White Balance, Exposure, Color Balance shut |

These imply Camera ≈203.4 pt, Film ≈348.5, Print ≈210.8; collapsed right
headers ≈29–31 pt. Do not stretch every section to those heights at all
window sizes: scroll content and retain persistent disclosure state. Rules
are between sections, not a bottom border after the final section.

| Proposed role | Target | Current mapping / evidence |
|---|---|---|
| `headerHeight` | 30 | preserve; M: collapsed headers |
| `rowInset` | 16 | M: label x 15.61…17.12; current 18 |
| `camera.labelColumn` | 70 | M/D: track/menu x 86.35 minus label x 16; current shared 84 |
| `camera.trackWidth.reference` | 90.44 | M: x 172.69…353.56 / 2; grows with rail |
| `controlHeight` | 13.9 | M: 27.8 / 2; current 14 |
| `sliderValueWidth` | 43.73 | M: 87.46 / 2; current 44 |
| `sliderValueGap` | 15.06 | M: (383.67 − 353.56) / 2; current 14 |
| `camera.meteringWidth.reference` | 149.22 | M: 298.44 / 2; fill after label column |
| `film.pickerWidth` | 107.03 | M: 214.06 / 2; current 112 |
| `film.fieldWidth`, `unitWidth` | 49.77, 38.32 | M: 99.53 / 2, 76.63 / 2 |
| `film.controlTrailingInset` | 23 | M/D: right edges x 231.10 on 254 rail |
| `film.rowPitch` | 22.5 | M: label baselines separated by 45 units |
| `camera.wbAxisPitch` | 20 | M/D: Temperature/Tint text pitch ≈19.87 |
| `trackHeight` | 1.36 | M: 2.71 / 2; current 3 |
| `knobSize` | 6.13 × 5.07 | M: vector bounds; current 10 × 10 |
| `checkbox.visualSize` | 5 | M/D: small square; current 9; preserve padded hit target |
| `selection.height`, `radius` | 15.27, 7.63 | M: 30.53 / 2; D: capsule radius |
| `stock.rowPitch` | 18 | M: list text baseline interval 36 / 2; current 19.5 |
| `stock.leadingInset` | 16.79 | M: selection x 33.57 / 2; current well inset 4 |
| `stock.textLeadingInset` | 21.33 | M: text origin 42.66 / 2 |
| `stock.trailingInset` | 26.48 | M/D: selection ends x 227.52 on 254 rail |
| `stock.selectionWidth.reference` | 210.74 | M: 421.47 / 2, grows with rail |
| `stock.scrollIndicatorWidth` | 3.04 | M: 6.08 / 2; height reflects scroll state, not fixed art |
| `cinePill` | 21.59 × 8.07 | M: vector bounds; current 28 × 11 |
| `actionSize` | 82.86 × 18.52 | M: 165.72 × 37.03 / 2; current full-width × 26 |
| `actionRadius`, `actionGap`, `actionLeading` | 9.26, 12.18, 13.33 | M/D: capsule, second x 108.37, first end 96.19 |

Do not replace the single shared `rowSpacing=9` with another universal gap:
Camera has mixed one/two-line blocks; Film uses a 22.5 pt pitch; stock rows
use 18 pt. Introduce component-specific rhythm tokens. Keep hit regions
independent of ink size, keyboard editing, focus and accessible labels.

Stocks now sit directly on the rail: **no lighter well background** and no
outer well clipping radius. The white selection itself is rounded and inset,
unlike today's full-width rectangular gray band. Positive and Negative are
separate visible film groups, each with a scrollbar in the illustration.
Print has its own list. Reference shows 3 positive, 4 negative and 4 print
rows; these are reference viewport counts, not a filtered catalog or permission
to remove entries. Existing odd-row centering assumes the old scroll layout;
a grouped implementation must use complete row alignment and update that
assumption rather than blindly reuse the odd-count rule.

Right plot content: retain live `HistogramPlot` and `CurveEditor`. The AI
contains embedded raster plots with example data, Chinese labels and an
eyedropper; those are references, not assets to place in the app. Approximate
visual targets: histogram about 256 × 45 pt, curve reference image about
256 × 225 pt. Keep channel tabs, draggable curve points, input/output readout
and eyedropper. Expanded right sections not drawn use the same control roles.

## 4. Color tokens

The AI uses CMYK fills. A Poppler raster produced ground `#585B61`, while
the supplied screenshot has `#5F5F5F`; do not treat a renderer's CMYK-to-RGB
conversion as the intended UI palette. The following are **S, provisional
screenshot RGB samples**, not recovered Illustrator RGB swatches. Convert
through an agreed color-managed workflow if exact source swatches are needed.

| Semantic token | v3 sample | Current Theme role |
|---|---|---|
| `surface.canvas`, `surface.control` | `#5F5F5F` | `ground`, `pill`; retain separation of names |
| `surface.rail`, `surface.toolbar`, `surface.stockList` | `#2D2D2C` | `card`; stock list must stop using `well = ground` |
| `ink.primary` | `#F9F7F3` | `text` |
| `ink.muted` | `#898989` | `dim` |
| `separator` | `#B5B6B6` | `rule` |
| `accent` | `#E1A95F` | current `#ECA650`; sample-based, not an exact source swatch |
| `selection.fill` | `#FFFFFF` | current `#C9CACA` |
| `selection.text` | `#0F0E0E` | current `#0E0E0E` |
| `action.fill` | transparent | no gray plate; active outline/text accent, inactive outline/text muted |

Preserve `disabledOpacity=0.38` as P until checked visually. Muted inactive
Original is not automatically disabled. Disabled text and control must gray
together via the existing row policy. Use dynamic accent states for selected
tools/compare; the drawing only depicts a static state. Plot/channel and
temperature/tint gradient colors keep their existing semantic roles; do not
sample a photograph or embedded histogram into the general UI palette.

## 5. Typography

**All text uses SF Pro Bold, explicitly confirmed by the user.** Apply
`.system(size: ..., weight: .bold)` to every text role below, including values,
captions, stock entries and CINE. Weight is not an unresolved design decision.
The PDF's embedded `SFPro-Regular` name and weight-400 metadata do not override
this instruction. Use the PDF text data for sizes, not for choosing weight.
The current Theme's all-bold policy is correct and must be preserved.

| Proposed font role | pt (M) | Applies to |
|---|---:|---|
| `railTitle` | 12 | Develop, Edit |
| `leftSectionTitle` | 12 | Input / Camera, Film, Print, Crop |
| `rightSectionTitle` | 10.5 | Histogram, White Balance, Exposure, Curve, Color Balance |
| `cameraLabel`, `controlValue`, `stockItem`, `asShot` | 9 | Camera controls, stock entries, value/menu text |
| `filmLabel`, `stockGroup`, `edrLabel`, `zoomValue` | 10.5 | Film controls, Positive/Negative, EDR, percentage |
| `action` | 13.11 | Developed, Original |
| `cine` | 5.71 | CINE; very small, optical QA required |

These are font sizes, not glyph ink heights. Keep monospaced digits for
changing numeric values as P. Do not globally repoint `Font.Export`, which
currently aliases editor roles: this task's drawing only specifies the main
editor. Capture current export values before any later shared-token migration.

## 6. Icon ownership: SF Symbols versus custom

“SF Pro icons” means **SF Symbols**; SF Pro is the text family. Names below
are implementation mappings, not claims that Illustrator embeds SF Symbols.
Use monochrome template rendering with semantic ink/accent and preserve aspect
ratio. Symbol availability should be checked against the deployment OS.

| Location / role | Source | Mapping / guidance |
|---|---|---|
| Develop header: import | SF Symbols | `square.and.arrow.down`; v3 depicts a square/container, current uses `tray.and.arrow.down` |
| Develop header: export | SF Symbols | `square.and.arrow.up` |
| Toolbar: Select | SF Symbols | `cursorarrow` |
| Toolbar: Pan | **Custom** | v3's tilted hand with surrounding curved marks. Plain current `hand.raised` is not the same silhouette; extract/trace v3 vector later, do not use a bitmap crop |
| Toolbar: Crop | SF Symbols | `crop` |
| Toolbar: Before/After | **Custom, existing** | Reuse `BeforeAfterIcon`; canonical geometry in `../control_asset/SVG/资源 1.svg`. Outline left, filled right, divider; compare opacity/aspect against v3 |
| Toolbar: Zoom out / in | SF Symbols | `minus.magnifyingglass`, `plus.magnifyingglass` |
| Toolbar: Fullscreen | SF Symbols | `arrow.up.left.and.arrow.down.right`; inverse `arrow.down.right.and.arrow.up.left` when fullscreen |
| Camera and Film header: reset | SF Symbols | `arrow.counterclockwise`; new visible affordance, scope unresolved (§8) |
| Camera neutral picker | SF Symbols | `eyedropper`; connect to existing picker only |
| Curve neutral picker | SF Symbols | `eyedropper`, already used in `CurveEditor` |
| All section disclosures | **Custom, existing primitive** | `Triangle` outline, down open / right closed; not filled `triangle.fill`, not an open chevron |
| Section overflow menus | SF Symbols | `ellipsis` horizontal, not vertical; existing `EllipsisGlyph` can be replaced only when implementing. Do not create inert/empty menus |
| Menu/picker disclosure | **Custom primitive** | small outlined down triangle as drawn; reuse disclosure geometry at ~6.9 × 4.1 pt |
| Filmstrip left/right navigation | **Custom primitive for exact v3** | closed outlined triangles, same disclosure family rotated; current `chevron.left/right` are open chevrons |
| Sidebar collapse/restore (not drawn) | SF Symbols, preserve | `sidebar.left`, `sidebar.right`; placement issue §8 |
| Filmstrip collapse tab (not drawn) | existing control, preserve | retain bottom hover-tab behavior and its existing symbol |
| Checkboxes, selection capsule, CINE pill, scrollbar, slider | **Custom control geometry, not icons** | drawn primitives and text; no asset export or symbol substitution |
| Develop/Edit titles | text, not icons | remove the inert right `slider.horizontal.3` only as part of future header layout |
| Window traffic lights | native AppKit | never trace/draw replacement icons |

Suggested visual sizes: toolbar standard glyph box 20–22 pt, header actions
18 pt, reset about 8–9 pt, overflow about 15 × 3 pt, disclosure 12.17 × 7.22
pt. The standard boxes are D, informed by M bounds: zoom ≈21.3 × 21.6,
Select ≈12.9 × 16.6, Pan ≈21.4 × 16.5, Crop ≈17.9 × 19.6. Optical alignment
matters more than stretching every silhouette to a square. Preserve at least
28 pt toolbar / 26 pt rail-action hit regions and non-overlapping hit targets.

## 7. Behavior map to preserve

This is a source read, not a claim of runtime testing this session.

| Area | Existing behavior / future layout constraint |
|---|---|
| Open / export | `session.openPanel()`; export sets `showExport`, consumed by EditorWindow to open the separate export scene sharing Session |
| Metering | Visual rename of `AE Method`; `session.aeMethod` retains offered values and legacy restoration. Custom means auto-exposure off |
| Film Exposure | `params.exposureCompensationEV`, -4…4 with 1/3 EV snap; As Shot delegates to `setFilmExposureAsShot` |
| Camera WB | Decode-side temperature/tint and per-axis As Shot state; RAW applicability and disabled reasons remain. Picker currently lives in Camera menu |
| Vignetting | `adjustments.vignette.amount`, Layer 2 despite its location on left rail |
| Lens Correction | Decode-side `setLensCorrection`; honor `lensCorrectionEnabled` and reason |
| Film stock | Preserve IDs, declared-paper selection logic, `applyFilmStageRule`, and positive-film handling. Group by catalog metadata, not names or artwork order |
| Film Format | Visual rename of Film Type. Retain frame/side/length derivation of engine long-edge millimeters, unit conversions and Custom-only editability |
| Grain/Halation/Glare | Existing engine Boolean bindings; crop re-maps physical format only according to the existing setting |
| Print stock | Preserve scan-film sentinel, remembered paper, positive-film disabled papers, declared pairing, and fast-flip semantics |
| EDR | Engine print parameter, applies to canvas/proof/file; disabled in scan-film mode. Drawing's absent helper text is not permission to change scope |
| Process / Original | Current Process invokes `solveNow`; Original toggles `showingOriginal`; Space is temporary original. Developed is a semantic question (§8) |
| Right rail | Histogram reads adjusted image; WB/Exposure/Curve/Color Balance edit `session.adjustments`, not engine params |
| Canvas tools | Existing select/hand/crop gestures and shortcuts; compare capability gating; crop zoom locking; zoom menu including Fit |
| Filmstrip | `Session.click(_:command:)`, relative selection arrows, lazy thumbnails, rendered updates, context menus, and `Session.framing(of:)` outlines remain |
| Window | Persistent rail width/disclosure/collapse state, always-available restore controls, fullscreen state read from actual window |

Do not change `Session.openDelta` (sidecar + preview size + `product_defaults`),
warm-up before cache keys, Layer 1/Layer 2 separation, shared export/canvas
session, or `recomputeFilmFormat(beforeOpen:)` during layout work. The README
§8.1 names tests protecting these boundaries. Engine/render changes are not
necessary for this token translation.

## 8. Explicit handoff decisions, not silent implementation

1. **Developed vs Process (U):** artwork suggests a two-state view selector.
   Recommended future mapping is Developed → leave Original view, Original →
   enter Original view, using existing session API. Keep solve available through
   the existing Print menu. Do not rename the solve button to Developed and
   leave its solve action behind that label. This recommendation needs a
   behavior decision in the implementation session.
2. **Sidebar controls / traffic lights (U):** artwork omits both. Existing PRD
   requires sidebar controls always visible. Preserve those controls and native
   traffic lights; allocate header/toolbar space responsively. Record the
   resulting deviation from the reference rather than hiding functionality.
3. **Reset scope (U):** Camera currently offers reset film exposure; Film's
   menu resets stock or all effects. The two new reset arrows do not define
   whether they reset a whole section. Specify scope and tooltip before wiring.
4. **Shared WB As Shot (U):** drawing shows one line under Temperature/Tint,
   but app tracks two independent axes. Preserve independent semantics;
   combining controls requires defined mixed-state behavior. Do not silently
   couple temperature and tint to satisfy the screenshot.
5. **Histogram ellipsis (U):** drawn, but current Histogram has no actions.
   Keep omitted unless meaningful existing actions are assigned. An empty
   popup or inert three-dot button is not successful visual parity.
6. **Stock grouping (D/U):** positive/negative grouping is visible; independent
   scroll view behavior is inferred from two thumbs. Preserve the entire
   catalog and selection state, including No Print Profile, before choosing
   exact viewport behavior. Covered/hidden PDF text includes old Portra names;
   do not manufacture duplicate entries from text extraction.
7. **Color QA (U):** screen palette is sampled. Establish color equivalence in
   the real app. Typography is SF Pro Bold throughout; check size, alignment
   and clipping without substituting a lighter weight.

## 9. Next Claude Code session: bounded implementation guidance

Start with this file and `tokens-main-v3.json`, then inspect the source paths
above. Apply v3 roles to Theme only with explicit editor scope: global color,
font, control and `Font.Export` aliases currently affect the export page too.
Do not overwrite generic `well` to change only stock lists. Separate editor
stock, action and typography roles rather than causing export-page drift.

The numeric token changes alone cannot implement: toolbar order/shape,
full-height dividers, text rail headers, grouped rail-colored lists, inset
rounded selection, direct reset/picker affordances, or Developed semantics.
Those are future view changes. No Swift/source/assets/project generator changes
have been made as part of this handoff. No custom icon assets were fabricated.

When implementation is authorized, resolve §8; build and run focused layout,
frontend policy, WB and affected interaction checks. Check stock boundaries
for clipped rows and long labels; verify no-image, RAW and flat-file disabled
states, positive/negative films, Original/Developed, crop zoom locks, sidebar
restore, resizable/minimum window and fullscreen traffic lights. Existing
layout/compare tools target the older floating toolbar and must be updated
before their pass can count as v3 evidence. Do not assert old reference pixels.

Use a real-window capture to validate Metal canvas, traffic lights and actual
interactions; offscreen snapshots only validate their own layout path. Run the
fixture-backed full suite at integration/merge/push boundaries under repository
rules. UI-only work does not call for engine parity harnesses. This session
ran no app build/test suite because it changed specifications only.
