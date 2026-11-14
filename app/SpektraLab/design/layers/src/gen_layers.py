#!/usr/bin/env python3
"""Generates the 图层 (Layers) panel's drawings and the double exposure's Mac UI (PRD-D §3.6, §3.7; 2026-11-11).

    python3 app/SpektraLab/design/layers/src/gen_layers.py            # -> design/layers/*.svg
    python3 app/SpektraLab/design/layers/src/gen_layers.py --png      # ... and a PNG beside each, at 2x
    python3 app/SpektraLab/design/layers/src/gen_layers.py --strings  # the strings table of LAYERS-SPEC.md §9

What each drawing is, and every number in it, is LAYERS-SPEC.md beside the drawings. The kit (tokens, text,
SF Symbols, the column's existing parts) is kit.py. Needs macOS and swiftc: three small tools beside this file
draw Apple's symbols (sf_symbols.swift), measure text (text_width.swift) and render the PNGs as WebKit does
(svgshot.swift; `tools/svg2png.swift` draws the system font's medium and semibold as regular and bold).

Units: one unit is one scene point of the develop page, 0.9625 of a Mac point at the 100 % interface scale.
The window drawn is 1000 x 860 units (962 x 828 Mac points) with the browser put away, so the column is
legible; the library's drawings are 1180 wide.
"""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import kit as K
from kit import (Drawing, tw, CW, BG, CARD, PLOT, RULE, PANEL, TEXT, TEXT2, DIM, FAINT, ACCENT, SEL, ONSEL,
                 SELFRAME, DANGER, WALL, DISABLED, picture, double_picture, pair_picture, fold_header, fold_rule,
                 toggle, small_round, slider, chip, chips, pill_menu, segmented, note, capsule_button, disc, wrap,
                 histogram_card, nav_band, chevron)

OUT = os.path.dirname(HERE)
LANG = "zh"

# ---------------------------------------------------------------------------------------------------------
# Every word the drawings show: key -> (zh-Hans, en, where it comes from). "catalog" is a key
# Localizable.xcstrings has today with this zh; "new" is a string this design adds; "renamed" is a catalog
# key whose zh this design proposes to change (LAYERS-SPEC.md §9, §12).

S = {
    # the panel
    "layers": ("图层", "Layers", "new"),
    "film": ("胶片", "Film", "catalog"),
    "left": ("左格", "Left frame", "catalog"),
    "right": ("右格", "Right frame", "catalog"),
    "upper": ("上格", "Top frame", "catalog"),
    "lower": ("下格", "Bottom frame", "catalog"),
    "top": ("上层", "Top", "catalog"),
    "bottom": ("下层", "Bottom", "catalog"),
    "empty": ("空", "Empty", "catalog"),
    "balance": ("平衡", "Balance", "renamed"),
    "top_share": ("上层占比", "Top’s share", "new"),
    "alone_top": ("仅上层", "Top alone", "new"),
    "alone_bottom": ("仅下层", "Bottom alone", "new"),
    "alone_word": ("单独", "alone", "new"),
    "only_film": ("仅胶片一层", "Film only", "new"),
    "add_frame": ("添加照片", "Add Frame", "catalog"),
    "add_exposure": ("添加曝光", "Add Exposure", "new"),
    "fill_double": ("两次曝光都放入照片后才能导出多重曝光。", "Fill both exposures to export the double exposure.", "catalog"),
    "fill_pair_1": ("空着的一格是未曝光的胶片。", "An empty hole is unexposed film.", "new"),
    "fill_pair_2": ("两格都填上才能导出。", "Fill both frames to export the pair.", "catalog"),
    # the panel's menu
    "swap_double": ("交换上下层", "Swap Top and Bottom", "new"),
    "swap_pair": ("对调两格", "Swap the Two Frames", "catalog"),
    "arrange_cmd": ("摆放…", "Arrange…", "new"),
    "flip_h": ("水平翻转", "Flip Horizontally", "new"),
    "show_alone": ("单独查看", "Show Alone", "new"),
    "show_both": ("显示两次曝光", "Show Both Exposures", "new"),
    "replace_cmd": ("替换照片…", "Replace Photograph…", "new"),
    "remove_cmd": ("移除照片", "Remove Photograph", "new"),
    # the layer's page
    "arrange": ("摆放", "Arrange", "new"),
    "covers": ("覆盖整格", "Covers the frame", "catalog"),
    "centred": ("居中", "Centred", "catalog"),
    "flipped": ("已翻转", "Flipped", "new"),
    "advanced": ("进阶", "Advanced", "new"),
    "exposure": ("曝光", "Exposure", "catalog"),
    "meter": ("测光", "meter", "catalog"),
    "balance_to": ("平衡 →", "Balance →", "new"),
    "scope_frame": ("此格", "Frame", "catalog"),
    "white_balance": ("白平衡", "White Balance", "catalog"),
    "temperature": ("色温", "Temperature", "catalog"),
    "tint": ("色调", "Tint", "catalog"),
    "as_shot": ("原照设置", "As Shot", "catalog"),
    "wb_writes": ("白平衡会写入图库中的这张照片。", "White balance is written to this photograph in the library.", "new"),
    "enlarger": ("放大机", "Enlarger", "catalog"),
    "date_back": ("日期后背", "Date Back", "catalog"),
    "date_note": ("每一格都是一次单独的曝光，带着自己的日期。", "Each frame was its own exposure, and carries its own date.", "catalog"),
    "photograph": ("照片", "Photograph", "new"),
    "replace": ("替换", "Replace", "catalog"),
    "remove": ("移除", "Remove", "catalog"),
    "also_alone": ("图库里也有它单独的一张。", "It is in the library by itself as well.", "new"),
    "empty_layer": ("空着的一层是未曝光的胶片：画面只按另一次曝光冲洗。",
                    "An empty layer is unexposed film: the frame develops with the other exposure’s light alone.", "new"),
    "began_double": ("多重曝光从这张照片开始，它留在其中；交换上下层可换位置。",
                     "The double exposure began with this photograph: it stays. Swap Top and Bottom moves it.", "new"),
    "belongs_film": ("胶片、相纸与效果属于「胶片」", "Film, paper and effects belong to Film", "new"),
    # the film's page
    "film_paper": ("胶片与相纸", "Film & Paper", "catalog"),
    "format": ("格式", "Format", "catalog"),
    "paper": ("相纸", "Paper", "catalog"),
    "all": ("全部", "All", "catalog"),
    "decode": ("解码", "Decode", "catalog"),
    "film_exposure": ("胶片曝光", "Film Exposure", "catalog"),
    "both_exposures": ("两次曝光", "Both exposures", "catalog"),
    "both_frames": ("两格", "both frames", "catalog"),
    "wb_each_exposure": ("白平衡属于每一次曝光。", "White balance belongs to each exposure.", "new"),
    "wb_each_frame": ("白平衡属于每一格。", "White balance belongs to each frame.", "new"),
    "curve": ("曲线", "Curve", "catalog"),
    "hdr": ("高动态范围", "High Dynamic Range", "catalog"),
    "double": ("多重曝光", "Double Exposure", "new"),
    "frame_is_bottoms": ("画幅的大小和比例取自下层曝光。", "The frame’s size and shape are the bottom exposure’s.", "catalog"),
    "swap_sets": ("下层决定画幅与日期", "The bottom sets the frame and the date", "new"),
    "swap_same": ("两张画幅相同：交换后画面不变", "Same shape: a swap changes nothing you can see", "new"),
    "pair": ("半格组", "Half-Frame Pair", "catalog"),
    "camera": ("相机", "Camera", "catalog"),
    "level": ("横放", "Level", "catalog"),
    "turned": ("竖放", "Turned", "catalog"),
    "spacing": ("间距", "Spacing", "catalog"),
    "between": ("两格之间", "between the frames", "catalog"),
    "film_edge": ("片边", "Film Edge", "catalog"),
    "off": ("关", "Off", "catalog"),
    "size": ("尺寸", "Size", "catalog"),
    "half": ("半格", "Half", "catalog"),
    "antihalation": ("移除防光晕层", "Remove anti-halation layer", "catalog"),
    "experimental": ("实验性功能", "Experimental simulation for all stocks", "catalog"),
    "effects": ("效果", "Effects", "catalog"),
    "grain": ("颗粒", "Grain", "catalog"),
    "halation": ("光晕", "Halation", "catalog"),
    # Edit
    "brightness": ("亮度", "Brightness", "catalog"), "contrast": ("对比度", "Contrast", "catalog"),
    "tone": ("色调", "Tone", "catalog"), "channels": ("通道", "Channels", "catalog"),
    "wheels": ("色轮", "Colour Wheels", "catalog"), "vibrance": ("鲜艳度", "Vibrance", "catalog"),
    "saturation": ("饱和度", "Saturation", "catalog"), "lens": ("镜头", "Lens", "catalog"),
    "no_edits_top": ("「上层」没有自己的编辑。编辑作用于整张胶片。", "Top has no edits of its own. Edit works on the whole film.", "new"),
    "select_film": ("选择胶片", "Select Film", "new"),
    # Arrange
    "zoom": ("缩放", "Zoom", "new"),
    "turn90": ("旋转 90°", "Turn 90°", "new"),
    "reset": ("还原", "Reset", "catalog"),
    "arrange_note": ("拖动时预览为两张照片按平衡相加；停下后按胶片冲洗。",
                     "While you drag, the preview adds the two photographs at Balance; it develops on film when you stop.", "new"),
    "cancel": ("取消", "Cancel", "catalog"),
    "done": ("完成", "Done", "catalog"),
    # the window
    "library": ("图库", "Library", "catalog"), "develop": ("冲洗", "Develop", "catalog"),
    "edit": ("编辑", "Edit", "catalog"), "crop": ("裁剪", "Crop", "catalog"), "export": ("导出", "Export", "catalog"),
    "histogram": ("直方图", "Histogram", "catalog"),
    "developed": ("已冲洗", "Developed", "catalog"), "developing": ("冲洗中", "Developing", "catalog"),
    "search": ("搜索", "Search", "catalog"),
    # 合成
    "combine": ("合成", "Combine", "new"),
    "double_sub": ("两次曝光叠在同一格底片上", "Two exposures on one frame of film", "new"),
    "pair_menu": ("半格", "Half-Frame Pair", "new"),
    "pair_sub": ("两张各占半格，排在同一段胶片上", "Two half frames on one piece of film", "new"),
    "order_double": ("下层 DSC_0412 · 上层 IMG_2207", "Bottom DSC_0412 · Top IMG_2207", "new"),
    "order_pair": ("左格 DSC_0412 · 右格 IMG_2207", "Left DSC_0412 · Right IMG_2207", "new"),
    "open_develop": ("在冲洗中打开", "Open in Develop", "catalog"),
    "light_table": ("放到观片台上", "Put on Light Table", "catalog"),
    "info": ("信息", "Info", "catalog"),
    "export_2": ("导出 2", "Export 2", "catalog"),
    "copy_settings": ("拷贝设置", "Copy Settings", "catalog"),
    "photos_selected": ("已选 2 张", "2 photos selected", "catalog"),
    "pick_second": ("选择第二次曝光，叠在同一格底片上", "Choose the second exposure, on the same frame of film", "new"),
    "same_mirrored": ("同一张 · 镜像", "Same one, mirrored", "new"),
    "create": ("创建", "Create", "catalog"),
    "replace_top": ("替换上层", "Replace Top", "new"),
    "replace_sub": ("选一张照片放进上层；原来的那张仍在图库中", "Choose a photograph for the top; the old one stays in the library", "new"),
    # refusal
    "cant_export": ("无法导出「多重曝光 3」", "“Double Exposure 3” can’t be exported", "new"),
    "ok": ("好", "OK", "catalog"),
    "one_exposure": ("一次曝光", "one exposure", "new"),
    # not drawn: the menu's refusals, the keys' names in the Keyboard Shortcuts menu, VoiceOver
    "combine_choose": ("选择一张或两张照片", "Choose one or two photographs", "new"),
    "combine_refused": ("半格组与多重曝光不能再合成", "A pair or a double exposure cannot be combined again", "new"),
    "prev_layer": ("上一图层", "Previous Layer", "new"),
    "next_layer": ("下一图层", "Next Layer", "new"),
    "vo_share": ("占 %@ %", "%@ % of the light", "new"),
    "vo_alone": ("单独显示", "shown alone", "new"),
    "vo_out": ("未显示", "not shown", "new"),
    "vo_eye_top": ("单独查看上层", "Show Top Alone", "new"),
    "vo_eye_bottom": ("单独查看下层", "Show Bottom Alone", "new"),
    "vo_add_to": ("添加照片到%@", "Add a photograph to %@", "new"),
    "vo_layers_of": ("%@ 个图层，选中%@", "%@ layers, %@ picked", "new"),
    # the future drawing
    "subject": ("主体", "Subject", "future"), "background": ("背景", "Background", "future"),
    "people": ("人", "People", "future"), "opacity": ("不透明度", "Opacity", "future"),
    "combine_masks": ("组合蒙版", "Combine Masks", "future"), "refine_mask": ("完善遮罩…", "Refine Mask…", "future"),
    "mask_sky": ("天空", "Sky", "future"), "mask_1": ("蒙版 1", "Mask 1", "future"),
    "not_shipping": ("2.4.x 蒙版 · 本次不做", "2.4.x masks · not in this release", "future"),
}


