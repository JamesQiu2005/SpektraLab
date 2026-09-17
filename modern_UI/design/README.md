# Visual iteration — the snapshot harness

> **Current design target (2026-09-18):**
> [Main v3 tokens and Claude Code handoff](TOKENS-main-v3-2026-09-18.md), with
> [machine-readable tokens](tokens-main-v3.json), translates
> `reference_layout/Main/sample_frontend_v3.ai`. All text is **SF Pro Bold**.
> The handoff includes the SF Symbols/custom icon inventory.
>
> **The app implements it as of 2026-09-18.** `Theme.swift` carries the v3
> palette, metrics and the split type ramp; the tool bar is flush and 38 pt;
> the rail dividers run the full window height; the rails are headed
> *Develop* and *Edit*; the stock lists sit on the rail with a white inset
> capsule for the selection and the film list is grouped Positive/Negative;
> and the two capsules under the print list are a Developed/Original **view
> selector**, with solve still in that section's `•••` (handoff §8.1).
> `SpektrafilmTests/LayoutTests.swift` asserts v3's geometry and
> `StockListTests.swift` the list rules — the 2026-09-17 assertions those
> replaced are gone, per §9's "Do not assert old reference pixels."
>
> **What is not done, and is not evidence yet.** The two Swift tools below
> (`measure-layout.swift`, `compare-design.swift`) still measure the old
> floating bar and the old drawing's render, so **a pass from either is not
> v3 validation** — they have to be re-pointed first. No fresh capture has
> been taken. The custom Pan glyph (§6) is still `hand.raised`. Handoff §8.3
> (reset scope) is answered narrowly — Camera's arrow resets film exposure
> and Film's resets the stock, each saying so in its tooltip — and §8.5's
> histogram ellipsis is deliberately still absent. Colour (§8.7) and the
> 5.71 pt `CINE` type (§5) are open optical QA.
>
> [Simplified Chinese copy guide](LOCALIZATION-zh-Hans.md) keeps profile names
> and necessary technical identifiers in English. **It is wired as of
> 2026-09-18**: `Localization/Localization.swift` holds the setting
> (`Follow the system` / `English` / `简体中文`, persisted at `ui2.language`)
> and `Localization/Strings.swift` the two-language table; Settings ▸ Language
> switches it live, with no relaunch. Deliberately **not** an `.xcstrings`
> catalog — a bundle cannot be swapped under a running process, and
> `Resources/` is a folder reference, so a catalog there would be copied
> rather than compiled. Out of scope for that pass and still English: the
> Settings page's own copy, the export page, the menu bar, and the strings
> the guide's two tables do not cover.

| | |
|---|---|
| **What this is** | The loop that lets the interface be checked against the drawing without a human looking at it. |
| **One command** | `design/snapshot.sh [image]` → `design/snapshots/window-*.png` |
| **The frame** | `spektrafilm/tests/Test_image/Nikon Z7ii/_DSC0897.NEF` — always this one |
| **Measure it** | `swift Spektrafilm/Tools/measure-layout.swift design/snapshots/window-16x9.png 2` |
| **Date** | 2026-09-08 |

## The frame the captures use

Every committed capture is of **`_DSC0897.NEF`** (the Nikon Z7ii folder in the
`spektrafilm` tests tree, which the repository-root `tests` symlink reaches).
It is not arbitrary and it should not be swapped casually: a capture is read
by diffing it against the last one, and changing the photograph changes every
pixel of the canvas, the histogram, the curve and four thumbnails at once. A
real regression is then a needle in a frame-sized haystack.

The export page's capture is the same frame:

```
SpektraLab --snapshot 1490x990 out.png --export --open <frame> --wait 120
```

## How it works

The app itself has a snapshot mode:

```
Spektrafilm --snapshot 1920x1080 out.png [--open file.NEF --wait 90]
```

It opens its own `NSWindow` at that size, hosts the real `EditorWindow`, and
in `--open` mode runs the whole pipeline (Core Image decode → linear TIFF →
service `open` → `reprint` → texture) and waits for the print to land before
capturing. The Metal canvas is replaced by an offscreen render through the
same `Renderer` (`SnapshotCanvas`), so the capture shows the real render path
including Layer 2 and the histogram. `Tools/snapshot.sh` runs it at the three
shapes that matter: MacBook Pro 14" (1512×982), 16:9 (1920×1080) and the 21:9
display (3360×1418).

`measure-layout.swift` reads the capture and prints, in points, the three
regions' edges, the floating bar's rectangle and every hairline in both rails.
Under 2.5 pt of drift is a pass; the run recorded on 2026-09-17 was **exact**
at all three shapes — left rail 0…254, right 1632…1920, filmstrip 948…1080,
bar y 5…36 inset 9/9.

