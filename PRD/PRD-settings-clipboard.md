# PRD — The settings clipboard (编辑配方的复制与粘贴)

**Date:** 2026-09-28 · **Author:** session notes from the user's design and one user report
**Implementation:** `rfc/RFC-027-settings-clipboard.md`
**Reference:** Capture One's *Adjustments Clipboard*. Copy with a set of ticked groups, then paste. The groups are chosen **at copy time**.

**Standing constraints**
- This is the **edit** recipe: how the photograph is printed. It is not the **export** recipe (`ExportRecipeStore`, RFC-018), which is how a finished print is delivered. The two never reference each other. An export recipe never carries an edit, because the export must match the canvas.
- Crop and geometry are **not** part of the clipboard in this version.
- Named presets (saving a clipboard as a reusable look) are the next step and are **not** in this PRD. §7 records what this design leaves ready for them.

---

## 1. Why

A user report after 1.1.x, verbatim:

> 我复制设置再应用到其他照片的时候有时候，会出现曝光和显示复制过去了，但是实际上再次选择胶片会发现似乎是没有成功复制…说不清。还有一些反差比较大的照片会出现整个曝掉的问题。……期待后期可以给一些设置组合做一个预设自定义存储。

Three problems are in there:

1. **"It copied, but not really."** This is a real defect: an edit that lands while a frame is developing never reaches the engine (RFC-027 §5.1). The interface shows the pasted film while the print is still the old one.
2. **"High-contrast photos blow out."** Today ⌘⇧V pastes the *whole* `FilmParams`. That includes the Scene Placement curve, which was solved against the *source* photograph's histogram. A curve fitted to a flat scene, applied to a contrasty one, is wrong (RFC-027 §5.2).
3. **"I can't say what got copied."** The clipboard is all-or-nothing and invisible.

The user's diagnosis of the design problem: **there are different pasting behaviours, and they should not be unified.**

- "Use this film and this paper on the whole roll."
- "Same scene: bring the exposure and white balance intent too."
- "Near-identical frames: bring the scene placement and the masks too."

The user chooses what to copy; the software does not guess.

## 2. The seven groups

Each group is one checkbox. The user's list, in the user's order:

| # | Group (zh / en) | What it carries | Where the controls are |
|---|---|---|---|
| 1 | 胶片&相纸 / Film & Paper | film stock, paper stock, *No print profile* (scan), EDR | left rail: Film, Print |
| 2 | 曝光 / Exposure | metering method (Tone), auto-exposure on/off, film exposure compensation, **enlarger brightness** | right rail: Camera; left rail: Enlarger |
| 3 | 白平衡 / White Balance | camera white balance (As Shot / preset / Kelvin + tint), **enlarger Y/M filters** | right rail: Camera; left rail: Enlarger |
| 4 | 胶片效果 / Film Effects | film format (135/120, side, side length), grain / halation / glare switches and strengths, scatter, DIR couplers | right rail: Film Format |
| 5 | 相纸效果 / Print Effects | the Print Effects switch, **pre-flash** | left rail: Print, Enlarger |
| 6 | 场景置位 / Scene Placement | highlight / shadow pull-back and the percentiles they are fitted to | right rail: Scene Placement |
| 7 | 遮罩 / Masks | the Tone Mask, and the local masks | right rail: Tone Mask (local masks are withdrawn behind `FeatureFlags.masks`) |

The user settled the placement of the enlarger's three controls and of the film format (2026-09-28): the brightness goes with Exposure, the filters with White Balance (in the darkroom, colour *is* the filter pack), pre-flash with Print Effects (the Print Effects switch already gates it), and film format with Film Effects (it sets the physical scale of grain and halation).

**Not copied by any group:**
- crop and geometry;
- the lens correction switch (a property of the lens, not of the look);
- the Post-Dev grade (显影后: white balance, exposure, curve, colour balance). Under the 2026-09-23 positioning it is not part of the product's editing model. ⌘⇧V used to copy it.

## 3. What a pasted value means: the setting, not the solved number

The user decided (2026-09-28): **a paste carries the setting, and the target solves its own numbers.**

