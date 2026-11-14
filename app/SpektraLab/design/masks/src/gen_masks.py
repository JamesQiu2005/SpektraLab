#!/usr/bin/env python3
"""Generates the mask layers' drawings (PRD-E, 2026-11-12): the 图层 panel with masks, a layer's page, the tools
on the picture.

    python3 app/SpektraLab/design/masks/src/gen_masks.py            # -> design/masks/*.svg
    python3 app/SpektraLab/design/masks/src/gen_masks.py --png      # ... and a PNG beside each, at 2x
    python3 app/SpektraLab/design/masks/src/gen_masks.py --strings  # the strings table of MASKS-SPEC.md §10

What each drawing is, and every number in it, is MASKS-SPEC.md beside the drawings. The kit and the parts the
图层 design already drew (the window, the bar, a picture's row, the histogram, a menu) are imported from
`design/layers/src` and not copied: a number changed there is changed here. A line that does not fit its room
stops the run (`fits`), in either language.

Units: one unit is one scene point of the develop page (0.9625 of a Mac point at the 100 % interface scale);
the column is 393.
"""
import math, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "layers", "src")))
sys.dont_write_bytecode = True
import kit as K
import gen_layers as GL
from kit import (Drawing, tw, CW, BG, CARD, PLOT, RULE, PANEL, TEXT, TEXT2, DIM, FAINT, ACCENT, SEL, ONSEL,
                 SELFRAME, WALL, DISABLED, picture, fold_header, fold_rule, toggle, small_round, slider, chip,
                 pill_menu, segmented, note, capsule_button, wrap)
from gen_layers import (Page, toolbar, info_strip, wall, canvas_box, canvas_tag, layer_row, menu_panel, sheet,
                        dim_h, dim_v, fits, HEAD, STRIP, M, L_INSET, L_HEAD, L_ROW, L_ROWPAD, L_GAP, ROW_X, EYE_CX,
                        THUMB_X, THUMB_W, THUMB_H, NAME_X, TRAIL_X)

OUT = os.path.dirname(HERE)
LANG = "zh"

# The overlay: system red in sRGB, at half strength where the mask is 1. (The app converts the literal to the
# working space before it reaches the drawable: trap 27.)
OVERLAY, OVERLAY_OP = "#FF3B30", 0.5
POP, POP_EDGE = "#2A2D33", "#4a4e57"
BLUE = "#7fb6ff"

# ---------------------------------------------------------------------------------------------------------
# The words this design adds or decides. Words it only reuses (胶片, 冲洗, 曝光 …) stay in gen_layers' table and
# are listed by `--strings` with the status they have there.

MS = {
    # the panel
    "new_layer": ("新建图层", "New Layer", "new"),
    "delete_layer": ("删除图层", "Delete Layer", "new"),
    "subject": ("主体", "Subject", "new"),
    "background": ("背景", "Background", "catalog"),
    "people": ("人", "People", "new"),
    "brush": ("画笔", "Brush", "new"),
    "linear": ("线性渐变", "Linear Gradient", "new"),
    "radial": ("径向渐变", "Radial Gradient", "new"),
    "eraser": ("橡皮", "Eraser", "new"),
    "opacity": ("不透明度", "Opacity", "new"),
    "combine_masks": ("组合蒙版", "Combine Masks", "new"),
    "refine_mask": ("完善蒙版…", "Refine Mask…", "new"),
    "refine_title": ("完善蒙版", "Refine Mask", "new"),
    "stage_scene": ("场景", "Scene", "catalog"),
    "stage_finished": ("成片", "Finished", "new"),
    "mask_count": ("蒙版 %@", "%@ masks", "new"),
    "finding": ("正在查找", "Finding", "new"),
    # names a new layer is given
    "name_subject": ("主体 1", "Subject 1", "new"),
    "name_background": ("背景 1", "Background 1", "new"),
    "name_person": ("人物 1", "Person 1", "new"),
    "name_gradient": ("渐变 1", "Gradient 1", "new"),
    "name_gradient2": ("渐变 2", "Gradient 2", "new"),
    "name_brush": ("画笔 1", "Brush 1", "new"),
    "name_layer": ("图层 1", "Layer 1", "new"),
    # the layer's page
    "applies_to": ("作用于", "Works on", "new"),
    "scene_note": ("改变到达胶片的光，胶片随之重新冲洗。", "Changes the light that reaches the film. The film develops again.", "new"),
    "finished_note": ("改变成片，胶片与相纸不重做。", "Changes the finished picture. The film and the print stay as made.", "new"),
    "mask": ("蒙版", "Mask", "new"),
    "invert": ("反相", "Invert", "new"),
    "feather": ("羽化", "Feather", "new"),
    "join_add": ("加", "Add", "new"),
    "join_subtract": ("减去", "Subtract", "new"),
    "join_intersect": ("相交", "Intersect", "new"),
    "mask_empty": ("蒙版是空的：选一个工具把它画出来。", "The mask is empty. Choose a tool and draw it.", "new"),
    "tint_shift": ("着色", "Tint", "catalog"),
    "highlights": ("高光", "Highlights", "catalog"),
    "shadows": ("阴影", "Shadows", "catalog"),
    "hl_sh": ("高光与阴影", "Highlights & Shadows", "catalog"),
    "adjust": ("调整", "Adjust", "catalog"),
    "belongs_film_edit": ("曲线、色轮、HSL、通道与镜头属于「胶片」", "Curve, wheels, HSL, channels and lens are Film’s", "new"),
    "restarted": ("这一层的调整已从零开始。", "Its adjustments start again from zero.", "new"),
    "undo": ("撤销", "Undo", "catalog"),
    "geometry_moved": ("镜头校正已更改，蒙版的位置可能偏移。", "Lens correction changed: the mask may have moved.", "new"),
    "find_again": ("重新查找", "Find Again", "new"),
    "keep_as_is": ("保持现状", "Keep As It Is", "new"),
    "pair_refusal": ("蒙版图层目前用于单张照片", "Mask layers are for single photographs for now", "new"),
    # the brush
    "brush_size": ("大小", "Size", "new"),
    "hardness": ("硬度", "Hardness", "new"),
    "flow": ("流量", "Flow", "new"),
    # on the picture
    "mask_tag": ("蒙版 · %@", "Mask · %@", "new"),
    "show_mask": ("显示蒙版", "Show Mask", "new"),
    "mask_alone": ("仅显示蒙版", "Show Mask Alone", "new"),
    # people
    "all_people": ("全部人物", "All People", "new"),
    "person_n": ("人物 %@", "Person %@", "new"),
    "no_people": ("未找到人物", "No people found", "new"),
    # a layer's menu
    "rename": ("重命名", "Rename", "catalog"),
    "duplicate_layer": ("复制图层", "Duplicate Layer", "new"),
    "to_finished": ("改为作用于成片", "Work on Finished", "new"),
    "to_scene": ("改为作用于场景", "Work on Scene", "new"),
    "starts_again": ("调整从零开始", "its adjustments start again", "new"),
    # keys, as the Keyboard Shortcuts menu names them
    "larger_brush": ("放大画笔", "Larger Brush", "new"),
    "smaller_brush": ("缩小画笔", "Smaller Brush", "new"),
    "harder_brush": ("提高硬度", "Harder Brush", "new"),
    "softer_brush": ("降低硬度", "Softer Brush", "new"),
    "put_tool_down": ("放下工具", "Put the Tool Down", "new"),
    # VoiceOver
    "vo_layers": ("%@ 个图层，选中%@", "%@ layers, %@ picked", "catalog"),
    "vo_layer_value": ("%@，不透明度 %@ %，%@", "%@, opacity %@ %, %@", "new"),
    "vo_shown": ("已启用", "on", "new"),
    "vo_hidden": ("已关闭", "off", "new"),
    "vo_part": ("%@ · %@", "%@, %@", "new"),
    "vo_eye": ("显示图层", "Show Layer", "new"),
    "vo_canvas_tool": ("%@，在画面上拖动", "%@: drag on the picture", "new"),
    "handle_full": ("100 % 线", "100 % line", "new"),
    "handle_mid": ("中线", "Middle line", "new"),
    "handle_zero": ("0 % 线", "0 % line", "new"),
    "handle_centre": ("中心", "Centre", "new"),
    # later, drawn dashed: not shipped in M1
    "magic_brush": ("魔术画笔", "Magic Brush", "future"),
    "heal": ("修复", "Heal", "future"),
    "clone": ("仿制", "Clone", "future"),
    "sky": ("天空", "Sky", "future"),
    "luma_range": ("亮度范围", "Luma Range", "future"),
    "click_select": ("点选", "Click to Select", "future"),
    "edge_radius": ("边缘半径", "Edge Radius", "future"),
    "grow": ("扩张 / 收缩", "Expand / Contract", "future"),
    "enlarger_stage": ("放大机", "Enlarger", "future"),
    "not_in_m1": ("M2 / M3 · 本次不做", "M2 / M3 · not in M1", "future"),
}
GL.S.update(MS)
USED = set()


def T(k):
    USED.add(k)
    return GL.S[k][0 if LANG == "zh" else 1]


def Tf(k, *args):
    s = T(k)
    for a in args:
        s = s.replace("%@", str(a), 1)
    return s


def cap(zh, en):
    return zh if LANG == "zh" else en


# ---------------------------------------------------------------------------------------------------------
# Stand-in pictures and their masks. `figure` is kit.pic_portrait's own geometry, so a mask lies on its subject.

def figure_path(cx, hy, r, bottom):
    return (f"M{cx - r * 2.3:.1f},{bottom:.1f} C{cx - r * 2.2:.1f},{hy + r * 1.37:.1f} {cx - r * 1.1:.1f},{hy + r * 1.1:.1f} "
            f"{cx:.1f},{hy + r * 1.1:.1f} C{cx + r * 1.1:.1f},{hy + r * 1.1:.1f} {cx + r * 2.2:.1f},{hy + r * 1.37:.1f} "
            f"{cx + r * 2.3:.1f},{bottom:.1f} Z")


def figure(d, cx, hy, r, bottom, fill, op=1):
    if op != 1:
        d.open(op=op)
    d.circle(cx, hy, r, fill)
    d.path(figure_path(cx, hy, r, bottom), fill=fill)
    if op != 1:
        d.close()


def portrait_geo(x, y, w, h):
    """kit.pic_portrait's head and shoulders: (cx, head's cy, head's r, bottom)."""
    r = min(w, h) * 0.19
    return x + w * 0.5, y + h * 0.36, r, y + h


def pic_group(d, x, y, w, h):
    ground = d.gradient([(0, "#cfd6cf"), (1, "#8f9a8c")])
    d.rect(x, y, w, h, ground)
    people = group_geo(x, y, w, h)
    for cx, hy, r, fill in (people[0], people[2], people[1]):       # the middle one stands in front
        figure(d, cx, hy, r, y + h + r, fill)


def group_geo(x, y, w, h):
    s = min(w, h)
    return [(x + w * 0.22, y + h * 0.46, s * 0.13, "#2b2623"), (x + w * 0.52, y + h * 0.38, s * 0.16, "#1d1a18"),
            (x + w * 0.80, y + h * 0.50, s * 0.12, "#3a302a")]


K.PICS["group"] = pic_group


def fade(d, color, x1, y1, x2, y2, stops):
    """A linear gradient of one colour's opacity, in the drawing's own coordinates."""
    ident = d.uid("f")
    s = "".join(f'<stop offset="{o}" stop-color="{color}" stop-opacity="{a}"/>' for o, a in stops)
    d.defs.append(f'<linearGradient id="{ident}" gradientUnits="userSpaceOnUse" x1="{x1:.2f}" y1="{y1:.2f}" '
                  f'x2="{x2:.2f}" y2="{y2:.2f}">{s}</linearGradient>')
    return f"url(#{ident})"


def radial_fade(d, color, cx, cy, rx, ry, angle, stops):
    ident = d.uid("r")
    s = "".join(f'<stop offset="{o}" stop-color="{color}" stop-opacity="{a}"/>' for o, a in stops)
    d.defs.append(f'<radialGradient id="{ident}" gradientUnits="userSpaceOnUse" cx="0" cy="0" r="1" '
                  f'gradientTransform="translate({cx:.2f},{cy:.2f}) rotate({angle}) scale({rx:.2f},{ry:.2f})">{s}</radialGradient>')
    return f"url(#{ident})"


