# The 图层 (Layers) panel, and the double exposure on the Mac: the design

Status: **drawings and spec for the owner's approval. Nothing is built.** Date: 2026-11-11.
Branch `mac/layers-2026-11-11` (off the integration branch at 5c5b890d). Brief: PRD-D §3.6, §3.7, §5b, §6
(`PRD/PRD-D-lens-film-edge-double-layers-2026-11-11.md`).

The drawings are the 44 SVGs beside this file, each with a PNG at 2x. They are generated
(`src/gen_layers.py`, `src/kit.py`), so a number changed here is changed there and drawn again:

```bash
python3 app/SpektraLab/design/layers/src/gen_layers.py --png      # every drawing, and its PNG
python3 app/SpektraLab/design/layers/src/gen_layers.py --strings  # §9's table
```

The generator refuses to draw a line that does not fit its room (`fits`), in either language; it stopped three
times while these were made, and each stop became a wider menu, a wrapped note or a shorter sentence.

**Units.** One unit is one scene point of the develop page (`PAGES.md` §1): 0.9625 of a Mac point at the 100 %
interface scale. The column is 393 units, 378 Mac points; `screenshots/Screenshot_v2.png` has its wall at
377. Every number of an existing part is that part's own, read from its Swift file. The pictures are vector
stand-ins for the engine's develop, and the film and paper cards' names are left as bars: neither is this design's.

## 1. What is fixed, and what this adds

The owner's decisions (PRD-D §6, and the brief) are taken as they stand: one panel, 图层, in both 冲洗 and 编辑,
keeping its selection and fold across the modes; 胶片 on top, then 左格 · 右格 (上格 · 下格 turned) or 上层 · 下层;
a picked row scopes the column; the double exposure's entry is 图库's 合成; the eye shows an exposure alone; no
opacity on a pair; no masks, brushes or AI in this release.

What the design adds, in one paragraph: the panel is **a second card under the histogram**, the same shell,
pinned above everything a mode owns. **胶片 picked is the column as it is today**, with one section added at the
top of 格式 for what only a pair or a double has. **A picture's row picked is that picture's own page**: one
scroll holding only what is that picture's, and one row at its foot leading back to 胶片. **Balance lives in the
panel**, where Capture One keeps 不透明度, so it is there whichever row is picked and develops while it is dragged.

## 2. Anatomy and measurements

Drawings `28-anatomy`, `29-row-states`.

The card is `HistogramPanel`'s shell: `Theme.plot`, radius 12 (continuous), 12 from each side of the column, so
369 wide in the narrowest column and growing with it. It follows the histogram's own 6 underneath, and has 6
under itself.

| part | measure | type and ink |
|---|---|---|
| head | 32 high; the chevron's centre 20.5 from the card's left; the title from 34 | `chevron.down` 10 semibold `secondaryText`, turned −90° folded; 图层 13 semibold `text` |
| head, trailing (unfolded) | ⋯ on a 22 disc (`Theme.card`), 10 from the card's right | `ellipsis` 11 bold |
| head, trailing (folded) | the picked row's name, ending 14 from the card's right; an accent `eye` 10 before it while an exposure is shown alone | 12 medium `secondaryText` |
| row | 30 high; its capsule 28 high, radius 6, 6 from the card's sides | |
| eye | a 20 slot from 4 inside the capsule; lit: a 22 × 18 accent ground, radius 5 | `eye` / `eye.slash` 11 medium |
| thumbnail | 30 × 20 slot, the picture fitted in it, radius 3; 胶片 wears `film` 13 medium there | |
| name | 8 after the thumbnail | 13 medium `text`; semibold `onSelection` when picked |
| trailing value | ends 10 inside the capsule | 12 medium, tabular digits, `dim` |
| under the last row | 6 | |
| Balance (a filled double) | a half-point `Theme.rule` 14 from the card's sides, then `ValueSlider` 40 high, 14 from the card's sides, its number's box 62 wide; 4 under | the slider's own type |
| foot note (an empty layer or hole) | 4, the note at 16.3 a line, 8 | 11.5 regular `dim`, wrapped, never cut |

Heights: **32** folded, and for a single frame; **128** a pair; **172.5** a double; with an empty layer Balance
goes and the note comes. `LayersPanel.height(...)` is a static function of the piece and the fold, as
`HistogramPanel.height()` is, because the column gives the panel under it the room that is left.

Density, against the HIG and the owner's rule: a row is 30 units, 28.9 Mac points (the HIG's medium sidebar row
is 28). New type is never under 11.5 units, 11.07 Mac points. The one smaller line is `ValueSlider`'s own 10.5
sub-label, which is that slider's everywhere in the column and is not changed here.

Selection is the white capsule (`Theme.selection`), never the accent. The accent appears twice, both states:
the lit eye, and "平衡 → 67 %" beside an exposure's own stops (§6.4).

## 3. Where it sits

**The left column, directly under the histogram, pinned, in both modes** (drawings 01–04).

`PadDevelopPage.column` becomes: histogram, 图层, then the mode's own (冲洗's 胶片与相纸 | 格式 band and its
scroll; 编辑's tool list). The reasons:

1. It is the one place both modes already share. The histogram is the only part of the column that 冲洗 and
   编辑 draw identically, so a panel directly under it does not move when the mode changes, which is what
   "switching mode keeps it" has to mean on screen.
2. It is Capture One's order: 直方图, then 图层与遮罩, then the tools.
3. Pinned, not in the scroll: the panel says what the controls below are about, and that has to stay in view
   while they scroll.
4. A card, not a flat folding section: under the histogram's card and above 冲洗's capsule band, a flat header
   with rows would read as one more of the mode's sections. Two cards read as the frame's own instruments, and
   the mode's sections scroll under them. The fold is the histogram's (the chevron in the head, a click on the
   head).

The fold is one preference for both modes, kept across launches: `DevelopPanelPrefs.layersCollapsed`,
`develop.wide.layers.collapsed`. The picked row is the session's (`OpenFrameSession`), so it survives a mode
switch and is forgotten with the page, as today.

The band under the picture (`DevelopRegion.layers`, 44 units, `layerPicker`) goes on the Mac: the panel replaces
it and the picture gains the room. A click on a frame of a pair on the canvas still picks it (`PieceMarks`).

With the column put away (⌘T) nothing shows the pick, so ↑ and ↓ stand down (§7).

## 4. Rows

| piece | rows, top to bottom | drawing |
|---|---|---|
| a single frame | 胶片 (the panel is one line: §4.1) | 05 |
| a pair, level | 胶片 · 左格 · 右格 | 06–08 |
| a pair, turned | 胶片 · 上格 · 下格 | 09–11 |
| a double exposure | 胶片 · 上层 · 下层 | 13–15 |

The names are the catalog's (`HalfFramePair.title(_:)`, `DoubleExposure.Layer.title`). A double's rows are top
first, as the words say, although the model's list is bottom first.

**States** (drawing 29):

