# The main window's tokens — 2026-09-17 drawing

> **Superseded.** This is the historical derivation of the 2026-09-17
> drawing. The implemented layout is [Main v3](TOKENS-main-v3-2026-09-18.md),
> derived from `sample_frontend_v3.ai` and in the app since 2026-09-18 — see
> `README.md` for what of it is done and what is still open. All v3 text uses
> SF Pro Bold.
>
> Kept, not deleted, because several numbers below are still the ones in
> `Theme.swift`: v3 re-measured the bar, the lists, the type ramp and the
> slider ink, and left the three region widths, the filmstrip, the hairline
> and the collapse tab where this drawing put them. Where the two disagree,
> v3 wins; where v3 is silent, this is the derivation. `sample_frontend.svg`
> itself is gone — the drawing this file measures is no longer in the
> repository, so nothing here can be re-derived, only read.

| | |
|---|---|
| **Drawing** | `modern_UI/reference_layout/Main/sample_frontend.svg` |
| **Render of it** | `modern_UI/reference_layout/Main/main_page.png` |
| **PRD** | `PRD/Frontend_Rework_2026-09-17.md` |
| **Implemented in** | `Spektrafilm/Theme/Theme.swift` |
| **Checked by** | `SpektrafilmTests/LayoutTests.swift`, then `Tools/snapshot.sh` |

This is the derivation. Every number in `Theme` that is not obvious comes from
a rectangle or a line in the drawing, named here with the coordinate it came
from, so that a token can be argued with rather than only obeyed.

## 0. The scale

The artboard is `viewBox="0 0 3840 2160"`. Three of the previous drawing's
tokens reproduce in it at 2 — the well radius (`rx 22.9` → 11.5), the
collapse tab (`27.8 × 83.1` → 14 × 41.5) and the zoom pill (`210.5 × 41.4` →
105 × 20.7) — so the scale is **2** and the window it describes is
**1920 × 1080 pt**. Every number below is the drawing's divided by two.

`main_page.png` is a *render* of that drawing, not the drawing, and it is not
pixel-aligned with the artboard (3706 × 2094 against 3840 × 2160, with a
border). It is used here for **appearance** — what a control looks like, which
colour won, where the text sits inside a pill — and never for geometry. The
SVG's own rectangles are the geometry.

## 1. What changed, in one paragraph

The four floating rounded cards on a ground are gone. The window is three
flush regions: a full-height left rail, the centre, a full-height right rail,
separated by **1 pt hairlines**. There is no outer margin, no gutter and no
card radius, so `outerX`, `outerY` and `gutter` stopped being tokens —
a rail flush with the window's edge has nothing to be inset by. `cardRadius`
survives only because the export page still draws rounded cards with it.

The one thing that still floats is the tool bar.

## 2. The frame

```
  0        254                        1632      1920
  ┌─────────┬──────────────────────────┬─────────┐  0
  │ header  │      ▁▁▁▁ bar ▁▁▁▁       │ header  │  38
  ├─────────┤                          ├─────────┤
  │  left   │         canvas           │  right  │
  │  rail   │                          │  rail   │
  │         ├──────────────────────────┤         │  948
  │         │        filmstrip         │         │
  └─────────┴──────────────────────────┴─────────┘  1080
```

| Token | Drawing | ÷2 | Token value |
|---|---|---|---|
| `leftPanelWidth` | `rect .st15 x -2.6 w 509.9` | 254.95 | **254** |
| `rightPanelWidth` | `rect .st15 x 3263.9 w 576.1` | 288.05 | **288** |
| `filmstripHeight` | `rect .st15 y 1895.3 h 264.7` | 132.35 | **132** |
| `panelHeaderHeight` | first hairline, `y 75.6` | 37.8 | **38** |
| `rule` | `.st1 stroke-width 2px` | 1 | **1** |

All three rectangles run to the window's edge and all three hairlines run the
full width of their rail (`line x1="-4" … x2="505.9"` on a rail whose own
edges are 0 and 254 — a person drawing "edge to edge", which is what the rule
is for). No inset anywhere.

The filmstrip spans the **centre column only**; the two vertical hairlines at
`x 508.8` and `x 3263.6`, y 1895…2160, are what separates it from the rails.

### Rounding to 38

`panelHeaderHeight` is the drawing's 37.8 rounded up rather than down, so that
`trafficLightCentreY` is a whole 19. Half a point of header against a window
button that lands on a pixel is the right way round to spend it.