# A mask's thumbnail: white on black, in the row's 30 x 20 slot.

def thumb_ground(d, x, y, w, h):
    d.rect(x, y, w, h, "#050506", r=3)


def thumb_subject(d, x, y, w, h, inverse=False):
    c = d.clip(x, y, w, h, 3)
    d.open(clip=c)
    d.rect(x, y, w, h, "#f2f0ec" if inverse else "#050506")
    cx, hy, r, b = portrait_geo(x, y, w, h)
    figure(d, cx, hy, r, b, "#050506" if inverse else "#f2f0ec")
    d.close()


def thumb_linear(d, x, y, w, h):
    c = d.clip(x, y, w, h, 3)
    d.open(clip=c)
    d.rect(x, y, w, h, d.gradient([(0, "#f2f0ec"), (0.35, "#f2f0ec"), (0.75, "#050506"), (1, "#050506")]))
    d.close()


def thumb_radial(d, x, y, w, h):
    c = d.clip(x, y, w, h, 3)
    d.open(clip=c)
    d.rect(x, y, w, h, "#050506")
    d.add(f'<ellipse cx="{x + w / 2:.2f}" cy="{y + h * 0.45:.2f}" rx="{w * 0.2:.2f}" ry="{h * 0.36:.2f}" '
          f'fill="{radial_fade(d, "#f2f0ec", x + w / 2, y + h * 0.45, w * 0.2, h * 0.36, 0, [(0, 1), (0.55, 1), (1, 0)])}"/>')
    d.close()


def thumb_brush(d, x, y, w, h):
    c = d.clip(x, y, w, h, 3)
    d.open(clip=c)
    d.rect(x, y, w, h, "#050506")
    d.path(f"M{x + w * 0.12:.1f},{y + h * 0.72:.1f} C{x + w * 0.3:.1f},{y + h * 0.2:.1f} {x + w * 0.55:.1f},{y + h * 0.9:.1f} "
           f"{x + w * 0.86:.1f},{y + h * 0.36:.1f}", stroke="#f2f0ec", sw=h * 0.34)
    d.close()


def thumb_empty(d, x, y, w, h):
    d.rect(x, y, w, h, "#050506", r=3)


THUMBS = {"subject": thumb_subject, "background": lambda d, x, y, w, h: thumb_subject(d, x, y, w, h, True),
          "linear": thumb_linear, "radial": thumb_radial, "brush": thumb_brush, "empty": thumb_empty}


# ---------------------------------------------------------------------------------------------------------
# The panel with masks. Every number is MASKS-SPEC.md §2; what is the 图层 panel's own is imported.

SEL_ROW = 36      # the selection row: buttons 28 high, 4 over and under
TOOL_ROW = 36     # the tool row: slots 30 x 28, 4 over and under
OPAC = 44.5       # the rule, ValueSlider's 40, 4 under
BTNS = 40         # 2, the buttons' 28, 10
CARD_X0, CARD_X1 = L_INSET + 14, CW - L_INSET - 14      # 26 … 367: the card's content
SLOT = 30
HEAD_MORE = CW - L_INSET - 21                            # ⋯'s centre, as built
HEAD_MINUS, HEAD_PLUS = HEAD_MORE - 28, HEAD_MORE - 56


def tool_glyph(d, kind, cx, cy, color, op=1):
    """A tool's glyph. Brush and eraser are Apple's symbols; the two gradients are drawn (the build draws
    them in `DrawnIcons`), since no symbol says "a gradient"."""
    if op != 1:
        d.open(op=op)
    if kind == "linear":
        d.rect(cx - 7.5, cy - 6, 15, 12, fade(d, color, cx - 7.5, 0, cx + 7.5, 0, [(0, 1), (1, 0.05)]), r=2.5)
        d.rect(cx - 7.5, cy - 6, 15, 12, None, r=2.5, stroke=color, sw=1)
    elif kind == "radial":
        d.circle(cx, cy, 7, radial_fade(d, color, cx, cy, 7, 7, 0, [(0, 1), (0.35, 1), (1, 0.05)]))
        d.circle(cx, cy, 7, None, stroke=color, sw=1)
    else:
        name = {"brush": "paintbrush.pointed", "eraser": "eraser", "magic": "wand.and.stars", "heal": "bandage",
                "clone": "seal", "luma": "sun.max", "click": "cursorarrow.rays", "subject": "person.crop.rectangle",
                "background": "photo", "people": "person.fill", "sky": "cloud"}[kind]
        d.sym(name, cx, cy, 13, 500, color)
    if op != 1:
        d.close()


def spinner(d, cx, cy, r=5.5, color=TEXT2):
    d.circle(cx, cy, r, None, stroke=color, sw=1.5, op=0.3)
    d.path(f"M{cx:.2f},{cy - r:.2f} A{r},{r} 0 0 1 {cx + r:.2f},{cy:.2f}", stroke=color, sw=1.5)


def select_button(d, x, y, w, key, state="rest", menu=False):
    """主体 · 背景 · 人: 28 high, radius 7. state: rest | hover | working | disabled."""
    label = T("finding") if state == "working" else T(key)
    if state == "disabled":
        d.open(op=DISABLED)
    d.rect(x, y, w, 28, "#3A3F47" if state == "hover" else CARD, r=7)
    lw_ = fits(label, 12.5, 500, w - 16 - 18 - (14 if menu else 0), "a selection button")
    total = 11 + 6 + lw_
    sx = x + (w - total - (10 if menu else 0)) / 2
    cy = y + 14
    if state == "working":
        spinner(d, sx + 5.5, cy)
    else:
        tool_glyph(d, key, sx + 5.5, cy, TEXT if state == "hover" else TEXT2)
    d.ctext(sx + 17, cy, label, 12.5, 500, TEXT if state in ("hover", "working") else TEXT2)
    if menu:
        d.sym("chevron.down", x + w - 11, cy, 8, 700, DIM)
    if state == "disabled":
        d.close()


def tool_button(d, cx, cy, kind, state="rest"):
    """A tool's slot, 30 x 28 (the glyph's ground 28 x 24, radius 6). state: rest | hover | on | disabled."""
    if state == "on":
        d.rect(cx - 14, cy - 12, 28, 24, ACCENT, r=6)
    elif state == "hover":
        d.rect(cx - 14, cy - 12, 28, 24, CARD, r=6)
    color = ONSEL if state == "on" else TEXT if state == "hover" else TEXT2
    tool_glyph(d, kind, cx, cy, color, op=DISABLED if state == "disabled" else 1)


M1_TOOLS = ["brush", "linear", "radial", None, "eraser"]
LATER_TOOLS = ["brush", "magic", "linear", "radial", None, "heal", "clone", None, "eraser"]


def tool_centres(tools):
    """The slots' centres, laid from the card's right edge: {kind: cx}, and the dividers' x."""
    x = CARD_X1 + 1
    centres, rules = {}, []
    for k in reversed(tools):
        if k is None:
            rules.append(x - 6)
            x -= 12
        else:
            centres[k] = x - SLOT / 2
            x -= SLOT
    return centres, rules, x


def tool_pill(d, y, text, room):
    """What the tool that is on is set to, and the way to its settings: at the tool row's leading end."""
    w = 12 + 16 + fits(text, 12, 500, room - 12 - 16 - 20, "the tool's pill") + 6 + 8 + 8
    cy = y + TOOL_ROW / 2
    d.rect(CARD_X0, cy - 12, w, 24, CARD, r=12)
    d.sym("slider.horizontal.3", CARD_X0 + 12 + 5, cy, 10, 600, TEXT2)
    d.ctext(CARD_X0 + 28, cy, text, 12, 500, TEXT)
    d.sym("chevron.down", CARD_X0 + w - 11, cy, 8, 700, DIM)
    return CARD_X0, cy, w


def mask_row(d, y, row, state="rest"):
    """A mask layer's row. row: name, stage ('scene' | 'finished'), thumb, on (its eye), opacity, warn."""
    cy = y + L_ROW / 2
    sel = state == "selected"
    if sel:
        d.rect(ROW_X, y + 1, CW - 2 * ROW_X, L_ROW - 2, SEL, r=6)
    elif state == "hover":
        d.rect(ROW_X, y + 1, CW - 2 * ROW_X, L_ROW - 2, CARD, r=6, op=0.5)
    ink = ONSEL if sel else TEXT
    quiet = ONSEL if sel else DIM
    on = row.get("on", True)
    if on:
        d.sym("eye", EYE_CX, cy, 11, 500, ink if sel else TEXT2, op=0.75)
    else:
        d.sym("eye.slash", EYE_CX, cy, 11, 500, quiet, op=0.8 if sel else 1)
    off = not on and not sel
    if off:
        d.open(op=DISABLED)
    ty = cy - THUMB_H / 2
    THUMBS[row["thumb"]](d, THUMB_X, ty, THUMB_W, THUMB_H)
    d.rect(THUMB_X + 0.25, ty + 0.25, THUMB_W - 0.5, THUMB_H - 0.5, None, r=3, stroke="#8a8a88" if sel else RULE, sw=0.5)
    stage = T("stage_scene" if row["stage"] == "scene" else "stage_finished")
    sw_ = tw(stage, 12, 500)
    x = TRAIL_X
    d.ctext(x, cy, stage, 12, 500, quiet, "end", op=0.85 if sel else 1)
    x -= sw_ + 10
    opacity = row.get("opacity", 100)
    if opacity != 100:
        text = f"{opacity} %"
        d.ctext(x, cy, text, 12, 500, quiet, "end", op=0.85 if sel else 1, mono=True)
        x -= tw(text, 12, 500) + 10
    if row.get("warn"):
        d.sym("exclamationmark.triangle", x - 7, cy, 12, 700, "#A8691C" if sel else ACCENT)
        x -= 12 + 10
    fits(row["name"], 13, 600, x - NAME_X, "a mask row's name")
    d.ctext(NAME_X, cy, row["name"], 13, 600 if sel else 500, ink)
    if off:
        d.close()
    return L_ROW