**That pass meant much less than it sounded like**, and this is the cautionary
note the harness exists under now. The interface it graded exact was the one
the user rejected outright: the type carried its hierarchy in neither size nor
ink, the film well cut its first and last rows through the glyphs, the left
rail drew five equal hairlines where the drawing draws three, and the Film
Type and Side pills were each as wide as their own word. None of those is an
edge, a bar or a hairline *position*, so none of them was measured.

The reason the gap could hide is worth keeping in mind whenever the drawing is
consulted: `sample_frontend.svg` contains 74 rectangles and **one empty
`<text/>` node**. Illustrator exported its type — SF Pro, which is what the
app is set in — as outlines and linked rasters, so a validator that reads the
SVG can confirm every rectangle in it and never learn that typography exists.

```
Tools/compare-design.swift <capture.png> <reference.png> [scale]
```

is the second half. It resamples the drawing's *render* onto the capture's own
pixel grid — `main_page.png` is 3706 × 2094 inside a **ground-grey** matte, so
it is neither the artboard nor a whole multiple of it — and then compares the
things an edge cannot show: separator inventory, text-line count, ink height
and stem width (and the spread of each), control heights and widths and their
right-edge scatter, well extents and whether any well clips a row, and the
rail's ink distribution. It exits non-zero on drift.

Two of its numbers, `mean ink height` and `mean stem width`, print as
`(context)` and never fail a run. Illustrator's rasteriser lays down thinner,
smaller ink than the macOS text system at the same nominal weight, so the
reference reads about 1 px light whatever the app does; chasing it would mean
shipping type lighter than the house face. The paired **spread** is the gate,
because that bias is common to every role and cancels.

`compare-layout.py` measured the *previous* drawing's four floating cards.
There are no cards to find any more, and it needs Pillow, which this
repository is not allowed to depend on; the Swift tool replaced it.

`Tools/snapshot.sh` also takes a fourth shot, `window-folded-both.png`, with
both rails folded (`--folded left|right|both`). That is the one state the
harness otherwise goes out of its way to reset, and the 2026-09-17 PRD makes a
requirement about it: the two `sidebar` buttons have to be on screen "at any
given time", so when a rail folds its button moves onto the bar, along with
the window buttons' clearance. Nothing but a capture shows that.

## What it cannot capture — and the harness that can

Hover, focus and drag: no pointer exists. Menus and sheets are not opened.

**The canvas.** `cacheDisplay` cannot see a `CAMetalLayer`, so snapshot mode
substitutes an offscreen render through the same `Renderer`. That covers the
render path and misses everything between it and the screen — which is where
two shipped defects lived at once: a drawable pixel format `CAMetalLayer`
rejects (the app crashed on launch) and a redraw that never reached the view
(the canvas stayed blank while every number behind it was right).

```
Spektrafilm/Tools/capture-live.sh [image.NEF]   # → design/snapshots/live-window.png
```

launches the real app, opens a frame, waits for the print, and asks the window
server for the pixels. It needs Screen Recording permission. It is the only
capture that proves the canvas draws — run it before believing it does.

## Two more things the harness itself got wrong

- **A titled window is clamped to the screen.** Asking for 1920×1080 on a
  smaller display quietly produced an 1800-point-wide capture, and every
  measurement against it was wrong by that ratio. The snapshot window is now
  borderless and never centred, so the capture does not depend on which
  display is attached.
- **A capture inherited persisted UI state.** A filmstrip collapsed in some
  earlier session removed a whole card, and `compare-layout.py` matched the
  missing card against the nearest one and reported drift instead of absence.
  Snapshot mode now resets the collapse flags, and the matcher requires a
  region of about the right size before it will call it a match.

## Reference

`modern_UI/reference_layout/Main/sample_frontend_v3.ai` is the drawing
(2026-09-18), with `layout_screenshot.png` as its appearance reference;
`Theme.swift` carries its numbers at artboard ÷ 2 and
`design/TOKENS-main-v3-2026-09-18.md` is the derivation of each one.

**The 2026-09-17 drawing is gone from the repository.**
`reference_layout/Main/sample_frontend.svg`, its nine linked rasters and the
`main_page.png` render were deleted with the redraw. `TOKENS-main-2026-09-17.md`
can therefore be *read* but not re-derived, and four things still cite files
that are no longer there: this file's own history above, `Theme.swift`'s
header, `modern_UI/frontend_architecture.md`'s Authority row,
`handoff/design-references/README.md`, and both comparison tools
(`Tools/compare-design.swift`, `Tools/compare-layout.py`), which take
`main_page.png` as their reference and so **cannot be run at all** until they
are re-pointed at the v3 artwork. That is the same thing as the warning at the
top of this file — an old harness pass is not v3 validation — stated as a
missing file rather than as a caveat.
