# What this is

This is the PRD alongside with the new UI system for both better fit for desktop app and more professional style, and a smoother SpektraLab Desktop userflow and mind model. The main page svg and screenshot reference is at modern_UI/reference_layout, and the export page is at modern_UI/reference_layout/Export_Page

## What is changed

Unlike the current version frontend, it is reworked to less 圆角矩形 and took more inspiration from codex / capture one's frontend, with white lines separating different functions (this is important, as the grid and token system would also incorporate that), and the main page expandable tab, except the bottom gallery view remains unchanged, moved to become sidebar.left and sidebar.right (all SF pro symbols) and clicking them would expand /collapse the side bars, hence these two buttons must also remain on the screen at any given time, but moves according to a good way. 

Also note that tone changed to AE methods in the new frontend, and it is now wired with the Film Exposure right beneath it. It's behavior is: take the linearized baseline as the +0.0 baseline (also "As Shot", clicking this automatically switches AE method to custom), and the different AE methods just adjust the exposure based on it.

How Temperature and Tint is wired remain unchanged.

The new Lens Correction works like this:
1. only RAW files can apply lens correction
2. If the RAW carries lens correction information already, i.e. Nikon NEFs, otherwise let core image handles it based on EXIF (The standard way). This option is non-selectable and the select button and the text greys themself.

Note that if one option is non-selectable, both the text and the input pill is greyed across the app.

The way to display selected film and print profile is also changed. As the screenshot, selected entries has shallow, instead of framed square around it, and the text turns from white to black.

Also note that the cinematic film rolls and the cinematic print profile now has an orange "CINE" pill follows it.

Now the film type, this is very important, as it goes straight into the grain, halation and glare calculation pipeline.
1. Film type: what type of film it is, includes the cine format (also has the orange pill behind it), the still format (110, APS, 135, 120, custom)
2. Side: decides whether the short side or the long side of the image in the pipeline is at the edge of each type of film (Should be easy to understand)
3. edge length (change the name to Side Length): cannot be changed unless custom is selected. Shows the actual Side length if non-custom film type is selected. Side Length also follows the side above, short means altering the short side width. mm, cm, and inch are provided, with input number below. Note that if a crop happens, user can decide in settings if the effects are recalculated.

I didn't draw the crop, since it just need to change it's layout to the new system, everything else works fine there.
---

## What landed — 2026-09-17

Four commits on `rfc019-decode-export-memory`, from `2cfcb12` to `1023ad3`.
The token derivation is `modern_UI/design/TOKENS-main-2026-09-17.md`; the
geometry is `modern_UI/frontend_architecture.md` §1–2.

**This is the appearance, not the essence.** Everything below is the visual
system and three behavioural wirings the PRD names. The information
architecture the reconstruction handoff asks for —
`Input / Film / Develop / Render / Grade`, a Reference default, recipes that
recompute at their own cost — is untouched. See
`handoff/HANDOFF-SPEKTRALAB-FRONTEND-RECONSTRUCTION.md` §14 for what that
leaves open.

| asked for | state |
|---|---|
| less 圆角矩形; white lines separating functions | **done** — three flush regions, 1 pt `#b5b5b6` hairline, and the hairline is the grid: sections, rails and the filmstrip are all separated by it |
| the expandable tabs become `sidebar.left` / `sidebar.right`, always on screen | **done** — each at the far end of its rail's header, moving onto the tool bar when that rail folds. `Tools/snapshot.sh` takes a fourth capture, `--folded both`, because nothing else can show it |
| the bottom gallery view unchanged | **done** — the filmstrip's hover tab is the only one of the four left |
| Tone → AE Method, wired with Film Exposure beneath it | **done** — `AEMethod`, and `Custom` is the engine's existing `camera.auto_exposure = false`. The As Shot box sets both halves |
| Temperature and Tint unchanged | **done** — same values, same boxes, same rules. The preset pill and the eyedropper moved into the section's "•••"; the drawing's Camera is five rows and neither is one of them |
| Lens Correction: RAW only, greyed when the file carries its own | **done** — `CIRAWFilter.isLensCorrectionEnabled`, greyed on a flat file and on a RAW reporting `isLensCorrectionSupported == false` |
| a non-selectable option greys its text **and** its pill, app-wide | **done** — `View.rowEnabled(_:)`, one modifier on the row |
| selection is a shallow band with black text, not a frame | **done** — `#c9caca` at the well's full width, `#0e0e0e` text. One `StockList` draws both lists |
| orange `CINE` pill on cine rolls, cine print profiles, cine film types | **done** — `.st2`, an accent outline rather than a plate |
| Film Type / Side / Side Length, feeding grain, halation and glare | **done** — the engine takes a long edge, and it is derived from the type, the side and **the photograph's own aspect**, so one `120` entry is right for 645, 6×6, 6×7 and 6×9 |
| Side Length editable only on Custom, showing the type's own value otherwise | **done** |
| a setting for whether a crop recalculates the effects | **done** — Settings → Rendering → "Crop re-maps the frame", **off** by default, which is also the physically true answer |
| Crop: new layout, everything else unchanged | **done** — rows moved onto the rail, no well, no section icon |

### Deviations, and why

- **The Enlarger section is kept**, collapsed and last. It is not in the
  drawing; it is also the only access to `print_exposure` and the two filter
  axes, and this PRD does not ask for it to go.
- **The tool bar's two large gaps are 40 and 46, not the drawing's 63.6 and
  85.2.** At the minimum window (1100 pt, a 540 pt bar) the drawing's spacing
  is 19 pt wider than the bar it is on.
- **`barInset` is 9**, the mean of the drawing's unequal 11.1 and 6.95: a bar
  that is not centred in its own column is a thing you can see.
- **The Camera section is 230 pt tall against the drawing's 241.35.** The
  drawing puts about 5 pt more air around each block that is not a slider;
  Film (309 against 310.6) and Print (176.5 against 170.45) are within 6, so
  the row rhythm is left self-consistent rather than tuned per section.
- **`Solve` is `Process`**, the drawing's word. The button is unchanged, and
  so is the complaint the reconstruction handoff makes about it.

### What this was checked against

`swift Tools/measure-layout.swift <capture> 2` — the previous
`compare-layout.py` measured four cards that no longer exist and needs Pillow,
which this repository may not depend on. At all three display shapes the
capture is **exact**: left rail 0…254, right 1632…1920, filmstrip 948…1080,
bar y 5…36 inset 9/9, and the two collapsed sections in the right rail pitch
at 31 against the drawing's 29–31.

Captured from the real app with a 45 MP NEF open: the `CINE` pill in both
lists, the selection band inverting a row's text while the pill stays accent,
Lens Correction live on a Nikon and greyed with no frame, both `sidebar`
buttons on the bar with both rails folded, and the bar at the minimum window
with nothing clipped.

Full suite: 347 tests, 0 failures. **No API route and no engine parameter was
added** — `auto_exposure`, `auto_exposure_method`, `exposure_compensation_ev`
and `film_format_mm` were all already declared, and Lens Correction never
reaches the engine at all.