def masks_card(d, y, rows, sel=0, tool=None, pill=None, working=None, folded=False, summary=None, bar=True,
               tools=M1_TOOLS, hover=None, sel_hover=None, tool_hover=None, minus=None, later=()):
    """The 图层 card with masks at y. Returns (its height with the 6 under it, the places things are at)."""
    masks = [r for r in rows if r["kind"] == "mask"]
    picked = rows[sel] if sel is not None else None
    on_mask = bool(picked and picked["kind"] == "mask")
    h = L_HEAD
    if not folded:
        h += (SEL_ROW + TOOL_ROW if bar else 0) + L_ROW * len(rows) + L_ROWPAD + (OPAC + BTNS if masks else 0)
    d.rect(L_INSET, y, CW - 2 * L_INSET, h, PLOT, r=12)
    at = {"top": y, "height": h}
    cy = y + L_HEAD / 2
    d.sym("chevron.down", L_INSET + 20.5, cy, 10, 600, TEXT2, rotate=-90 if folded else 0)
    d.ctext(L_INSET + 34, cy, T("layers"), 13, 600, TEXT)
    if folded:
        right = CW - L_INSET - 14
        fits(summary, 12, 500, 250, "the folded panel's summary")
        d.ctext(right, cy, summary, 12, 500, TEXT2, "end")
        return h + L_GAP, at
    small_round(d, HEAD_MORE, cy, "ellipsis", pt=11, weight=700)
    small_round(d, HEAD_MINUS, cy, "minus", pt=11, weight=700, op=1 if (on_mask if minus is None else minus) else DISABLED)
    small_round(d, HEAD_PLUS, cy, "plus", pt=11, weight=700)
    at["head"] = cy
    yy = y + L_HEAD
    if bar:
        bw = (CARD_X1 - CARD_X0 - 16) / 3
        x = CARD_X0
        at["select"] = {}
        for k in ("subject", "background", "people"):
            state = "working" if working == k else "hover" if sel_hover == k else "rest"
            select_button(d, x, yy + 4, bw, k, state, menu=(k == "people"))
            at["select"][k] = (x, yy + 4, bw)
            x += bw + 8
        yy += SEL_ROW
        centres, rules, left = tool_centres(tools)
        tcy = yy + TOOL_ROW / 2
        for k, cx in centres.items():
            tool_button(d, cx, tcy, k, "on" if tool == k else "hover" if tool_hover == k else "rest")
        for rx in rules:
            d.rect(rx, yy + 8, 0.5, 20, RULE)
        at["tools"], at["tool_cy"], at["tool_left"] = centres, tcy, left
        if pill:
            at["pill"] = tool_pill(d, yy, pill, left - CARD_X0 - 8)
        yy += TOOL_ROW
    at["rows"] = []
    for i, row in enumerate(rows):
        state = "selected" if i == sel else "hover" if i == hover else "rest"
        at["rows"].append(yy)
        if row["kind"] == "mask":
            mask_row(d, yy, row, state)
        else:
            layer_row(d, yy, row, state)
        yy += L_ROW
    yy += L_ROWPAD
    if masks:
        op = 1 if on_mask else DISABLED
        d.rect(CARD_X0, yy, CARD_X1 - CARD_X0, 0.5, RULE)
        value = picked.get("opacity", 100) if on_mask else 100
        lw = tw(T("opacity"), 13.5, 600) + 2
        slider(d, yy + 0.5, T("opacity"), value / 100, f"{value} %", rest=None, x0=CARD_X0, x1=CARD_X1, label_w=lw,
               field_w=62, op=op)
        at["opacity"] = yy + 0.5
        yy += OPAC
        bw = (CARD_X1 - CARD_X0 - 8) / 2
        at["buttons"] = {}
        for i, k in enumerate(("combine_masks", "refine_mask")):
            bx = CARD_X0 + i * (bw + 8)
            if op != 1:
                d.open(op=op)
            d.rect(bx, yy + 2, bw, 28, "#4B5059" if k in later else CARD, r=7)
            lw_ = fits(T(k), 12.5, 500, bw - 16 - (14 if i == 0 else 0), "a panel button")
            if i == 0:
                d.ctext(bx + (bw - 10) / 2, yy + 16, T(k), 12.5, 500, TEXT, "middle")
                d.sym("chevron.down", bx + (bw - 10) / 2 + lw_ / 2 + 9, yy + 16, 8, 700, DIM)
            else:
                d.ctext(bx + bw / 2, yy + 16, T(k), 12.5, 500, TEXT, "middle")
            if op != 1:
                d.close()
            at["buttons"][k] = (bx, yy + 2, bw)
    return h + L_GAP, at


def film_row():
    return dict(name=T("film"), kind="film")


def mrow(name_key, stage, thumb, **kw):
    return dict(name=T(name_key), kind="mask", stage=stage, thumb=thumb, **kw)


# ---------------------------------------------------------------------------------------------------------
# A mask layer's page: the column under the panel while its row is picked.

def stage_switch(d, y, stage, notice=None, later=False):
    """作用于 [场景 | 成片], and under it what that stage is. Returns its height."""
    fold_rule(d, y)
    cy = y + 0.5 + 22
    d.ctext(16, cy, T("applies_to"), 12.5, 500, TEXT)
    titles = [T("stage_scene"), T("stage_finished")] + ([T("enlarger_stage")] if later else [])
    seg = 76
    for t_ in titles:
        fits(t_, 12.5, 600, seg - 12, "a stage's name")
    w = segmented(d, CW - 16, cy, titles, 0 if stage == "scene" else 1, seg=seg)
    if later:
        d.rect(CW - 16 - seg + 1, cy - 14 + 1, seg - 2, 26, PLOT, r=13, op=0.55)
        d.rect(CW - 16 - seg - 2, cy - 17, seg + 4, 34, None, r=8, stroke=ACCENT, sw=1, dash="4 3")
    yy = y + 0.5 + 44
    lines = wrap(T("scene_note" if stage == "scene" else "finished_note"), 11.5, 400, CW - 32)
    yy += note(d, 16, yy - 4, lines) + 6
    if notice:
        yy += 2
        d.rect(16, yy, CW - 32, 36, PLOT, r=8)
        d.sym("info.circle", 16 + 14, yy + 18, 11, 600, ACCENT)
        uw = tw(T("undo"), 12.5, 500) + 24
        fits(notice, 12, 500, CW - 32 - 30 - uw - 14, "the stage's notice")
        d.ctext(16 + 28, yy + 18, notice, 12, 500, TEXT)
        chip(d, CW - 16 - 6 - uw, yy + 18, T("undo"), h=24, color=TEXT)
        yy += 36 + 8
    return yy - y


JOIN_GLYPH = {"add": "plus", "subtract": "minus", "intersect": "circle.lefthalf.filled"}


def part_row(d, y, join, kind, name, on=True, hover=False):
    """One part of a mask: how it joins, what it is, its own eye and remove. 30 high."""
    cy = y + 15
    if hover:
        d.rect(8, y + 1, CW - 16, 28, CARD, r=6, op=0.5)
    d.circle(34 + 9, cy, 9, CARD)
    d.sym(JOIN_GLYPH[join], 34 + 9, cy, 9, 700, TEXT)
    tool_glyph(d, kind, 34 + 18 + 8 + 9, cy, TEXT2)
    label = T("join_" + join) + " · " + name
    fits(label, 12.5, 500, CW - 16 - 56 - 88, "a mask part's line")
    d.ctext(88, cy, label, 12.5, 500, TEXT if on else DIM)
    d.sym("eye" if on else "eye.slash", CW - 16 - 34, cy, 11, 500, TEXT2 if on else DIM, op=0.75 if on else 1)
    d.sym("xmark", CW - 16 - 7, cy, 9, 600, DIM)
    return 30


def section_mask(d, y, parts, invert=False, feather="0", open_=True, warn=False, found=True, empty=False, overlay_on=False):
    h, cy = fold_header(d, y, T("mask"), open_=open_)
    small_round(d, CW - 16 - 11, cy, "eye", fill=ACCENT if overlay_on else CARD, color=ONSEL if overlay_on else TEXT)
    at = {"eye": (CW - 16 - 11, cy)}
    if not open_:
        d.ctext(CW - 16 - 30, cy, " · ".join(p[2] for p in parts), 12, 500, DIM, "end")
        return h, at
    yy = y + h
    if warn:
        lines = wrap(T("geometry_moved"), 12, 500, CW - 34 - 16 - 22)
        d.sym("exclamationmark.triangle", 34 + 7, yy + 12, 12, 700, ACCENT)
        for i, ln in enumerate(lines):
            d.text(34 + 20, yy + 16 + i * 17, ln, 12, 500, TEXT)
        yy += 8 + 17 * len(lines) + 6
        x = 34 + 20
        if found:
            x += chip(d, x, yy + 14, T("find_again"), color=TEXT, symbol="arrow.clockwise") + 8
        chip(d, x, yy + 14, T("keep_as_is"), color=TEXT)
        yy += 28 + 10
    if empty:
        yy += note(d, 34, yy + 2, wrap(T("mask_empty"), 11.5, 400, CW - 34 - 16)) + 10
    for p in parts:
        yy += part_row(d, yy, *p[:3], **(p[3] if len(p) > 3 else {}))
    yy += 2
    d.ctext(34, yy + 16, T("invert"), 12.5, 500, TEXT)
    toggle(d, CW - 16, yy + 16, invert)
    yy += 32
    d.ctext(34, yy + 16, T("feather"), 12.5, 500, TEXT)
    pill_menu(d, CW - 16, yy + 16, feather)
    at["feather"] = yy + 16
    yy += 32 + 8
    return yy - y, at


def label_w():
    return 64 if LANG == "zh" else 92


TEMP = ("#4A63D8", "#E2B04A")
TINT = ("#58B26A", "#C85BB8")
GREY = ("#2A2A29", "#BDBBB7")


def section_adjust_scene(d, y, ev=0.0, temp=0, tint=0):
    h, cy = fold_header(d, y, T("adjust"))
    live = ev != 0 or temp != 0 or tint != 0
    small_round(d, CW - 16 - 11, cy, "arrow.counterclockwise", op=1 if live else DISABLED)
    yy = y + h
    sign = lambda v, n=0: ("+" if v > 0 else "−" if v < 0 else "") + (f"{abs(v):.{n}f}")
    yy += slider(d, yy, T("exposure"), 0.5 + ev / 8, sign(ev, 1) + " EV", tint=GREY, label_w=label_w()) + 2
    yy += slider(d, yy, T("temperature"), 0.5 + temp / 200, sign(temp), tint=TEMP, label_w=label_w()) + 2
    yy += slider(d, yy, T("tint"), 0.5 + tint / 200, sign(tint), tint=TINT, label_w=label_w()) + 10
    return yy - y


FINISHED_TOOLS = [("brightness", "sun.max"), ("contrast", "circle.lefthalf.filled"), ("tone", "circle.lefthalf.striped.horizontal"),
                  ("vibrance", "drop.halffull"), ("saturation", "rainbow"), ("temperature", "thermometer.medium")]


def section_adjust_finished(d, y, values=None, opened=("brightness",)):
    """Edit's own six scalar tools, each its folding header (AdjustColumn's, without the grip: the order is
    the film's page's to set)."""
    values = values or {}
    h, cy = fold_header(d, y, T("adjust"))
    small_round(d, CW - 16 - 11, cy, "arrow.counterclockwise", op=1 if values else DISABLED)
    yy = y + h
    sign = lambda v, n=0: ("+" if v > 0 else "−" if v < 0 else "") + (f"{abs(v):.{n}f}")
    for k, symbol in FINISHED_TOOLS:
        is_open = k in opened
        title = T(k)
        if k == "tone" and is_open:
            title = T("tone") + " · " + T("hl_sh")
        hh, tcy = fold_header(d, yy, title, open_=is_open, symbol=symbol)
        if k == "tone" and is_open:
            d.sym("chevron.down", 16 + 12 + 6 + 24 + tw(title, 12.5, 600) + 8, tcy, 8, 700, TEXT2)
        yy += hh
        if not is_open:
            continue
        rows = {"brightness": [("brightness", GREY, 100, 0), ("exposure", GREY, 6, 1)],
                "contrast": [("contrast", GREY, 100, 0)],
                "tone": [("highlights", GREY, 200, 0), ("shadows", GREY, 200, 0)],
                "vibrance": [("vibrance", None, 200, 0)], "saturation": [("saturation", None, 200, 0)],
                "temperature": [("temperature", TEMP, 200, 0), ("tint_shift", TINT, 200, 0)]}[k]
        for key, track, span, dec in rows:
            v = values.get(key, 0)
            text = sign(v, dec) + (" EV" if key == "exposure" else "")
            yy += slider(d, yy, T(key), 0.5 + v / span, text, tint=track, label_w=label_w()) + 2
        yy += 8
    fold_rule(d, yy)
    return yy - y


def layer_foot(d, y, key):
    """The page's last row: where the rest is (the 图层 design's `layer_link`, with this page's own words)."""
    fold_rule(d, y)
    cy = y + 0.5 + 18
    d.sym("film", 16 + 9, cy, 12, 500, DIM)
    fits(T(key), 12, 500, CW - 44 - 34, "the layer page's link")
    d.ctext(44, cy, T(key), 12, 500, TEXT2)
    d.sym("chevron.right", CW - 16 - 4, cy, 9, 600, DIM)
    fold_rule(d, y + 36.5)
    return 37


# ---------------------------------------------------------------------------------------------------------
# On the picture.

def over_subject(d, box, color=OVERLAY, op=OVERLAY_OP):
    x, y, w, h = box
    c = d.clip(x, y, w, h)
    d.open(clip=c)
    cx, hy, r, b = portrait_geo(x, y, w, h)
    figure(d, cx, hy, r, b, color, op=op)
    d.close()


def handle(d, cx, cy, r=5, fill="#FFFFFF"):
    d.circle(cx, cy, r + 1.5, "#000", op=0.35)
    d.circle(cx, cy, r, fill)


