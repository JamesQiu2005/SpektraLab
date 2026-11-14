# Mask layers in the 图层 panel: the design

Status: **drawings and spec for the owner's approval. Nothing is built.** Date: 2026-11-12.
Brief: `PRD/masks-2026-11-12/PRD-E-layers-and-masks-2026-11-12.md` (what the product does) and
`rfc/RFC-052-layers-and-masks.md` (how it is computed, stored and checked). This file is how it looks and
how it is used. Base: local `main` f193d8c5, the 图层 panel as built (`design/layers/LAYERS-SPEC.md` §15).

The drawings are the 25 SVGs beside this file, each with a PNG at 2x. They are generated
(`src/gen_masks.py`), on the 图层 design's own kit (`design/layers/src/kit.py`, `gen_layers.py`, imported
by path and not copied), so a number changed there is changed here and drawn again:

```bash
python3 app/SpektraLab/design/masks/src/gen_masks.py --png      # every drawing, and its PNG
python3 app/SpektraLab/design/masks/src/gen_masks.py --strings  # §10's table
```

The generator refuses to draw a line that does not fit its room (`fits`), in either language. It stopped
once while these were made (the stage notice in English, which became a shorter sentence).

**Units.** One unit is one scene point of the develop page: 0.9625 of a Mac point at the 100 % interface
scale. The column is 393 units. Every number of an existing part is that part's own, from its Swift file or
from LAYERS-SPEC §2. The pictures are vector stand-ins, and no drawing shows the film's look or a layer's
effect on the picture: neither is this design's.

## 1. What is fixed, and what this adds

Taken as they stand, from PRD-E: a layer is a mask, a stage and a few adjustments; two stages, 场景 and
成片, chosen per layer; a layer's page is its own in both modes; M1's tools are 画笔 and 橡皮, 线性渐变,
径向渐变, 主体, 背景, 人; 组合蒙版 with 加 · 减去 · 相交; 反相, 羽化; the overlay and the mask alone; 不透明度;
single photographs only in M1; 蒙版 is the one word; the overlay is red. And from the 图层 design, drawing
27's three reserved places: + and − left of ⋯; two rows between the head and the list; 不透明度 and two
buttons under the list. Nothing of today's panel moves.

What the design adds, in one paragraph. **The tool row carries the lit tool's own pill** at its leading
end, which names the tool, its size and how it joins, and opens its settings. **A mask row says its stage
in a word**, not a glyph, at its trailing end. **The layer's page is three parts**: a stage switch with one
line of what the stage means, 蒙版 with its parts listed, and 调整. **组合蒙版 is one step shorter than
Capture One's**: choose the join, click a tool. **羽化 has one slider**, in 完善蒙版…, and the page shows its
value. **A stage switch asks nothing**: a line under the switch says the adjustments start again, with
撤销 beside it.

## 2. Anatomy and measurements

Drawings `15-anatomy`, `16-states`.

The card, the head's chevron and title, a row's height and capsule, the eye's slot, the thumbnail's slot and
the trailing inset are the 图层 panel's (LAYERS-SPEC §2). New:

| part | measure | type and ink |
|---|---|---|
| head, trailing | three 22 discs (`Theme.card`), 6 apart: + − ⋯; ⋯ still 10 from the card's right | `plus`, `minus`, `ellipsis` 11 bold; − at 0.38 unless a mask layer is picked |
| selection row | 36 high; three equal buttons 28 high, radius 7, `Theme.card`, 8 apart, 14 from the card's sides (108.3 wide in the narrowest column) | an 11 glyph, 6, the word at 12.5 medium `secondaryText`; 人 has `chevron.down` 8 bold `dim`, 11 from its right |
| tool row | 36 high; slots 30 × 28 laid from the card's right inset; a divider 0.5 × 20 `Theme.rule` with 6 on each side | glyph 13 medium `secondaryText`; lit: a 28 × 24 accent ground, radius 6, glyph `onSelection` |
| tool pill | at the tool row's leading end, 24 high, capsule, `Theme.card`; only while a tool with settings or a join other than 加 is lit | `slider.horizontal.3` 10 semibold, the words 12 medium `text`, `chevron.down` 8 bold |
| mask row | 30 high, capsule 28; the eye's slot and the thumbnail's as a picture's row | name 13 medium (semibold picked) |
| mask thumbnail | 30 × 20, radius 3, the mask white on black, a 0.5 stroke (`Theme.rule`; grey on the white capsule) | |
| mask row, trailing | ends 10 inside the capsule: [mark] [opacity] stage, 10 apart | stage 12 medium `dim`; opacity 12 medium tabular, only when not 100; the mark `exclamationmark.triangle` 12 bold accent |
| 不透明度 | a half-point rule 14 from the card's sides, `ValueSlider` 40, its number's box 62, 4 under | the slider's own type; 0–100 %, no rest mark |
| buttons | 2, then two equal buttons 28 high, radius 7, 8 apart, then 10 | 12.5 medium `text`; 组合蒙版 has `chevron.down` 8 bold |