- **Exposure** pastes the metering method and the compensation offset. The target meters itself. With auto-exposure off (*As Shot*), the offset is from the target's own linear baseline.
- **White balance:** *As Shot* pastes as *As Shot*, which is the target's own camera value, never the source's Kelvin. A preset (Daylight, Tungsten…) pastes as that preset. A custom Kelvin/tint pastes as those numbers, because there the number *is* the setting.
- **Enlarger filters** are offsets from the filter pack the target solves.
- **Scene Placement** pastes the pull-back ("hold the highlights back 2 stops"). The curve that achieves it is **fitted again on the target**. The source's fitted curve is never pasted. If the target cannot be fitted (the engine refuses: unmeasurable, no light), the placement is left off and the Scene Placement section says why.

This is what makes pasting onto a high-contrast frame safe.

## 4. Where it lives and what it looks like

**Left rail, directly under 导航 (Navigator), collapsed by default.** Section title: **设置剪贴板 / Settings Clipboard**.

No new drawing is needed. It is built entirely from existing rail parts: the section header, `ToggleRow`, the pill buttons the Navigator's *Fit* uses, and the metadata ink.

```
▽ 设置剪贴板
   胶片&相纸                 ■
   曝光                      ■
   白平衡                    ■
   胶片效果                  ■
   相纸效果                  ■
   场景置位                  ■
   遮罩                      ■
   剪贴板：DSC03710 · 5 项          ← metadata line: what the clipboard holds
   ( 复制 )  ( 粘贴 )               ← two pills
```

- **Checkboxes** are the choice for the *next* copy. They persist across launches. The default is all seven ticked, which matches what ⌘⇧V used to do.
- **复制 / Copy** takes the ticked groups **from the frame on the canvas** and replaces the clipboard. Greyed when no frame is open or nothing is ticked.
- **The metadata line** always says what the clipboard holds: the source frame and which groups. Changing a checkbox after copying does *not* change what is held. That is the copy-time model, and the line is how the user can see it. Empty: 剪贴板为空.
- **粘贴 / Paste** applies exactly what the clipboard holds to **every picked frame** (the ⌘-click selection, which always includes the frame on the canvas). With more than one picked, the pill reads **粘贴到 N 张**. Greyed when the clipboard is empty, no frame is open, or a batch export is running.
- **⌘⇧C / ⌘⇧V** and the canvas's right-click *Copy Settings / Paste Settings* are the same two actions, using the same checkboxes.

## 5. Behaviour the user must be able to rely on

- **R1 — What you see is what printed.** After a paste, the print on the canvas is made from the pasted settings. That includes a paste made the instant a frame is opened, while it is still developing. (This is the defect in §1.1.)
- **R2 — A pasted frame never shows its old look.** A picked frame that is not on the canvas gets its settings written at once. Its old print is discarded, and it is marked as needing a render. When the user opens it, it develops with the pasted settings, not with the old print or a bare decode.
- **R3 — Only ticked groups change.** Every field outside the pasted groups is left exactly as it was on the target.
- **R4 — Undo.** On the frame on the canvas, one ⌘Z undoes the whole paste. On other picked frames, a paste cannot be undone in this version. The status line says how many frames were written.
- **R5 — Film & Paper keeps the film list's rules.** A slide film is scanned (no paper), and pasting it keeps it scanned.
- **R6 — Paste is disabled during a batch export**, like every other edit.

## 6. Acceptance

- The user report's first symptom cannot be reproduced. There is a test that pastes during a develop and checks the **print**, not the interface.
- Pasting Scene Placement from a flat photograph onto a contrasty one produces the contrasty photograph's own fit. A test compares the pasted frame's curve with the curve the same pull-back fits on that frame directly.
- Each group, pasted alone, changes its own fields and no others. A test enumerates every stored field, so a new field that is not assigned to a group (or explicitly to *not copied*) fails the build's tests.
- Pasting to three picked frames writes three sidecars, and opening any of them shows the pasted look.

## 7. Next (not in this PRD)

- **Presets:** a clipboard saved under a name, applied with the same groups. The clipboard's value (groups plus the source's settings) is already the preset's shape.
- **Undo across frames** for a multi-frame paste.
- **Crop** as an eighth group, once the crop work settles.
- A **"lock the number"** variant for Exposure and White Balance (same-scene series shot in manual). The user chose settings-only for now.