def guide(d, x1, y1, x2, y2, dash=None, sw=1.5):
    d.line(x1, y1, x2, y2, "#000", sw + 2, op=0.3)
    d.line(x1, y1, x2, y2, "#FFFFFF", sw, dash=dash)


def pct_tag(d, x, y, text):
    w = tw(text, 11.5, 600) + 14
    d.rect(x, y - 10, w, 20, "#000", r=10, op=0.55)
    d.ctext(x + 7, y, text, 11.5, 600, "#FFFFFF")


def popover(d, x, y, w, h, tip=None):
    """A popover's ground; tip = x of its arrow on the top edge."""
    d.rect(x + 1, y + 4, w, h, "#000", r=10, op=0.35)
    d.rect(x, y, w, h, POP, r=10, stroke=POP_EDGE, sw=0.5)
    if tip is not None:
        d.path(f"M{tip - 8:.1f},{y + 0.5:.1f} L{tip:.1f},{y - 7:.1f} L{tip + 8:.1f},{y + 0.5:.1f} Z", fill=POP)
        d.path(f"M{tip - 8:.1f},{y:.1f} L{tip:.1f},{y - 7:.1f} L{tip + 8:.1f},{y:.1f}", stroke=POP_EDGE, sw=0.5)


def later_box(d, x, y, w, h, mark=None):
    d.rect(x, y, w, h, None, r=7, stroke=ACCENT, sw=1, dash="4 3")
    if mark:
        mw = max(tw(mark, 11.5, 700) + 8, 16)
        d.rect(x + w - 2 - mw / 2, y + 2 - 8, mw, 16, ACCENT, r=8)
        d.text(x + w - 2, y + 6, mark, 11.5, 700, ONSEL, "middle")


# ---------------------------------------------------------------------------------------------------------
# Whole drawings.

def caption(notes, ww=1000):
    """The caption's lines, wrapped a little inside the window's width (a line ending in an opening mark, or a
    run of full-width punctuation, measures narrower than it draws)."""
    return [ln for n in notes for ln in wrap(n, 11.5, 400, ww - 44)]


def std(name, title, notes, mode, column, canvas, over=None, status=None, busy=False, file_="DSC_0412.NEF", wh=860):
    p = Page(name, title, caption(notes), wh=wh)
    d = p.d
    toolbar(d, p.ww, mode)
    c = d.clip(0, HEAD, CW, p.wh - HEAD)
    d.open(clip=c)
    at = column(d)
    d.close()
    wall(d, p.wh)
    box = canvas(p)
    info_strip(d, CW + 1, p.ww, p.wh, status or T("developed"), busy=busy, name=file_)
    if over:
        over(p, at, box)
    return p


def column_top(d, folded=True):
    return HEAD + GL.histogram(d, HEAD, folded)


def portrait_canvas(p, kind="portrait"):
    box = canvas_box(p.ww, p.wh, 1.5)
    picture(p.d, kind, *box)
    return box


def film_page_stub(d, y):
    """冲洗's own column with 胶片 picked, as today (the 图层 design's parts)."""
    y += GL.nav_band(d, y, [T("film_paper"), T("format")], 0)
    h, cy = fold_header(d, y, T("film"), rule=False)
    pill_menu(d, CW - 16, cy, T("all"))
    y += h
    y += GL.stock_cards(d, y)
    h, cy = fold_header(d, y, T("paper"), open_=False)
    pill_menu(d, CW - 16, cy, T("all"))
    y += h
    h, cy = fold_header(d, y, T("decode"))
    y += h
    y += GL.part_header(d, y, T("exposure"))
    y += slider(d, y, T("film_exposure"), 0.5, "0.0 EV", label_w=label_w()) + 8
    y += GL.part_header(d, y, T("white_balance"), extra="eyedropper")
    y += slider(d, y, T("temperature"), 0.42, "5167 K", sub=T("as_shot"), rest=None, tint=("#5f86c9", "#e3c25a"), label_w=label_w()) + 6
    y += slider(d, y, T("tint"), 0.56, "+17", tint=("#6fbf73", "#c86fb5"), label_w=label_w()) + 6
    return y