Heights (`LayerRules.height`): folded **32**; a single photograph with no mask layer **140**
(32 + 36 + 36 + 30 + 6); with n mask layers **224.5 + 30 n** (n ≤ 4). Past five rows the list scrolls within
150 and the card stops at **344.5**, so the column under it never loses its room to a long list. A pair's
and a double's heights are today's (the two rows are not shown there in M1, §4.4).

Density: a row is 30 units, 28.9 Mac points. New type is never under 11.5 units; the smallest new line is a
note at 11.5. Selection is the white capsule. The accent appears as state only: a lit tool, the lit
overlay eye, the geometry mark, the feather handle, the stage notice's glyph.

**Glyphs.** Apple's symbols as stand-ins, to be drawn in `DrawnIcons` where the app draws its own:
主体 `person.crop.rectangle`, 背景 `photo`, 人 `person.fill`, 画笔 `paintbrush.pointed`, 橡皮 `eraser`. The two
gradients have no symbol that says "a gradient", so the generator draws them: a 15 × 12 rounded rectangle
fading left to right, and a 14 circle fading from its centre. Later: 魔术画笔 `wand.and.stars`, 修复
`bandage`, 仿制 `seal`, 亮度范围 `sun.max`, 点选 `cursorarrow.rays`.

## 3. Where it sits, and what unfolds

The panel is where it is: under the histogram, pinned, in both modes. **A single photograph's panel now
unfolds** (drawing 01), following the fold preference like every other piece; `LayerRules.isOneLine` is
true for nothing in M1 on the Mac. Folded, the head's trailing words are the count of mask layers and the
picked row's name, "蒙版 3 · 渐变 1" (drawing 12); with no mask layer, the picked row's name alone, as
today.

## 4. Rows

### 4.1 Order and names

胶片 first, always. Mask layers under it, **the newest directly under 胶片** and older ones below. The
order is for reading: layers of a stage add up (RFC-052), none covers another, and there is no drag to
reorder in M1. A new layer is named for how it was made and numbered within its kind: 主体 1, 背景 1,
人物 2, 渐变 1, 画笔 1; + makes 图层 1 with an empty mask. A double-click on the name renames it in place.

### 4.2 States (drawing 16)

| state | how it is drawn |
|---|---|
| at rest | name `text`, eye `secondaryText` at 75 %, stage `dim` |
| pointer over it | `Theme.card` at 50 % behind it |
| picked | white capsule, `onSelection` ink |
| switched off | `eye.slash`, the thumbnail and name at 0.38; a picked row keeps its ink |
| opacity not 100 | "60 %" before the stage |
| geometry changed | the accent mark before the trailing words (§6.5) |
| empty mask | an all-black thumbnail |

The eye here is a real switch (the layer is in the picture or not, written with the edit, one step of Undo).
A double exposure's eye is "alone" and is the page's state; the two never appear on the same piece in M1.

### 4.3 The head's buttons, and the two rows

- **+** makes an empty layer, picked, in the stage of the mode in front. **−** removes the picked mask
  layer; it asks nothing and Undo restores.
- **主体 · 背景 · 人** each make a new layer with that mask, picked (drawing 02). While it is looked for the
  button reads 正在查找 with a spinner and keeps its width (drawing 16). 人 opens its menu (§6.4).
- **A tool** is lit by a click and put down by a second click or Esc. With 胶片 picked, the first stroke or
  drag makes a new layer; with a mask layer picked, it joins that layer's mask as 加 unless 组合蒙版 set
  another join. 橡皮 is 画笔 with the join 减去: it has its own slot because it is the commonest correction.

### 4.4 A pair and a double (drawing 13)

No mask layers in M1. + and − are drawn at 0.38 and take no click; the selection and tool rows are **not
shown** (nothing in them could be used, and a pair's panel keeps today's height); one line at the panel's
foot says "蒙版图层目前用于单张照片".

## 5. The layer's page

The column under the panel while a mask layer is picked, in either mode (drawings 02, 03). No band.