## 3. The floating bar

`rect .st15 x 529 y 9.4 w 2721 h 61.8 rx 28` → a rounded pill at
`(264.5, 4.7) 1360.5 × 30.9 r14`, on the ground, over the canvas.

| Token | Value | Where from |
|---|---|---|
| `topBarHeight` | 31 | 61.8 / 2 |
| `barRadius` | 14 | `rx 28` / 2 — the drawing's number, not `height / 2` |
| `barTop` | 5 | 9.4 / 2 |
| `barInset` | 9 | see below |
| `barStrip` | 41 | `barTop × 2 + topBarHeight` |

**`barInset` is a judgement.** The drawing's gaps are 11.1 leading and 6.95
trailing, which is a sketch being a sketch: a bar that is not centred in its
own column is a thing you can see. 9 is the mean of the two.

**`barStrip` is the other judgement.** The drawing puts the bar *over* the
ground rectangle, and the ground is also the canvas surround, so the drawing
does not say whether a picture may pass under the bar. The centre column
reserves the strip, which is the only arrangement in which a maximised frame
is not partly under a toolbar — and it is what the drawing looks like, because
there is ground above and below the bar in it either way.

## 4. The window buttons

`.windowStyle(.hiddenTitleBar)` floats the three buttons over the content;
they are *placed* (`Windows/TrafficLights.swift`). The row they are placed on
is the **rail header's** — the window's first row, `y 0…38`, which is also the
row the bar's centre falls in (the bar spans 5…36, centre 20.5, against the
header's centre 19).

That coincidence is what makes the buttons stay still when the left rail
folds: one centreline serves both rows, so nothing moves. What changes is only
which of the two *reserves* the space — the header when the rail is open
(`trafficLightClearance`), the bar when it is not (`barLeadingWithButtons`).

`trafficLightLeading` is 20, and it is not the drawing's: the drawing has no
window buttons in it at all, and puts the import glyph at x 10. 20 is where
macOS puts a close button, and the import glyph moves right to clear it.

## 5. A section on a rail

A section is a header row, its content, and a hairline.

The two **collapsed** sections in the drawing measure the header directly:
White Balance is `130.6 → 159.65` and Exposure is `159.65 → 190.7`, so 29.05
and 31.05. `headerHeight` is **30**.

The **expanded** ones agree within the drawing's own noise: Camera puts its
first control 27.25 below the rule above it and Histogram puts its plot 30.75
below.

| Token | Value | Where from |
|---|---|---|
| `headerHeight` | 30 | the two collapsed sections |
| `sectionBottom` | 12 | air before the next rule: 14.6 (Camera), 10 (Film), 10.75 (Print) |
| `headerLeading` | 7 | so the 12 pt triangle in its 18 pt box lands on the drawing's x 11 |
| `headerTitleGap` | 7 | so the title lands on the drawing's x 32 |
| `headerTrailing` | 10 | the "•••", `x 229.55 w 15.15` on a 254 rail |
| `disclosure` | 12 × 7 | `rect .st10 24.3 × 14.5` |

The two rails disagree about the header's leading in the drawing — the left
puts its triangle at 11 and its title at 34, the right at 3.5 and 23 — and
they are unified here at the left rail's. Two columns that are nearly the same
read as a mistake; one that is the same reads as a system.

## 6. A row on a rail

Measured off the drawing: labels start at **17.6** and value pills end at
**235.6** on a 254 pt rail. So the row is inset 18 from both edges, and its
interior is 218 wide.

| Token | Value | Where from |
|---|---|---|
| `rowInset` | 18 | 17.6 leading, 254 − 235.6 trailing |
| `controlHeight` | 14 | every pill and field, `h 27.8` |
| `rowHeight` | 20 | the line box a control sits in |
| `rowSpacing` | 5 | so a two-line slider block pitches at 40 (drawing: 39.8) |
| `subRowHeight` | 15 | the "As Shot" line (drawing: 15.6 below its label) |
| `sliderValueWidth` | 44 | `w 87.5` |
| `sliderValueGap` | 14 | 191.85 − 176.8 |
| `pickerWidth` | 112 | `w 214.1`, right-aligned — Film Type and Side |
| `fieldWidth` / `unitWidth` | 50 / 38 | `w 99.5` and `w 76.6`, the Side Length row |
| `toggleRowHeight` | 17 | Grain/Halation/Glare pitch 21.25–22.25 with `rowSpacing` |
| `fieldRadius` | 4.25 | `rx 8.5` — *not* a capsule, unlike the menus' `rx 13.9` |