def T(k):
    return S[k][0 if LANG == "zh" else 1]


def fits(text, size, weight, room, what):
    w = tw(text, size, weight)
    if w > room - 1:
        raise SystemExit(f"DOES NOT FIT ({LANG}) {what}: “{text}” is {w:.1f} in {room:.1f}")
    return w


# ---------------------------------------------------------------------------------------------------------
# The window (MainWindowLayout, WindowToolbar, MacSharedControls, MacInfoStrip), from Screenshot_v2.png.

M = 24            # the page round the window
HEAD = 82         # the title bar's 31 and the bar's 51 (MacMetric.pt(44) at the Mac pages' 10/9)
STRIP = 32        # MacInfoStrip.height, MacMetric.pt(28)


class Page:
    """One drawing: a window `ww` x `wh` with a caption under it."""

    def __init__(self, name, title, notes=(), ww=1000, wh=860):
        self.name, self.ww, self.wh = name, ww, wh
        lines = [ln for n in notes for ln in wrap(n, 11.5, 400, ww)]
        self.d = Drawing(ww + 2 * M, wh + 2 * M + 30 + 16 * len(lines) + 10)
        d = self.d
        d.text(M, wh + 2 * M + 14, title, 14, 600, TEXT)
        for i, n in enumerate(lines):
            d.text(M, wh + 2 * M + 34 + i * 16, n, 11.5, 400, DIM)
        d.text(ww + M, wh + 2 * M + 14, name, 11.5, 500, FAINT, "end")
        self.clipid = d.clip(0, 0, ww, wh, 10)
        d.open(translate=(M, M))
        d.open(clip=self.clipid)
        d.rect(0, 0, ww, wh, BG)

    def finish(self):
        d = self.d
        d.close()
        d.rect(0.5, 0.5, self.ww - 1, self.wh - 1, None, r=10, stroke="#3a3d44", sw=1)
        d.close()
        return d


def toolbar(d, ww, mode, crop_on=False, combine=None, export_op=1, browser=False, place=False):
    """The window's bar: the shared controls, 图库 · 冲洗 · 编辑, the page's actions."""
    for i, c in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]):
        d.circle(15.5 + i * 23.9, 15.5, 6.2, c)
    cy = 57
    d.sym("sidebar.left", 24.3, cy, 15, 500, TEXT)
    d.sym("rectangle.righthalf.inset.filled", 64, cy, 15, 500, ACCENT if browser else TEXT)
    d.sym("square.grid.2x2", 102.4, cy, 15, 500, TEXT)
    d.sym("rectangle.on.rectangle", 141.4, cy, 14, 500, TEXT)
    w = tw(T("crop"), 13, 600) + 46
    d.rect(166.5, cy - 14, w, 28, ACCENT if crop_on else CARD, r=14)
    d.sym("crop", 166.5 + 18, cy, 12, 600, ONSEL if crop_on else TEXT)
    d.ctext(166.5 + 32, cy, T("crop"), 13, 600, ONSEL if crop_on else TEXT)
    mx = 166.5 + w + 26
    seg = max(tw(T(k), 13.5, 600) for k in ("library", "develop", "edit")) + 44
    d.rect(mx, cy - 15, seg * 3, 30, CARD, r=15)
    for i, k in enumerate(("library", "develop", "edit")):
        on = k == mode
        if on:
            d.rect(mx + seg * i + 2, cy - 13, seg - 4, 26, SEL, r=13)
        d.ctext(mx + seg * i + seg / 2, cy, T(k), 13.5, 600 if on else 500, ONSEL if on else TEXT2, "middle")
    # the trailing group
    x = ww - 26
    d.sym("sidebar.right", x, cy, 15, 500, TEXT)
    ew = max(tw(T("export"), 14.5, 600) + 52, 97)
    ex = ww - 56 - ew
    d.rect(ex, cy - 18, ew, 36, ACCENT, r=18, op=export_op)
    d.ctext(ex + ew / 2, cy, T("export"), 14.5, 600, ONSEL, "middle", op=export_op)
    x = ex - 26
    if mode == "library":
        for s_ in ("doc.on.clipboard", "ellipsis"):
            disc(d, x, cy, s_)
            x -= 39.5
        if combine is not None:
            # 合成: a pull-down with its name, as 裁剪 has its own (a bare glyph would have to be guessed).
            cw_ = tw(T("combine"), 13, 600) + 62
            cx0 = x + 18 - cw_
            d.rect(cx0, cy - 14, cw_, 28, "#4B5059" if combine == "open" else CARD, r=14)
            d.sym("square.2.layers.3d", cx0 + 19, cy, 12, 600, TEXT)
            d.ctext(cx0 + 33, cy, T("combine"), 13, 600, TEXT)
            d.sym("chevron.down", cx0 + cw_ - 14, cy, 8, 700, TEXT2)
            d.combine_x = cx0 + cw_
    else:
        for s_, op in (("rectangle.lefthalf.filled", 1), ("doc.on.clipboard", 1), ("ellipsis", 1),
                       ("arrow.uturn.forward", DISABLED), ("arrow.uturn.backward", 1)):
            disc(d, x, cy, s_, op=DISABLED if place else op)
            x -= 39.5
    d.rect(0, HEAD - 0.5, ww, 0.5, WALL)


def info_strip(d, x0, ww, wh, status, busy=False, name="DSC_0412.NEF", exposure="1/500 s", accent_status=False):
    y = wh - STRIP
    d.rect(x0, y, ww - x0, 0.5, WALL)
    cy = y + STRIP / 2 + 0.5
    x = x0 + 16
    if exposure:
        d.ctext(x, cy, exposure, 12.5, 500, TEXT2)
        x += tw(exposure, 12.5, 500) + 18
    if status:
        d.circle(x + 3, cy, 3, ACCENT if (busy or accent_status) else TEXT2)
        d.ctext(x + 11, cy, status, 12.5, 500, TEXT2)
        x += 11 + tw(status, 12.5, 500) + 18
    d.ctext(x, cy, name, 12.5, 600, TEXT)
    for i in range(5):
        d.circle(ww - 96 + i * 13, cy, 1.4, DIM)
    d.sym("chevron.down", ww - 22, cy, 9, 600, DIM)


def wall(d, wh, x=CW):
    d.rect(x, HEAD, 1, wh - HEAD, WALL)


def canvas_box(ww, wh, aspect, pad=22, x0=CW + 1):
    """The picture's rectangle in the canvas, fitted about its middle."""
    ax, ay, aw, ah = x0 + pad, HEAD + pad, ww - x0 - 2 * pad, wh - HEAD - STRIP - 2 * pad
    w = min(aw, ah * aspect)
    h = w / aspect
    return ax + (aw - w) / 2, ay + (ah - h) / 2, w, h


def canvas_tag(d, cx, y, text, symbol="eye"):
    w = tw(text, 12, 600) + 24 + 18
    d.rect(cx - w / 2, y, w, 24, PANEL, r=12, op=0.92)
    d.sym(symbol, cx - w / 2 + 17, y + 12, 11, 600, ACCENT)
    d.ctext(cx - w / 2 + 29, y + 12, text, 12, 600, TEXT)


# ---------------------------------------------------------------------------------------------------------
# The 图层 panel. Every number here is LAYERS-SPEC.md §2.

L_INSET = 12      # the card from the column's sides, the histogram's
L_HEAD = 32       # its head, the histogram's
L_ROW = 30        # a row
L_ROWPAD = 6      # the row's capsule from the card's sides; and under the last row
L_GAP = 6         # under the card
ROW_X = L_INSET + L_ROWPAD                      # 18
EYE_CX = ROW_X + 14                             # 32
THUMB_X, THUMB_W, THUMB_H = ROW_X + 28, 30, 20  # 46
NAME_X = THUMB_X + THUMB_W + 8                  # 84
TRAIL_X = CW - L_INSET - L_ROWPAD - 10          # 365


def thumb_of(kind, **kw):
    def draw(d, x, y, w, h):
        if kind == "double":
            double_picture(d, x, y, w, h, r=3, **kw)
        elif kind == "pair":
            pair_picture(d, x, y, w, h, r=3, **kw)
        else:
            picture(d, kind, x, y, w, h, r=3)
    return draw


def fit_thumb(aspect):
    """A picture fitted in the 30 x 20 slot."""
    w = min(THUMB_W, THUMB_H * aspect)
    h = w / aspect
    return (THUMB_W - w) / 2, (THUMB_H - h) / 2, w, h


def layer_row(d, y, row, state="rest", alone=None):
    """One row. state: rest | selected | hover | disabled. row: name, kind (film | pic | empty), thumb, aspect,
    trail, eye (None: no eye; 'on': in the picture; 'alone': shown alone; 'out': the other is shown alone)."""
    cy = y + L_ROW / 2
    sel = state == "selected"
    if sel:
        d.rect(ROW_X, y + 1, CW - 2 * ROW_X, L_ROW - 2, SEL, r=6)
    elif state == "hover":
        d.rect(ROW_X, y + 1, CW - 2 * ROW_X, L_ROW - 2, CARD, r=6, op=0.5)
    ink = ONSEL if sel else TEXT
    quiet = ONSEL if sel else DIM
    dim = state == "disabled" or (row.get("eye") == "out" and not sel)
    if state == "disabled":
        d.open(op=DISABLED)
    eye = row.get("eye")
    if eye == "alone":
        d.rect(EYE_CX - 11, cy - 9, 22, 18, ACCENT, r=5)
        d.sym("eye", EYE_CX, cy, 11, 600, ONSEL)
    elif eye == "out":
        d.sym("eye.slash", EYE_CX, cy, 11, 500, quiet, op=0.8 if sel else 1)
    elif eye == "on":
        d.sym("eye", EYE_CX, cy, 11, 500, ink if sel else TEXT2, op=0.75)
    if dim and state != "disabled":
        d.open(op=DISABLED)
    kind = row["kind"]
    if kind == "film":
        d.sym("film", THUMB_X + THUMB_W / 2, cy, 13, 500, ink)
    elif kind == "empty":
        d.rect(THUMB_X + 0.5, cy - THUMB_H / 2 + 0.5, THUMB_W - 1, THUMB_H - 1, None, r=3, stroke=quiet, sw=1, dash="3 2.5",
               op=0.7 if sel else 1)
    else:
        ox, oy, w, h = fit_thumb(row.get("aspect", 1.5))
        row["thumb"](d, THUMB_X + ox, cy - THUMB_H / 2 + oy, w, h)
    name = row["name"]
    d.ctext(NAME_X, cy, name, 13, 600 if sel else 500, ink if kind != "empty" else quiet)
    nx = NAME_X + tw(name, 13, 600 if sel else 500)
    if kind == "empty":
        d.ctext(nx + 8, cy, T("empty"), 11.5, 500, quiet, op=0.8 if sel else 1)
    if dim and state != "disabled":
        d.close()
    trail = row.get("trail")
    if kind == "empty" and row.get("add", True):
        d.circle(TRAIL_X - 9, cy, 11, "#E7E5E0" if sel else CARD)
        d.sym("plus", TRAIL_X - 9, cy, 10, 700, ONSEL if sel else TEXT)
    elif trail:
        d.ctext(TRAIL_X, cy, trail, 12, 500, quiet if not sel else ONSEL, "end", op=0.85 if sel else 1, mono=True)
    if state == "disabled":
        d.close()
    return L_ROW


def layers_card(d, y, rows=(), sel=0, folded=False, balance=None, foot=None, hover=None, disabled=(),
                menu=True, one_line=False, summary=None, summary_eye=False, drag=False, balance_op=1):
    """The panel in the column at y. Returns its height, its 6 pt underneath included."""
    h = L_HEAD
    open_ = not folded and not one_line
    if open_:
        h += L_ROW * len(rows) + L_ROWPAD
        if balance is not None:
            h += 0.5 + 40 + 4
        if foot:
            foot = [ln for para in foot for ln in wrap(para, 11.5, 400, CW - 2 * L_INSET - 28)]
            h += 4 + 16.3 * len(foot) + 8
    d.rect(L_INSET, y, CW - 2 * L_INSET, h, PLOT, r=12)
    cy = y + L_HEAD / 2
    d.sym("chevron.down", L_INSET + 14 + 6.5, cy, 10, 600, TEXT2, rotate=0 if open_ else -90, op=DISABLED if one_line else 1)
    d.ctext(L_INSET + 34, cy, T("layers"), 13, 600, TEXT)
    if open_ and menu:
        small_round(d, CW - L_INSET - 10 - 11, cy, "ellipsis", pt=11, weight=700)
    elif not open_ and summary:
        right = CW - L_INSET - 14
        w = fits(summary, 12, 500, 220, "the folded panel's summary")
        d.ctext(right, cy, summary, 12, 500, TEXT2 if not one_line else DIM, "end")
        if summary_eye:
            d.sym("eye", right - w - 12, cy, 10, 600, ACCENT)
    if not open_:
        return h + L_GAP
    yy = y + L_HEAD
    for i, row in enumerate(rows):
        state = "selected" if i == sel else "hover" if i == hover else "disabled" if i in disabled else "rest"
        layer_row(d, yy, row, state)
        yy += L_ROW
    yy += L_ROWPAD
    if balance is not None:
        d.rect(L_INSET + 14, yy, CW - 2 * L_INSET - 28, 0.5, RULE)
        lw = max(tw(T("balance"), 13.5, 600), tw(T("top_share"), 10.5, 500)) + 2
        slider(d, yy + 0.5, T("balance"), (balance - 0.10) / 0.80, f"{round(balance * 100)} %", sub=T("top_share"),
               rest=0.5, x0=L_INSET + 14, x1=CW - L_INSET - 14, label_w=lw, field_w=62, knob_big=drag, op=balance_op)
        yy += 44.5
    if foot:
        note(d, L_INSET + 14, yy + 4, foot, 11.5, DIM, lead=16.3)
    return h + L_GAP