| part | holds |
|---|---|
| **作用于** | a `SegmentedSwitch` 场景 \| 成片 (segments 76) at the trailing edge of a 44-unit row; under it one line: "改变到达胶片的光，胶片随之重新冲洗。" or "改变成片，胶片与相纸不重做。" |
| **蒙版** (folds) | head: the overlay's eye at its trailing end (lit on the accent while the overlay shows; it is `M`). Rows, 30 each: one per part, as "加 · 主体": a 18 disc with the join's glyph (`plus`, `minus`, `circle.lefthalf.filled`), the part's glyph, the words, its own eye, × to remove. Then 反相 with a toggle, and 羽化 with its value in a pill that opens 完善蒙版…. Folded, the head names the parts at its trailing end |
| **调整** (folds) | head: ↺ for all of the layer's adjustments. 场景: 曝光 (−4…+4 EV, grey track), 色温, 色调 (the tinted tracks). 成片: Edit's six scalar tools, each its own folding header with its symbol and no grip (`AdjustColumn`'s sections, filtered by `AdjustTool.controls`): 亮度 (亮度, 曝光), 对比度, 色调 (高光与阴影 · 白色与黑色, by its menu), 鲜艳度, 饱和度, 色温 (色温, 着色) |
| **foot** | one row leading to 胶片: "胶片、相纸与效果属于「胶片」" (场景) or "曲线、色轮、HSL、通道与镜头属于「胶片」" (成片) |

A click on a part's row makes it the one the picture's handles are for (a gradient's lines appear; §6).
The tools' order in 成片 is the one the user set on 胶片's page; it is not set here.

**Changing the stage** (drawing 11). A click on the other segment switches at once. The mask, the name, the
opacity and the eye stay; the adjustments are the other stage's, from zero. When the old ones were not
zero, a line appears under the switch, "这一层的调整已从零开始。" with 撤销; it goes with the next action.
No alert: the switch is reversible in one step, and an alert on every switch would teach people to click
through it.

## 6. On the picture

### 6.1 The overlay and the mask alone (drawings 04, 05, 07)

- **Overlay**: red, sRGB (255, 59, 48), at 50 % where the mask is 1 and in proportion below. The literal is
  converted to the working space before it reaches the drawable (trap 27), like every other colour the
  canvas draws.
- **It shows itself** while a mask is being made or changed (a stroke, a handle's drag, a found mask
  arriving, for 0.6 s after) and steps aside while an adjustment is dragged. `M` holds it on or off; the
  section's eye is the same switch.
- **The mask alone**, `⌥M`: the picked layer's mask white on black, a tag on the picture ("蒙版 · 主体 1",
  `circle.lefthalf.filled` in the accent) and the status line reading 仅显示蒙版. It is the page's state.
  Nothing stored ever holds either view.
- 完善蒙版… shows the mask alone while it is open, and returns the view as it was.

### 6.2 画笔 and 橡皮 (drawing 04)

| | |
|---|---|
| cursor | the brush's circle: the outer ring its size (1.5 white over a 3-unit shadow), a dashed inner ring where the hardness begins to fall, a 8-unit cross at its centre. No arrow |
| a drag | paints (or erases); the overlay follows; one press-to-release is one step of Undo |
| ⌥ held | the other of brush and eraser, for as long as it is held |
| ⇧ click | a straight stroke from the last point |
| `[` `]` | smaller and larger, by a tenth; `⇧[` `⇧]` softer and harder, by ten |
| settings | the pill's popover: 大小, 硬度, 流量, each a `ValueSlider` (label, track, a 56 box) |

The numbers' units are RFC-052's (a size is a share of the photograph's long edge, so a brush is the same
brush at every zoom); the drawing's 120 is a stand-in.

### 6.3 The gradients (drawings 05, 06)

**线性渐变.** Drag from where the effect is full to where it ends. Three lines across the picture: the
100 % line and the 0 % line solid (1.5 white over a shadow), the middle one dashed (1); small tags name the
two ends while the pointer is down. Handles: the middle's (6.5) moves the gradient; each end's (4.5) turns
and stretches it about the other end, ⇧ holding 15° steps. Hit targets are 22 units round a handle and 8
either side of a line (a line drags like its handle).

**径向渐变.** Drag an ellipse out from its centre (⇧: a circle). Inside is the mask: 100 % within the dashed
ring, falling to 0 at the outer line. Handles: the centre's moves it; the four on the outer line set the two
radii (⌥: both together); a drag from just outside a handle turns it; the accent handle on the dashed ring
sets how wide the fall is.

Both: the lines stay while the tool is lit and that part is the chosen one; Delete removes the chosen part;
arrow keys are not taken (they are the rows' and the photographs').

### 6.4 人 (drawing 10)

The first click on 人 looks for people in the photograph, then opens the menu: 全部人物 with the count, then a
row for each person, 40 high with a 28 square of that person. The row under the pointer lights that person
in the overlay on the picture. A click makes the layer. Nobody found: one grey row, 未找到人物. The second
time the menu opens at once. Parts of a person are M3.

### 6.5 The photograph's geometry changed (drawing 14)

When 镜头校正 is switched after a mask was made, the layer's row wears the mark, and the first line of its
蒙版 section says "镜头校正已更改，蒙版的位置可能偏移。" with 重新查找 (a found mask only) and 保持现状. Either
clears the mark. The picture shows the mask where it now lies, so the drift can be seen.

## 7. 组合蒙版 and 完善蒙版…

**组合蒙版** (drawing 08): a popover under the button. A `SegmentedSwitch` 加 · 减去 · 相交 (加 at first), then
主体, 背景, 人 ›, a rule, 画笔, 线性渐变, 径向渐变. A click on a found mask applies it with that join at once and
closes; a click on a drawn tool lights it with that join, said in the tool's pill ("减去 · 画笔 · 大小 120"),
until it is put down. Capture One asks for a third click, 创建蒙版; this does not. **M2's entries (亮度范围,
魔术画笔, 点选) are left out**, not listed disabled: what is not built is not shown (drawing 17 has them).