### `sliderLabelWidth` is 74, and the drawing says 68.35

The drawing's label column is 68.35 (labels at 17.6, first control at 86.35)
and `Film Exposure` fills 66 of it **there**, at Illustrator's optical size.
macOS sets the same string wider — this is the same four-to-six points the
export page paid for its own label column — and a truncated label is worse
than a column six points wide.

### Two column rules, not one

`AE Method` **fills** the row after its label (86.35 → 235.6 = 149.25, which
is 218 − 68.35). `Film Type`, `Side` and the unit pill do **not**: they are
drawn 107 wide and right-aligned. Both rules are in the drawing and both are
kept.

## 7. The lists

| Token | Value | Where from |
|---|---|---|
| `wellInset` | 4 | well `x 9.4 w 491.7` on a 254 rail: 4.7 and 3.45 |
| `wellRadius` | 11.5 | `rx 22.9` |
| `wellPadding` | 12 | list text starts 11.9 inside the well |
| `listRowHeight` | 19.5 | selection band `h 39.2` |
| `cinePill` | 28 × 11 | `rect .st2 55.2 × 20.6 rx 10.3` |
| `cinePillTrailing` | 11 | 250.55 − 239.8 |

**Selection is a band, not a frame.** `.st16 #c9caca`, the full width of the
well and exactly one row tall, with the row's text inverted to near-black.
The PRD's own words: "selected entries has shallow, instead of framed square
around it, and the text turns from white to black".

The `CINE` pill is `.st2` — `fill: none; stroke: #eca650; stroke-width: 2px` —
so an outline in the accent, not a plate.

## 8. The two actions

Process / Original: `rect .st13 h 52.6 rx 16.5`, at `x 6.6 w 241.3` and
`x 252.4 w 245.8`. So **26 pt tall, radius 8.25** — a rounded rectangle and
deliberately not a capsule, which at that height would be 13.15 — with a 2.25
gap, spanning the same 4 pt inset the wells above them have.

## 9. Sliders and the checkbox

| Token | Value | Where from |
|---|---|---|
| `trackHeight` | 1.5 | `rect h 2.7` |
| `knobSize` | 7 × 7 | `rect 12.3 × 10.1 rx 5.1` → 6.15 × 5.05, fully rounded |
| `knobRadius` | 3.5 | as above: a dot |
| `checkbox` | 8 | see below |

The track is `.st13` — **the same grey as the ground**, not a dim grey of its
own. At 1.5 pt that is the whole reason the track reads as a track rather than
as a divider, so the thinness is load-bearing.

The checkbox is `rect .st3 9.9 × 9.9`, `fill: #eca650; stroke: #faf8f4;
stroke-width: 2px` — 5 pt of accent inside a 1 pt white box. 5 pt is below
what the eye resolves as a shape on a dark rail; 8 is the same drawing at a
size that reads, and its hit area is padded well past it.

## 10. Colour

| Token | Hex | Class | What it is |
|---|---|---|---|
| `ground` | `#5f5f5f` | `.st13` | canvas surround **and** every well, pill and track |
| `card` | `#2c2d2b` | `.st15` | the two rails and the filmstrip |
| `rule` | `#b5b5b6` | `.st1` stroke | the hairline |
| `text` | `#faf8f4` | `.st12` | |
| `knob` | `#fbf8f3` | `.st18` | a hair warmer than `text`, in the drawing |
| `accent` | `#eca650` | `.st17` / `.st3` / `.st2` | **changed** from `#ee8a2b` |
| `selection` | `#c9caca` | `.st16` | the chosen row's band |
| `onSelection` | `#0e0e0e` | `.st1` fill | its text |

The palette got *smaller*: one grey does the work four tokens used to. A
control is a lighter shape on a darker rail — elevation, not hue — and the
hairline does what a gutter used to.

`field` (`#2c2d2b`, a pill **inside** a well) stays for the export page, where
the well is already ground-coloured and a control on it has to be darker to be
seen. It has no use on an editor rail any more.

## 11. Type

Cap heights off the render, halved: a section title is 8.1–8.8 pt (so a 12 pt
face), a row label and a list row are 7.25 (10.5), "As Shot" is smaller again
(9), and the two actions are a step up from a label (11.5).