# the rows of each kind of piece

def rows_single():
    return [dict(name=T("film"), kind="film")]


def rows_pair(turned=False, empty=None):
    names = (T("upper"), T("lower")) if turned else (T("left"), T("right"))
    kinds = ("hills", "street")
    out = [dict(name=T("film"), kind="film")]
    for i in range(2):
        if empty == i:
            out.append(dict(name=names[i], kind="empty"))
        else:
            out.append(dict(name=names[i], kind="pic", thumb=thumb_of(kinds[i]), aspect=1.33 if turned else 0.75))
    return out


def rows_double(share=0.5, alone=None, empty=None, swapped=False):
    """胶片, then 上层, then 下层. alone: None | 'top' | 'bottom'."""
    top_kind, bottom_kind = ("portrait", "city") if swapped else ("city", "portrait")
    def eye(which):
        return "on" if alone is None else ("alone" if alone == which else "out")
    out = [dict(name=T("film"), kind="film")]
    for which, kind, s in (("top", top_kind, share), ("bottom", bottom_kind, 1 - share)):
        if empty == which:
            out.append(dict(name=T(which), kind="empty"))
        else:
            out.append(dict(name=T(which), kind="pic", thumb=thumb_of(kind), aspect=1.5,
                            trail=None if empty else f"{round(s * 100)} %", eye=eye(which) if not empty else None))
    return out


# ---------------------------------------------------------------------------------------------------------
# The column's pages under the panel.

def histogram(d, y, folded=True):
    h, cy = histogram_card(d, y, folded)
    d.ctext(12 + 14 + 13 + 7, cy, T("histogram"), 13, 600, TEXT)
    if not folded:
        px, py, pw, ph = 26, y + 6 + 32, CW - 52, 84
        for i in range(1, 4):
            d.rect(px + pw * i / 4, py, 0.5, ph, RULE, op=0.6)
        pts = [0, .02, .05, .2, .55, .8, .72, .6, .62, .5, .4, .42, .3, .2, .12, .1, .16, .08, .03, 0]
        n = len(pts) - 1
        path = f"M{px},{py + ph} " + " ".join(f"L{px + pw * i / n:.1f},{py + ph - ph * 0.92 * v:.1f}" for i, v in enumerate(pts)) + " Z"
        d.path(path, fill="#8a8a88", op=0.55)
        for c, k in (("#e06a5f", 0.9), ("#6fbf73", 1.0), ("#5f86c9", 1.12)):
            line = " ".join(("M" if i == 0 else "L") + f"{px + pw * i / n:.1f},{py + ph - min(ph * 0.92 * v * k, ph):.1f}" for i, v in enumerate(pts))
            d.path(line, stroke=c, sw=1, op=0.9)
        fy = py + ph + 11
        d.ctext(px, fy, "ISO 200", 11, 500, TEXT2)
        d.ctext(px + pw / 2, fy, "1/500 s", 11, 500, TEXT2, "middle")
        d.ctext(px + pw, fy, "f/2.8", 11, 500, TEXT2, "end")
    return h


def stock_cards(d, y, n_sel=1, shades=("#6d7f95", "#8a7a5c", "#5f7d6b", "#7a6a86", "#84604f")):
    """A strip's cards (StockCards.swift), one row: 79.5 x 66, 7.5 apart, from 16. The names are left as bars:
    the cards are not this design's."""
    c = d.clip(0, y, CW, 82)
    d.open(clip=c)
    x = 16
    for i, sh in enumerate(shades):
        g = d.gradient([(0, sh), (1, "#1c1f24")])
        d.rect(x, y + 8, 79.5, 66, g, r=10)
        d.rect(x + 8, y + 8 + 50, 40 - (i % 3) * 6, 6, TEXT, r=3, op=0.75)
        if i == n_sel:
            d.rect(x + 1, y + 9, 77.5, 64, None, r=9, stroke=SELFRAME, sw=2)
        x += 87
    d.close()
    return 82


def part_header(d, y, title, reset=True, reset_live=False, extra=None, scope=None):
    """Decode's part line (DecodeSection.partHeader, 28): the name under Decode's own, its ↺ at 22."""
    cy = y + 14
    d.ctext(34, cy, title, 12, 500, TEXT2)
    x = CW - 16 - 11
    if reset:
        small_round(d, x, cy, "arrow.counterclockwise", op=1 if reset_live else DISABLED)
        x -= 28
    if extra:
        small_round(d, x, cy, extra)
    return 28


def layer_link(d, y):
    """The layer page's last row: where the rest is."""
    fold_rule(d, y)
    cy = y + 0.5 + 18
    d.sym("film", 16 + 9, cy, 12, 500, DIM)
    fits(T("belongs_film"), 12, 500, CW - 44 - 34, "the layer page's link")
    d.ctext(44, cy, T("belongs_film"), 12, 500, TEXT2)
    d.sym("chevron.right", CW - 16 - 4, cy, 9, 600, DIM)
    fold_rule(d, y + 36.5)
    return 37


def section_arrange(d, y, value, flip=None):
    h, cy = fold_header(d, y, T("arrange"))
    fits(value, 12, 500, 200, "Arrange's value")
    d.ctext(CW - 16, cy, value, 12, 500, DIM, "end")
    by = y + h + 4 + 14
    x = 34
    x += capsule_button(d, x, by, T("arrange_cmd"), symbol="arrow.up.left.and.arrow.down.right") + 8
    if flip is not None:
        chip(d, x, by, T("flip_h"), on=flip, symbol="arrow.left.and.right.righttriangle.left.righttriangle.right")
    return h + 4 + 28 + 12


def section_wb(d, y, writes_note=True):
    h, cy = fold_header(d, y, T("white_balance"))
    small_round(d, CW - 16 - 11, cy, "arrow.counterclockwise", op=DISABLED)
    small_round(d, CW - 16 - 11 - 28, cy, "eyedropper")
    yy = y + h
    lw = 64 if LANG == "zh" else 92
    yy += slider(d, yy, T("temperature"), 0.42, "5167 K", sub=T("as_shot"), rest=None, tint=("#5f86c9", "#e3c25a"), label_w=lw) + 6
    yy += slider(d, yy, T("tint"), 0.56, "+17", rest=0.5, tint=("#6fbf73", "#c86fb5"), label_w=lw) + 6
    if writes_note:
        yy += note(d, 34, yy, wrap(T("wb_writes"), 11.5, 400, CW - 34 - 16)) + 10
    return yy - y


def section_photo(d, y, file_, lines, can_change=True):
    h, cy = fold_header(d, y, T("photograph"))
    yy = y + h
    d.text(34, yy + 12, file_, 12, 600, TEXT)
    yy += 22
    x = 34
    x += chip(d, x, yy + 14, T("replace") + "…", dim=not can_change) + 8
    chip(d, x, yy + 14, T("remove"), dim=not can_change)
    yy += 28 + 8
    lines = [ln for para in lines for ln in wrap(para, 11.5, 400, CW - 34 - 16)]
    yy += note(d, 34, yy, lines) + 10
    return yy - y


def page_layer_double(d, y, which="top", advanced=False, origin=False, flipped=False, share=0.6, zoom="1.30×"):
    value = T("covers") + " · " + zoom + (" · " + T("flipped") if flipped else "")
    y += section_arrange(d, y, value, flip=flipped)
    h, cy = fold_header(d, y, T("advanced"), open_=advanced)
    if not advanced:
        d.ctext(CW - 16, cy, T("exposure") + " · " + T("meter") + " +1.3", 12, 500, DIM, "end")
    y += h
    if advanced:
        lw = 64 if LANG == "zh" else 92
        y += slider(d, y, T("exposure"), 0.44, "−0.6 EV", sub=T("meter") + " +1.3", label_w=lw) + 4
        line = T("balance_to") + f" {round(share * 100)} %"
        d.ctext(34, y + 12, line, 11.5, 500, ACCENT)
        pill_menu(d, CW - 16, y + 12, T("meter") + " · " + ("中央重点" if LANG == "zh" else "Centre"))
        y += 24 + 8
    y += section_wb(d, y)
    if origin:
        y += section_photo(d, y, "DSC_0412.NEF", [T("began_double")], can_change=False)
    else:
        y += section_photo(d, y, "IMG_2207.JPG", [T("also_alone")])
    y += layer_link(d, y)
    return y


def page_layer_pair(d, y, file_="DSC_0412.NEF", dated=True):
    y += section_arrange(d, y, T("centred") + " · 1.00×")
    h, cy = fold_header(d, y, T("exposure"))
    w = pill_menu(d, CW - 16, cy, T("scope_frame"))
    d.ctext(CW - 16 - w - 10, cy, T("meter") + " +0.4", 12, 500, DIM, "end")
    y += h
    lw = 64 if LANG == "zh" else 92
    y += slider(d, y, T("exposure"), 0.53, "+0.3 EV", label_w=lw) + 6
    y += section_wb(d, y, writes_note=False)
    h, cy = fold_header(d, y, T("enlarger"), open_=False)
    pill_menu(d, CW - 16, cy, T("scope_frame"))
    y += h
    h, cy = fold_header(d, y, T("date_back"))
    toggle(d, CW - 16, cy, dated)
    y += h
    d.ctext(34, y + 9, "’25  9 12", 12.5, 600, K.ACCENT if dated else DIM)
    y += 22
    y += note(d, 34, y, wrap(T("date_note"), 11.5, 400, CW - 34 - 16)) + 10
    y += section_photo(d, y, file_, [T("also_alone")])
    y += layer_link(d, y)
    return y


def page_layer_empty(d, y, double=True):
    yy = y + 14
    w = CW - 32
    d.rect(16, yy, w, 36, CARD, r=18)
    label = T("add_exposure") if double else T("add_frame")
    lw_ = tw(label, 13.5, 600)
    d.sym("plus", CW / 2 - lw_ / 2 - 9, yy + 18, 11, 700, TEXT)
    d.ctext(CW / 2 + 7, yy + 18, label, 13.5, 600, TEXT, "middle")
    yy += 36 + 12
    lines = [T("empty_layer")] if double else [T("fill_pair_1")]
    lines = [ln for para in lines for ln in wrap(para, 11.5, 400, CW - 32)]
    yy += note(d, 16, yy, lines) + 14
    yy += layer_link(d, yy)
    return yy


def decode_film(d, y, double=True, wb_rows=("top", "bottom")):
    """解码 with the film picked: Film Exposure for both, and white balance as each picture's own (R3)."""
    h, cy = fold_header(d, y, T("decode"))
    y += h
    y += part_header(d, y, T("exposure"))
    lw = 64 if LANG == "zh" else 92
    y += slider(d, y, T("film_exposure"), 0.5, "0.0 EV", sub=T("both_exposures") if double else T("both_frames"), label_w=lw) + 8
    y += part_header(d, y, T("white_balance"), reset=False)
    line = T("wb_each_exposure") if double else T("wb_each_frame")
    fits(line, 12, 500, CW - 34 - 16, "the R3 line")
    d.ctext(34, y + 10, line, 12, 500, TEXT2)
    y += 26
    x = 34
    for k in wb_rows:
        x += chip(d, x, y + 14, T(k), symbol="arrow.up.forward") + 8
    y += 28 + 12
    y += part_header(d, y, T("curve"))
    return y


def page_film_and_paper(d, y, double=True, wb_rows=("top", "bottom"), clip_to=None):
    y += nav_band(d, y, [T("film_paper"), T("format")], 0)
    h, cy = fold_header(d, y, T("film"), rule=False)
    pill_menu(d, CW - 16, cy, T("all"))
    y += h
    y += stock_cards(d, y)
    h, cy = fold_header(d, y, T("paper"), open_=False)
    pill_menu(d, CW - 16, cy, T("all"))
    y += h
    y = decode_film(d, y, double, wb_rows)
    # the curve's plot runs off the window, as today
    d.rect(34, y + 4, CW - 34 - 16, 240, PLOT, r=8)
    d.line(34, y + 244, CW - 16, y + 4, DIM, 1, op=0.6)
    return y