**完善蒙版…** (drawing 09): a popover with ↺ and, in M1, one slider, 羽化. Live: the mask alone is on the
picture while it is open. M2's 扩张 / 收缩 and 边缘半径 are drawn dashed.

**A layer's menu** (drawing 18; ⋯ and the secondary click are one list): 重命名, 复制图层, 显示蒙版 `M`,
仅显示蒙版 `⌥M`, 反相, 改为作用于成片 (or 场景) with "调整从零开始" as its second line, 删除图层 `⌫`.

## 8. Keyboard

Built on LAYERS-SPEC §7: a plain key is a registry entry (`HiddenKeyEquivalent` → `MacShortcutRegistry`),
never a `keyboardShortcut`; the entries are the develop page's and are enabled under `macPhotoKeysFree`'s
conditions; none sets `allowsDuringTextEditing` (trap 32), so a slider's number box and a row being renamed
keep their keys.

| key | does | when |
|---|---|---|
| `M` | the overlay on and off | a mask layer picked |
| `⌥M` | the mask alone | a mask layer picked |
| `B` / `E` | 画笔 / 橡皮 | the develop page in front |
| `[` `]` | 缩小画笔 / 放大画笔 | 画笔 or 橡皮 lit |
| `⇧[` `⇧]` | 降低硬度 / 提高硬度 | 画笔 or 橡皮 lit |
| ⌥ held | the other of brush and eraser | 画笔 or 橡皮 lit |
| Esc | 放下工具; with no tool lit, closes a popover | a tool lit |
| ⌫ | removes the chosen part; with none chosen and a mask layer picked, the layer | no field being edited |
| ↑ / ↓ | the previous / next row, mask rows included | as today |
| ⌘Z / ⇧⌘Z | every action here is one step | unchanged |

**What the registry has today** (`Sources/Mac/MacShortcuts.swift`, read 2026-11-12): the develop page's
plain keys are Space, `-` `*` `+` (labels), `G`, `C`, `P`, `Y`, `,` `.`, `F`, the digits (ratings), the
arrows and Return (摆放). **`M`, `B`, `E`, `[` and `]` are bound nowhere.** Two things to hold at build:
⌫ is the Curve panel's Delete Point while a curve point is chosen (`CurvePanel.swift`), and the registry
answers with the last enabled registration, so the layer's ⌫ is enabled only with a mask layer picked and
no curve point chosen; and `[` `]` with ⇧ arrive as `{` `}` on a US layout, so they are registered by
their unshifted input with the shift flag, and checked on an ISO keyboard. `tools/mac_shortcuts_check.py`
was read, not run. Gradients have no plain key in M1: Capture One's `G` is this app's Grid.

## 9. VoiceOver

| element | label | value | traits and actions |
|---|---|---|---|
| the panel | 图层 | "3 个图层，选中渐变 1" | header; fold action as today |
| + / − | 新建图层 / 删除图层 | | button; − dimmed says why by its state |
| 主体 · 背景 · 人 | the word | 正在查找 while it looks | button; 人 opens a menu |
| a tool | its name | 已启用 when lit | button, selected when lit |
| the tool's pill | "画笔，大小 120" | | opens its settings |
| a mask row | its name | "场景，不透明度 60 %，已启用" | button, selected when picked; named actions for each item of its menu |
| a mask row's eye | 显示图层 | on or off | switch |
| 不透明度 | 不透明度 | "60 %" | adjustable, 5 % a step |
| the stage switch | 作用于 | 场景 or 成片 | adjustable; the line under it is its hint |
| a part's row | "加，主体" | on or off | button; actions 移除, 显示 / 隐藏 |
| the picture, a tool lit | "画笔，在画面上拖动" | | allows direct touch; a gradient's handles are adjustable elements named 100 % 线, 中线, 0 % 线, 中心, 羽化 |
| the picture's tag | "蒙版 · 主体 1" | | static |

A brush cannot be used without a pointer; 主体, 背景, 人 and both gradients (by their handles' adjustable
actions) can. Identifiers: `layers.add`, `layers.remove`, `layers.select.subject|background|people`,
`layers.tool.brush|linear|radial|eraser`, `layers.tool.pill`, `layers.row.mask.<n>`, `layers.eye.mask.<n>`,
`layers.opacity`, `layers.combine`, `layers.refine`, `layers.page.stage|mask|adjust|film-link`,
`layers.part.<n>`, `layers.part.<n>.eye|remove`, `mask.overlay`, `mask.alone`.