Everything is semibold or heavier. The drawing sets every string in a bold
face, and at 10.5 pt on a dark ground a regular weight disappears.

## 12. What is a judgement rather than a measurement

Listed in one place, because these are the ones to argue with:

- `barInset` 9 — the drawing's two gaps differ by 4 pt (§3).
- `barStrip` — the drawing does not say whether a picture may pass under the
  bar (§3).
- `trafficLightLeading` 20 — the drawing has no window buttons (§4).
- The unified header leading (§5).
- `sliderLabelWidth` 74 against the drawing's 68.35 (§6).
- `checkbox` 8 against the drawing's 5 (§9).
- `leftPanelRange` 232…380 — nothing in the drawing bounds a rail it draws at
  one width; the floor is the AE Method row's own content and the ceiling is
  where the only thing still growing is a slider's track.

## 12. 2026-09-17, later: what the rectangles could not say

The tokens above are all derived from the drawing's **rectangles**, and every
one of them still holds. The interface built from them was rejected anyway,
and the reason is in the derivation's own blind spot: `sample_frontend.svg`
has 74 rectangles and one empty `<text/>` node, so nothing in this document
could be about type, weight, ink or rhythm. Section 0 says `main_page.png` is
"used here for **appearance** … and never for geometry" — but typography *is*
geometry, and it only exists in that render.

`Tools/compare-design.swift` measures it there, and these tokens moved as a
result. The numbers are the drawing's render resampled onto the capture's grid
(scale 1.9204, ground-grey matte at 9, 12).

| token | was | now | why |
|---|---|---|---|
| `Font` sizes | 12 / 11.5 / 10.5 / 10 / 9 / 7 | 12.5 / 11 / 9.5 / 8 | six sizes over eleven roles read as noise; the drawing's ink-height spread is 4.0 pt against the built rail's 7.0 |
| `Font` weights | bold / semibold / medium / regular | **bold throughout** | the drawing is one weight, so its stem spread is 1.0 px; mixing weights took the built rail to 2.99. Unbolding made it *worse* |
| `Ink` | — | primary / secondary / tertiary | the hierarchy the ramp deliberately stopped carrying |
| `rowSpacing` | 5 | 9 | the drawing's largest gap in the left rail is 35.5 pt; the built rail's was 24 |
| `rowHeight` | 20 | 22 | with the above, gives back the 36 pt the Camera section was short |
| `toggleRowHeight` | 17 | 21 | the drawing's pitch is 21.25–22.25 and 17 was under it |
| `sectionBottom` | 12 | 16 | as `rowSpacing` |
| `trackHeight` | 1.5 | 3 | a 1.5 pt track in the ground's own grey is *thinner than the hairlines beside it* |
| `knobSize` | 7 | 10 | smaller than the value pill's corner radius |
| `sliderLabelWidth` | 74 | 84 | "Film Exposure" truncates in the bold face at 74 |
| `wellVPadding` | — | 8 | rows ran flush into the 11.5 pt corner radius |
| `checkbox` | 8 | 9 | and its *off* state is inked `tertiary`, not `text` |

Three defects were structural rather than numeric, and are recorded here
because a token cannot hold them:

- **The film well showed six rows.** `StockList` centres the selected row, so
  the rows land on the well's edges only at an **odd** count; at six, every
  row sat half a row out of register and the first and last were cut through
  the glyphs. Now five, asserted by `testStockListShowsAnOddNumberOfRows`.
- **A rule after the last section.** `LeftPanel` was `Section(); Hairline()`
  repeated, which draws a border under the final section against empty rail,
  and with a collapsed Crop last it put two rules 31 pt apart. The hairlines
  go *between* sections now, and the rail carries four where it carried five
  — the drawing has three.
- **Non-filling pills hugged their text.** `.frame(maxWidth:)` under a
  `.fixedSize(horizontal: true)` resolves to the intrinsic width, so Film Type
  came out 42 pt and Side 44 pt with a different left edge on each row.

### Still drifting

`rule count` 4 v 3, `last ink` 883 v 780 — the rail holds more content than
the drawing does, which is a product decision (catalogue length, how many
sections) and not a token. `control width spread` now reads 96 against 111
because the pills are *more* uniform than the drawing's, which is drift in the
harmless direction. The export page has not been through any of this.