def simple_row(d, y, title, h=32, sub=None, trailing=None, chev=False, op=1):
    cy = y + h / 2
    if op != 1:
        d.open(op=op)
    if sub:
        d.text(34, cy - 2, title, 12.5, 500, TEXT)
        d.text(34, cy + 12, sub, 11.5, 400, DIM)
    else:
        d.ctext(34, cy, title, 12.5, 500, TEXT)
    if chev:
        d.sym("chevron.right", CW - 16 - 4, cy, 9, 600, DIM)
    if op != 1:
        d.close()
    return h


def format_tail(d, y, size_value, edge_on=False, date_on=False, sizes_op=1, sections=True):
    h, cy = fold_header(d, y, T("size"), open_=False, op=sizes_op)
    d.ctext(CW - 16, cy, size_value, 12, 500, DIM, "end", op=sizes_op)
    y += h
    if sections:
        h, cy = fold_header(d, y, T("film_edge"), open_=False)
        toggle(d, CW - 16, cy, edge_on)
        y += h
        h, cy = fold_header(d, y, T("date_back"), open_=False)
        toggle(d, CW - 16, cy, date_on)
        y += h
    fold_rule(d, y)
    d.text(16, y + 16, T("antihalation"), 12.5, 500, TEXT)
    d.text(16, y + 30, T("experimental"), 10.5, 500, TEXT2)
    toggle(d, CW - 16, y + 20, False)
    y += 40.5
    h, cy = fold_header(d, y, T("effects"))
    y += h
    lw = 64 if LANG == "zh" else 92
    y += slider(d, y, T("grain"), 0.5, "1.00×", sub="135", label_w=lw) + 6
    y += slider(d, y, T("halation"), 0.25, "1.00×", label_w=lw) + 6
    return y


def page_format_double(d, y, same_shape=False):
    y += nav_band(d, y, [T("film_paper"), T("format")], 1)
    h, cy = fold_header(d, y, T("double"), rule=False)
    y += h
    sub = T("swap_same") if same_shape else T("swap_sets")
    fits(sub, 11.5, 400, CW - 34 - 60, "the swap row's line")
    d.text(34, y + 14, T("swap_double"), 12.5, 600, TEXT)
    d.text(34, y + 29, sub, 11.5, 400, DIM)
    small_round(d, CW - 16 - 13, y + 19, "arrow.up.arrow.down", diameter=26, pt=11)
    y += 40
    y += note(d, 34, y + 2, wrap(T("frame_is_bottoms"), 11.5, 400, CW - 34 - 16)) + 12
    return format_tail(d, y, "135", edge_on=False, date_on=True)


def page_format_pair(d, y, turned=False, strip=False):
    y += nav_band(d, y, [T("film_paper"), T("format")], 1)
    h, cy = fold_header(d, y, T("pair"), rule=False)
    y += h
    d.ctext(34, y + 18, T("camera"), 12.5, 500, TEXT)
    segmented(d, CW - 16, y + 18, [T("level"), T("turned")], 1 if turned else 0, seg=64)
    y += 38
    lw = tw(T("spacing"), 13.5, 600) + 2
    slider(d, y, T("spacing"), 0.2, "2.0 mm", sub=T("between"), rest=None, x0=34, label_w=max(lw, tw(T("between"), 10.5, 500) + 2))
    y += 46
    for title, value in ((T("film_edge"), T("off")), (T("date_back"), "LCD · " + T("both_frames"))):
        d.ctext(34, y + 16, title, 12.5, 500, TEXT)
        pill_menu(d, CW - 16, y + 16, value)
        y += 32
    d.ctext(34, y + 16, T("swap_pair"), 12.5, 600, TEXT)
    small_round(d, CW - 16 - 13, y + 16, "arrow.up.arrow.down" if turned else "arrow.left.arrow.right", diameter=26, pt=11)
    y += 38
    return format_tail(d, y, T("half"), sizes_op=DISABLED, sections=False)


EDIT_TOOLS = [("brightness", "sun.max"), ("contrast", "circle.lefthalf.filled"), ("tone", "circle.lefthalf.striped.horizontal"),
              (None, "paintpalette"), ("channels", "line.3.horizontal.decrease"), ("wheels", "circle.grid.3x3"),
              ("vibrance", "drop.halffull"), ("saturation", "rainbow"), ("temperature", "thermometer.medium"),
              ("curve", "point.topleft.down.to.point.bottomright.curvepath"), ("lens", "camera.metering.center.weighted")]


def page_edit(d, y, open_first=True, op=1):
    """Edit › Adjust's list (AdjustColumn.swift): every tool a 32 pt folding header with its symbol and grip."""
    if op != 1:
        d.open(op=op)
    for i, (k, symbol) in enumerate(EDIT_TOOLS):
        title = T(k) if k else "HSL"
        is_open = open_first and i == 0
        h, cy = fold_header(d, y, title, open_=is_open, symbol=symbol)
        d.sym("line.3.horizontal", CW - 16 - 8, cy, 11, 600, DIM, op=0.45)
        y += h
        if is_open:
            lw = 64 if LANG == "zh" else 92
            y += slider(d, y, title, 0.5, "0", label_w=lw) + 10
    fold_rule(d, y)
    if op != 1:
        d.close()
    return y


def edit_standdown(d, y, which="top"):
    """With a picture's row picked in Edit: what the row has there (nothing), and the way to what does."""
    fold_rule(d, y)
    lines = wrap(T("no_edits_top"), 12, 500, CW - 32)
    for i, ln in enumerate(lines):
        d.text(16, y + 22 + i * 17, ln, 12, 500, TEXT2)
    yy = y + 22 + (len(lines) - 1) * 17
    capsule_button(d, 16, yy + 26, T("select_film"), symbol="film")
    return yy + 26 + 14 + 10 - y


# ---------------------------------------------------------------------------------------------------------
# Whole drawings.

def column_top(d, hist_folded=True):
    y = HEAD
    y += histogram(d, y, hist_folded)
    return y


def canvas_double(p, share=0.6, alone=None, tag=None, busy=False, status=None, flipped=False, empty=None, zoom=1.3):
    d = p.d
    x, y, w, h = canvas_box(p.ww, p.wh, 1.5)
    if alone == "top" or empty == "bottom":
        picture(d, "city", x, y, w, h)
    elif alone == "bottom" or empty == "top":
        if empty == "top":
            d.open(op=0.5)       # the one exposure there is, at its -1 EV
        picture(d, "portrait", x, y, w, h)
        if empty == "top":
            d.close()
    else:
        double_picture(d, x, y, w, h, share=share, flipped=flipped, top_zoom=zoom)
    if tag:
        canvas_tag(d, x + w / 2, y + 12, tag)
    if busy:
        d.rect(x, y + h - 3, w, 3, "#000", op=0.5)
        d.rect(x, y + h - 3, w * 0.62, 3, ACCENT)
    return x, y, w, h


def canvas_pair(p, turned=False, picked=None, empty=None):
    d = p.d
    x, y, w, h = canvas_box(p.ww, p.wh, 0.72 if turned else 1.5, pad=28)
    boxes = pair_picture(d, x, y, w, h, turned=turned, empty=empty)
    if picked is not None:
        b = boxes[picked]
        d.rect(b[0] - 1.5, b[1] - 1.5, b[2] + 3, b[3] + 3, None, r=2, stroke=SELFRAME, sw=2)
    if empty is not None:
        b = boxes[empty]
        d.rect(b[0] + 6, b[1] + 6, b[2] - 12, b[3] - 12, None, r=4, stroke=DIM, sw=1, dash="5 4")
        d.sym("plus", b[0] + b[2] / 2, b[1] + b[3] / 2, 20, 500, DIM)
    return boxes


def std(name, title, notes, mode, column, canvas, strip_status=None, busy=False, strip_name="DSC_0412.NEF", **tb):
    p = Page(name, title, notes)
    d = p.d
    toolbar(d, p.ww, mode, **tb)
    c = d.clip(0, HEAD, CW, p.wh - HEAD)
    d.open(clip=c)
    column(d)
    d.close()
    wall(d, p.wh)
    canvas(p)
    info_strip(d, CW + 1, p.ww, p.wh, strip_status or T("developed"), busy=busy, name=strip_name)
    return p


DOUBLE_NAME = {"zh": "多重曝光 3", "en": "Double Exposure 3"}
PAIR_NAME = {"zh": "半格组 2", "en": "Half-Frame Pair 2"}


def cap(zh, en):
    return zh if LANG == "zh" else en


def menu_panel(d, x, y, w, items, title=None):
    """A Mac menu, drawn plainly: rows 24 high (two lines 40), separators, a section's title."""
    h = 6
    for it in items:
        h += 9 if it == "-" else (20 if it[0] == "title" else (40 if len(it) > 3 and it[3] else 24))
    h += 6
    d.rect(x + 1, y + 3, w, h, "#000", r=8, op=0.35)
    d.rect(x, y, w, h, "#2A2D33", r=8, stroke="#4a4e57", sw=0.5)
    yy = y + 6
    for it in items:
        if it == "-":
            d.rect(x + 10, yy + 4, w - 20, 0.5, "#4a4e57")
            yy += 9
            continue
        if it[0] == "title":
            d.ctext(x + 12, yy + 10, it[1], 11.5, 600, DIM)
            yy += 20
            continue
        kind, label, symbol = it[0], it[1], it[2]
        sub = it[3] if len(it) > 3 else None
        rh = 40 if sub else 24
        if kind == "hi":
            d.rect(x + 5, yy, w - 10, rh, "#4B5059", r=5)
        ink = DIM if kind == "off" else TEXT
        if symbol:
            d.sym(symbol, x + 22, yy + (13 if sub else rh / 2), 12, 500, ink)
        tx = x + 38
        fits(label, 13, 500, w - 38 - 12, "a menu row")
        if sub:
            d.text(tx, yy + 17, label, 13, 500, ink)
            fits(sub, 11.5, 400, w - 38 - 12, "a menu row's second line")
            d.text(tx, yy + 32, sub, 11.5, 400, TEXT2 if kind == "hi" else DIM)
        else:
            d.ctext(tx, yy + rh / 2, label, 13, 500, ink)
        if len(it) > 4 and it[4]:
            d.ctext(x + w - 14, yy + rh / 2, it[4], 12.5, 500, DIM, "end")
        yy += rh
    return h