| state | how it is drawn |
|---|---|
| at rest | name `text`, eye `secondaryText` at 75 % |
| pointer over it | `Theme.card` at 50 % behind it (`FoldHeader`'s hover) |
| picked | white capsule, `onSelection` ink |
| shown alone | the eye on an accent ground with a dark glyph; the same on a picked row |
| the other is shown alone | `eye.slash`, the thumbnail and name at 0.38; a picked row keeps its ink |
| empty | a dashed 30 × 20 box, the name and 空 in `dim`, and + on a 22 disc at the end |
| standing down | the whole row at 0.38, no hit testing (胶片 while arranging) |

A pair's rows have no eye and no trailing value. The eye's slot stays empty so names line up across pieces,
and so a mask layer's eye has its place later.

### 4.1 A single frame: one line (recommended)

The panel is its head alone, 32 high, reading 图层 at the left and 胶片 in `dim` at the right; the chevron is
drawn at 0.38 and the head does not unfold. The user's fold preference is not touched and returns on the next
pair or double. Reason: a single frame is nearly every frame, the column is short, and a list whose one row can
only be picked is a control that does nothing. When masks arrive a single frame gains rows and the same head
unfolds. The alternative, the unfolded card with its one row (68 high), is drawn dashed in 05.

## 5. What each row scopes

The rule: **胶片 is the column as it is. A picture's row is that picture's page.** Source of truth:
`DoublePanelKind.of(tab, layer, double, has:)` for a double, and the pair's existing split
(`PairPiecePanel` / `PairPicturePanel` / `PairEmptyPanel`, `HalfFramePair.trim(on:look:)`, `Hole.exposureEV`).

### 5.1 冲洗

**胶片 picked** (drawings 01, 06, 09, 13): 胶片与相纸 | 格式 and every section as for a single frame, with:

| where | a pair | a double exposure |
|---|---|---|
| 解码 › 曝光 | 胶片曝光, sub-label 两格 | 胶片曝光, sub-label 两次曝光 |
| 解码 › 白平衡 | "白平衡属于每一格。" and two chips, 左格 · 右格, each picking that row | "白平衡属于每一次曝光。" and 上层 · 下层 (R3; `decodePosition(on:)` is nil for the whole) |
| 解码 › 曲线, 放大机, 高动态范围 | the piece's | the piece's (`.printWhole`) |
| 格式, first section | **半格组**: 相机 横放 · 竖放, 间距, 片边, 日期后背, 对调两格 (`PairPiecePanel`'s content, as rows of the Mac's column) | **多重曝光**: 交换上下层 with what it changes under it, and "画幅的大小和比例取自下层曝光。" (`.frameWhole`) |
| 格式 › 尺寸 | stands down (a pair's size is its own) | the photograph's |
| 格式 › 片边, 日期后背 | in 半格组 (a pair's are its own switches) | the single frame's sections; the date is the bottom's |
| 格式 › 效果 | the piece's | the piece's (`.effectsWhole`) |

**A picture's row picked** (drawings 07, 08, 10, 11, 14, 15): no band. Sections, in order, each folding under
`ColumnSectionHeader`:

| section | a pair's frame | a double's exposure |
|---|---|---|
| 摆放 | "居中 · 1.00×" and 摆放… | "覆盖整格 · 1.30×" (and 已翻转), 摆放… and 水平翻转 (`.picture`) |
| 曝光 | open: this frame's stops, −5…+5, with 作用于 (此格 / + 胶片) and its meter | inside **进阶**, folded by default (R4): its stops and meter, and "平衡 → 67 %" (`.filmExposure`) |
| 白平衡 | this frame's photograph's | this exposure's photograph's, with "白平衡会写入图库中的这张照片。" (`.sceneExposure`) |
| 放大机 | this frame's own trim, with 作用于 | not shown: one negative, both print together (`.printExposure`) |
| 日期后背 | this frame's switch and what it printed | not shown: the piece's |
| 照片 | the file's name, 替换… and 移除, and why they stand down on the frame the piece began with | the same (`mayChange`) |
| foot | "胶片、相纸与效果属于「胶片」" › picks 胶片 | the same |

Film, paper, curve, effects and format are not shown dimmed on a picture's page: they are not that picture's,
and the foot row says where they are. This also answers the review's R10 note about Print and Effects on an
exposure: there is nothing there to mistake.

**An empty row picked** (drawings 12, 21): 添加照片 / 添加曝光 as one wide button, a line of what an empty layer
is, and the foot row. The panel's own foot says why the piece will not export.

### 5.2 编辑

**胶片 picked** (drawing 03): `AdjustColumn` as it is.

**A picture's row picked** (drawing 26): the pick is kept across the switch. Edit's tools are Layer 2, which the
model keeps once for the piece, so a picture has none: one line says so, 选择胶片 picks 胶片 (↑ does too), and
the tool list stands down at 0.38. The eye and Balance work as in 冲洗. This replaces
`DevelopWorkspace`'s two `onChange` handlers that move a pair's pick to 胶片 when Edit opens: the page no longer
changes a selection the user made. When masks come, a mask layer has its own edits in this same place.

### 5.3 裁剪 and Reset

In 冲洗, 裁剪 (the bar's button and `C`) with a picture's row picked opens **摆放** for that picture, as
`cropAction` opens the pair's place page today. With 胶片 picked on a pair it stands down, as today (a piece has
no one picture to cut); on a double it opens 摆放 on the exposure picked last, 上层 at first, so the way in never
depends on the pick (the review's 1.9c). 编辑's 裁剪 cuts the finished picture and belongs to 胶片; that it works
on a double as on a photograph is not verified (G12). Each section's ↺ and the bar's Reset keep their
scopes: `filmExposureReset(look:picked:madeMeter:)` already resets the whole or the picked exposure, never the
placements, the flips or the order.

## 6. The double exposure on the Mac

### 6.1 The way in (drawings 22, 23)

**合成 in the bar**, in 图库's trailing group: a pull-down with its name, as 裁剪 has its own, live with one or
two photographs chosen. One menu, two rows, each with a line under it:

- 多重曝光: "两次曝光叠在同一格底片上"; with two chosen the line names them, "下层 DSC_0412 · 上层 IMG_2207".
- 半格: "两张各占半格，排在同一段胶片上"; with two chosen, "左格 … · 右格 …".

The same two rows are a titled section, 合成, of a photograph's secondary-click menu, in place of 组成半格组: one
level, no submenu (R7). The photograph picked first is the bottom, the one that sets the frame (R6). With more
than two chosen, or a pair or a double among them, the rows are disabled and their second line says why.

Two chosen: the piece is made at once and lands as a row of this library, chosen, the library still in front,
as a pair does today. One chosen: the picker.

### 6.2 The second exposure (drawing 24), and Replace (drawing 20)

One sheet for three jobs: the second exposure, 替换, and 添加 into an empty layer. It lists the library's
photographs as the browser has them (pairs and doubles are not offered), with a search field. The photograph
already in the piece is marked with its layer's name and can still be chosen: the same one twice is a mirror
double, and its top starts flipped (R10). **A click picks, 创建 (or 替换) or a double-click confirms, Esc
cancels.** Nothing is made until it is confirmed, which is the review's 1.2 answered: one touch would make
a library item with no way back.

### 6.3 Balance (drawing 17)

The one `ValueSlider`, in the panel: range 10–90 %, whole percent, a hairline and a detent at 50 %
(`BalanceTrack`), the number typed or dragged. Its sub-label is 上层占比, and the two rows' trailing values show
both shares and move with it. Every value is written as it comes and the page develops at the live tier when the
pointer rests; the whole drag is one step of Undo (`balanceDrag`: R2).

**Its name: 平衡 / Balance, recommended over 不透明度.** Light adds on film and nothing covers anything, so 100 %
"opacity" would promise that the top hides the bottom; the range is 10–90 with the frame's total light held, which
is a balance. It sits in Capture One's 不透明度 place, so the habit of looking there is kept; and when masks come
a mask layer's 不透明度 takes the same place. The catalog's zh for this key is 比重 today; this
changes it to 平衡.

### 6.4 An exposure's own controls (drawings 14, 15)

On its page (§5.1). Its own stops are under 进阶, folded by default: Balance and 胶片曝光 cover every case (R4).
When it is open, moving the stops moves Balance too (measured in the review: +1 EV on one exposure leaves
Balance at 33 %), so the line beside it says "平衡 → 67 %" and the panel's slider and rows move with it. White
balance is the exposure's photograph's, and only with that exposure picked (R3).

### 6.5 Alone, by the eye (drawing 16)

A click on a row's eye shows that exposure as it develops by itself (`showAlone`, `developAlone`): its own light
as metered and the whole's 胶片曝光, without the share it gave the other. The lit eye is on its accent ground;
the other row's eye is struck and the row dims. A click on the lit eye shows both again; a click on the other
eye switches straight to that one, which is the comparison people make. The states are three: both, top alone,
bottom alone; there is no state with nothing shown.

It is the page's state, not the piece's: nothing is written or undone, and an export is always the double. So
that this cannot be mistaken, the picture wears a tag ("仅上层") and the status line says it. While the engine
develops it, the guide of that exposure alone stands in. Independent of the pick. Cleared when the frame
changes, and when that layer is emptied.

### 6.6 摆放 (drawing 18)

In the page, as 裁剪 is (`CropScreen(inline:)`), not a cover:

- The picture becomes the frame, outlined. The placed exposure's spill beyond the frame stays faint round it,
  with its outline and corner handles. Drag moves it, scroll or pinch or the 缩放 slider enlarges it (1.00–4.00×,
  it always covers the frame), 旋转 90°, 水平翻转, 还原.
- **It shows what will develop** (R5). While the pointer moves, the two photographs are added at Balance's real
  shares (`guideLayers`' gains are the exposures' own stops, so they are); when it rests, the page develops, as
  for every film-side control. The note under the controls says so.
- The panel stays: its rows choose which exposure is being arranged (胶片 stands down), its eye works, and
  **Balance is right there**, so placing and strength are one loop.
- 完成 is one step of Undo for everything the visit moved, the placement and Balance together; 取消 writes
  nothing. Return and Esc are their keys.

A pair's frame uses the same stage in place of the `PairPlaceFlow` cover: the hole is the frame.

Its name is **摆放 / Arrange**, for the row the pair calls 画面 and a double's was called 位置: the review found 位置
beside 安置 confusing (R5).

### 6.7 Swap, replace, remove (drawings 19, 20, 21)

The panel's ⋯ and a row's secondary-click menu are one list, for the picked (or clicked) row: 摆放…, 水平翻转,
单独查看, 交换上下层, 替换照片…, 移除照片. An item that cannot be done is listed disabled with its reason as its
second line.

- **交换上下层** is also a row of 胶片 › 格式 › 多重曝光, with what it changes written under it: "下层决定画幅与日期".
  When the two shapes match it says "两张画幅相同：交换后画面不变", so a swap that changes nothing on screen is not
  a mystery (the review's 1.6). Balance's number stays with the position. One step of Undo.
- **替换** opens the sheet of §6.2; **移除** leaves the layer empty and the photograph in the library. Both stand
  down on the photograph the piece began with (`mayChange`), and the page says why.
- An empty layer: Balance goes (there is nothing to balance), the row offers +, the page offers 添加曝光, and the
  picture is the remaining exposure at its −1 EV, film-true.

### 6.8 The export refusal (drawing 25)

A double with an empty layer is not exported, as a pair with an empty hole is not (R10: exported, it would be
one stop dark). It is said before it is asked: the panel's foot, and "一次曝光" in the status line. 导出 is not
dimmed; pressing it answers with the reason (`DoubleWords.exportRefusal`) and a default button, 添加曝光…, that
goes and fixes it. In a batch the export page's list says the same sentence beside that item and skips it.

### 6.9 The review's R1–R10 on the Mac

| | on the Mac | drawing |
|---|---|---|
| R1 one home | moot: the panel and the exposure's page are the home | 13–15 |
| R2 Balance develops while dragged | yes, in the panel | 17 |
| R3 white balance per exposure | the whole shows the line and two chips; an exposure shows its own | 01, 14 |
| R4 per-exposure stops under Pro | under 进阶, folded by default | 14, 15 |
| R5 摆放 shows what develops, with Balance | the stage's guide at Balance's shares, a develop at rest, Balance beside it; renamed | 18 |
| R6 pick order | the first picked is the bottom; the menu's line names them | 22, 23 |
| R7 one level deep | a titled section of the menu, and the bar's pull-down | 22, 23 |
| R9 alone, visible and at once | the eye; the guide stands in while it develops | 16 |
| R10 an empty layer's export | refused, with the way to fix it | 25 |
| R10 the same photograph twice | marked in the picker; the top starts flipped | 24 |
| R10 Print and Effects on an exposure | not shown on an exposure's page | 14 |
| R10 合成 on a double | the menu's rows disabled, with why | |
| R10 a photograph's Info names the doubles using it | not in this round (§14) | |

## 7. Keyboard

| key | does | when |
|---|---|---|
| ↑ / ↓ | the previous / next row; they stop at the ends | 冲洗 or 编辑, a piece with more than one row, the column shown |
| ← / → | the previous / next photograph, as today | unchanged |
| C | 裁剪; with a picture's row picked, 摆放 for it | as today |
| Return / Esc | 完成 / 取消 | in 摆放, and in the sheet (创建 / 取消) |
| Space | the original, as today | unchanged |
| ⌘Z / ⇧⌘Z | Undo and Redo: every panel action is one step | unchanged; in 摆放 they are the stage's own, as in 裁剪 |

How they are built, and the traps:

- **A plain key is a registry entry, not a `keyboardShortcut`.** Catalyst drops a SwiftUI shortcut with no
  modifier (measured 2026-10-26), so ↑ and ↓ are `HiddenKeyEquivalent`s (`MacKeyRegistration` →
  `MacShortcutRegistry`, answered by `MacKeyAnchor`), as ← and → are. Their titles, 上一图层 and 下一图层,
  appear in the Keyboard Shortcuts menu by themselves.
- **Trap 32, the menu takes a plain key before the focused field.** The registry already rebuilds the menu
  without plain keys while a field is edited (issue #112). Balance's number box is a `SliderField`, which sets
  `MacKeyFocus.commitEditing`, so while it is typed in ↑ and ↓ are the field's. The entries must not set
  `allowsDuringTextEditing`.
- **No focus is needed, and none is used.** A tapped field never resigns on Catalyst and SwiftUI focus is not
  reliable there, so the panel is not a focus target: the keys act on the page's picked row wherever the pointer
  last clicked. That is safe because ↑ and ↓ mean nothing else in 冲洗 and 编辑.
- **They are the develop page's registrations only.** 图库's ↑ and ↓ move the grid (`MacLibraryPage`); the
  registry answers with the last enabled registration, so the panel's are enabled only while the develop page
  is in front with no sheet, cover, inline crop or typing (`macPhotoKeysFree`'s conditions). To check with
  `--key-trace`, and by `tools/mac_shortcuts_check.py`.
- In 摆放, ↑ and ↓ move between the two exposures only.
- There is no plain key for the eye or for Swap in this round (§14).

## 8. VoiceOver

| element | label | value | traits and actions |
|---|---|---|---|
| the panel | 图层 | "3 个图层，选中上层"; 已收起 when folded | header; action 显示控制区 / 收起控制区, as the column's sections |
| the panel, a single frame | 图层 | 仅胶片一层 | header, no action |
| a row | its name | for an exposure "占 60 %"; 单独显示 or 未显示 while one is alone; 空 when empty; the photograph's file name | button, selected when picked; named actions for each item of its menu that can be done |
| a row's eye | 单独查看上层 / 单独查看下层 | on or off | button; when it changes, the page announces 仅上层 or 显示两次曝光 |
| an empty row's + | "添加照片到上层" | | button |
| ⋯ | 图层 | | opens the menu |
| Balance | 平衡 | "上层 60 %" (`BalanceTrack.valueText`) | adjustable, 5 % a step (`BalanceTrack.stepped`) |
| the R3 line | the sentence | | static; each chip a button named for its row |
| Edit's stand-down line | the sentence | | static; 选择胶片 a button |
| the picture's tag | 仅上层 | | static; the canvas's own label says it too |
| the stage in 摆放 | "摆放 · 上层" | "覆盖整格 · 1.30×" | adjustable for zoom; named actions 旋转 90°, 水平翻转, 还原 |

Thumbnails, the chevron and the trailing shares are hidden: their content is in the row's value. Identifiers
for the drive and the checks: `layers.panel`, `layers.fold`, `layers.menu`, `layers.balance`,
`layers.row.film|left|right|top|bottom`, `layers.eye.top|bottom`, `layers.add.top|bottom|left|right`,
`layers.page.arrange|advanced|wb|enlarger|date|photo|film-link`, `combine.menu`, `combine.double`, `combine.pair`.

## 9. Strings

Every string, zh-Hans and en. `catalog`: a key `Localizable.xcstrings` has today, with this zh. `new`: added by
this design (zh-Hant and ja go to `l10n-pending`). `renamed`: a catalog key whose zh this design changes.
`future`: the masks drawing only, not shipped. Printed by `gen_layers.py --strings`, so the table and the
drawings cannot disagree.

| key | zh-Hans | en | status |
|---|---|---|---|
| `layers` | 图层 | Layers | new |
| `film` | 胶片 | Film | catalog |
| `left` | 左格 | Left frame | catalog |
| `right` | 右格 | Right frame | catalog |
| `upper` | 上格 | Top frame | catalog |
| `lower` | 下格 | Bottom frame | catalog |
| `top` | 上层 | Top | catalog |
| `bottom` | 下层 | Bottom | catalog |
| `empty` | 空 | Empty | catalog |
| `balance` | 平衡 | Balance | renamed |
| `top_share` | 上层占比 | Top’s share | new |
| `alone_top` | 仅上层 | Top alone | new |
| `alone_bottom` | 仅下层 | Bottom alone | new |
| `alone_word` | 单独 | alone | new |
| `only_film` | 仅胶片一层 | Film only | new |
| `add_frame` | 添加照片 | Add Frame | catalog |
| `add_exposure` | 添加曝光 | Add Exposure | new |
| `fill_double` | 两次曝光都放入照片后才能导出多重曝光。 | Fill both exposures to export the double exposure. | catalog |
| `fill_pair_1` | 空着的一格是未曝光的胶片。 | An empty hole is unexposed film. | new |
| `fill_pair_2` | 两格都填上才能导出。 | Fill both frames to export the pair. | catalog |
| `swap_double` | 交换上下层 | Swap Top and Bottom | new |
| `swap_pair` | 对调两格 | Swap the Two Frames | catalog |
| `arrange_cmd` | 摆放… | Arrange… | new |
| `flip_h` | 水平翻转 | Flip Horizontally | new |
| `show_alone` | 单独查看 | Show Alone | new |
| `show_both` | 显示两次曝光 | Show Both Exposures | new |
| `replace_cmd` | 替换照片… | Replace Photograph… | new |
| `remove_cmd` | 移除照片 | Remove Photograph | new |
| `arrange` | 摆放 | Arrange | new |
| `covers` | 覆盖整格 | Covers the frame | catalog |
| `centred` | 居中 | Centred | catalog |
| `flipped` | 已翻转 | Flipped | new |
| `advanced` | 进阶 | Advanced | new |
| `exposure` | 曝光 | Exposure | catalog |
| `meter` | 测光 | meter | catalog |
| `balance_to` | 平衡 → | Balance → | new |
| `scope_frame` | 此格 | Frame | catalog |
| `white_balance` | 白平衡 | White Balance | catalog |
| `temperature` | 色温 | Temperature | catalog |
| `tint` | 色调 | Tint | catalog |
| `as_shot` | 原照设置 | As Shot | catalog |
| `wb_writes` | 白平衡会写入图库中的这张照片。 | White balance is written to this photograph in the library. | new |
| `enlarger` | 放大机 | Enlarger | catalog |
| `date_back` | 日期后背 | Date Back | catalog |
| `date_note` | 每一格都是一次单独的曝光，带着自己的日期。 | Each frame was its own exposure, and carries its own date. | catalog |
| `photograph` | 照片 | Photograph | new |
| `replace` | 替换 | Replace | catalog |
| `remove` | 移除 | Remove | catalog |
| `also_alone` | 图库里也有它单独的一张。 | It is in the library by itself as well. | new |
| `empty_layer` | 空着的一层是未曝光的胶片：画面只按另一次曝光冲洗。 | An empty layer is unexposed film: the frame develops with the other exposure’s light alone. | new |
| `began_double` | 多重曝光从这张照片开始，它留在其中；交换上下层可换位置。 | The double exposure began with this photograph: it stays. Swap Top and Bottom moves it. | new |
| `belongs_film` | 胶片、相纸与效果属于「胶片」 | Film, paper and effects belong to Film | new |
| `film_paper` | 胶片与相纸 | Film & Paper | catalog |
| `format` | 格式 | Format | catalog |
| `paper` | 相纸 | Paper | catalog |
| `all` | 全部 | All | catalog |
| `decode` | 解码 | Decode | catalog |
| `film_exposure` | 胶片曝光 | Film Exposure | catalog |
| `both_exposures` | 两次曝光 | Both exposures | catalog |
| `both_frames` | 两格 | both frames | catalog |
| `wb_each_exposure` | 白平衡属于每一次曝光。 | White balance belongs to each exposure. | new |
| `wb_each_frame` | 白平衡属于每一格。 | White balance belongs to each frame. | new |
| `curve` | 曲线 | Curve | catalog |
| `hdr` | 高动态范围 | High Dynamic Range | catalog |
| `double` | 多重曝光 | Double Exposure | new |
| `frame_is_bottoms` | 画幅的大小和比例取自下层曝光。 | The frame’s size and shape are the bottom exposure’s. | catalog |
| `swap_sets` | 下层决定画幅与日期 | The bottom sets the frame and the date | new |
| `swap_same` | 两张画幅相同：交换后画面不变 | Same shape: a swap changes nothing you can see | new |
| `pair` | 半格组 | Half-Frame Pair | catalog |
| `camera` | 相机 | Camera | catalog |
| `level` | 横放 | Level | catalog |
| `turned` | 竖放 | Turned | catalog |
| `spacing` | 间距 | Spacing | catalog |
| `between` | 两格之间 | between the frames | catalog |
| `film_edge` | 片边 | Film Edge | catalog |
| `off` | 关 | Off | catalog |
| `size` | 尺寸 | Size | catalog |
| `half` | 半格 | Half | catalog |
| `antihalation` | 移除防光晕层 | Remove anti-halation layer | catalog |
| `experimental` | 实验性功能 | Experimental simulation for all stocks | catalog |
| `effects` | 效果 | Effects | catalog |
| `grain` | 颗粒 | Grain | catalog |
| `halation` | 光晕 | Halation | catalog |
| `brightness` | 亮度 | Brightness | catalog |
| `contrast` | 对比度 | Contrast | catalog |
| `tone` | 色调 | Tone | catalog |
| `channels` | 通道 | Channels | catalog |
| `wheels` | 色轮 | Colour Wheels | catalog |
| `vibrance` | 鲜艳度 | Vibrance | catalog |
| `saturation` | 饱和度 | Saturation | catalog |
| `lens` | 镜头 | Lens | catalog |
| `no_edits_top` | 「上层」没有自己的编辑。编辑作用于整张胶片。 | Top has no edits of its own. Edit works on the whole film. | new |
| `select_film` | 选择胶片 | Select Film | new |
| `zoom` | 缩放 | Zoom | new |
| `turn90` | 旋转 90° | Turn 90° | new |
| `reset` | 还原 | Reset | catalog |
| `arrange_note` | 拖动时预览为两张照片按平衡相加；停下后按胶片冲洗。 | While you drag, the preview adds the two photographs at Balance; it develops on film when you stop. | new |
| `cancel` | 取消 | Cancel | catalog |
| `done` | 完成 | Done | catalog |
| `library` | 图库 | Library | catalog |
| `develop` | 冲洗 | Develop | catalog |
| `edit` | 编辑 | Edit | catalog |
| `crop` | 裁剪 | Crop | catalog |
| `export` | 导出 | Export | catalog |
| `histogram` | 直方图 | Histogram | catalog |
| `developed` | 已冲洗 | Developed | catalog |
| `developing` | 冲洗中 | Developing | catalog |
| `search` | 搜索 | Search | catalog |
| `combine` | 合成 | Combine | new |
| `double_sub` | 两次曝光叠在同一格底片上 | Two exposures on one frame of film | new |
| `pair_menu` | 半格 | Half-Frame Pair | new |
| `pair_sub` | 两张各占半格，排在同一段胶片上 | Two half frames on one piece of film | new |
| `order_double` | 下层 DSC_0412 · 上层 IMG_2207 | Bottom DSC_0412 · Top IMG_2207 | new |
| `order_pair` | 左格 DSC_0412 · 右格 IMG_2207 | Left DSC_0412 · Right IMG_2207 | new |
| `open_develop` | 在冲洗中打开 | Open in Develop | catalog |
| `light_table` | 放到观片台上 | Put on Light Table | catalog |
| `info` | 信息 | Info | catalog |
| `export_2` | 导出 2 | Export 2 | catalog |
| `copy_settings` | 拷贝设置 | Copy Settings | catalog |
| `photos_selected` | 已选 2 张 | 2 photos selected | catalog |
| `pick_second` | 选择第二次曝光，叠在同一格底片上 | Choose the second exposure, on the same frame of film | new |
| `same_mirrored` | 同一张 · 镜像 | Same one, mirrored | new |
| `create` | 创建 | Create | catalog |
| `replace_top` | 替换上层 | Replace Top | new |
| `replace_sub` | 选一张照片放进上层；原来的那张仍在图库中 | Choose a photograph for the top; the old one stays in the library | new |
| `cant_export` | 无法导出「多重曝光 3」 | “Double Exposure 3” can’t be exported | new |
| `ok` | 好 | OK | catalog |
| `one_exposure` | 一次曝光 | one exposure | new |
| `combine_choose` | 选择一张或两张照片 | Choose one or two photographs | new |
| `combine_refused` | 半格组与多重曝光不能再合成 | A pair or a double exposure cannot be combined again | new |
| `prev_layer` | 上一图层 | Previous Layer | new |
| `next_layer` | 下一图层 | Next Layer | new |
| `vo_share` | 占 %@ % | %@ % of the light | new |
| `vo_alone` | 单独显示 | shown alone | new |
| `vo_out` | 未显示 | not shown | new |
| `vo_eye_top` | 单独查看上层 | Show Top Alone | new |
| `vo_eye_bottom` | 单独查看下层 | Show Bottom Alone | new |
| `vo_add_to` | 添加照片到%@ | Add a photograph to %@ | new |
| `vo_layers_of` | %@ 个图层，选中%@ | %@ layers, %@ picked | new |
| `subject` | 主体 | Subject | future |
| `background` | 背景 | Background | future |
| `people` | 人 | People | future |
| `opacity` | 不透明度 | Opacity | future |
| `combine_masks` | 组合蒙版 | Combine Masks | future |
| `refine_mask` | 完善遮罩… | Refine Mask… | future |
| `mask_sky` | 天空 | Sky | future |
| `mask_1` | 蒙版 1 | Mask 1 | future |
| `not_shipping` | 2.4.x 蒙版 · 本次不做 | 2.4.x masks · not in this release | future |

Notes on the words:

- 摆放… , 替换照片… and 添加曝光… end in an ellipsis because they open something, the Mac's convention for a
  command. It is never a truncation: no label here is cut, and the generator's fit check holds each to its room.
- 交换上下层 for a double beside 对调两格 for a pair: the pair's word is the catalog's and is kept.
- No trademarks, no "Pro": the folded group is 进阶 / Advanced.

## 10. How it maps onto the phase-1 model

| the design | the API that exists |
|---|---|
| pick a row | `OpenFrameSession.pick(_:)` (a pair), `pickLayer(_:)` (a double) |
| which sections a row has | `DoublePanelKind.of(_:_:_:has:)`; the pair's split in `PairPanels.swift` |
| a row's share | `DoubleExposure.balance` |
| Balance dragged; typed, clicked, stepped | `AppServices.balanceDrag(_:_:to:)`; `setDoubleBalance`; `BalanceTrack` |
| the eye | `showAlone(_:_:)`, `developAlone(_:_:)`, `OpenFrameSession.alone` |
| an exposure's stops and meter | `setDoubleExposure`, `setDoubleMeter`, `DoubleExposure.reading(_:)`, `Exposure.meter(film:)` |
| an exposure's white balance | `changeDecode(on:inDouble:_:)`, which refuses the whole; `decodePosition(on:)` |
| flip | `flipDouble(_:_:)` |
| swap | `swapDouble(_:)`; a pair: `changePair { piece.swap(look:) }` |
| replace, add, remove | `replaceDouble(_:_:with:)`, `removeDouble(_:_:)`, `DoubleExposure.mayChange(_:)` |
| 摆放's arithmetic and Done | `DoubleExposure.placement(_:draggedBy:…)`, `placement(_:zoomedBy:…)`, `window(_:framed:)`, `guideLayers(_:)`; `placeDouble(_:_:)` |
| Reset | `resetDouble(_:)`, `filmExposureReset(look:picked:madeMeter:)` |
| the words | `DoubleWords`, `DoubleExposure.placedText(_:)`, `PairWords` |
| making one, and its library row | `AppServices.makeDouble(_:_:beginsWithFirst:)`; `MacDoubleRows` |
| the refusal | `DoubleWords.exportRefusal(_:has:)` |

**Gaps.** None needs an engine change or a change to the file formats.

| | gap | what it takes |
|---|---|---|
| G1 | `MacLibraryBrowser.selection` is a `Set`: the order the photographs were picked in is not kept (R6) | an ordered list beside it, appended by each click; a ⇧-range in grid order |
| G2 | `ExportService` names only a pair's refusal; a double with an empty layer is "Nothing to develop it from" | `frame.double.flatMap { DoubleWords.exportRefusal(…) }` beside the pair's line, and the single export's alert |
| G3 | `OpenFrameSession.alone` has no reader: nothing shows the alone picture | the canvas shows `developAlone`'s picture and the guide before it; asked again when the look or that exposure changes; cleared with the frame and with an emptied layer |
| G4 | two picks, `layer` (a pair) and `doubleLayer` (a double), and `DevelopWorkspace` forces a pair's to 胶片 when Edit opens | one view-side `LayerPick` over both (no model change); the two `onChange` handlers go |
| G5 | the wide column's 解码 › 曝光 is always the whole's `exposureCompensationEV`: a pair frame's own stops, scope and meter exist only in the compact `FilmPanel`; a double exposure's have no control | the exposure's section of the layer page, on `changePair` / `setDoubleExposure` |
| G6 | no 摆放 on the Mac: a pair's is the `PairPlaceFlow` cover, a double has none | the inline stage (`ArrangeStage`), for both |
| G7 | `placeDouble` writes placements only; 完成 must be one Undo step with Balance | one history transaction round the visit (`beginHistoryTransaction` / `endHistoryTransaction`) |
| G8 | a mirror double does not start flipped (R10) | at the call that makes it, in the same step |
| G9 | `DoublePanelKind` speaks five tabs | `LayerRules` derives the Mac's sections from it, and the self-test holds the two against each other so they cannot drift |
| G10 | spklib has no kind for `.spektradouble` (the row is `other`; `MAC-LIBRARY-DATA.md` §2k) | the SDK's one line; until then the File Type facet cannot name a double |
| G11 | phase 1 re-fitted the composed open's memory on the Mac (`CostModel.ComposedOpen`); how long a live-tier develop of a double takes under a Balance drag has no measurement | measure it, interleaved (trap 17), before calling the drag smooth |
| G12 | not verified: 漏光, the single frame's 片边 / 日期后背 sections (`FilmEdgeColumn` guards on a pair only) and 编辑's 裁剪, on a double | check at build; the drawings assume a double takes them as a photograph does |

## 11. Build plan (for the next step, after approval)

**New files** (`app/SpektraLab/Sources`):

| file | holds |
|---|---|
| `Features/Layers/LayerRules.swift` | Foundation only: the rows of a piece and their order, `LayerPick`, what each row has in each mode, the folded summary, the eye's three states, ↑ ↓ stepping, the panel's height |
| `Features/Layers/LayersPanel.swift`, `LayerRowView.swift` | the card: head, rows, Balance, foot |
| `Features/Layers/LayerMenu.swift` | the one list behind ⋯ and the secondary click |
| `Features/Layers/LayerPage.swift` | a picture's page: 摆放, 进阶 / 曝光, 白平衡, 放大机, 日期后背, 照片, the foot row; the empty page |
| `Features/Layers/LayerPieceSections.swift` | 格式's first section (半格组, 多重曝光); the R3 line in 解码; Edit's stand-down line |
| `Features/Layers/ArrangeStage.swift` | 摆放 in the page, for a double's exposure and a pair's frame |
| `Features/Layers/LayerPhotoPicker.swift` | the sheet: second exposure, replace, add |
| `Mac/LibraryUI/MacCombineMenu.swift` | 合成 in the bar and in the photograph's menu; `MacLibraryActions.makeDouble` |
| `Mac/Layers/MacLayersCheck.swift` | `--layers-check` (below) |
| `tools/layers_selftest.swift` | the rules, held |

**Changed:** `PadDevelopPage.swift` (the panel in `column`; the band under the picture goes),
`DevelopRegions.swift`, `DevelopWorkspace.swift` (the routing; the forced pick goes), `DevelopInspectorParts.swift`
(`layersCollapsed` and the page's folds), `DecodeSection.swift`, `DevelopCanvas.swift` (alone, its tag),
`MacInfoStrip` (the status words), `WindowToolbar.swift` / `MacShellBar`, `MacLibraryGrid.swift`,
`MacLibraryUIState.swift` (G1), `ExportService.swift` (G2), `PairPanels.swift` (its Mac use ends),
`Localizable.xcstrings` through `tools/localization_add.py`, `SnapshotHarness.pages`,
`MacDriver` (steps `layers.pick`, `layers.eye`, `layers.balance`, `layers.arrange`, `combine.double`). Then
`python3 gen_project.py`.

**Notes to edit in the same commits, said here first as AGENTS.md asks for the shared ones:** `PAGES.md` §2 and
§6, `PAIR-WIRING.md` §8, `MAC-LIBRARY-DATA.md` §2k ("No menu entry yet"), `design/MAC-LIBRARY-UI.md` §5's keys.
None of `AGENTS.md`, `ARCHITECTURE.md`, `API-SPEC-*` or `CONTRACT-*` is touched: there is no wire change.

**Order**, each a commit that records its gate:

1. `LayerRules` and its self-test, red before green.
2. The panel's shell for all three pieces, pinned and folding; a single frame's page byte-same in
   `same_snapshots.sh` apart from the 32-unit line.
3. A pair: the rows replace the band and `PairFramePanel`; the frame's page; 半格组.
4. A double: 胶片's page (the R3 line, 多重曝光), an exposure's page, Balance live, the eye on the canvas (G3–G5).
5. `ArrangeStage` (G6, G7), a double first, then a pair.
6. 合成, the sheet, ordered picks (G1, G8); replace, add and remove through the sheet.
7. The refusal (G2).
8. Keys, VoiceOver, strings; Debug and Release builds; `screenshots/` retaken (said in the commit).

**Tests.**

- `tools/layers_selftest.swift`: rows, names and order for a single frame, a pair level and turned, a double,
  each with an empty layer; 胶片 first always; the pick unchanged by a mode switch; ↑ ↓ clamp; the eye's
  transitions, and an emptied layer clears it; Balance's slot exactly when a double is filled; the heights 32,
  128, 172.5; each row's sections equal to `DoublePanelKind.of` for every tab (G9); the refusal's words exactly
  when a layer is empty. And every string of §9, measured in the column's type against its room at 393, in each
  language, as `develop_selftest` measures the notes.
- Kept green: `double_selftest`, `double_darkroom_selftest`, `pair_selftest`, `piece_selftest`,
  `navigation_selftest`, `mac_shortcuts_selftest`, `mac_shortcuts_check.py` (↑ ↓ bound once),
  `localization_check.py`, `develop_selftest`.
- **Where it shows the frame: `--layers-check`**, the 2.x form of a `SurfaceAgreementTests` case (trap 33): the
  real window, a scratch home (`CFFIXED_USER_HOME`), fixtures copied before they are opened, a report, and a
  `--self-test` that breaks each mapping and expects red (a check that cannot fail is not one).
  1. The panel is the model: rows, names, the pick and the shares against `double.balance`, after each of pick,
     swap, replace, remove, undo and redo.
  2. **The canvas is the export.** The double on the canvas against the exported file, at `MacExportCheck`'s
     bar; and again with an eye on: the export does not change (alone never reaches it), and the canvas does.
  3. Balance develops under the pointer: a develop lands with the button still down; the picture at 20 % and at
     80 % differ by more than noise, measured at the ends of the range and not by not-equal alone (the dead
     sliders of RFC-025); one Undo puts both the number and the picture back.
  4. Alone is that exposure: the canvas with the eye on against `developAlone`, and against that photograph
     developed by itself at the whole's 胶片曝光; the eye off returns the double as it was.
  5. 摆放's guide is at Balance's shares: the two layers' light in the guide tracks `double.balance` at 20, 50 and
     80 %; 完成 is one history step, 取消 leaves the model equal.
  6. 冲洗 → 编辑 → 冲洗 keeps the pick, the fold and the eye, and the panel's frame does not move (measured, as
     `tools/measure` reads a strip).
  7. An empty layer: 导出 writes no file and shows `DoubleWords.exportRefusal`'s sentence.
  8. Trap 34: picking rows and switching the eye while a batch export runs changes nothing it writes.
- A person clicks through it before it is called seen: a report with 0 failures that nobody has looked at is
  said to be so (`PAGES.md` §7).

## 12. Decisions for the owner

| | decision | recommended | the other |
|---|---|---|---|
| 1 | a single frame's panel | **one line**, 32 high, reading 胶片 (§4.1) | the card unfolded with its one row |
| 2 | the double's slider | **平衡 / Balance**; the catalog's 比重 becomes 平衡 (§6.3) | 不透明度 |
| 3 | a picture's row picked, in 冲洗 | **its own page**, only what is that picture's (§5.1) | keep the 胶片与相纸 · 格式 band and dim what is the film's |
| 4 | a picture's row picked, in 编辑 | **keep the pick**; the tools stand down under one line (§5.2) | show 胶片 while in 编辑 and return the pick in 冲洗 |
| 5 | where "Pro" is on the Mac | **a folded 进阶 group** on the exposure's page; `settings.proControl` has no Mac switch today | a switch in Settings › Develop |
| 6 | the second exposure | **pick, then 创建** (a double-click does both) (§6.2) | one click makes it, as today's pair sheet |
| 7 | 导出 on a double with an empty layer | **live, and it answers with the reason and 添加曝光…** (§6.8) | dimmed |
| 8 | the word for placing | **摆放 / Arrange**, for the pair's 画面 row too (§6.6) | keep 位置 / Place |
| 9 | the panel's look | **the histogram's card, pinned** (§3) | a flat folding section in the mode's scroll |
| 10 | 合成 in the bar | **a pull-down with its name**, in 图库 only (§6.1) | a bare symbol; or the menu alone |

Smaller defaults taken, to change by saying so: the other row's struck eye switches to it rather than returning
to both; a mirror double starts with its top flipped; white balance in a double still writes to the library
photograph, and says so (the review's open question 6, which touches the pair too); the histogram follows what
the canvas shows, alone included.

## 13. The drawings

All in `app/SpektraLab/design/layers/`, as `NAME.zh.svg` and `.png`; those marked en also as `NAME.en.*`.

| | name | shows | en |
|---|---|---|---|
| 01 | `01-develop-unfolded` | 冲洗, the panel unfolded, a double, 胶片 picked; the R3 line | yes |
| 02 | `02-develop-folded` | 冲洗, folded | yes |
| 03 | `03-edit-unfolded` | 编辑, unfolded | yes |
| 04 | `04-edit-folded` | 编辑, folded | |
| 05 | `05-single-frame` | a single frame: one line, and the alternative | yes |
| 06 | `06-pair-level-film` | a pair, level, 胶片: 格式 with 半格组 | yes |
| 07 | `07-pair-level-left` | 左格: the frame's page | yes |
| 08 | `08-pair-level-right` | 右格 | |
| 09 | `09-pair-turned-film` | turned, 胶片 | |
| 10 | `10-pair-turned-upper` | 上格 | |
| 11 | `11-pair-turned-lower` | 下格 | |
| 12 | `12-pair-empty` | an empty hole | |
| 13 | `13-double-film-format` | a double, 胶片: 格式 with 多重曝光 | yes |
| 14 | `14-double-top` | 上层: the exposure's page | yes |
| 15 | `15-double-bottom-advanced` | 下层, 进阶 open, the photograph it began with | |
| 16 | `16-double-alone` | the eye: 上层 alone | yes |
| 17 | `17-double-balance-drag` | Balance being dragged | yes |
| 18 | `18-double-arrange` | 摆放, the other exposure at Balance's share | yes |
| 19 | `19-double-swap` | the menu, 交换上下层 | |
| 20 | `20-double-replace` | the sheet as 替换 | |
| 21 | `21-double-removed-empty` | after 移除: an empty layer | |
| 22 | `22-combine-toolbar` | 图库, 合成 in the bar | yes |
| 23 | `23-combine-context` | 合成 in the photograph's menu | |
| 24 | `24-second-exposure-picker` | the second exposure | yes |
| 25 | `25-export-refusal` | the refusal | yes |
| 26 | `26-edit-top-picked` | 编辑 with 上层 picked | |
| 27 | `27-future-masks` | where masks go later; **not shipping** | |
| 28 | `28-anatomy` | the panel at 2x with its measurements | yes |
| 29 | `29-row-states` | every state of a row, at 2x | |

In `27-future-masks` the three dashed places are the whole of what is reserved: ① + and − in the head's
trailing group, left of ⋯; ② two rows between the head and the list, the selection row (主体 · 背景 · 人) and the
tool row; ③ under the list, the picked layer's 不透明度 where a double's Balance is today, and two buttons under
it. Mask rows go under the picture rows, each with its eye. Nothing of today's panel moves when they come.

## 14. Not done, and not verified

- **Nothing is built or run.** These are drawings: no line of Swift was written, no self-test exists, and no
  claim here about the running app has been seen in it.
- The drawings' window is 1000 × 860 units with the browser put away, and the bar is drawn from
  `Screenshot_v2.png`'s measurements with stand-in symbols for the app's own drawn icons. The column and the
  panel are to the code's numbers; the bar is not this design's and is approximate.
- The stand-in pictures do not show the film's look, and the double's is a `screen` blend, not the engine's sum.
- Light Mode is not drawn. The tokens are `Theme`'s, so it follows; it has not been looked at.
- zh-Hant and ja are not written.
- Not designed: a photograph's Info naming the doubles that use it (R10); a plain key for the eye and for Swap;
  dragging a row onto the other to swap; 合成 offered from 冲洗 (the brief's entry is 图库's); a menu-bar 合成.
- G11 and G12 are open questions for the build, not answered here.

## 15. As built (2026-11-12)

The owner approved the drawings with every recommendation of §12 (2026-11-11), and the panel was built on
`mac/layers-2026-11-11`. This section is where the build stands against the drawings; where the two differ the
build is what runs, and the reason is here.

**Where it lives.** `Sources/Features/Layers/` — `LayerRules.swift` (no view in it; `tools/layers_selftest.swift`),
`LayersPanel.swift` (the card, its rows, Balance, the menu, `LayersStage`), `LayerPage.swift` (a picture's page,
the stand-down line, the whole's white-balance links, 格式's 多重曝光 section), `ArrangeStage.swift`,
`LayerSheets.swift` (the sheet, the refusal, one exposure alone) — and `Sources/Mac/Layers/` — `MacCombineMenu.swift`
(合成, `MacPhotoPicker`), `MacLayersCheck.swift` (`--layers-check`, the drive steps). Captures of the running app,
in Chinese and English, were taken beside these drawings for the build's report.

**The gaps of §10.** G1 closed (`PickOrder`, `MacLibraryBrowser.picked`). G2 closed (`ExportService` asks
`DoubleWords.exportRefusal`; Export on an unfilled piece alone answers with the alert of drawing 25). G3 closed
(`LayerAloneOverlay` reads `OpenFrameSession.alone`). G4 closed (`layerPick`, `pick(row:)`; the two handlers that
forced the pick are gone). G5 closed (a frame's page has its own exposure, scope and meter). G6 and G7 closed
(`ArrangeStage`; `OpenFrameSession.holdHistory`: the visit is one step of Undo, Cancel none). G8 closed
(`makeDouble`). G9 closed (`LayerRules.page(of:)`, held by the self-test tab by tab). G10 stands: the row's kind is
`other`, and the pickers leave it out by its file's extension. G11 stands: unmeasured. G12 verified by
`--layers-check` on two RAW files: 漏光, 片边 with 日期后背 and Edit's crop on a double each give a canvas the export
agrees with (16 × 16 block means: mean difference 0.03–0.43 codes of 255; the worst single block is 10.7, on the
crop's edge where it cuts across the film edge's border). Edit's crop on a double *was* wrong — it opened
the crop before the film, which a double does not have — and now opens the finished picture's alone.

**Where the build differs from the drawings.**

1. **摆放's stage (drawing 18).** The drawing shrinks the frame and shows the exposure's overflow faintly round it,
   with handles, the two photographs added while it is dragged. The build keeps the canvas at its fit with a
   one-unit frame round what is being arranged: the picture stands still under the drag and is the develop itself
   — film, paper and Balance — where the pointer rests. No overflow, no handles, no added preview. The note's
   words say what happens ("Drag the picture to move it. It develops on film, at Balance, when you stop.").
   Zoom is the slider and a pinch; a scroll wheel does not zoom here.
2. **The bar under 摆放.** As under 裁剪, the actions are away and 裁剪 is lit; the drawing dims them in place.
   The info strip keeps the develop's own line where the drawing reads "摆放 · 上层 · 1.30×".
3. **合成's second item** reads 半格组 (the catalog's "Half-Frame Pair") where drawing 22 reads 半格: one English key
   cannot carry two Chinese words, and the pair is 半格组 everywhere else.
4. **The pickers (drawings 20, 24)** are the app's sheet over the window with the library's rows as tiles, each
   under its file's name; a picture the piece holds says so in the name's place. The drawing's larger Mac sheet
   with a search field is not built.
5. **A picture's page.** White Balance has no eyedropper (the neutral pick writes the page's own decode, not a
   photograph's); 照片 shows a thumbnail beside the name; an empty layer's button spans the column.
6. **A pair's 格式 with 胶片 picked** begins with the piece's rows (相机, 间距, 片边, 日期后背, 对调两格) without a
   半格组 title over them.
7. **Keys.** ↑ ↓ walk the rows and stop at the ends; in 摆放 they move between the pictures; Return is Done. Esc
   is not Cancel, and the eye has no key.
8. **VoiceOver.** Rows, eyes, Balance, the menu, the page's parts and 摆放's controls carry the identifiers of §8
   and their labels; the composed sentences ("3 layers, Top picked") are not built.
9. **The histogram** does not follow one exposure alone: it stays the double's.
10. **A turned pair, a missing photograph, the head's menu and the second-exposure sheet's double click** were
    built and are covered by the rules' self-test or the layers check, but were not captured from the running app.

**Mask layers (PRD-E, 2026-11-13).** A single photograph's panel now unfolds with its mask layers, the two rows that
make them, 不透明度 and the two buttons under the list; that design and how it is built are
`design/masks/MASKS-SPEC.md` (§11 maps it onto `LayerRules`; §12 is the build order). A pair's and a double's panel
is as above, with + and − dimmed and one line at its foot saying mask layers are a single photograph's for now. In
every build since M1c (2026-11-13: 主体 · 背景 · 人, 组合蒙版, 完善蒙版…, the geometry mark; `FeatureFlags.maskLayers`),
which also builds the composed sentence of §14's item 8 for a photograph's panel ("3 个图层，选中渐变 1").