def draw_all():
    out = []
    Z = LANG == "zh"

    # --- 01: a single photograph, no mask layer yet --------------------------------------------------------
    def col01(d):
        y = column_top(d)
        h, at = masks_card(d, y, [film_row()], sel=0)
        film_page_stub(d, y + h)
        return at
    out.append(std("01-panel-no-masks", cap("01 · 冲洗 · 单张照片，还没有蒙版图层", "01 · Develop · a single photograph, no mask layer yet"),
                   [cap("单张照片的面板现在展开：标题行右侧是 + − ⋯；下面两行是图层设计第 27 张图留出的位置：选择行（主体 · 背景 · 人）与工具行（画笔、线性渐变、径向渐变｜橡皮）。只有「胶片」一行时没有不透明度和两枚按钮：它们属于蒙版图层。",
                        "A single photograph’s panel now unfolds. The head’s trailing side is + − ⋯; the two rows under it are the places drawing 27 of the Layers design reserved: the selection row (Subject · Background · People) and the tool row (Brush, Linear Gradient, Radial Gradient | Eraser). With Film alone there is no Opacity and no buttons: those are a mask layer’s."),
                    cap("选中「胶片」时，下面就是今天的整栏。选中「胶片」时用任何一个工具，都会新建一个图层。", "With Film picked the column below is today’s. Using any tool with Film picked makes a new layer.")],
                   "develop", col01, lambda p: portrait_canvas(p)))

    # --- 02: after 主体: a scene layer and its page --------------------------------------------------------
    def col02(d):
        y = column_top(d)
        h, at = masks_card(d, y, [film_row(), mrow("name_subject", "scene", "subject")], sel=1)
        y += h
        y += stage_switch(d, y, "scene")
        hh, _ = section_mask(d, y, [("add", "subject", T("subject"))])
        y += hh
        y += section_adjust_scene(d, y, ev=0.7)
        layer_foot(d, y, "belongs_film")
        return at
    out.append(std("02-subject-scene-page", cap("02 · 按下「主体」之后：图层「主体 1」与它自己的页面（场景）", "02 · After Subject: the layer Subject 1 and its own page (Scene)"),
                   [cap("新图层在「胶片」之下，已选中；行上是眼睛、蒙版的缩略图（黑底白形）、名称，右端写着它的阶段。面板下方是这一层的不透明度与两枚按钮。",
                        "The new layer is under Film, picked. Its row: the eye, the mask’s thumbnail (white on black), the name, and its stage at the trailing end. Under the list, this layer’s Opacity and the two buttons."),
                    cap("面板之下是这一层自己的页面，不分冲洗与编辑：作用于（场景｜成片）与一句说明；蒙版（各个部分、反相、羽化）；调整（场景：曝光、色温、色调）；最后一行通向「胶片」。场景图层的滑块停下时冲洗一次。",
                        "Under the panel is the layer’s own page, the same in Develop and Edit: Works on (Scene | Finished) with one line of what that means; Mask (its parts, Invert, Feather); Adjust (Scene: Exposure, Temperature, Tint); and the last row leads back to Film. A Scene layer develops when the slider rests.")],
                   "develop", col02, lambda p: portrait_canvas(p)))

    # --- 03: a finished layer in 编辑 ---------------------------------------------------------------------
    def col03(d):
        y = column_top(d)
        h, at = masks_card(d, y, [film_row(), mrow("name_background", "finished", "background")], sel=1)
        y += h
        y += stage_switch(d, y, "finished")
        hh, _ = section_mask(d, y, [("add", "background", T("background"))], open_=False)
        y += hh
        y += section_adjust_finished(d, y, values={"brightness": -18, "exposure": -0.4}, opened=("brightness",))
        layer_foot(d, y - 0.5, "belongs_film_edit")
        return at
    out.append(std("03-finished-layer-edit", cap("03 · 编辑 · 作用于成片的图层「背景 1」", "03 · Edit · a Finished layer, Background 1"),
                   [cap("成片图层的调整就是「编辑」自己的六个数值工具（亮度、对比度、色调、鲜艳度、饱和度、色温），同样的名称、范围与算法，跟手，不冲洗。工具的顺序取自「胶片」那一页；这里不显示拖动把手。",
                        "A Finished layer’s adjustments are Edit’s own six scalar tools (Brightness, Contrast, Tone, Vibrance, Saturation, Temperature): the same names, ranges and arithmetic, following the pointer, with no develop. Their order is the Film page’s; no grips here."),
                    cap("曲线、色轮、HSL、通道与镜头仍是整张照片的：最后一行这样说，并通向「胶片」。蒙版一节收起时，标题右侧写着它由什么组成。",
                        "Curve, wheels, HSL, channels and lens stay the whole picture’s: the last row says so and leads to Film. Folded, the Mask section names its parts at its trailing end.")],
                   "edit", col03, lambda p: portrait_canvas(p), wh=900))

    # --- 04: the brush ---------------------------------------------------------------------------------
    def col04(d):
        y = column_top(d)
        pill = T("brush") + " · " + T("brush_size") + " 120"
        h, at = masks_card(d, y, [film_row(), mrow("name_brush", "scene", "brush")], sel=1, tool="brush", pill=pill)
        y += h
        y += stage_switch(d, y, "scene")
        hh, _ = section_mask(d, y, [("add", "brush", T("brush"))], overlay_on=True)
        y += hh
        y += section_adjust_scene(d, y)
        layer_foot(d, y, "belongs_film")
        return at

    def can04(p):
        d = p.d
        box = canvas_box(p.ww, p.wh, 1.5)
        picture(d, "hills", *box)
        x, y, w, h = box
        c = d.clip(*box)
        d.open(clip=c)
        stroke = (f"M{x + w * 0.10:.1f},{y + h * 0.78:.1f} C{x + w * 0.2:.1f},{y + h * 0.62:.1f} {x + w * 0.3:.1f},{y + h * 0.9:.1f} "
                  f"{x + w * 0.42:.1f},{y + h * 0.74:.1f} S{x + w * 0.58:.1f},{y + h * 0.6:.1f} {x + w * 0.66:.1f},{y + h * 0.72:.1f}")
        d.path(stroke, stroke=OVERLAY, sw=84, op=OVERLAY_OP)
        d.close()
        bx, by, br = x + w * 0.66, y + h * 0.72, 42
        d.circle(bx, by, br, None, stroke="#000", sw=3, op=0.3)
        d.circle(bx, by, br, None, stroke="#FFFFFF", sw=1.5)
        d.add(f'<circle cx="{bx:.2f}" cy="{by:.2f}" r="{br * 0.5:.2f}" fill="none" stroke="#FFFFFF" stroke-width="1" '
              f'stroke-dasharray="3 3" opacity="0.9"/>')
        d.line(bx - 4, by, bx + 4, by, "#FFFFFF", 1)
        d.line(bx, by - 4, bx, by + 4, "#FFFFFF", 1)
        return box

    def over04(p, at, box):
        d = p.d
        px, pcy, pw = at["pill"]
        W_, H_ = 318, 12 + 3 * 42 + 10
        y0 = pcy + 12 + 10
        popover(d, px, y0, W_, H_, tip=px + pw / 2)
        lw = max(tw(T(k), 13.5, 600) for k in ("brush_size", "hardness", "flow")) + 2
        yy = y0 + 12
        for k, frac, val in (("brush_size", 0.3, "120"), ("hardness", 0.5, "50"), ("flow", 1.0, "100")):
            slider(d, yy, T(k), frac, val, rest=None, x0=px + 14, x1=px + W_ - 14, label_w=lw, field_w=56)
            yy += 42
    out.append(std("04-brush", cap("04 · 画笔：圆、硬度环、跟着笔画的叠色，和它的设置", "04 · The brush: its circle, the hardness ring, the overlay under the stroke, its settings"),
                   [cap("工具亮起（强调色底、深色字形，与亮着的「裁剪」同一个状态色）。指针是画笔的圆：外圈是大小，虚线内圈是硬度开始衰减的位置。叠色是红色、蒙版为 1 处 50 %，随笔画即时出现；松开后一笔是撤销的一步。",
                        "The tool is lit (accent ground, dark glyph: the state colour the lit Crop wears). The pointer is the brush’s circle: the outer ring is its size, the dashed inner ring where its hardness begins to fall off. The overlay is red, 50 % where the mask is 1, drawn with the stroke; one stroke is one step of Undo."),
                    cap("工具行左端的胶囊写着亮起的工具和它的大小，点它打开设置：大小、硬度、流量，都是 ValueSlider。[ 与 ] 改大小，⇧[ 与 ⇧] 改硬度，按住 ⌥ 临时变成橡皮。",
                        "The pill at the tool row’s leading end names the lit tool and its size; a click opens its settings: Size, Hardness, Flow, each a ValueSlider. [ and ] size it, ⇧[ and ⇧] set hardness, ⌥ held is the eraser.")],
                   "develop", col04, can04, over04, file_="DSC_0398.NEF"))

    # --- 05: a linear gradient -------------------------------------------------------------------------
    def col05(d):
        y = column_top(d)
        h, at = masks_card(d, y, [film_row(), mrow("name_gradient", "scene", "linear")], sel=1, tool="linear")
        y += h
        y += stage_switch(d, y, "scene")
        hh, _ = section_mask(d, y, [("add", "linear", T("linear"))], overlay_on=True)
        y += hh
        y += section_adjust_scene(d, y, ev=-1.2)
        layer_foot(d, y, "belongs_film")
        return at

    def can05(p):
        d = p.d
        box = canvas_box(p.ww, p.wh, 1.5)
        picture(d, "hills", *box)
        x, y, w, h = box
        ang = math.radians(-7)
        ax, ay = x + w * 0.46, y + h * 0.16           # where the effect is full
        L = h * 0.42
        ux, uy = math.sin(-ang), math.cos(ang)         # along the gradient (down, turned)
        ux, uy = -math.sin(ang), math.cos(ang)
        bx, by = ax + ux * L, ay + uy * L              # where it ends
        vx, vy = uy, -ux                               # along the lines
        c = d.clip(*box)
        d.open(clip=c)
        far = w * 2
        # the overlay: full before a, falling to nothing at b
        d.add(f'<polygon points="{ax - vx * far - ux * far:.1f},{ay - vy * far - uy * far:.1f} {ax + vx * far - ux * far:.1f},{ay + vy * far - uy * far:.1f} '
              f'{bx + vx * far:.1f},{by + vy * far:.1f} {bx - vx * far:.1f},{by - vy * far:.1f}" '
              f'fill="{fade(d, OVERLAY, ax - ux * 0.01, ay - uy * 0.01, bx, by, [(0, OVERLAY_OP), (0.5, OVERLAY_OP * 0.5), (1, 0)])}"/>')
        d.add(f'<polygon points="{ax - vx * far - ux * far:.1f},{ay - vy * far - uy * far:.1f} {ax + vx * far - ux * far:.1f},{ay + vy * far - uy * far:.1f} '
              f'{ax + vx * far:.1f},{ay + vy * far:.1f} {ax - vx * far:.1f},{ay - vy * far:.1f}" fill="{OVERLAY}" opacity="0"/>')
        mx, my = (ax + bx) / 2, (ay + by) / 2
        guide(d, ax - vx * far, ay - vy * far, ax + vx * far, ay + vy * far, sw=1.5)
        guide(d, mx - vx * far, my - vy * far, mx + vx * far, my + vy * far, dash="5 4", sw=1)
        guide(d, bx - vx * far, by - vy * far, bx + vx * far, by + vy * far, sw=1.5)
        d.close()
        handle(d, ax, ay, 4.5)
        handle(d, mx, my, 6.5)
        d.circle(mx, my, 2.2, "#1A1D22")
        handle(d, bx, by, 4.5)
        pct_tag(d, x + 12, ay - vy * (ax - x - 12) / vx - 16, "100 %")
        pct_tag(d, x + 12, by - vy * (bx - x - 12) / vx + 16, "0 %")
        return box
    out.append(std("05-linear-gradient", cap("05 · 线性渐变：三条线与三个手柄", "05 · A linear gradient: three lines and three handles"),
                   [cap("在画面上从「效果最强」拖到「效果结束」。三条线跟着拖动：100 % 线、虚线的中线、0 % 线。松开即成图层（或加入选中图层的蒙版）。",
                        "Drag on the picture from where the effect is full to where it ends. Three lines follow: the 100 % line, the dashed middle line, the 0 % line. Releasing makes the layer (or adds to the picked layer’s mask)."),
                    cap("工具亮着时线留在画面上：拖中间的手柄移动整个渐变；拖两端的手柄改变方向与宽度，按住 ⇧ 时每 15° 一停。过渡是平滑的（两端没有折线），所以 100 % 线之前全是蒙版，0 % 线之后全无。",
                        "The lines stay while the tool is on: the middle handle moves the gradient; an end’s handle turns and stretches it, held to 15° steps with ⇧. The ramp is smooth at both ends, so everything before the 100 % line is mask and nothing after the 0 % line is.")],
                   "develop", col05, can05, file_="DSC_0398.NEF"))

    # --- 06: a radial gradient -------------------------------------------------------------------------
    def col06(d):
        y = column_top(d)
        h, at = masks_card(d, y, [film_row(), mrow("name_gradient", "finished", "radial")], sel=1, tool="radial")
        y += h
        y += stage_switch(d, y, "finished")
        hh, _ = section_mask(d, y, [("add", "radial", T("radial"))], overlay_on=True)
        y += hh
        section_adjust_finished(d, y, values={"brightness": 12}, opened=("brightness",))
        return at

    def can06(p):
        d = p.d
        box = canvas_box(p.ww, p.wh, 1.5)
        picture(d, "portrait", *box)
        x, y, w, h = box
        cx, hy, r, _ = portrait_geo(*box)
        rx, ry, ang = r * 1.3, r * 1.62, -12
        inner = 0.6
        c = d.clip(*box)
        d.open(clip=c)
        d.add(f'<ellipse cx="{cx:.2f}" cy="{hy:.2f}" rx="{rx:.2f}" ry="{ry:.2f}" transform="rotate({ang} {cx:.2f} {hy:.2f})" '
              f'fill="{radial_fade(d, OVERLAY, cx, hy, rx, ry, ang, [(0, OVERLAY_OP), (inner, OVERLAY_OP), (1, 0)])}"/>')
        for k, dash, sw in ((1.0, None, 1.5), (inner, "5 4", 1)):
            d.add(f'<ellipse cx="{cx:.2f}" cy="{hy:.2f}" rx="{rx * k:.2f}" ry="{ry * k:.2f}" transform="rotate({ang} {cx:.2f} {hy:.2f})" '
                  f'fill="none" stroke="#000" stroke-width="{sw + 2}" opacity="0.3"/>')
            d.add(f'<ellipse cx="{cx:.2f}" cy="{hy:.2f}" rx="{rx * k:.2f}" ry="{ry * k:.2f}" transform="rotate({ang} {cx:.2f} {hy:.2f})" '
                  f'fill="none" stroke="#FFFFFF" stroke-width="{sw}"' + (f' stroke-dasharray="{dash}"' if dash else "") + "/>")
        d.close()
        a = math.radians(ang)
        for ex, ey in ((rx, 0), (-rx, 0), (0, ry), (0, -ry)):
            handle(d, cx + ex * math.cos(a) - ey * math.sin(a), hy + ex * math.sin(a) + ey * math.cos(a), 4.5)
        fx, fy = rx * inner * math.cos(math.radians(45)), -ry * inner * math.sin(math.radians(45))
        handle(d, cx + fx * math.cos(a) - fy * math.sin(a), hy + fx * math.sin(a) + fy * math.cos(a), 4.5, fill=ACCENT)
        handle(d, cx, hy, 6.5)
        d.circle(cx, hy, 2.2, "#1A1D22")
        return box
    out.append(std("06-radial-gradient", cap("06 · 径向渐变：椭圆、羽化环与手柄", "06 · A radial gradient: the ellipse, the feather ring, the handles"),
                   [cap("从中心向外拖出椭圆。椭圆之内是蒙版；虚线环之内是 100 %，从虚线环到外圈平滑过渡到 0。中心的手柄移动它，外圈四个手柄改变两条半径，拖手柄外侧一点可旋转；强调色的手柄在羽化环上，拖它改变过渡的宽度。",
                        "Drag an ellipse out from its centre. Inside it is the mask: 100 % within the dashed ring, falling smoothly to 0 at the outer line. The centre handle moves it, the four on the outer line set its two radii, a drag just outside a handle turns it; the accent handle is on the feather ring and sets how wide the fall is."),
                    cap("这一层作用于成片：页面上是「编辑」的工具，拖动时跟手。", "This layer works on Finished: its page holds Edit’s tools, and they follow the pointer.")],
                   "edit", col06, can06, wh=936))

    # --- 07: the mask alone ----------------------------------------------------------------------------
    def col07(d):
        y = column_top(d)
        h, at = masks_card(d, y, [film_row(), mrow("name_subject", "scene", "subject")], sel=1)
        y += h
        y += stage_switch(d, y, "scene")
        hh, _ = section_mask(d, y, [("add", "subject", T("subject"))], overlay_on=True)
        y += hh
        y += section_adjust_scene(d, y, ev=0.7)
        layer_foot(d, y, "belongs_film")
        return at

    def can07(p):
        d = p.d
        box = canvas_box(p.ww, p.wh, 1.5)
        x, y, w, h = box
        d.rect(x, y, w, h, "#000000")
        over_subject(d, box, "#FFFFFF", 1)
        canvas_tag(d, x + w / 2, y + 12, Tf("mask_tag", T("name_subject")), symbol="circle.lefthalf.filled")
        return box
    out.append(std("07-mask-alone", cap("07 · 仅显示蒙版：黑底白形（⌥M）", "07 · The mask alone: white on black (⌥M)"),
                   [cap("⌥M 只显示选中图层的蒙版：1 是白，0 是黑，过渡是灰。画面上方的标签写着是谁的蒙版，状态栏也这样说；它是页面的状态，不写入照片，导出、图库与直方图里永远没有它。",
                        "⌥M shows the picked layer’s mask by itself: 1 is white, 0 is black, the fall is grey. A tag on the picture says whose it is, and the status line says so too. It is the page’s state: nothing is written, and no export, library picture or histogram ever holds it."),
                    cap("M 是红色叠色的开关。默认叠色只在画或改蒙版时出现，拖动调整时让开。蒙版一节标题右侧的眼睛就是 M。",
                        "M switches the red overlay. By default the overlay shows itself while a mask is made or changed and steps aside while an adjustment is dragged. The eye at the Mask section’s head is M.")],
                   "develop", col07, can07, status=cap("仅显示蒙版", "Mask alone")))

    # --- 08: 组合蒙版 -----------------------------------------------------------------------------------
    def col08(d):
        y = column_top(d)
        h, at = masks_card(d, y, [film_row(), mrow("name_subject", "scene", "subject")], sel=1, later=("combine_masks",))
        y += h
        y += stage_switch(d, y, "scene")
        hh, _ = section_mask(d, y, [("add", "subject", T("subject")), ("subtract", "linear", T("linear"))])
        y += hh
        y += section_adjust_scene(d, y, ev=0.7)
        return at

    def can08(p):
        d = p.d
        box = canvas_box(p.ww, p.wh, 1.5)
        picture(d, "portrait", *box)
        x, y, w, h = box
        c = d.clip(*box)
        d.open(clip=c)
        cx, hy, r, b = portrait_geo(*box)
        ident = d.uid("m")
        cut = y + h * 0.62
        d.defs.append(f'<mask id="{ident}" maskUnits="userSpaceOnUse" x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}">'
                      f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" fill="{fade(d, "#FFFFFF", 0, cut, 0, y + h, [(0, 1), (1, 0)])}"/>'
                      f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{cut - y:.1f}" fill="#FFFFFF"/></mask>')
        d.add(f'<g mask="url(#{ident})">')
        figure(d, cx, hy, r, b, OVERLAY, op=OVERLAY_OP)
        d.add("</g>")
        d.close()
        return box

    def over08(p, at, box):
        d = p.d
        bx, by, bw = at["buttons"]["combine_masks"]
        items = [("subject", T("subject"), False), ("background", T("background"), False), ("people", T("people"), True),
                 None, ("brush", T("brush"), False), ("linear", T("linear"), False), ("radial", T("radial"), False)]
        W_ = 232
        H_ = 12 + 28 + 10 + sum(9 if it is None else 28 for it in items) + 8
        y0 = by + 28 + 10
        popover(d, bx, y0, W_, H_, tip=bx + bw / 2)
        seg = (W_ - 24) / 3
        for k in ("join_add", "join_subtract", "join_intersect"):
            fits(T(k), 12.5, 600, seg - 10, "a join's name")
        segmented(d, bx + W_ - 12, y0 + 12 + 14, [T("join_add"), T("join_subtract"), T("join_intersect")], 1, seg=seg, track="#3A3F47")
        yy = y0 + 12 + 28 + 10
        for it in items:
            if it is None:
                d.rect(bx + 12, yy + 4, W_ - 24, 0.5, POP_EDGE)
                yy += 9
                continue
            kind, label, sub = it
            if kind == "linear":
                d.rect(bx + 5, yy, W_ - 10, 28, "#4B5059", r=6)
            tool_glyph(d, kind, bx + 24, yy + 14, TEXT)
            fits(label, 13, 500, W_ - 44 - 24, "a combine row")
            d.ctext(bx + 44, yy + 14, label, 13, 500, TEXT)
            if sub:
                d.sym("chevron.right", bx + W_ - 16, yy + 14, 9, 600, DIM)
            yy += 28
    out.append(std("08-combine-masks", cap("08 · 组合蒙版：加 · 减去 · 相交，然后选一个工具", "08 · Combine Masks: Add · Subtract · Intersect, then a tool"),
                   [cap("先选怎样组合（默认「加」），再点一个工具：找到的蒙版（主体、背景、人）立刻生效，画的工具（画笔、渐变）随即亮起，下一笔按所选方式并入。比 Capture One 少一步「创建蒙版」。图中从主体里减去了一个线性渐变：下半身渐渐不在蒙版里。",
                        "Choose how to join (Add by default), then click a tool: a found mask (Subject, Background, People) applies at once; a drawn one (Brush, a gradient) lights up and its next stroke joins that way. One step fewer than Capture One’s Create Mask. Here a linear gradient is taken away from Subject: the lower body fades out of the mask."),
                    cap("每个部分都列在图层页面的「蒙版」里：怎样并入、是什么、它自己的眼睛与移除。M2 的亮度范围、魔术画笔与点选不在这张菜单里（见 17）：没做的东西不摆出来。",
                        "Each part is listed under Mask on the layer’s page: how it joins, what it is, its own eye and remove. M2’s Luma Range, Magic Brush and Click to Select are not in this menu (see 17): what is not built is not shown.")],
                   "develop", col08, can08, over08))

    # --- 09: 完善蒙版 ----------------------------------------------------------------------------------
    def col09(d):
        y = column_top(d)
        h, at = masks_card(d, y, [film_row(), mrow("name_subject", "scene", "subject")], sel=1, later=("refine_mask",))
        y += h
        y += stage_switch(d, y, "scene")
        hh, _ = section_mask(d, y, [("add", "subject", T("subject"))], feather="12", overlay_on=True)
        y += hh
        y += section_adjust_scene(d, y, ev=0.7)
        return at

    def can09(p):
        d = p.d
        box = canvas_box(p.ww, p.wh, 1.5)
        x, y, w, h = box
        d.rect(x, y, w, h, "#000000")
        c = d.clip(*box)
        d.open(clip=c)
        blur = d.uid("b")
        d.defs.append(f'<filter id="{blur}" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="7"/></filter>')
        d.add(f'<g filter="url(#{blur})">')
        cx, hy, r, b = portrait_geo(*box)
        figure(d, cx, hy, r, b + 20, "#FFFFFF")
        d.add("</g>")
        d.close()
        canvas_tag(d, x + w / 2, y + 12, Tf("mask_tag", T("name_subject")), symbol="circle.lefthalf.filled")
        return box

    def over09(p, at, box):
        d = p.d
        bx, by, bw = at["buttons"]["refine_mask"]
        W_ = 318
        x0 = CARD_X1 - W_ + 60
        H_ = 12 + 22 + 6 + 42 + 14 + 2 * 42 + 12
        y0 = by + 28 + 10
        popover(d, x0, y0, W_, H_, tip=bx + bw / 2)
        d.ctext(x0 + 14, y0 + 12 + 11, T("refine_title"), 12.5, 600, TEXT)
        small_round(d, x0 + W_ - 14 - 11, y0 + 12 + 11, "arrow.counterclockwise")
        lw = max(tw(T(k), 13.5, 600) for k in ("feather", "grow", "edge_radius")) + 2
        yy = y0 + 12 + 22 + 6
        slider(d, yy, T("feather"), 0.12, "12", rest=None, x0=x0 + 14, x1=x0 + W_ - 14, label_w=lw, field_w=56)
        yy += 42 + 8
        later_box(d, x0 + 8, yy - 2, W_ - 16, 2 * 42 + 4, "M2")
        d.open(op=DISABLED)
        slider(d, yy, T("grow"), 0.5, "0", x0=x0 + 14, x1=x0 + W_ - 14, label_w=lw, field_w=56)
        slider(d, yy + 42, T("edge_radius"), 0.0, "0", rest=None, x0=x0 + 14, x1=x0 + W_ - 14, label_w=lw, field_w=56)
        d.close()
    out.append(std("09-refine-mask", cap("09 · 完善蒙版…：M1 只有羽化", "09 · Refine Mask…: Feather alone in M1"),
                   [cap("羽化只有这一个滑块：按照片长边的比例计，不按像素，所以预览与导出是同一个边缘。打开时画面换成「仅显示蒙版」，边缘怎么变看得见；关闭后回到原来的显示。图层页面上「羽化」一行写着当前的值，点它打开的也是这里。",
                        "Feather has this one slider: it is a share of the photograph’s long edge, not pixels, so the preview and the export have the same edge. While it is open the picture shows the mask alone, so the edge is seen changing; closing returns the view as it was. The Feather row on the layer’s page shows the value, and a click on it opens this."),
                    cap("虚线框是 M2（扩张 / 收缩、边缘半径），本次不做。", "The dashed box is M2 (Expand / Contract, Edge Radius): not in this release.")],
                   "develop", col09, can09, over09, status=cap("仅显示蒙版", "Mask alone")))

    # --- 10: 人 ----------------------------------------------------------------------------------------
    def col10(d):
        y = column_top(d)
        h, at = masks_card(d, y, [film_row()], sel=0, sel_hover="people")
        film_page_stub(d, y + h)
        return at

    def can10(p):
        d = p.d
        box = canvas_box(p.ww, p.wh, 1.5)
        picture(d, "group", *box)
        x, y, w, h = box
        c = d.clip(*box)
        d.open(clip=c)
        cx, hy, r, fill = group_geo(*box)[1]
        figure(d, cx, hy, r, y + h + r, OVERLAY, op=OVERLAY_OP)
        d.close()
        return box

    def over10(p, at, box):
        d = p.d
        bx, by, bw = at["select"]["people"]
        people = group_geo(*box)
        W_ = 204
        H_ = 6 + 28 + 9 + 3 * 40 + 6
        x0 = bx + bw - W_
        y0 = by + 28 + 6
        d.rect(x0 + 1, y0 + 3, W_, H_, "#000", r=8, op=0.35)
        d.rect(x0, y0, W_, H_, POP, r=8, stroke=POP_EDGE, sw=0.5)
        yy = y0 + 6
        d.sym("person.3.fill", x0 + 24, yy + 14, 12, 500, TEXT)
        d.ctext(x0 + 46, yy + 14, T("all_people"), 13, 500, TEXT)
        d.ctext(x0 + W_ - 14, yy + 14, "3", 12.5, 500, DIM, "end")
        yy += 28
        d.rect(x0 + 10, yy + 4, W_ - 20, 0.5, POP_EDGE)
        yy += 9
        bxp, byp, bwp, bhp = box
        for i, (cx, hy, r, fill) in enumerate(people):
            if i == 1:
                d.rect(x0 + 5, yy, W_ - 10, 40, "#4B5059", r=6)
            tx, ty = x0 + 12, yy + 6
            c = d.clip(tx, ty, 28, 28, 5)
            d.open(clip=c)
            d.rect(tx, ty, 28, 28, "#aab3a8")
            figure(d, tx + 14, ty + 12, 7.5, ty + 28 + 7.5, fill)
            d.close()
            d.ctext(x0 + 50, yy + 20, Tf("person_n", i + 1), 13, 500, TEXT)
            yy += 40
    out.append(std("10-people", cap("10 · 人：找到的每个人，和「全部人物」", "10 · People: each person found, and All People"),
                   [cap("第一次点「人」时在这张照片上查找（按钮显示「正在查找」，见 16），然后列出找到的人，各有一张小像；指针停在哪一行，画面上那个人就以叠色亮起。点一行即成图层「人物 2」。没有找到时只有一行灰色的「未找到人物」。",
                        "The first click on People looks for them in this photograph (the button reads Finding, see 16), then lists who was found, each with a small picture; the person under the pointer’s row lights up in the overlay on the picture. A click makes the layer Person 2. With nobody found there is one grey row, No people found."),
                    cap("查找只在本机进行，结果随编辑保存；系统更新不会改动旧的蒙版。皮肤、头发等部位是 M3。", "Finding runs on this Mac and its result is kept with the edit; a system update never changes an old mask. Parts of a person (skin, hair) are M3.")],
                   "develop", col10, can10, over10, file_="DSC_0451.NEF"))

    # --- 11: the stage switch, with adjustments that were not zero ------------------------------------
    def col11(d):
        y = column_top(d)
        h, at = masks_card(d, y, [film_row(), mrow("name_subject", "finished", "subject")], sel=1)
        y += h
        y += stage_switch(d, y, "finished", notice=T("restarted"))
        hh, _ = section_mask(d, y, [("add", "subject", T("subject"))], open_=False)
        y += hh
        section_adjust_finished(d, y, opened=("brightness",))
        return at
    out.append(std("11-stage-switch", cap("11 · 改变阶段：蒙版留下，调整从零开始", "11 · Changing the stage: the mask stays, the adjustments start again"),
                   [cap("「主体 1」原来作用于场景、曝光 +0.7；点了「成片」。蒙版、名称、不透明度都留下；调整换成成片的那一组，从零开始：胶片上的一档光和成片上的一档亮度不是一回事，从不悄悄换算。",
                        "Subject 1 worked on Scene with Exposure +0.7; Finished was clicked. The mask, the name and the opacity stay; the adjustments are now Finished’s own, from zero: a stop of light on the film and a stop on the finished picture are not the same thing and are never converted silently."),
                    cap("不弹确认框：开关下方的一行说明发生了什么，「撤销」（或 ⌘Z）一步回到场景和原来的数值。这一行在下一次操作后消失。调整本来就是零时不出现。",
                        "No confirmation is asked: the line under the switch says what happened, and Undo (or ⌘Z) is one step back to Scene and its values. The line goes with the next action, and does not appear when the adjustments were already zero.")],
                   "develop", col11, lambda p: portrait_canvas(p)))

    # --- 12: several layers ----------------------------------------------------------------------------
    def col12(d):
        y = column_top(d)
        rows = [film_row(), mrow("name_brush", "scene", "brush"),
                mrow("name_gradient", "scene", "linear", opacity=60),
                mrow("name_subject", "finished", "subject", on=False)]
        h, at = masks_card(d, y, rows, sel=2)
        y += h
        y += stage_switch(d, y, "scene")
        hh, _ = section_mask(d, y, [("add", "linear", T("linear"))], open_=False)
        y += hh
        y += section_adjust_scene(d, y, ev=-1.2)
        y += layer_foot(d, y, "belongs_film")
        # the folded head, set apart at the column's foot
        ay = 776
        d.rect(8, ay - 26, CW - 16, 74, BG, r=8, op=0.96)
        d.rect(8, ay - 26, CW - 16, 74, None, r=8, stroke=BLUE, sw=1, dash="4 3")
        d.text(20, ay - 9, cap("收起时：一行，写着有几个蒙版、选中的是谁", "Folded: one line, how many masks and which row is picked"), 11.5, 600, BLUE)
        masks_card(d, ay, rows, sel=2, folded=True, summary=Tf("mask_count", 3) + " · " + T("name_gradient"))
        return at

    def can12(p):
        d = p.d
        box = canvas_box(p.ww, p.wh, 1.5)
        picture(d, "hills", *box)
        return box
    out.append(std("12-several-layers", cap("12 · 几个图层：关掉的一层、60 % 的一层、阶段的标记", "12 · Several layers: one switched off, one at 60 %, the stage marks"),
                   [cap("新图层排在「胶片」之下、旧图层之上。眼睛是真正的开关（多重曝光的眼睛是「单独查看」，这里不是）：关掉的一行缩略图与名称变暗，眼睛划掉。不透明度不是 100 时写在阶段之前。行的顺序只是给人看的：同一阶段的图层是相加的，谁也不盖住谁，所以 M1 没有拖动排序。",
                        "A new layer goes under Film, above the older ones. The eye is a real switch here (a double exposure’s eye is Show Alone; this one is not): a row switched off dims its thumbnail and name and strikes its eye. An opacity that is not 100 is written before the stage. The order is for reading only: layers of a stage add up and none covers another, so M1 has no drag to reorder."),
                    cap("面板下方的不透明度永远是选中那一层的。↑ ↓ 在各行之间移动。超过五行时列表在卡片内滚动，卡片不再变高。", "Opacity under the list is always the picked layer’s. ↑ ↓ move between rows. Past five rows the list scrolls inside the card, which grows no taller.")],
                   "develop", col12, can12, file_="DSC_0398.NEF"))

    # --- 13: a pair: + stands down ---------------------------------------------------------------------
    def col13(d):
        y = column_top(d)
        h = GL.layers_card(d, y, GL.rows_pair(False), sel=0, foot=[T("pair_refusal")])
        cy = y + L_HEAD / 2
        small_round(d, HEAD_MINUS, cy, "minus", pt=11, weight=700, op=DISABLED)
        small_round(d, HEAD_PLUS, cy, "plus", pt=11, weight=700, op=DISABLED)
        GL.page_format_pair(d, y + h)
        return {}
    out.append(std("13-pair-stands-down", cap("13 · 半格组：+ 退下，并说明原因", "13 · A pair: + stands down, and says why"),
                   [cap("半格组与多重曝光在 M1 没有蒙版图层：+ 与 − 以 0.38 画出、不接受点击，选择行与工具行不出现（里面没有一样能用），面板底部一行写着原因。其余和今天完全一样。M2 取消这一限制。",
                        "A pair and a double have no mask layers in M1: + and − are drawn at 0.38 and take no click, the selection and tool rows are not shown (nothing in them could be used), and one line at the panel’s foot says why. Everything else is as today. M2 lifts this.")],
                   "develop", col13, lambda p: GL.canvas_pair(p), file_=GL.PAIR_NAME[LANG]))

    # --- 14: the photograph's geometry changed ---------------------------------------------------------
    def col14(d):
        y = column_top(d)
        h, at = masks_card(d, y, [film_row(), mrow("name_subject", "scene", "subject", warn=True)], sel=1)
        y += h
        y += stage_switch(d, y, "scene")
        hh, _ = section_mask(d, y, [("add", "subject", T("subject"))], warn=True)
        y += hh
        y += section_adjust_scene(d, y, ev=0.7)
        layer_foot(d, y, "belongs_film")
        return at

    def can14(p):
        d = p.d
        box = canvas_box(p.ww, p.wh, 1.5)
        picture(d, "portrait", *box)
        x, y, w, h = box
        c = d.clip(*box)
        d.open(clip=c)
        cx, hy, r, b = portrait_geo(*box)
        figure(d, cx + 9, hy + 5, r * 0.97, b, OVERLAY, op=OVERLAY_OP)
        d.close()
        return box
    out.append(std("14-geometry-changed", cap("14 · 照片的几何变了（镜头校正）：行上的标记与页面上的一行", "14 · The photograph’s geometry changed (Lens Correction): the row’s mark and the page’s line"),
                   [cap("蒙版记在照片自己的坐标里。做好蒙版之后再开关「镜头校正」，照片在底下变了形：这一层在行上带一个标记，「蒙版」一节第一行说明原因。找到的蒙版可以「重新查找」；任何蒙版都可以「保持现状」，标记随之消失。什么都不会悄悄漂移。",
                        "A mask is kept in the photograph’s own coordinates. If Lens Correction is switched after a mask is made, the photograph changes shape underneath: the layer wears a mark on its row, and the first line of its Mask section says why. A found mask offers Find Again; any mask offers Keep As It Is, and the mark goes. Nothing drifts silently.")],
                   "develop", col14, can14, wh=900))

    out.append(draw_anatomy())
    out.append(draw_states())
    out.append(draw_later())

    # --- 18: a layer's menu ----------------------------------------------------------------------------
    def col18(d):
        y = column_top(d)
        rows = [film_row(), mrow("name_brush", "scene", "brush"), mrow("name_subject", "scene", "subject")]
        h, at = masks_card(d, y, rows, sel=2)
        y += h
        y += stage_switch(d, y, "scene")
        hh, _ = section_mask(d, y, [("add", "subject", T("subject")), ("subtract", "linear", T("linear"), dict(on=False)),
                                    ("add", "brush", T("brush"))])
        y += hh
        y += section_adjust_scene(d, y, ev=0.7)
        layer_foot(d, y, "belongs_film")
        return at

    def over18(p, at, box):
        d = p.d
        items = [("on", T("rename"), "pencil"), ("on", T("duplicate_layer"), "plus.square.on.square"), "-",
                 ("on", T("show_mask"), "eye", None, "M"), ("on", T("mask_alone"), "circle.lefthalf.filled", None, "⌥M"),
                 ("on", T("invert"), "circle.righthalf.filled"), "-",
                 ("hi", T("to_finished"), "arrow.left.arrow.right", T("starts_again")), "-",
                 ("on", T("delete_layer"), "trash", None, "⌫")]
        menu_panel(d, HEAD_MORE - 8, at["head"] + 15, 250, items)
    out.append(std("18-layer-menu", cap("18 · 图层的菜单（⋯ 与次级点击是同一张）", "18 · A layer’s menu (⋯ and the secondary click are one list)"),
                   [cap("作用于选中（或被点的）那一行：重命名（双击名称也可以）、复制图层、显示蒙版、仅显示蒙版、反相、改为作用于另一个阶段（第二行写着后果）、删除图层。删除不询问，撤销可恢复。「胶片」一行的菜单是今天的。",
                        "For the picked (or clicked) row: Rename (a double-click on the name does it too), Duplicate Layer, Show Mask, Show Mask Alone, Invert, work on the other stage (its second line says what follows), Delete Layer. Delete asks nothing and Undo restores. Film’s menu is today’s."),
                    cap("页面上的「蒙版」一节这里有三个部分：加 · 主体，减去 · 线性渐变（它自己的眼睛关着，暂不计入），加 · 画笔。按顺序计算，每一部分可以单独关掉或移除。",
                        "The Mask section on the page has three parts here: Add · Subject, Subtract · Linear Gradient (its own eye is off, so it is left out for now), Add · Brush. They are taken in order, and each can be switched off or removed by itself.")],
                   "develop", col18, lambda p: portrait_canvas(p), over18, wh=920))
    return out


# ---------------------------------------------------------------------------------------------------------
# The measured sheets.

def draw_anatomy():
    sc = 2
    W_, H_ = CW * sc + 620, 930
    d = sheet("15-anatomy",
              cap("15 · 带蒙版的面板：构造与尺寸（2×；单位 = 冲洗页的点，100 % 界面下 1 = 0.9625 Mac 点）",
                  "15 · The panel with masks: anatomy and measurements (2x; one unit = a develop-page point, 0.9625 Mac pt at 100 %)"),
              cap("卡片、标题、行、眼睛、缩略图的位置都是图层面板已有的数字；这里新增的只有：标题右侧的 + 与 −、选择行 36、工具行 36、不透明度 44.5 与按钮 40。行高仍是 30（28.9 Mac 点）；新增文字不小于 11.5。",
                  "The card, the head, a row, the eye and the thumbnail are the Layers panel’s own numbers. New here: + and − in the head, the selection row 36, the tool row 36, Opacity 44.5 and the buttons 40. A row is still 30 (28.9 Mac pt); new type is never under 11.5."),
              W_, H_)
    ox, oy = M + 170, M + 60
    rows = [film_row(), mrow("name_brush", "scene", "brush"), mrow("name_subject", "finished", "subject", opacity=60)]
    d.add(f'<g transform="translate({ox},{oy}) scale({sc})">')
    d.rect(0, -8, CW, 330, BG)
    d.rect(CW, -8, 1, 330, WALL)
    h, at = masks_card(d, 0, rows, sel=2, tool="brush", pill=T("brush") + " · " + T("brush_size") + " 120")
    d.add("</g>")
    X = lambda v: ox + v * sc
    Y = lambda v: oy + v * sc
    dim_h(d, X(0), X(L_INSET), Y(-4) - 12, "12")
    dim_h(d, X(L_INSET), X(CW - L_INSET), Y(-4) - 30, "369")
    dim_h(d, X(HEAD_PLUS - 11), X(HEAD_PLUS + 11), Y(-4) - 12, "22")
    dim_h(d, X(HEAD_PLUS + 11), X(HEAD_MINUS - 11), Y(-4) - 12, "6")
    dim_h(d, X(HEAD_MORE + 11), X(CW - L_INSET), Y(-4) - 12, "10")
    rx = X(CW) + 16
    y0 = 0
    marks = [(L_HEAD, cap("标题 32", "head 32")), (SEL_ROW, cap("选择行 36（按钮 28，圆角 7）", "selection row 36 (buttons 28, radius 7)")),
             (TOOL_ROW, cap("工具行 36（格 30 × 28）", "tool row 36 (slots 30 × 28)")), (L_ROW, cap("行 30", "row 30")), (L_ROW, "30"), (L_ROW, "30"),
             (L_ROWPAD, "6"), (OPAC, cap("不透明度 44.5（分隔线 0.5 + ValueSlider 40 + 4）", "Opacity 44.5 (rule 0.5 + ValueSlider 40 + 4)")),
             (BTNS, cap("按钮 40（2 + 28 + 10）", "buttons 40 (2 + 28 + 10)"))]
    for hh, label in marks:
        dim_v(d, rx, Y(y0), Y(y0 + hh), label)
        y0 += hh
    dim_v(d, ox - 22, Y(0), Y(h - L_GAP), cap(f"两个蒙版图层 {h - L_GAP:g}", f"two mask layers {h - L_GAP:g}"), right=False)
    by = Y(h) + 22
    bw = (CARD_X1 - CARD_X0 - 16) / 3
    dim_h(d, X(L_INSET), X(CARD_X0), by, "14", above=False)
    dim_h(d, X(CARD_X0), X(CARD_X0 + bw), by + 22, cap(f"选择按钮 {bw:.1f}，间隔 8", f"selection button {bw:.1f}, 8 apart"), above=False)
    centres = at["tools"]
    dim_h(d, X(centres["eraser"] - 15), X(centres["eraser"] + 15), by, "30", above=False)
    dim_h(d, X(centres["radial"] + 15), X(centres["eraser"] - 15), by + 22, "12", above=False)
    dim_h(d, X(TRAIL_X), X(CW - L_INSET - L_ROWPAD), by + 44, "10", above=False)
    ly = by + 96
    lines = [
        cap("标题：chevron 与「图层」不动；+ − ⋯ 是 22 的圆钮，相隔 6，⋯ 仍距卡片右缘 10。− 只在选中蒙版图层时可用。",
            "Head: the chevron and the title do not move; + − ⋯ are 22 discs, 6 apart, ⋯ still 10 from the card’s edge. − is live only with a mask layer picked."),
        cap("选择行：三枚等宽按钮（Theme.card、圆角 7），字形 11 + 6 + 文字 12.5 medium；「人」右侧有 chevron.down 8。",
            "Selection row: three equal buttons (Theme.card, radius 7), an 11 glyph, 6, the word at 12.5 medium; People has a chevron.down 8 at its trailing end."),
        cap("工具行：自右向左排，每格 30 × 28，字形 13；分隔线 0.5 × 20，两侧各 6。亮起 = 28 × 24 强调色底、圆角 6、深色字形。左端的胶囊（高 24）写着亮起的工具与它的大小。",
            "Tool row: laid from the right, each slot 30 × 28 with a 13 glyph; a 0.5 × 20 divider with 6 on each side. Lit = a 28 × 24 accent ground, radius 6, dark glyph. The pill at the leading end (24 high) names the lit tool and its size."),
        cap("蒙版行：眼睛 eye / eye.slash 11 · 缩略图 30 × 20 黑底白形、圆角 3、0.5 描边 · 名称 13 medium（选中 semibold）· 右端 12 medium：[⚠] [60 %] 阶段，各相隔 10。",
            "Mask row: eye / eye.slash 11 · the thumbnail 30 × 20, white on black, radius 3, a 0.5 stroke · the name 13 medium (semibold picked) · trailing at 12 medium: [mark] [60 %] stage, 10 apart."),
        cap("不透明度：ValueSlider，0–100 %，无静止刻线；数字框宽 62。两枚按钮等宽（圆角 7，12.5 medium），相隔 8；选中「胶片」时这一段整体 0.38。",
            "Opacity: a ValueSlider, 0–100 %, no rest mark; its number’s box 62 wide. Two equal buttons (radius 7, 12.5 medium), 8 apart; with Film picked this whole block is at 0.38."),
        cap("高度：无蒙版图层 140（32 + 36 + 36 + 30 + 6）；n 个蒙版图层 224.5 + 30 n（n ≤ 4；更多时列表在 150 内滚动，卡片最高 344.5）。收起 32。下方 6。",
            "Heights: with no mask layer 140 (32 + 36 + 36 + 30 + 6); with n mask layers 224.5 + 30 n (n ≤ 4; beyond that the list scrolls within 150 and the card stops at 344.5). Folded 32. 6 under it."),
    ]
    for i, ln in enumerate(lines):
        for j, piece in enumerate(wrap(ln, 11.5, 400, W_ - 100)):
            d.text(M + 40, ly, piece, 11.5, 400, TEXT2)
            ly += 17
        ly += 4
    return ("15-anatomy", d)


def draw_states():
    sc = 2
    row_cases = [
        (mrow("name_subject", "scene", "subject"), "rest", cap("静止", "At rest")),
        (mrow("name_subject", "scene", "subject"), "hover", cap("指针悬停：Theme.card 50 %", "Pointer over it: Theme.card at 50 %")),
        (mrow("name_subject", "scene", "subject"), "selected", cap("选中：白色胶囊、深色字", "Picked: the white capsule, dark ink")),
        (mrow("name_subject", "finished", "subject", opacity=60), "rest", cap("作用于成片、不透明度 60 %", "Works on Finished, opacity 60 %")),
        (mrow("name_subject", "scene", "subject", on=False), "rest", cap("关掉：眼睛划掉，缩略图与名称 0.38", "Switched off: the eye struck, thumbnail and name at 0.38")),
        (mrow("name_subject", "scene", "subject", on=False), "selected", cap("关掉并选中：保持可读", "Switched off and picked: it stays readable")),
        (mrow("name_subject", "scene", "subject", warn=True), "rest", cap("照片的几何变了：强调色的标记", "The photograph’s geometry changed: the accent mark")),
        (mrow("name_layer", "scene", "empty"), "selected", cap("新建的空图层：缩略图全黑", "A new, empty layer: an all-black thumbnail")),
    ]
    tool_cases = [("rest", cap("静止", "rest")), ("hover", cap("悬停", "hover")), ("on", cap("亮起", "on")), ("disabled", cap("退下", "disabled"))]
    sel_cases = [("rest", cap("静止", "rest")), ("hover", cap("悬停", "hover")), ("working", cap("查找中", "working")), ("disabled", cap("退下", "disabled"))]
    W_ = CW * sc + 350
    H_ = 30 + len(row_cases) * (L_ROW * sc + 12) + 40 + 110 + 40 + 96
    d = sheet("16-states", cap("16 · 蒙版行、工具与选择按钮的各种状态（2×）", "16 · The states of a mask row, a tool and a selection button (2x)"),
              cap("选中是白色胶囊，不是强调色；强调色只用于状态：亮起的工具、几何变化的标记。退下一律 0.38。查找时按钮的字形换成转圈、文字换成「正在查找」，宽度不变。",
                  "Selection is the white capsule, never the accent; the accent is for state only: a lit tool, the geometry mark. Standing down is always 0.38. While finding, a button’s glyph becomes the spinner and its word Finding; its width does not change."),
              W_, H_)
    ox, oy = M + 40, M + 30
    y = oy
    for row, state, label in row_cases:
        d.add(f'<g transform="translate({ox},{y}) scale({sc})">')
        d.rect(L_INSET, 0, CW - 2 * L_INSET, L_ROW, PLOT)
        mask_row(d, 0, row, state)
        d.add("</g>")
        d.text(ox + CW * sc + 6, y + L_ROW * sc / 2 + 4, label, 12, 500, TEXT2)
        y += L_ROW * sc + 12
    y += 22
    d.text(ox + L_INSET * sc, y, cap("工具（画笔、线性渐变）", "A tool (Brush, Linear Gradient)"), 12, 600, TEXT)
    y += 14
    x = ox + L_INSET * sc
    for state, label in tool_cases:
        d.add(f'<g transform="translate({x},{y}) scale({sc})">')
        d.rect(0, 0, 76, 36, PLOT, r=6)
        tool_button(d, 21, 18, "brush", state)
        tool_button(d, 55, 18, "linear", state)
        d.add("</g>")
        d.text(x + 76, y + 36 * sc + 16, label, 12, 500, TEXT2, "middle")
        x += 76 * sc + 24
    y += 36 * sc + 44
    d.text(ox + L_INSET * sc, y, cap("选择按钮（主体）", "A selection button (Subject)"), 12, 600, TEXT)
    y += 14
    x = ox + L_INSET * sc
    bw = (CARD_X1 - CARD_X0 - 16) / 3
    for state, label in sel_cases:
        d.add(f'<g transform="translate({x},{y}) scale({sc})">')
        d.rect(0, 0, bw + 12, 36, PLOT, r=6)
        select_button(d, 6, 4, bw, "subject", state)
        d.add("</g>")
        d.text(x + (bw + 12), y + 36 * sc + 16, label, 12, 500, TEXT2, "middle")
        x += (bw + 12) * sc + 14
    return ("16-states", d)


def draw_later():
    p = Page("17-later", cap("17 · 以后：M2 与 M3 放在哪里（本次不做）", "17 · Later: where M2 and M3 go (not in M1)"),
             caption([cap("虚线框里的都不在 M1。① 工具行：画笔之后是魔术画笔，橡皮之前是修复与仿制；格子都是 30，所以今天的四个工具到时不动。② 「天空」是 M2 的一种找到的蒙版，这里是它做出的图层；它在选择行里是第四枚按钮还是并入「人」的菜单，到 M2 再定。③ 阶段开关的第三段「放大机」：在放大机下加光减光（M3）。",
                  "Nothing in a dashed box is in M1. ① The tool row: Magic Brush after Brush, Heal and Clone before Eraser; every slot is 30, so today’s four tools do not move then. ② Sky is a found mask of M2, shown here as the layer it makes; whether it is a fourth selection button or a row of People’s menu is decided in M2. ③ The stage switch’s third segment, Enlarger: dodging and burning under the enlarger (M3)."),
              cap("④ 组合蒙版的菜单在 M2 多出亮度范围、魔术画笔与点选（画在画面下方）。完善蒙版的 M2 部分见 09。", "④ Combine Masks gains Luma Range, Magic Brush and Click to Select in M2 (drawn under the picture). Refine Mask’s M2 part is in 09.")]))
    d = p.d
    toolbar(d, p.ww, "develop")
    c = d.clip(0, HEAD, CW, p.wh - HEAD)
    d.open(clip=c)
    y = column_top(d)
    rows = [film_row(), mrow("sky", "scene", "linear"), mrow("name_subject", "scene", "subject")]
    h, at = masks_card(d, y, rows, sel=2, tools=LATER_TOOLS)
    centres = at["tools"]
    fut = [(centres["magic"] - 15, at["tool_cy"] - 15, 30, 30, None),
           (centres["heal"] - 16, at["tool_cy"] - 15, 62, 30, "①"),
           (ROW_X + 2, at["rows"][1] + 1, CW - 2 * ROW_X - 4, L_ROW - 2, "②")]
    y += h
    sy = y
    y += stage_switch(d, y, "scene", later=True)
    hh, _ = section_mask(d, y, [("add", "subject", T("subject"))], open_=False)
    y += hh
    y += section_adjust_scene(d, y, ev=0.7)
    layer_foot(d, y, "belongs_film")
    d.close()
    for fx, fy, fw, fh, mark in fut:
        later_box(d, fx, fy, fw, fh, mark)
    d.circle(CW - 16 + 2, sy + 0.5 + 22 - 17 + 2, 8, ACCENT)
    d.text(CW - 16 + 2, sy + 0.5 + 22 - 17 + 6, "③", 11.5, 700, ONSEL, "middle")
    wall(d, p.wh)
    box = canvas_box(p.ww, p.wh, 1.5)
    picture(d, "portrait", *box)
    x, yy, w, hgt = box
    tagw = tw(T("not_in_m1"), 13, 700) + 28
    d.rect(x + w / 2 - tagw / 2, yy + 14, tagw, 28, ACCENT, r=14)
    d.ctext(x + w / 2, yy + 28, T("not_in_m1"), 13, 700, ONSEL, "middle")
    info_strip(d, CW + 1, p.ww, p.wh, T("developed"))
    # the combine menu's later rows
    items = [("luma", T("luma_range")), ("magic", T("magic_brush")), ("click", T("click_select"))]
    W_, H_ = 232, 8 + 28 * 3 + 8
    bx, y0 = x, yy + hgt + 44
    d.text(bx, y0 - 12, T("combine_masks") + " · M2", 12, 600, ACCENT)
    popover(d, bx, y0, W_, H_)
    yq = y0 + 8
    for kind, label in items:
        tool_glyph(d, kind, bx + 24, yq + 14, TEXT2)
        d.ctext(bx + 44, yq + 14, label, 13, 500, TEXT2)
        yq += 28
    later_box(d, bx + 4, y0 + 4, W_ - 8, H_ - 8, "④")
    return p


# ---------------------------------------------------------------------------------------------------------

EN_TOO = {"01-panel-no-masks", "02-subject-scene-page", "03-finished-layer-edit", "05-linear-gradient", "07-mask-alone",
          "08-combine-masks", "15-anatomy"}


def setlang(lang):
    global LANG
    LANG = lang
    GL.LANG = lang


def strings_table():
    setlang("zh")
    draw_all()
    rows = ["| key | zh-Hans | en | status |", "|---|---|---|---|"]
    for k, (zh, en, st) in MS.items():
        rows.append(f"| `{k}` | {zh} | {en} | {st} |")
    for k in sorted(USED - set(MS)):
        zh, en, st = GL.S[k]
        rows.append(f"| `{k}` | {zh} | {en} | {'catalog (2.4.0)' if st in ('new', 'renamed') else st} |")
    return "\n".join(rows)


def main():
    if "--strings" in sys.argv:
        print(strings_table())
        return
    written = []
    for lang in ("zh", "en"):
        setlang(lang)
        for item in draw_all():
            name, d = (item.name, item.finish()) if isinstance(item, Page) else item
            if lang == "en" and name not in EN_TOO:
                continue
            path = os.path.join(OUT, f"{name}.{lang}.svg")
            with open(path, "w") as f:
                f.write(d.svg())
            written.append(path)
    print(f"{len(written)} drawings -> {OUT}")
    if "--png" in sys.argv:
        subprocess.run([K.tool("svgshot"), "2", OUT] + written, check=True)


if __name__ == "__main__":
    main()