def draw_all():
    out = []
    Z = LANG == "zh"

    # --- 01 / 02: the panel in 冲洗, unfolded and folded (a double exposure, 胶片 picked) -------------------
    def col01(d):
        y = column_top(d, hist_folded=False)
        y += layers_card(d, y, rows_double(0.5), sel=0, balance=0.5)
        page_film_and_paper(d, y)
    out.append(std("01-develop-unfolded", cap("01 · 冲洗 · 图层展开（多重曝光，选中「胶片」）", "01 · Develop · Layers unfolded (a double exposure, Film picked)"),
                   [cap("图层固定在直方图之下、两个模式共用的位置；选中「胶片」时，下面就是今天的整栏。白平衡属于每一次曝光（R3）：两枚按钮各选中那一层。",
                        "Layers is pinned under the histogram, where both modes share it. With Film picked the column below is today’s. White balance belongs to each exposure (R3): each chip picks that row."),
                    cap("平衡在面板里，任何一行选中时都在（Capture One 放「不透明度」的位置）。", "Balance is in the panel whichever row is picked (where Capture One keeps Opacity).")],
                   "develop", col01, lambda p: canvas_double(p, 0.5), strip_name=DOUBLE_NAME[LANG]))

    def col02(d):
        y = column_top(d, hist_folded=False)
        y += layers_card(d, y, rows_double(0.5), sel=0, folded=True, summary=T("film"))
        page_film_and_paper(d, y)
    out.append(std("02-develop-folded", cap("02 · 冲洗 · 图层收起", "02 · Develop · Layers folded"),
                   [cap("收起后只剩 32 的一行；右侧写着选中的是哪一层，所以下面的控制作用于谁仍然看得见。收起状态跨模式、跨启动保留。",
                        "Folded, it is one 32-unit line; its trailing words name the picked row, so what the controls are about is still said. The fold is kept across modes and launches.")],
                   "develop", col02, lambda p: canvas_double(p, 0.5), strip_name=DOUBLE_NAME[LANG]))

    # --- 03 / 04: the panel in 编辑 ---------------------------------------------------------------------
    def col03(d):
        y = column_top(d, hist_folded=False)
        y += layers_card(d, y, rows_double(0.5), sel=0, balance=0.5)
        page_edit(d, y)
    out.append(std("03-edit-unfolded", cap("03 · 编辑 · 图层展开（选中「胶片」）", "03 · Edit · Layers unfolded (Film picked)"),
                   [cap("换到编辑：面板原地不动，选中行、收起状态、「单独查看」都保留。编辑的工具属于整张胶片。",
                        "Switching to Edit: the panel does not move, and keeps its picked row, its fold and Show Alone. Edit’s tools are the whole film’s.")],
                   "edit", col03, lambda p: canvas_double(p, 0.5), strip_name=DOUBLE_NAME[LANG]))

    def col04(d):
        y = column_top(d, hist_folded=False)
        y += layers_card(d, y, rows_double(0.5), sel=0, folded=True, summary=T("film"))
        page_edit(d, y)
    out.append(std("04-edit-folded", cap("04 · 编辑 · 图层收起", "04 · Edit · Layers folded"),
                   [cap("与 02 是同一个收起状态（同一个偏好）。", "The same fold as 02 (one preference).")],
                   "edit", col04, lambda p: canvas_double(p, 0.5), strip_name=DOUBLE_NAME[LANG]))

    # --- 05: a single frame ----------------------------------------------------------------------------
    def col05(d):
        y = column_top(d)
        y += layers_card(d, y, rows_single(), one_line=True, summary=T("film"))
        y += nav_band(d, y, [T("film_paper"), T("format")], 0)
        h, cy = fold_header(d, y, T("film"), rule=False)
        pill_menu(d, CW - 16, cy, T("all"))
        y += h
        y += stock_cards(d, y)
        h, cy = fold_header(d, y, T("paper"), open_=False)
        pill_menu(d, CW - 16, cy, T("all"))
        y += h
        h, cy = fold_header(d, y, T("decode"))
        y += h
        y += part_header(d, y, T("exposure"))
        lw = 64 if Z else 92
        y += slider(d, y, T("film_exposure"), 0.5, "0.0 EV", label_w=lw) + 8
        y += part_header(d, y, T("white_balance"), extra="eyedropper")
        y += slider(d, y, T("temperature"), 0.42, "5167 K", sub=T("as_shot"), rest=None, tint=("#5f86c9", "#e3c25a"), label_w=lw) + 6
        y += slider(d, y, T("tint"), 0.56, "+17", tint=("#6fbf73", "#c86fb5"), label_w=lw) + 6
        # the alternative, set apart at the column's foot
        ay = 652
        d.rect(8, ay - 22, CW - 16, 118, None, r=8, stroke=ACCENT, sw=1, dash="4 3")
        d.rect(8, ay - 22, CW - 16, 118, BG, r=8, op=0.94)
        d.rect(8, ay - 22, CW - 16, 118, None, r=8, stroke=ACCENT, sw=1, dash="4 3")
        d.text(20, ay - 6, cap("另一种画法（未推荐）：展开为只有「胶片」的一行", "The alternative (not recommended): unfolded, with its one row"), 11.5, 600, ACCENT)
        layers_card(d, ay + 4, rows_single(), sel=0, menu=False)
    def can05(p):
        x, y, w, h = canvas_box(p.ww, p.wh, 1.5)
        picture(p.d, "hills", x, y, w, h)
    out.append(std("05-single-frame", cap("05 · 单张照片 · 推荐：收成一行", "05 · A single frame · recommended: one line"),
                   [cap("单张照片只有「胶片」一层：面板收成 32 的一行，写着「胶片」，不占一行只能选中、什么也不改变的列表。用户的收起偏好不动，回到半格或多重曝光时恢复。",
                        "A single frame has one layer: the panel is its 32-unit head reading Film, not a list whose one row can only be picked. The fold preference is untouched and returns on a pair or a double."),
                    cap("蒙版时代到来后，单张照片有了更多图层，这一行自然展开成列表。", "When masks arrive a single frame gains rows, and this line unfolds into the list.")],
                   "develop", col05, can05))

    # --- 06-11: a half-frame pair, level and turned, each row picked ----------------------------------
    def pair_page(n, turned, sel, en_too_title_zh, title_en, notes):
        def col(d):
            y = column_top(d)
            y += layers_card(d, y, rows_pair(turned), sel=sel)
            if sel == 0:
                page_format_pair(d, y, turned=turned)
            else:
                page_layer_pair(d, y, file_="DSC_0412.NEF" if sel == 1 else "IMG_2207.JPG")
        return std(n, cap(en_too_title_zh, title_en), notes, "develop", col,
                   lambda p: canvas_pair(p, turned=turned, picked=None if sel == 0 else sel - 1), strip_name=PAIR_NAME[LANG])

    out.append(pair_page("06-pair-level-film", False, 0, "06 · 半格组（横放）· 选中「胶片」· 冲洗 › 格式", "06 · A pair, level · Film picked · Develop › Format",
                         [cap("「胶片」的一栏就是单张照片的那一栏；格式的第一段是这段胶片自己的设置（今天 PairPiecePanel 的内容）：相机、间距、片边、日期后背、对调两格。",
                              "Film’s column is a single frame’s column; Format’s first section is the piece’s own (today’s PairPiecePanel): Camera, Spacing, Film Edge, Date Back, Swap."),
                          cap("半格组没有平衡，也没有不透明度；画面下方原来的「左格 · 胶片 · 右格」切换条取消，画面多出 44。", "A pair has no Balance and no Opacity. The Left · Film · Right band under the picture goes; the picture gains 44 units.")]))
    out.append(pair_page("07-pair-level-left", False, 1, "07 · 半格组（横放）· 选中「左格」", "07 · A pair, level · Left frame picked",
                         [cap("选中一格：整栏换成这一格自己的一页，只有属于它的东西（今天 PairPicturePanel 的内容，加上它自己的曝光、白平衡与放大机）：摆放、曝光、白平衡、放大机、日期、替换与移除。",
                              "A frame picked: the column is that frame’s own page and nothing else (today’s PairPicturePanel plus its own exposure, white balance and enlarger)."),
                          cap("没有「胶片与相纸 | 格式」切换：胶片、相纸与效果属于「胶片」，最后一行带过去。画面上这一格戴白框。", "No Film & Paper | Format band: those belong to Film, and the last row leads there. The frame wears the white frame on the picture.")]))
    out.append(pair_page("08-pair-level-right", False, 2, "08 · 半格组（横放）· 选中「右格」", "08 · A pair, level · Right frame picked",
                         [cap("与 07 相同的一页，属于右格。", "The same page as 07, the right frame’s.")]))
    out.append(pair_page("09-pair-turned-film", True, 0, "09 · 半格组（竖放）· 选中「胶片」", "09 · A pair, turned · Film picked",
                         [cap("竖放时行名是「胶片 · 上格 · 下格」，顺序与画面一致：上格在上。", "Turned, the rows read Film · Top frame · Bottom frame, in the picture’s order.")]))
    out.append(pair_page("10-pair-turned-upper", True, 1, "10 · 半格组（竖放）· 选中「上格」", "10 · A pair, turned · Top frame picked", []))
    out.append(pair_page("11-pair-turned-lower", True, 2, "11 · 半格组（竖放）· 选中「下格」", "11 · A pair, turned · Bottom frame picked", []))

    # --- 12: a pair with an empty hole ------------------------------------------------------------------
    def col12(d):
        y = column_top(d)
        y += layers_card(d, y, rows_pair(False, empty=1), sel=2, foot=[T("fill_pair_2")])
        page_layer_empty(d, y, double=False)
    out.append(std("12-pair-empty", cap("12 · 半格组 · 空着的一格", "12 · A pair · an empty hole"),
                   [cap("空的一行：虚线框、「空」、右端的 + 就是「添加照片」。面板底部一行说明为什么不能导出。", "An empty row: a dashed box, Empty, and + at its end is Add Frame. The panel’s foot says why it will not export.")],
                   "develop", col12, lambda p: canvas_pair(p, picked=1, empty=1), strip_name=PAIR_NAME[LANG]))

    # --- 13-15: a double exposure, each row picked -------------------------------------------------------
    def col13(d):
        y = column_top(d)
        y += layers_card(d, y, rows_double(0.6), sel=0, balance=0.6)
        page_format_double(d, y)
    out.append(std("13-double-film-format", cap("13 · 多重曝光 · 选中「胶片」· 冲洗 › 格式", "13 · A double exposure · Film picked · Develop › Format"),
                   [cap("格式的第一段是多重曝光自己的：交换上下层，旁边写明它改变什么（下层决定画幅与日期；两张画幅相同时写「交换后画面不变」）。其余是单张照片的格式。",
                        "Format’s first section is the double’s own: Swap Top and Bottom, with what it changes beside it (the bottom sets the frame and the date; “a swap changes nothing you can see” when the shapes match)."),
                    cap("胶片与相纸一页见 01。", "Film & Paper is drawing 01.")],
                   "develop", col13, lambda p: canvas_double(p, 0.6), strip_name=DOUBLE_NAME[LANG]))

    def col14(d):
        y = column_top(d)
        y += layers_card(d, y, rows_double(0.6), sel=1, balance=0.6)
        page_layer_double(d, y, "top")
    out.append(std("14-double-top", cap("14 · 多重曝光 · 选中「上层」", "14 · A double exposure · Top picked"),
                   [cap("上层自己的一页：摆放与水平翻转、进阶（它自己的曝光与测光，默认收起，R4）、白平衡（只写这一次曝光的照片，R3）、照片（替换、移除）。",
                        "Top’s own page: Arrange and Flip, Advanced (its own stops and meter, folded by default, R4), White Balance (this exposure’s photograph only, R3), Photograph (Replace, Remove)."),
                    cap("平衡留在面板里，拖它时画面跟着冲洗（R2）。", "Balance stays in the panel and develops while it is dragged (R2).")],
                   "develop", col14, lambda p: canvas_double(p, 0.6), strip_name=DOUBLE_NAME[LANG]))

    def col15(d):
        y = column_top(d)
        y += layers_card(d, y, rows_double(0.67), sel=2, balance=0.67)
        page_layer_double(d, y, "bottom", advanced=True, origin=True, share=0.67)
    out.append(std("15-double-bottom-advanced", cap("15 · 多重曝光 · 选中「下层」· 进阶展开", "15 · A double exposure · Bottom picked · Advanced open"),
                   [cap("进阶展开：这一次曝光自己的曝光量与测光；它一动，平衡跟着动，所以旁边用强调色写出「平衡 → 67 %」。",
                        "Advanced open: this exposure’s own stops and meter. Moving it moves Balance, so the line beside it says “Balance → 67 %” in the accent."),
                    cap("下层是这张多重曝光开始的那张照片：替换与移除退下，并说明原因。", "Bottom is the photograph the double began with: Replace and Remove stand down, and the note says why.")],
                   "develop", col15, lambda p: canvas_double(p, 0.67), strip_name=DOUBLE_NAME[LANG]))

    # --- 16: alone, by the eye ---------------------------------------------------------------------------
    def col16(d):
        y = column_top(d)
        y += layers_card(d, y, rows_double(0.6, alone="top"), sel=0, balance=0.6)
        page_format_double(d, y)
    out.append(std("16-double-alone", cap("16 · 多重曝光 · 眼睛：单独查看上层（R9）", "16 · A double exposure · the eye: Top alone (R9)"),
                   [cap("点一行的眼睛：只看这一次曝光按它自己冲洗出来的样子。亮起的眼睛是强调色（状态），另一行的眼睛划掉、整行变暗；再点一次回到两次曝光，点另一只眼睛直接换成那一层。",
                        "A click on a row’s eye shows that exposure as it develops by itself. The lit eye is the accent (a state); the other row’s eye is struck and the row dims. Click again for both, or the other eye to switch."),
                    cap("这是页面的状态，不写进作品、不进撤销；导出的永远是两次曝光。画面上方与状态栏都写着「仅上层」。", "It is the page’s state: nothing is written or undone, and an export is always the double. The picture’s tag and the status line say “Top alone”.")],
                   "develop", col16, lambda p: canvas_double(p, 0.6, alone="top", tag=T("alone_top")),
                   strip_status=T("developed") + " · " + T("alone_top"), strip_name=DOUBLE_NAME[LANG]))

    # --- 17: Balance being dragged -----------------------------------------------------------------------
    def col17(d):
        y = column_top(d)
        y += layers_card(d, y, rows_double(0.72), sel=0, balance=0.72, drag=True)
        page_format_double(d, y)
    out.append(std("17-double-balance-drag", cap("17 · 多重曝光 · 拖动平衡（R2）", "17 · A double exposure · Balance being dragged (R2)"),
                   [cap("平衡是那一个 ValueSlider：轨道不动、滑块跟手、数字可输入，50 % 处有刻线并吸附。拖动中每个值都写入，指针一停就按实时档冲洗；两行右端的占比同步变化。",
                        "Balance is the one ValueSlider: a fixed track, the knob under the pointer, a number that takes typing, a hairline and a detent at 50 %. Every value is written as it comes and develops at the live tier when the pointer rests; the rows’ shares follow."),
                    cap("整个拖动是一步撤销。范围 10–90 %。", "The whole drag is one step of Undo. The range is 10–90 %.")],
                   "develop", col17, lambda p: canvas_double(p, 0.72, busy=True), strip_status=T("developing"), busy=True,
                   strip_name=DOUBLE_NAME[LANG]))

    # --- 18: Arrange --------------------------------------------------------------------------------------
    out.append(draw_arrange())

    # --- 19: swap -----------------------------------------------------------------------------------------
    def col19(d):
        y = column_top(d)
        y0 = y
        y += layers_card(d, y, rows_double(0.6), sel=1, balance=0.6)
        page_layer_double(d, y, "top")
        d.rect(0, HEAD, CW, 1000, "#000", op=0.001)
        items = [("on", T("arrange_cmd"), "arrow.up.left.and.arrow.down.right"),
                 ("on", T("flip_h"), "arrow.left.and.right.righttriangle.left.righttriangle.right"),
                 ("on", T("show_alone"), "eye"), "-",
                 ("hi", T("swap_double"), "arrow.up.arrow.down", T("swap_sets")), "-",
                 ("on", T("replace_cmd"), "photo"),
                 ("on", T("remove_cmd"), "minus.circle")]
        menu_panel(d, CW - L_INSET - 10 - 280, y0 + 30, 280, items)
    out.append(std("19-double-swap", cap("19 · 多重曝光 · 交换上下层（面板的 ⋯ 菜单）", "19 · A double exposure · Swap Top and Bottom (the panel’s ⋯ menu)"),
                   [cap("面板右上的 ⋯ 与每一行的右键菜单是同一份：摆放、水平翻转、单独查看、交换、替换、移除，作用于选中（或被右键）的那一行。交换是一步撤销；平衡的数字留在位置上（上层仍是 60 %）。",
                        "The panel’s ⋯ and a row’s secondary-click menu are one list: Arrange, Flip, Show Alone, Swap, Replace, Remove, for the picked (or clicked) row. A swap is one step of Undo; Balance’s number stays with the position."),
                    cap("交换也在「胶片」› 格式 › 多重曝光里有一行（13）。", "Swap is also a row of Film › Format › Double Exposure (13).")],
                   "develop", col19, lambda p: canvas_double(p, 0.6), strip_name=DOUBLE_NAME[LANG]))

    # --- 20: replace (the picker) ------------------------------------------------------------------------
    out.append(draw_picker("20-double-replace", cap("20 · 多重曝光 · 替换上层的照片", "20 · A double exposure · replacing Top’s photograph"),
                           [cap("与「合成」的第二次曝光选择器是同一张表：标题与按钮换成「替换」。半格组与多重曝光不在其中；已在这张多重曝光里的照片标着它在哪一层。",
                                "The same sheet as 合成’s second-exposure picker, titled and confirmed as Replace. Pairs and doubles are not offered; a photograph already in this double says which layer it is.")],
                           replace=True, over="develop"))

    # --- 21: removed -> an empty layer --------------------------------------------------------------------
    def col21(d):
        y = column_top(d)
        y += layers_card(d, y, rows_double(0.6, empty="top"), sel=1, foot=[T("fill_double")])
        page_layer_empty(d, y, double=True)
    out.append(std("21-double-removed-empty", cap("21 · 多重曝光 · 移除之后：空着的上层", "21 · A double exposure · after Remove: an empty Top"),
                   [cap("移除把这一层留空（照片仍在图库中），一步撤销。只剩一次曝光时没有平衡可言：平衡一行收起，面板底部写明为什么不能导出；画面是剩下那次曝光按 −1 EV 冲洗的样子。",
                        "Remove leaves the layer empty (the photograph stays in the library), one step of Undo. With one exposure there is nothing to balance: the row goes, the panel’s foot says why it will not export, and the picture is the remaining exposure at its −1 EV."),
                    cap("行右端的 + 与下面的「添加曝光」是同一个动作。导出按钮仍可按：按下去得到的是 25 的那句话。", "The row’s + and Add Exposure below are one action. Export still takes a press: it answers with drawing 25.")],
                   "develop", col21, lambda p: canvas_double(p, empty="top"), strip_name=DOUBLE_NAME[LANG],
                   strip_status=T("developed") + " · " + T("one_exposure")))

    # --- 22 / 23: the way in from 图库 --------------------------------------------------------------------
    out.append(draw_library("22-combine-toolbar", cap("22 · 图库 · 合成 › 多重曝光（工具栏）", "22 · Library · Combine › Double Exposure (the bar)"),
                            [cap("图库选中一张或两张照片，工具栏的「合成」亮起：一份菜单，两行，各带一句解释；选中两张时第二行字写明谁是下层（先选的一张，R6）。",
                                 "With one or two photographs chosen, 合成 in the bar is live: one menu, two rows, each with a line of explanation. With two chosen, the line says which is the bottom (the one picked first, R6)."),
                             cap("两张：直接创建，作品落在图库这一行并被选中。一张：打开选择器（24）。", "Two: it is made at once and lands as a row, chosen. One: the picker (24).")],
                            menu="toolbar"))
    out.append(draw_library("23-combine-context", cap("23 · 图库 · 右键菜单里的「合成」", "23 · Library · 合成 in the photograph’s menu"),
                            [cap("照片的右键菜单里，「组成半格组」换成带标题的一段「合成」：多重曝光、半格，同一层，不进子菜单（R7）。",
                                 "In the photograph’s menu, Make Half-Frame Pair becomes a titled section, 合成: Double Exposure and Half-Frame Pair at the same level, no submenu (R7).")],
                            menu="context"))
    out.append(draw_picker("24-second-exposure-picker", cap("24 · 图库 · 选择第二次曝光", "24 · Library · choosing the second exposure"),
                           [cap("只选了一张时：一张表，列出图库里的照片；起头的那张标着「下层」，仍然可选（同一张叠两次是镜像多重曝光，创建时上层已水平翻转，R10）。",
                                "With one photograph chosen: a sheet of the library’s photographs. The one it began with is marked Bottom and can still be chosen (the same one twice is a mirror double; its top starts flipped, R10)."),
                            cap("单击选中，「创建」或双击确认，Esc 取消：创建之前可以反悔。", "A click picks, Create or a double-click confirms, Esc cancels: nothing is made until then.")],
                           replace=False, over="library"))

    # --- 25: the export refusal ---------------------------------------------------------------------------
    out.append(draw_refusal())

    # --- 26: Edit with a picture's row picked -------------------------------------------------------------
    def col26(d):
        y = column_top(d)
        y += layers_card(d, y, rows_double(0.6), sel=1, balance=0.6)
        y += edit_standdown(d, y)
        page_edit(d, y, open_first=False, op=DISABLED)
    out.append(std("26-edit-top-picked", cap("26 · 编辑 · 选中「上层」", "26 · Edit · Top picked"),
                   [cap("从冲洗换到编辑时选中的行不变。编辑（第二层）今天属于整张胶片，一次曝光没有自己的编辑：工具整体退下，一句话说明，一枚按钮选回「胶片」（↑ 也可以）。",
                        "The picked row survives the switch to Edit. Edit (Layer 2) is the whole film’s today and an exposure has none of its own: the tools stand down under one line, with one button back to Film (↑ does it too)."),
                    cap("眼睛与平衡在编辑里照常可用。2.4.x 的蒙版图层会在这里有自己的编辑。", "The eye and Balance work in Edit as in Develop. A 2.4.x mask layer will have its own edits here.")],
                   "edit", col26, lambda p: canvas_double(p, 0.6), strip_name=DOUBLE_NAME[LANG]))

    # --- 27: the future -----------------------------------------------------------------------------------
    out.append(draw_future())
    # --- 28 / 29: anatomy and the row's states -------------------------------------------------------------
    out.append(draw_anatomy())
    out.append(draw_states())
    return out