## 10. Strings

Every string, zh-Hans and en. `catalog`: a key `Localizable.xcstrings` has today with this zh (checked
against the file for the ones this design leans on: 背景, 场景, 调整, 重命名, 撤销, 着色, 高光, 阴影, 高光与阴影).
`catalog (2.4.0)`: added by the 图层 build. `new`: added by this design (zh-Hant and ja go to
`l10n-pending`). `future`: drawing 17 and 09's dashed part only, not shipped. Printed by
`gen_masks.py --strings`.

| key | zh-Hans | en | status |
|---|---|---|---|
| `new_layer` | 新建图层 | New Layer | new |
| `delete_layer` | 删除图层 | Delete Layer | new |
| `subject` | 主体 | Subject | new |
| `background` | 背景 | Background | catalog |
| `people` | 人 | People | new |
| `brush` | 画笔 | Brush | new |
| `linear` | 线性渐变 | Linear Gradient | new |
| `radial` | 径向渐变 | Radial Gradient | new |
| `eraser` | 橡皮 | Eraser | new |
| `opacity` | 不透明度 | Opacity | new |
| `combine_masks` | 组合蒙版 | Combine Masks | new |
| `refine_mask` | 完善蒙版… | Refine Mask… | new |
| `refine_title` | 完善蒙版 | Refine Mask | new |
| `stage_scene` | 场景 | Scene | catalog |
| `stage_finished` | 成片 | Finished | new |
| `mask_count` | 蒙版 %@ | %@ masks | new |
| `finding` | 正在查找 | Finding | new |
| `name_subject` | 主体 1 | Subject 1 | new |
| `name_background` | 背景 1 | Background 1 | new |
| `name_person` | 人物 1 | Person 1 | new |
| `name_gradient` | 渐变 1 | Gradient 1 | new |
| `name_gradient2` | 渐变 2 | Gradient 2 | new |
| `name_brush` | 画笔 1 | Brush 1 | new |
| `name_layer` | 图层 1 | Layer 1 | new |
| `applies_to` | 作用于 | Works on | new |
| `scene_note` | 改变到达胶片的光，胶片随之重新冲洗。 | Changes the light that reaches the film. The film develops again. | new |
| `finished_note` | 改变成片，胶片与相纸不重做。 | Changes the finished picture. The film and the print stay as made. | new |
| `mask` | 蒙版 | Mask | new |
| `invert` | 反相 | Invert | new |
| `feather` | 羽化 | Feather | new |
| `join_add` | 加 | Add | new |
| `join_subtract` | 减去 | Subtract | new |
| `join_intersect` | 相交 | Intersect | new |
| `mask_empty` | 蒙版是空的：选一个工具把它画出来。 | The mask is empty. Choose a tool and draw it. | new |
| `tint_shift` | 着色 | Tint | catalog |
| `highlights` | 高光 | Highlights | catalog |
| `shadows` | 阴影 | Shadows | catalog |
| `hl_sh` | 高光与阴影 | Highlights & Shadows | catalog |
| `adjust` | 调整 | Adjust | catalog |
| `belongs_film_edit` | 曲线、色轮、HSL、通道与镜头属于「胶片」 | Curve, wheels, HSL, channels and lens are Film’s | new |
| `restarted` | 这一层的调整已从零开始。 | Its adjustments start again from zero. | new |
| `undo` | 撤销 | Undo | catalog |
| `geometry_moved` | 镜头校正已更改，蒙版的位置可能偏移。 | Lens correction changed: the mask may have moved. | new |
| `find_again` | 重新查找 | Find Again | new |
| `keep_as_is` | 保持现状 | Keep As It Is | new |
| `pair_refusal` | 蒙版图层目前用于单张照片 | Mask layers are for single photographs for now | new |
| `brush_size` | 大小 | Size | new |
| `hardness` | 硬度 | Hardness | new |
| `flow` | 流量 | Flow | new |
| `mask_tag` | 蒙版 · %@ | Mask · %@ | new |
| `show_mask` | 显示蒙版 | Show Mask | new |
| `mask_alone` | 仅显示蒙版 | Show Mask Alone | new |
| `all_people` | 全部人物 | All People | new |
| `person_n` | 人物 %@ | Person %@ | new |
| `no_people` | 未找到人物 | No people found | new |
| `rename` | 重命名 | Rename | catalog |
| `duplicate_layer` | 复制图层 | Duplicate Layer | new |
| `to_finished` | 改为作用于成片 | Work on Finished | new |
| `to_scene` | 改为作用于场景 | Work on Scene | new |
| `starts_again` | 调整从零开始 | its adjustments start again | new |
| `larger_brush` | 放大画笔 | Larger Brush | new |
| `smaller_brush` | 缩小画笔 | Smaller Brush | new |
| `harder_brush` | 提高硬度 | Harder Brush | new |
| `softer_brush` | 降低硬度 | Softer Brush | new |
| `put_tool_down` | 放下工具 | Put the Tool Down | new |
| `vo_layers` | %@ 个图层，选中%@ | %@ layers, %@ picked | catalog |
| `vo_layer_value` | %@，不透明度 %@ %，%@ | %@, opacity %@ %, %@ | new |
| `vo_shown` | 已启用 | on | new |
| `vo_hidden` | 已关闭 | off | new |
| `vo_part` | %@ · %@ | %@, %@ | new |
| `vo_eye` | 显示图层 | Show Layer | new |
| `vo_canvas_tool` | %@，在画面上拖动 | %@: drag on the picture | new |
| `handle_full` | 100 % 线 | 100 % line | new |
| `handle_mid` | 中线 | Middle line | new |
| `handle_zero` | 0 % 线 | 0 % line | new |
| `handle_centre` | 中心 | Centre | new |
| `magic_brush` | 魔术画笔 | Magic Brush | future |
| `heal` | 修复 | Heal | future |
| `clone` | 仿制 | Clone | future |
| `sky` | 天空 | Sky | future |
| `luma_range` | 亮度范围 | Luma Range | future |
| `click_select` | 点选 | Click to Select | future |
| `edge_radius` | 边缘半径 | Edge Radius | future |
| `grow` | 扩张 / 收缩 | Expand / Contract | future |
| `enlarger_stage` | 放大机 | Enlarger | future |
| `not_in_m1` | M2 / M3 · 本次不做 | M2 / M3 · not in M1 | future |
| `all` | 全部 | All | catalog |
| `as_shot` | 原照设置 | As Shot | catalog |
| `belongs_film` | 胶片、相纸与效果属于「胶片」 | Film, paper and effects belong to Film | catalog (2.4.0) |
| `brightness` | 亮度 | Brightness | catalog |
| `contrast` | 对比度 | Contrast | catalog |
| `decode` | 解码 | Decode | catalog |
| `developed` | 已冲洗 | Developed | catalog |
| `exposure` | 曝光 | Exposure | catalog |
| `film` | 胶片 | Film | catalog |
| `film_exposure` | 胶片曝光 | Film Exposure | catalog |
| `film_paper` | 胶片与相纸 | Film & Paper | catalog |
| `format` | 格式 | Format | catalog |
| `layers` | 图层 | Layers | catalog (2.4.0) |
| `paper` | 相纸 | Paper | catalog |
| `saturation` | 饱和度 | Saturation | catalog |
| `temperature` | 色温 | Temperature | catalog |
| `tint` | 色调 | Tint | catalog |
| `tone` | 色调 | Tone | catalog |
| `vibrance` | 鲜艳度 | Vibrance | catalog |
| `white_balance` | 白平衡 | White Balance | catalog |