def draw_arrange():
    p = Page("18-double-arrange", cap("18 · 多重曝光 · 摆放上层（R5）", "18 · A double exposure · arranging Top (R5)"),
             [cap("摆放像裁剪一样在页面里进行：画面变成这一格，被摆放的那次曝光溢出画幅的部分淡淡地留在周围；另一次曝光按平衡的真实占比显示（R5），平衡就在面板里，可以一起调。",
                  "Arrange happens in the page, as Crop does: the picture becomes the frame, the placed exposure’s spill stays faint round it, and the other exposure shows at Balance’s real share (R5); Balance is right there in the panel."),
              cap("面板里点另一行就换成摆放那一层；「胶片」行退下。完成是一步撤销（位置与平衡一起），取消什么也不写。", "A click on the other row arranges that one; Film stands down. Done is one step of Undo (placement and Balance together); Cancel writes nothing.")])
    d = p.d
    toolbar(d, p.ww, "develop", crop_on=True, place=True)
    c = d.clip(0, HEAD, CW, p.wh - HEAD)
    d.open(clip=c)
    y = column_top(d)
    y += layers_card(d, y, rows_double(0.6), sel=1, balance=0.6, disabled=(0,), menu=False)
    h, cy = fold_header(d, y, T("arrange") + " · " + T("top"), rule=True)
    d.sym("chevron.right", 22, cy, 10, 700, BG)       # this header does not fold: no chevron
    d.rect(14, cy - 8, 16, 16, BG)
    d.sym("arrow.up.left.and.arrow.down.right", 22, cy, 11, 600, TEXT)
    d.ctext(CW - 16, cy, T("covers") + " · 1.30×", 12, 500, DIM, "end")
    y += h
    lw = 64 if LANG == "zh" else 92
    y += slider(d, y, T("zoom"), 0.1, "1.30×", rest=None, label_w=lw) + 8
    x = 34
    x += chip(d, x, y + 14, T("turn90"), symbol="rotate.right") + 8
    x += chip(d, x, y + 14, T("flip_h"), symbol="arrow.left.and.right.righttriangle.left.righttriangle.right") + 8
    y += 28 + 8
    chip(d, 34, y + 14, T("reset"), symbol="arrow.counterclockwise")
    y += 28 + 12
    y += note(d, 34, y, wrap(T("arrange_note"), 11.5, 400, CW - 34 - 16)) + 16
    fold_rule(d, y)
    y += 14
    bw = (CW - 32 - 10) / 2
    capsule_button(d, 16, y + 18, T("cancel"), w=bw, h=36, size=14)
    capsule_button(d, 16 + bw + 10, y + 18, T("done"), w=bw, h=36, size=14, primary=True)
    d.close()
    wall(d, p.wh)
    # the stage
    x, y, w, h = canvas_box(p.ww, p.wh, 1.5, pad=112)
    zoom = 1.3
    zw, zh = w * zoom, h * zoom
    ox, oy = -w * 0.05, h * 0.04
    zx, zy = x - (zw - w) / 2 + ox, y - (zh - h) / 2 + oy
    stage = d.clip(CW + 1, HEAD, p.ww - CW - 1, p.wh - HEAD - STRIP)
    d.open(clip=stage)
    picture(d, "city", zx, zy, zw, zh, op=0.22)
    c2 = d.clip(x, y, w, h)
    d.open(clip=c2)
    d.rect(x, y, w, h, "#000")
    d.open(op=0.35 + 0.65 * min(0.4 / 0.5, 1))
    K.PICS["portrait"](d, x, y, w, h)
    d.close()
    d.open(op=min(0.25 + 0.6 * 1.1, 1), extra=' style="mix-blend-mode:screen"')
    K.PICS["city"](d, zx, zy, zw, zh)
    d.close()
    d.close()
    d.rect(x, y, w, h, None, stroke=SELFRAME, sw=1.5)
    d.rect(zx, zy, zw, zh, None, stroke=TEXT2, sw=1, dash="4 4", op=0.7)
    for hx, hy in ((zx, zy), (zx + zw, zy), (zx, zy + zh), (zx + zw, zy + zh)):
        d.rect(hx - 4, hy - 4, 8, 8, SELFRAME, r=1.5)
    d.close()
    info_strip(d, CW + 1, p.ww, p.wh, T("arrange") + " · " + T("top") + " · 1.30×", name=DOUBLE_NAME[LANG], exposure=None, accent_status=True)
    return p


GRID = ["hills", "city", "street", "portrait", "city", "hills", "portrait", "street", "hills", "street", "city", "portrait",
        "street", "hills", "city", "hills", "portrait", "street"]


def library_window(p, selected=(1, 3), combine=True, dim=False):
    """图库, schematically: the sidebar's tree and the grid (MacLibraryPage); only the bar's 合成 is new."""
    d = p.d
    toolbar(d, p.ww, "library", combine=combine)
    # the sidebar
    y = HEAD + 10
    for i, s_ in enumerate(("folder", "line.3.horizontal.decrease.circle", "info.circle")):
        if i == 0:
            d.rect(16 + i * 40 - 4, y - 2, 32, 26, CARD, r=6)
        d.sym(s_, 28 + i * 40, y + 11, 13, 500, TEXT if i == 0 else DIM)
    y += 40
    widths = [150, 92, 118, 104, 76, 132, 98]
    for i, wd in enumerate(widths):
        ry = y + i * 28
        if i == 1:
            d.rect(8, ry, CW - 16, 26, SEL, r=5)
        d.rect(30 + (14 if i in (2, 3) else 0), ry + 10, wd, 6, ONSEL if i == 1 else TEXT2, r=3, op=0.8 if i == 1 else 0.45)
        d.rect(CW - 46, ry + 10, 26, 6, ONSEL if i == 1 else DIM, r=3, op=0.6)
    wall(d, p.wh)
    # the grid
    gx0 = CW + 1
    d.rect(gx0, HEAD + 36.5, p.ww - gx0, 0.5, WALL)
    count = cap("18 张照片", "18 photos")
    d.ctext(gx0 + 16, HEAD + 18, count, 13, 600, TEXT)
    d.rect(p.ww - 196, HEAD + 6, 180, 24, CARD, r=12)
    d.sym("magnifyingglass", p.ww - 182, HEAD + 18, 11, 500, DIM)
    d.ctext(p.ww - 168, HEAD + 18, T("search"), 12.5, 500, DIM)
    cols = 6
    cell = (p.ww - gx0 - 16) / cols
    cells = []
    for i, kind in enumerate(GRID):
        r_, c_ = divmod(i, cols)
        cx, cy = gx0 + 8 + c_ * cell, HEAD + 46 + r_ * (cell * 0.86)
        cw, ch = cell - 8, cell * 0.86 - 8
        if i in selected:
            d.rect(cx, cy, cw, ch, CARD, r=4)
            d.rect(cx, cy, cw, ch, None, r=4, stroke=SELFRAME, sw=2)
        asp = 1.5 if kind != "portrait" else 0.72
        pw = min(cw - 14, (ch - 14) * asp)
        ph = pw / asp
        picture(d, kind, cx + (cw - pw) / 2, cy + (ch - ph) / 2, pw, ph)
        cells.append((cx, cy, cw, ch))
    info_strip(d, CW + 1, p.ww, p.wh, T("photos_selected") if len(selected) == 2 else "", name="" if len(selected) == 2 else "DSC_0412.NEF", exposure=None)
    return cells


def draw_library(name, title, notes, menu):
    p = Page(name, title, notes, ww=1180)
    d = p.d
    cells = library_window(p, combine="open" if menu == "toolbar" else True)
    if menu == "toolbar":
        items = [("title", T("combine")),
                 ("hi", T("double"), "square.2.layers.3d", T("order_double")),
                 ("on", T("pair_menu"), "rectangle.split.2x1", T("order_pair"))]
        w = 300
        menu_panel(d, d.combine_x - w, 57 + 20, w, items)
    else:
        cx, cy, cw, ch = cells[3]
        items = [("on", T("open_develop"), "slider.horizontal.3"),
                 ("on", T("light_table"), "rectangle.on.rectangle"), "-",
                 ("title", T("combine")),
                 ("hi", T("double"), "square.2.layers.3d", T("order_double")),
                 ("on", T("pair_menu"), "rectangle.split.2x1", T("order_pair")), "-",
                 ("on", T("info"), "info.circle"),
                 ("on", T("export_2"), "square.and.arrow.up"),
                 ("on", T("copy_settings"), "square.on.square")]
        menu_panel(d, cx + cw * 0.55, cy + ch * 0.55, 300, items)
    return p


def draw_picker(name, title, notes, replace, over):
    ww = 1180 if over == "library" else 1000
    p = Page(name, title, notes, ww=ww)
    d = p.d
    if over == "library":
        library_window(p, selected=(1,), combine=True)
    else:
        toolbar(d, p.ww, "develop")
        c = d.clip(0, HEAD, CW, p.wh - HEAD)
        d.open(clip=c)
        y = column_top(d)
        y += layers_card(d, y, rows_double(0.6), sel=1, balance=0.6)
        page_layer_double(d, y, "top")
        d.close()
        wall(d, p.wh)
        canvas_double(p, 0.6)
        info_strip(d, CW + 1, p.ww, p.wh, T("developed"), name=DOUBLE_NAME[LANG])
    d.rect(0, 0, p.ww, p.wh, "#000", op=0.62)
    sw, sh = 640, 476
    sx, sy = (p.ww - sw) / 2, (p.wh - sh) / 2 + 10
    d.rect(sx, sy, sw, sh, PLOT, r=14, stroke="#3d4149", sw=0.5)
    head = T("replace_top") if replace else T("double")
    sub = T("replace_sub") if replace else T("pick_second")
    d.text(sx + 24, sy + 36, head, 17, 700, TEXT)
    fits(sub, 12.5, 500, sw - 48 - 200, "the picker's line")
    d.text(sx + 24, sy + 56, sub, 12.5, 500, DIM)
    d.rect(sx + sw - 24 - 180, sy + 22, 180, 26, CARD, r=13)
    d.sym("magnifyingglass", sx + sw - 24 - 166, sy + 35, 11, 500, DIM)
    d.ctext(sx + sw - 24 - 152, sy + 35, T("search"), 12.5, 500, DIM)
    cols, gx, gy = 5, sx + 24, sy + 76
    cell = (sw - 48) / cols
    picked = 7
    for i, kind in enumerate(GRID[:15]):
        r_, c_ = divmod(i, cols)
        cx, cy = gx + c_ * cell, gy + r_ * (cell * 0.9)
        cw, ch = cell - 8, cell * 0.9 - 8
        if i == picked:
            d.rect(cx, cy, cw, ch, CARD, r=4)
            d.rect(cx, cy, cw, ch, None, r=4, stroke=SELFRAME, sw=2)
        asp = 1.5 if kind != "portrait" else 0.72
        pw = min(cw - 14, (ch - 14) * asp)
        ph = pw / asp
        px, py = cx + (cw - pw) / 2, cy + (ch - ph) / 2
        marked = (i == 1) if not replace else (i in (1, 3))
        picture(d, kind, px, py, pw, ph, op=0.55 if marked else 1)
        if marked:
            label = T("bottom") if (not replace or i == 3) else T("top")
            if not replace:
                label = T("bottom")
            tw_ = tw(label, 11.5, 600) + 14
            d.rect(px + 4, py + 4, tw_, 18, "#000", r=9, op=0.7)
            d.ctext(px + 4 + tw_ / 2, py + 13, label, 11.5, 600, TEXT, "middle")
    fy = sy + sh - 30
    foot = (T("same_mirrored") if not replace else "")
    if foot:
        d.sym("arrow.left.and.right.righttriangle.left.righttriangle.right", sx + 32, fy, 11, 500, DIM)
        line = cap("再选「下层」那一张：", "Choosing the Bottom again: ") + foot
        fits(line, 11.5, 400, sw - 48 - 220, "the picker's foot")
        d.ctext(sx + 46, fy, line, 11.5, 400, DIM)
    bw = 92
    capsule_button(d, sx + sw - 24 - bw, fy, T("replace") if replace else T("create"), w=bw, h=30, size=13.5, primary=True)
    capsule_button(d, sx + sw - 24 - bw - 10 - bw, fy, T("cancel"), w=bw, h=30, size=13.5)
    return p


def draw_refusal():
    p = Page("25-export-refusal", cap("25 · 导出被拒：空着一层的多重曝光", "25 · The export refused: a double exposure with an empty layer"),
             [cap("空着一层的多重曝光不导出（导出去会暗一档，R10）。事先就说了：面板底部那一行、状态栏的「一次曝光」。按下导出时不是一个按不动的按钮，而是这一句为什么，和一个去解决的默认按钮。",
                  "A double with an empty layer is not exported (exported, it would be one stop dark, R10). It is said beforehand: the panel’s foot, and “one exposure” in the status line. Pressing Export is not a dead button: it answers with why, and a default button that goes and fixes it."),
              cap("批量导出里遇到它：导出页的列表在这一张旁边写同一句话并跳过它，其余照常导出。", "In a batch, the export page’s list says the same sentence beside this one and skips it; the rest export.")])
    d = p.d
    toolbar(d, p.ww, "develop")
    c = d.clip(0, HEAD, CW, p.wh - HEAD)
    d.open(clip=c)
    y = column_top(d)
    y += layers_card(d, y, rows_double(0.6, empty="top"), sel=0, foot=[T("fill_double")])
    page_format_double(d, y)
    d.close()
    wall(d, p.wh)
    canvas_double(p, empty="top")
    info_strip(d, CW + 1, p.ww, p.wh, T("developed") + " · " + T("one_exposure"), name=DOUBLE_NAME[LANG])
    d.rect(0, 0, p.ww, p.wh, "#000", op=0.45)
    aw, ah = 320, 214
    ax, ay = (p.ww - aw) / 2, (p.wh - ah) / 2 - 20
    d.rect(ax, ay, aw, ah, "#2A2D33", r=16, stroke="#4a4e57", sw=0.5)
    d.sym("square.2.layers.3d", ax + aw / 2, ay + 38, 26, 500, ACCENT)
    fits(T("cant_export"), 14, 700, aw - 32, "the alert's title")
    d.text(ax + aw / 2, ay + 78, T("cant_export"), 14, 700, TEXT, "middle")
    for i, ln in enumerate(wrap(T("fill_double"), 12, 400, aw - 40)):
        d.text(ax + aw / 2, ay + 100 + i * 17, ln, 12, 400, TEXT2, "middle")
    capsule_button(d, ax + 16, ay + 148, T("add_exposure") + "…", w=aw - 32, h=30, size=13.5, primary=True)
    capsule_button(d, ax + 16, ay + 184, T("ok"), w=aw - 32, h=30, size=13.5)
    return p


def draw_future():
    p = Page("27-future-masks", cap("27 · 以后：蒙版进来时放在哪里（本次不做）", "27 · Later: where masks go when they come (not in this release)"),
             [cap("虚线框里的都不在 2.4.0：主体 / 背景 / 人、画笔与渐变、修复与仿制、橡皮、不透明度、组合蒙版、完善遮罩。面板为它们留了三个位置，今天这些位置是空的或只放了平衡，所以到时候不用重画。",
                  "Nothing in a dashed box is in 2.4.0: Subject / Background / People, brushes and gradients, heal and clone, erasers, Opacity, Combine Masks, Refine Mask. The panel keeps three places for them, empty today or holding Balance, so nothing is redrawn then."),
              cap("① 标题行右侧：+（新建图层）与 −。② 标题与列表之间：选择与工具两行。③ 列表之下：这一层的不透明度（今天多重曝光的平衡就在这里），再下是两枚按钮。蒙版行排在照片行之下，每行都有眼睛。",
                  "① The head’s trailing side: + (a new layer) and −. ② Between the head and the list: the selection row and the tool row. ③ Under the list: the layer’s Opacity (where a double’s Balance is today), then two buttons. Mask rows go under the picture rows, each with its eye.")])
    d = p.d
    toolbar(d, p.ww, "edit")
    c = d.clip(0, HEAD, CW, p.wh - HEAD)
    d.open(clip=c)
    y = column_top(d)
    top = y
    H = L_HEAD + 36 + 36 + L_ROW * 4 + L_ROWPAD + 44.5 + 40
    d.rect(L_INSET, y, CW - 2 * L_INSET, H, PLOT, r=12)
    cy = y + 16
    d.sym("chevron.down", L_INSET + 20.5, cy, 10, 600, TEXT2)
    d.ctext(L_INSET + 34, cy, T("layers"), 13, 600, TEXT)
    small_round(d, CW - L_INSET - 21, cy, "ellipsis", pt=11, weight=700)
    fut = []          # the future's boxes, drawn dashed afterwards
    small_round(d, CW - L_INSET - 21 - 28, cy, "minus", pt=11, weight=700)
    small_round(d, CW - L_INSET - 21 - 56, cy, "plus", pt=11, weight=700)
    fut.append((CW - L_INSET - 21 - 56 - 15, cy - 15, 58, 30, "①"))
    y += L_HEAD
    # the selection row
    x = L_INSET + 14
    bw = (CW - 2 * L_INSET - 28 - 16) / 3
    for k, s_ in (("subject", "person.crop.rectangle"), ("background", "photo"), ("people", "person.fill")):
        d.rect(x, y + 4, bw, 28, CARD, r=7)
        lw_ = tw(T(k), 12.5, 500)
        d.sym(s_, x + bw / 2 - lw_ / 2 - 9, y + 18, 11, 500, TEXT2)
        d.ctext(x + bw / 2 + 7, y + 18, T(k), 12.5, 500, TEXT2, "middle")
        x += bw + 8
    y += 36
    tools = ["paintbrush.pointed", "wand.and.stars", "rectangle.righthalf.inset.filled", "circle.dotted", None, "bandage", "seal", None, "eraser"]
    x = CW - L_INSET - 14 - 11
    for s_ in reversed(tools):
        if s_ is None:
            d.rect(x + 4, y + 8, 0.5, 20, RULE)
            x -= 12
            continue
        d.sym(s_, x, y + 18, 13, 500, TEXT2)
        x -= 30
    fut.append((L_INSET + 8, y - 36 + 1, CW - 2 * L_INSET - 16, 70, "②"))
    y += 36
    rows = rows_double(0.6)
    for r_ in rows:
        r_.pop("trail", None)
    rows += [dict(name=T("mask_sky"), kind="mask", eye="on"), ]
    yy = y
    for i, r_ in enumerate(rows):
        if r_["kind"] == "mask":
            cyr = yy + 15
            d.sym("eye", EYE_CX, cyr, 11, 500, TEXT2, op=0.75)
            d.rect(THUMB_X, cyr - 10, THUMB_W, THUMB_H, "#0b0c0e", r=3)
            d.rect(THUMB_X, cyr - 10, THUMB_W, 9, "#e9e7e2", r=3)
            d.ctext(NAME_X, cyr, r_["name"], 13, 500, TEXT)
            fut.append((ROW_X + 2, yy + 1, CW - 2 * ROW_X - 4, L_ROW - 2, None))
        else:
            layer_row(d, yy, r_, "selected" if i == 0 else "rest")
        yy += L_ROW
    y = yy + L_ROWPAD
    d.rect(L_INSET + 14, y, CW - 2 * L_INSET - 28, 0.5, RULE)
    lw = tw(T("opacity"), 13.5, 600) + 2
    slider(d, y + 0.5, T("opacity"), 1.0, "100", rest=None, x0=L_INSET + 14, x1=CW - L_INSET - 14, label_w=lw, field_w=62)
    y += 44.5
    bw = (CW - 2 * L_INSET - 28 - 8) / 2
    for i, k in enumerate(("combine_masks", "refine_mask")):
        bx = L_INSET + 14 + i * (bw + 8)
        d.rect(bx, y + 2, bw, 28, CARD, r=7)
        d.ctext(bx + bw / 2, y + 16, T(k), 12.5, 500, TEXT2, "middle")
    fut.append((L_INSET + 8, y - 44.5 + 3, CW - 2 * L_INSET - 16, 44.5 + 34, "③"))
    y += 40 + L_GAP
    page_edit(d, y, open_first=False)
    d.close()
    for fx, fy, fw, fh, mark in fut:
        d.rect(fx, fy, fw, fh, None, r=7, stroke=ACCENT, sw=1, dash="4 3")
        if mark:
            d.circle(fx + fw - 2, fy + 2, 8, ACCENT)
            d.text(fx + fw - 2, fy + 6, mark, 11.5, 700, ONSEL, "middle")
    wall(d, p.wh)
    x, yy, w, h = canvas_box(p.ww, p.wh, 1.5)
    double_picture(d, x, yy, w, h, share=0.6)
    tagw = tw(T("not_shipping"), 13, 700) + 28
    d.rect(x + w / 2 - tagw / 2, yy + 14, tagw, 28, ACCENT, r=14)
    d.ctext(x + w / 2, yy + 28, T("not_shipping"), 13, 700, ONSEL, "middle")
    info_strip(d, CW + 1, p.ww, p.wh, T("developed"), name=DOUBLE_NAME[LANG])
    return p