Notes on the words:

- 完善蒙版… ends in an ellipsis because it opens something. No label is cut anywhere.
- 色调 is two things in the catalogue, Tone (Edit's tool) and Tint (the white balance's). A 场景 layer's
  third slider is Tint, 色调, as Decode's is; a 成片 layer's is Edit's 着色 beside 色温, as Edit has it.
- 作用于 is "Works on" in English, not "Applies to", so the two stage names read as places: Works on Scene.
- 人 is the button and 人物 the things found (人物 1, 全部人物), as Capture One has 人 and its people.
- `Size` is 尺寸 in the catalogue (a film's). A brush's is 大小, a new key with its own context.

## 11. How it maps onto the model that exists

`LayerRules.swift` holds the panel's rules with no view in them, and stays the place.

| the design | in `LayerRules` today | what it takes |
|---|---|---|
| a mask layer's row | `LayerPick` has `.film`, `.frame`, `.exposure` | a case `.mask(UUID)` (the layer's id); `key` gives `mask.<n>` |
| what a row shows | `LayerRow.Content`: film, photograph, missing, empty; `Eye`: none, shown, alone, out | `Content.mask(stage:)`; `Eye.on` and `.off` beside the double's three; `opacity`, `marked` on the row |
| which rows | `rows(_:alone:has:)` from the piece | the piece's rows, then the edit's mask layers, newest first: a second argument, the layers (RFC-052's model) |
| a single photograph unfolds | `isOneLine(_:)` is `piece.isSingle` | false on the Mac |
| the heights | `height(_:folded:)`: 32, 128, 172.5 | §2's: the two rows when the piece takes masks, 30 a row to five, 不透明度 and the buttons when a mask layer exists |
| what a pick shows | `page(_:piece:mode:has:)` → `.film`, `.picture`, `.empty`, `.standsDown` | `.mask(stage)`, the same in both modes |
| ↑ ↓ | `step(_:by:in:among:)` | unchanged: it walks whatever rows there are |
| the folded words | `summary(_:in:)` | the count before the name when mask layers exist |
| + on a pair or a double | none | `takesMasks(_ piece:)` and the line of §4.4, beside `refusal` |

Gaps, none of which this design fills:

| | gap |
|---|---|
| G1 | the layers' model, their storage, and the pass that applies them are RFC-052's; the panel is drawn against their shape, not their code |
| G2 | `OpenFrameSession.layerPick` is 胶片 for a single photograph by construction: a single photograph has no stored pick. It needs one (`maskPick`), kept across the modes as the pair's is |
| G3 | the canvas has no tool layer: a brush's cursor and a gradient's handles need a view over the picture that maps the pointer to the photograph's own coordinates through the crop, the turns and the film edge, the mapping `PieceMarks` and the crop stage already hold |
| G4 | `AdjustColumn` reads and writes `session.shownAdjustments`; a 成片 layer's page needs the same sections bound to a layer's values |
| G5 | Catalyst popovers anchored in a pinned card (the pill's, the two buttons') have not been tried in this column; the fallback is the app's own floating panel as the loupe uses |
| G6 | how fast a 场景 layer's develop lands under a stroke is not measured (PRD-E M0); the drawings assume "when the pointer rests", as every film-side control |

## 12. Build plan (after approval, and after RFC-052's M0)

**New files** (`app/SpektraLab/Sources/Features/Layers/`): `MaskRules.swift` (Foundation only: names and
numbering, the join's words, what the pill says, which controls a stage has, the notice's condition),
`MaskRows.swift` (the row, the selection and tool rows, the pill), `MaskPage.swift` (the switch, 蒙版, 调整,
the foot), `MaskPopovers.swift` (the brush's, 组合蒙版, 完善蒙版…, 人's menu), `MaskStage.swift` (the view over
the picture: cursor, handles, overlay, the mask alone, the tag), `Mac/Layers/MacMasksCheck.swift`,
`tools/masks_selftest.swift`.

**Changed**: `LayerRules.swift` (§11), `LayersPanel.swift` (the head's buttons, the two rows, 不透明度 where
Balance is), `PadDevelopPage.swift` (the keys), `DevelopCanvas.swift`, `AdjustColumn.swift` (G4),
`MacInfoStrip` (仅显示蒙版), `Localizable.xcstrings` through `tools/localization_add.py`, `MacDriver` (steps
`mask.subject`, `mask.brush`, `mask.gradient`, `mask.stage`, `mask.combine`). Then `python3 gen_project.py`.
Notes edited in the same commits: `PAGES.md` §2, LAYERS-SPEC §15 (a pointer here). None of `AGENTS.md`,
`ARCHITECTURE.md`, `API-SPEC-*`, `CONTRACT-*` for the interface; RFC-052 names its own.

**Order**, each a commit that records its gate:

1. `LayerRules` and `MaskRules` with `masks_selftest`, red before green: rows, order, names, heights (140,
   254.5, 284.5, the cap at 344.5), the page per pick and mode, the summary, the pair's refusal, and every
   string of §10 measured against its room in both languages.
2. The panel's shell with no tool working: head, two rows, mask rows from a stored edit, 不透明度, the fold.
   A photograph with no layers is byte-same in `same_snapshots.sh` apart from the unfolded card.
3. The page: the switch and the notice, 调整 for both stages on RFC-052's model.
4. The stage over the picture: both gradients and their handles; the overlay; the mask alone.
5. 画笔 and 橡皮, the pill and its popover, the keys.
6. 主体, 背景, 人; the working state; the menu.
7. 组合蒙版, the parts list, 反相, 完善蒙版….
8. The geometry mark; VoiceOver; Debug and Release builds; `screenshots/` retaken (said in the commit).

**`--masks-check`** (the running window, a scratch home, fixtures copied, a `--self-test` that breaks each
mapping and expects red), for PRD-E §7:

| PRD-E §7 | the case |
|---|---|
| 1 identity | a full-frame layer at 曝光 e against 胶片曝光 moved by e, on the canvas; each 成片 control against Edit's own |
| 2 neutral | no layers, layers off, opacity 0: the canvas byte-same as without the feature |
| 3 the meter | the info strip's solved exposure unchanged by a +2 场景 layer over half the frame |
| 5 canvas is export | a brush, a gradient and a subject in each stage: canvas against the exported file, and the mask's edge within a pixel of the smaller |
| 6 geometry | a stroke painted, then both crops, a straighten, a turn, a flip, a film edge: the overlay's centroid stays on the same photograph point |
| 7 every surface | the page, the zoom, a browser tile, the Light Table and the histogram agree; the overlay and the mask alone are in none of the stored ones |
| 8 kept | quit and reopen: rows, picks' names, opacity, stage and the mask's picture equal |
| panel | the rows are the model after each of add, remove, eye, rename, stage switch, undo, redo |
| stage switch | the mask's picture unchanged across it; the adjustments zero; one Undo restores both |

A person paints, drags both gradients' handles and uses the menus with a mouse and a trackpad before any of
it is called seen (PRD-E §7.9).

## 13. Decisions for the owner

Only what the drawings raised; PRD-E §9 has the product's ten.

| | decision | recommended | the other |
|---|---|---|---|
| 1 | how a row says its stage | **the word**, 场景 or 成片, at the row's end | a glyph (it would have to be learnt) |
| 2 | 组合蒙版's steps | **join, then a tool: two clicks** | Capture One's three, with 创建蒙版 |
| 3 | what M1's menus show of M2 | **nothing** (drawn only in 17) | listed disabled with 稍后 |
| 4 | where 羽化 lives | **one slider, in 完善蒙版…; the page shows its value** | a slider on the page as well |
| 5 | a stage switch on a layer with adjustments | **at once, with a line and 撤销** | an alert first |
| 6 | the panel on a pair or a double in M1 | **the two rows hidden, + − dimmed, one line** | the two rows shown dimmed |
| 7 | a long list | **the card stops at five rows and scrolls inside** | the card grows without limit |
| 8 | plain keys | **`M`, `⌥M`, `B`, `E`, `[`, `]`** (Capture One's, where free) | no plain keys in M1 |
| 9 | the folded head | **"蒙版 3 · 渐变 1"** | the picked row's name alone |

Smaller defaults taken: the newest layer sits directly under 胶片; 人's rows light the person on the picture
on hover; a gradient's end tags show only while the pointer is down; ⌫ on a picked layer with no part
chosen removes the layer.

## 14. The drawings

All in `app/SpektraLab/design/masks/`, as `NAME.zh.svg` and `.png`; those marked en also as `NAME.en.*`.

| | name | shows | en |
|---|---|---|---|
| 01 | `01-panel-no-masks` | 冲洗, a single photograph, the panel unfolded with no mask layer | yes |
| 02 | `02-subject-scene-page` | after 主体: 主体 1 picked, 场景, its page | yes |
| 03 | `03-finished-layer-edit` | 编辑, a 成片 layer and Edit's six tools on its page | yes |
| 04 | `04-brush` | the brush: cursor, overlay, the pill and its popover | |
| 05 | `05-linear-gradient` | a linear gradient's lines, handles and overlay | yes |
| 06 | `06-radial-gradient` | a radial gradient: ellipse, feather ring, handles | |
| 07 | `07-mask-alone` | the mask alone, with its tag | yes |
| 08 | `08-combine-masks` | 组合蒙版 open | yes |
| 09 | `09-refine-mask` | 完善蒙版…: 羽化, and M2's part dashed | |
| 10 | `10-people` | 人's menu | |
| 11 | `11-stage-switch` | the stage changed on a layer with adjustments | |
| 12 | `12-several-layers` | several layers, one off, one at 60 %; the folded head | |
| 13 | `13-pair-stands-down` | a pair in M1 | |
| 14 | `14-geometry-changed` | the mark and the page's line | |
| 15 | `15-anatomy` | the panel at 2x with its measurements | yes |
| 16 | `16-states` | every state of a mask row, a tool and a selection button | |
| 17 | `17-later` | M2 and M3, dashed; **not shipping** | |
| 18 | `18-layer-menu` | a layer's menu, and a three-part mask on the page | |

**Added to the brief's list:** 18 (the layer's menu had no drawing, and it is where Rename, Duplicate and
Delete live). **Merged:** the brief's "folded head's summary" is an inset of 12. Drawings 03, 06, 14 and 18
are drawn in a taller window (900–936 units) so the page's last row is in view.

## 15. Not done, and not verified

- **Nothing is built or run.** No line of Swift was written, and no claim here about the running app has
  been seen in it.
- The pictures are stand-ins: no drawing shows a layer's effect, grain across a mask's edge, or a real
  found mask's edge. The overlay over a dark subject reads darker than it will over a photograph.
- Light Mode is not drawn. zh-Hant and ja are not written. English is drawn for seven of the eighteen; the
  generator measures every string in both languages for all of them.
- The window's bar is the 图层 design's approximation of `Screenshot_v2.png`, not measured again.
- Popovers are drawn as the Mac's; how Catalyst presents one from the pinned card is G5.
- The keys' freedom is from reading `MacShortcuts.swift`; `mac_shortcuts_check.py` was not run, and `[` `]`
  were not tried on a non-US keyboard.
- The brush's numbers, the feather's scale and a gradient's exact ramp are RFC-052's; the drawings show
  their shape only.
- Not designed: masks on a pair's frame or a double's exposure (M2); 修复 and 仿制 on the picture (M3); 拷贝设置
  with layers (M2); a tablet's pressure.