def sheet(name, title, note_text, W_, H_):
    """A measured sheet (not a window): its ground, and its caption wrapped under it."""
    lines = wrap(note_text, 11.5, 400, W_)
    d = Drawing(W_ + 2 * M, H_ + 2 * M + 30 + 16 * len(lines) + 10)
    d.text(M, H_ + 2 * M + 14, title, 14, 600, TEXT)
    for i, ln in enumerate(lines):
        d.text(M, H_ + 2 * M + 34 + i * 16, ln, 11.5, 400, DIM)
    d.text(W_ + M, H_ + 2 * M + 14, name, 11.5, 500, FAINT, "end")
    d.rect(M, M, W_, H_, BG, r=10)
    return d


def dim_h(d, x0, x1, y, label, above=True, color="#7fb6ff"):
    d.line(x0, y, x1, y, color, 0.75)
    d.line(x0, y - 3, x0, y + 3, color, 0.75)
    d.line(x1, y - 3, x1, y + 3, color, 0.75)
    d.text((x0 + x1) / 2, y - 4 if above else y + 11, label, 9.5, 600, color, "middle")


def dim_v(d, x, y0, y1, label, right=True, color="#7fb6ff"):
    d.line(x, y0, x, y1, color, 0.75)
    d.line(x - 3, y0, x + 3, y0, color, 0.75)
    d.line(x - 3, y1, x + 3, y1, color, 0.75)
    d.text(x + 5 if right else x - 5, (y0 + y1) / 2 + 3.3, label, 9.5, 600, color, "start" if right else "end")


def draw_anatomy():
    """The panel alone at 2x, with its measurements (units = scene points)."""
    sc = 2
    W_, H_ = CW * sc + 330, 620
    d = sheet("28-anatomy",
              cap("28 · 面板的构造与尺寸（2×；单位 = 冲洗页的点，100 % 界面下 1 = 0.9625 Mac 点）",
                  "28 · The panel’s anatomy and measurements (2x; one unit = a develop-page point, 0.9625 Mac pt at 100 %)"),
              cap("卡片与直方图同一个壳：Theme.plot、圆角 12、距栏边 12。行高 30（28.9 Mac 点，HIG 中号侧栏行 28）；新增文字不小于 11.5（11.07 Mac 点），唯一更小的是 ValueSlider 自带的 10.5 副标签。",
                  "The card is the histogram’s shell: Theme.plot, radius 12, 12 from the column’s sides. A row is 30 (28.9 Mac pt; the HIG’s medium sidebar row is 28); new type is never under 11.5 (11.07 Mac pt), and the one smaller line is ValueSlider’s own 10.5 sub-label."),
              W_, H_)
    ox, oy = M + 40, M + 56
    d.add(f'<g transform="translate({ox},{oy}) scale({sc})">')
    d.rect(0, -8, CW, 200, BG)
    d.rect(CW, -8, 1, 200, WALL)
    h = layers_card(d, 0, rows_double(0.6), sel=1, balance=0.6)
    d.add("</g>")
    B = "#7fb6ff"
    X = lambda v: ox + v * sc
    Y = lambda v: oy + v * sc
    dim_h(d, X(0), X(L_INSET), Y(-4) - 12, "12")
    dim_h(d, X(L_INSET), X(CW - L_INSET), Y(-4) - 30, "369 (393 − 2 × 12)")
    dim_h(d, X(CW - L_INSET), X(CW), Y(-4) - 12, "12")
    rx = X(CW) + 16
    dim_v(d, rx, Y(0), Y(L_HEAD), cap("标题 32", "head 32"))
    dim_v(d, rx, Y(L_HEAD), Y(L_HEAD + L_ROW), cap("行 30（选中胶囊 28，圆角 6）", "row 30 (capsule 28, radius 6)"))
    dim_v(d, rx, Y(L_HEAD + L_ROW), Y(L_HEAD + 2 * L_ROW), "30")
    dim_v(d, rx, Y(L_HEAD + 2 * L_ROW), Y(L_HEAD + 3 * L_ROW), "30")
    dim_v(d, rx, Y(L_HEAD + 3 * L_ROW), Y(L_HEAD + 3 * L_ROW + L_ROWPAD), "6")
    dim_v(d, rx, Y(L_HEAD + 3 * L_ROW + L_ROWPAD + 0.5), Y(L_HEAD + 3 * L_ROW + L_ROWPAD + 40.5), cap("平衡 40（ValueSlider）", "Balance 40 (ValueSlider)"))
    dim_v(d, rx, Y(h - L_GAP - 4), Y(h - L_GAP), "4")
    dim_v(d, rx + 150, Y(0), Y(h - L_GAP), cap(f"多重曝光 {h - L_GAP:g}", f"a double {h - L_GAP:g}"))
    dim_v(d, rx + 150, Y(h - L_GAP), Y(h), cap("下方 6", "6 under"))
    by = Y(h) + 26
    dim_h(d, X(L_INSET), X(ROW_X), by, "6", above=False)
    dim_h(d, X(ROW_X + 4), X(ROW_X + 24), by, cap("眼睛 20", "eye 20"), above=False)
    dim_h(d, X(THUMB_X), X(THUMB_X + THUMB_W), by, cap("缩略图 30 × 20", "thumb 30 × 20"), above=False)
    dim_h(d, X(THUMB_X + THUMB_W), X(NAME_X), by + 22, "8", above=False)
    dim_h(d, X(TRAIL_X), X(CW - L_INSET - L_ROWPAD), by, "10", above=False)
    dim_h(d, X(CW - L_INSET - L_ROWPAD), X(CW - L_INSET), by + 22, "6", above=False)
    ly = by + 70
    lines = [
        cap("标题：chevron.down 10 semibold（收起时转 −90°）· 「图层」13 semibold · ⋯ 为 22 的圆钮（距卡片右缘 10）",
            "Head: chevron.down 10 semibold (turned −90° folded) · the title 13 semibold · ⋯ a 22 disc, 10 from the card’s edge"),
        cap("行：眼睛 eye 11 medium · 缩略图按比例放进 30 × 20、圆角 3 · 名称 13 medium（选中 semibold）· 右端 12 medium 等宽数字",
            "Row: eye 11 medium · the thumbnail fitted in 30 × 20, radius 3 · the name 13 medium (semibold picked) · the trailing value 12 medium, tabular"),
        cap("「胶片」行：缩略图位置是 SF Symbol film 13；没有眼睛。半格组的行没有眼睛，位置空着留给以后。",
            "The Film row: SF Symbol film 13 in the thumbnail’s place, and no eye. A pair’s rows have no eye; the slot stays for later."),
        cap("高度：收起或单张 32 · 半格组 128 · 多重曝光 172.5 · 空着一层时去掉平衡、加一行说明（+28.3）。面板下方 6，面板上方即直方图下方的 6。",
            "Heights: folded or a single frame 32 · a pair 128 · a double 172.5 · with an empty layer Balance goes and one line of note comes (+28.3). 6 under it; above it, the histogram’s own 6."),
    ]
    for i, ln in enumerate(lines):
        d.text(M + 40, ly + i * 19, ln, 11.5, 400, TEXT2)
    return ("28-anatomy", d)


def draw_states():
    """Every state a row has, 2x."""
    sc = 2
    W_, H_ = CW * sc + 330, 30 + 12 * (L_ROW * sc + 12) + 18
    d = sheet("29-row-states", cap("29 · 行的各种状态（2×）", "29 · A row’s states (2x)"),
              cap("选中是白色胶囊（Theme.selection），不是强调色；强调色只用于状态：亮起的眼睛。退下的一行整体 0.38。",
                  "Selection is the white capsule (Theme.selection), never the accent; the accent is for state only: the lit eye. A row that stands down is 0.38 as a whole."),
              W_, H_)
    ox, oy = M + 40, M + 30
    top = dict(name=T("top"), kind="pic", thumb=thumb_of("city"), aspect=1.5, trail="60 %", eye="on")
    bot = dict(name=T("bottom"), kind="pic", thumb=thumb_of("portrait"), aspect=1.5, trail="40 %", eye="on")
    cases = [
        (dict(top), "rest", cap("静止", "At rest")),
        (dict(top), "hover", cap("指针悬停：Theme.card 50 %", "Pointer over it: Theme.card at 50 %")),
        (dict(top), "selected", cap("选中：白色胶囊、深色字", "Picked: the white capsule, dark ink")),
        (dict(top, eye="alone"), "rest", cap("单独查看：眼睛亮起（强调色底、深色字形）", "Shown alone: the eye lit (accent ground, dark glyph)")),
        (dict(top, eye="alone"), "selected", cap("选中并单独查看", "Picked and shown alone")),
        (dict(bot, eye="out"), "rest", cap("另一层被单独查看：眼睛划掉，行变暗", "The other is shown alone: the eye struck, the row dimmed")),
        (dict(bot, eye="out"), "selected", cap("同上，且被选中：保持可读", "The same, picked: it stays readable")),
        (dict(name=T("top"), kind="empty"), "rest", cap("空：虚线框、「空」、右端 + 添加", "Empty: a dashed box, Empty, + to add")),
        (dict(name=T("top"), kind="empty"), "selected", cap("空，被选中", "Empty, picked")),
        (dict(name=T("film"), kind="film"), "disabled", cap("退下（摆放时的「胶片」）：0.38，不接受点击", "Standing down (Film while arranging): 0.38, takes no click")),
        (dict(name=T("film"), kind="film"), "selected", cap("「胶片」，被选中", "Film, picked")),
        (dict(name=T("left"), kind="pic", thumb=thumb_of("hills"), aspect=0.75), "rest", cap("半格组的一格：没有眼睛，没有占比", "A pair’s frame: no eye, no share")),
    ]
    for i, (row, state, label) in enumerate(cases):
        y = oy + i * (L_ROW * sc + 12)
        d.add(f'<g transform="translate({ox},{y}) scale({sc})">')
        d.rect(L_INSET, 0, CW - 2 * L_INSET, L_ROW, PLOT)
        layer_row(d, 0, row, state)
        d.add("</g>")
        d.text(ox + CW * sc + 6, y + L_ROW * sc / 2 + 4, label, 12, 500, TEXT2)
    return ("29-row-states", d)


# ---------------------------------------------------------------------------------------------------------

EN_TOO = {"01-develop-unfolded", "02-develop-folded", "03-edit-unfolded", "05-single-frame", "06-pair-level-film",
          "07-pair-level-left", "13-double-film-format", "14-double-top", "16-double-alone", "17-double-balance-drag",
          "18-double-arrange", "22-combine-toolbar", "24-second-exposure-picker", "25-export-refusal", "28-anatomy"}


def strings_table():
    rows = ["| key | zh-Hans | en | status |", "|---|---|---|---|"]
    for k, (zh, en, st) in S.items():
        rows.append(f"| `{k}` | {zh} | {en} | {st} |")
    return "\n".join(rows)


def main():
    global LANG
    if "--strings" in sys.argv:
        print(strings_table())
        return
    written = []
    for lang in ("zh", "en"):
        LANG = lang
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
