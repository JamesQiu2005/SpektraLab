#!/usr/bin/env python3
"""Half-frame pair v2 drawings (design scratch; not part of the product).

Desktop chrome comes from SpektraLab_mobile/design/src (gen.py / gen_overscan.py), the same parts the
Film Edge proposal used: Theme.swift tokens, 1920 x 1080 pt, rails 254 / 288, bar 38, filmstrip 132.
Pictures are engine renders of the owner's frames through filmify's own dylib (render_pair.py):
Kodak Gold 200 on Supra Endura, grain at half-frame scale; the gap is a render of unexposed film.
"""
import base64, os, sys
SRC = "/Volumes/Hanze_Qiu/Documents/Summer 2026/SpektraLab_mobile/design/src"
sys.path.insert(0, SRC)
from gen import t, latitude_hist, TEXT, TEXT2, DIM, ACCENT, SEL, ONSEL, SELFRAME, CARD, RULE, PLOT, FONT  # noqa
from gen_overscan import (d_slider, d_seg, d_button, l_section, l_label, l_pill, l_seg, l_sub, l_check,
                          l_label_at, l_turn_icons, GROUND, WELL, FIELD, DISABLED, DW, DH, LR, RR, BAR, STRIP,
                          RX0, CX0, CX1, CY0, CY1, LX, LW, CTL)

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.join(HERE, "img")
OUT = sys.argv[1]
PANEL = "#141413"
_cache = {}


def b64(path):
    if path not in _cache:
        with open(path, "rb") as f:
            _cache[path] = base64.b64encode(f.read()).decode()
    return _cache[path]


_defs = {}


def _size(path):
    import subprocess
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path], capture_output=True, text=True).stdout
    nums = [int(l.split()[-1]) for l in out.splitlines() if "pixel" in l]
    return nums[0], nums[1]


def im(x, y, w, h, name, slice_=True, extra=""):
    """Each picture is embedded once per file, as a symbol; every use scales it."""
    p = os.path.join(IMG, name) if not name.startswith("thumbs/") else os.path.join(SRC, name)
    key = (name, slice_)
    if key not in _defs:
        pw, ph = _size(p)
        sid = f"p{len(_defs)}"
        par = "xMidYMid slice" if slice_ else "none"
        _defs[key] = (sid, f'<symbol id="{sid}" viewBox="0 0 {pw} {ph}" preserveAspectRatio="{par}">'
                           f'<image width="{pw}" height="{ph}" xlink:href="data:image/jpeg;base64,{b64(p)}"/></symbol>')
    return f'<use xlink:href="#{_defs[key][0]}" x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" {extra}/>'


def flush_defs(svg):
    d = "<defs>" + "".join(v[1] for v in _defs.values()) + "</defs>"
    _defs.clear()
    return svg.replace("</svg>", d + "</svg>", 1) if svg.rstrip().endswith("</svg>") else svg


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ---------------------------------------------------------------------------------------------
# The pair's geometry on the canvas: the piece of film is the canvas; it never moves for a photo.
# 18 x 24 mm holes, 1.0 mm between them: 37 x 24 mm.
# ---------------------------------------------------------------------------------------------
PH = 700
HW, GAP = PH * 18 / 24, PH * 1.0 / 24
PW = 2 * HW + GAP
PX = CX0 + (CX1 - CX0 - PW) / 2
PY = CY0 + 64
LXH, RXH = PX, PX + HW + GAP
LEFT_NAME, RIGHT_NAME = "_DSC35210-6", "snow.tif"


def piece(left, right, gap, sel=None, dim_left=False):
    """left/right: slot image names or None (empty hole); gap: the overscan render."""
    o = []
    # an empty hole is unexposed film: the same render as the gap, at the hole's size
    o.append(im(LXH, PY, HW, PH, left or gap, slice_=bool(left)))
    o.append(im(LXH + HW, PY, GAP, PH, gap, slice_=False))
    o.append(im(RXH, PY, HW, PH, right or gap, slice_=bool(right)))
    if dim_left:
        o.append(f'<rect x="{LXH}" y="{PY}" width="{HW}" height="{PH}" fill="{GROUND}" opacity="0.62"/>')
    if sel == "R":
        o.append(f'<rect x="{RXH-2}" y="{PY-2}" width="{HW+4}" height="{PH+4}" fill="none" stroke="{SELFRAME}" stroke-width="2"/>')
    elif sel == "L":
        o.append(f'<rect x="{LXH-2}" y="{PY-2}" width="{HW+4}" height="{PH+4}" fill="none" stroke="{SELFRAME}" stroke-width="2"/>')
    elif sel == "F":
        o.append(f'<rect x="{PX-2}" y="{PY-2}" width="{PW+4}" height="{PH+4}" fill="none" stroke="{SELFRAME}" stroke-width="2"/>')
    return "".join(o)


def add_hole(x):
    """The empty hole's call to action, centred in it."""
    cx, cy = x + HW / 2, PY + PH / 2
    return (f'<rect x="{cx-62}" y="{cy-16}" width="124" height="32" rx="16" fill="{SEL}"/>'
            f'<path d="M{cx-40} {cy} h11 M{cx-34.5} {cy-5.5} v11" stroke="{ONSEL}" stroke-width="1.8" stroke-linecap="round"/>'
            + t(cx + 8, cy + 4.8, "Add Frame", 13, ONSEL, 600, "middle")
            + t(cx, cy + 40, "or drag a frame from the filmstrip here", 11.5, TEXT2, 500, "middle")
            + t(cx, cy + 56, "18 × 24 mm  ·  unexposed film", 10.5, DIM, 500, "middle"))


def status(line, size, u=1.0):
    y = PY + PH
    o = [f'<rect x="{PX:.1f}" y="{y+6:.1f}" width="{PW:.1f}" height="2" fill="#000" opacity="0.35"/>',
         f'<rect x="{PX:.1f}" y="{y+6:.1f}" width="{PW*u:.1f}" height="2" fill="{ACCENT}"/>' if u < 1 else "",
         f'<circle cx="{PX+6:.1f}" cy="{y+25:.1f}" r="3.5" fill="{ACCENT if u < 1 else TEXT2}"/>',
         t(PX + 16, y + 29, line, 11.5, TEXT2, 500), t(PX + PW, y + 29, size, 11, DIM, 500, "end")]
    return "".join(o)


# ---------------------------------------------------------------------------------------------
# chrome
# ---------------------------------------------------------------------------------------------
def svg_open(title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{DW}" height="{DH}" '
            f'viewBox="0 0 {DW} {DH}">\n<title>{esc(title)}</title>\n<rect width="{DW}" height="{DH}" fill="{CARD}"/>')


def topbar(title, crop=False):
    o = [f'<rect x="{CX0}" y="0" width="{CX1-CX0}" height="{BAR}" fill="{CARD}"/>',
         f'<line x1="{CX0}" y1="{BAR}" x2="{CX1}" y2="{BAR}" stroke="{RULE}"/>',
         f'<rect x="{CX0+18}" y="13" width="15" height="12" rx="2" stroke="{TEXT}" stroke-width="1.2" fill="none"/>'
         f'<line x1="{CX0+23}" y1="13" x2="{CX0+23}" y2="25" stroke="{TEXT}" stroke-width="1.2"/>']
    tx = CX0 + 150
    o.append(f'<path d="M{tx-4} 12 l9 9 h-4 l2 5 l-2 1 l-2 -5 l-3 3 Z" fill="{TEXT}"/>')
    if crop:
        o.append(f'<rect x="{tx+15}" y="6" width="32" height="26" rx="6" fill="{ACCENT}" fill-opacity="0.16"/>')
    o.append(f'<path d="M{tx+26} 11 v13 h13 M{tx+22} 15 h13 v13" stroke="{ACCENT if crop else TEXT}" stroke-width="1.3" fill="none"/>')
    px = CX0 + 400
    o.append(f'<rect x="{px}" y="9" width="66" height="20" rx="10" fill="none" stroke="{ACCENT}" stroke-width="1.2"/>'
             + t(px + 33, 23, "Process", 12, ACCENT, 600, "middle"))
    o.append(f'<rect x="{px+72}" y="9" width="66" height="20" rx="10" fill="none" stroke="{RULE}" stroke-width="1.2"/>'
             + t(px + 105, 23, "Original", 12, DIM, 500, "middle"))
    o.append(t(px + 152, 23, title, 11, DIM, 500))
    o.append(f'<rect x="{CX1-118}" y="10" width="44" height="18" rx="9" fill="{FIELD}"/>' + t(CX1 - 96, 23, "Fit", 11, TEXT, 600, "middle"))
    o.append(f'<circle cx="{CX1-52}" cy="18" r="5.5" stroke="{TEXT}" stroke-width="1.3" fill="none"/><path d="M{CX1-48} 22 l4 4" stroke="{TEXT}" stroke-width="1.3"/>')
    o.append(f'<rect x="{CX1-30}" y="12" width="15" height="12" rx="2" stroke="{TEXT}" stroke-width="1.2" fill="none"/>'
             f'<line x1="{CX1-20}" y1="12" x2="{CX1-20}" y2="24" stroke="{TEXT}" stroke-width="1.2"/>')
    return "".join(o)


def hdr_icons(xr, cy):
    """The section header's reset and more glyphs, as the running app draws them."""
    return (f'<path d="M{xr-31} {cy+1} a4 4 0 1 0 1.2 -3.2" stroke="{DIM}" stroke-width="1.1" fill="none"/>'
            f'<path d="M{xr-30.6} {cy-5} v3.2 h3.2" stroke="{DIM}" stroke-width="1.1" fill="none"/>'
            + "".join(f'<circle cx="{xr-10+i*4}" cy="{cy}" r="1.1" fill="{DIM}"/>' for i in range(3)))


def section(y, title, value=None, open_=False, check=None, icons=True, x0=0, x1=LR):
    """A rail section's header (both rails): disclosure, title, the folded value, reset/more."""
    o = [f'<line x1="{x0}" y1="{y}" x2="{x1}" y2="{y}" stroke="{RULE}"/>']
    cy = y + 19
    o.append(f'<path d="M{x0+12} {cy-5} l8 0 l-4 6 Z" fill="{TEXT}"/>' if open_ else f'<path d="M{x0+13} {cy-7} l6 4 l-6 4 Z" fill="{TEXT}"/>')
    o.append(t(x0 + 26, cy + 4.5, title, 13, TEXT, 600))
    right = x1 - 14
    if check is not None:
        o.append(l_check(x1 - 25, cy - 5.5, check))
        right = x1 - 34
    elif icons and open_:
        o.append(hdr_icons(x1 - 6, cy))
        right = x1 - 44
    if value:
        o.append(t(right, cy + 4, value, 10.5, DIM, 500, "end"))
    return "".join(o), y + 36


def scope_row(x, y, w, sel):
    """The exposure scope: does this section's exposure edit touch only the picture, or the overscan too."""
    return (t(x, y + 4, "Applies to", 11.5, TEXT, 500)
            + l_seg(x + 88, y, ["Frame", "+ Overscan"], sel, (w - 88) / 2)
            + t(x + 88, y + 20, "⌥-drag flips it for one drag", 9.5, DIM, 500))


def thumb_cell(x, y, w, h, name):
    return im(x, y, w, h, name)


def film_glyph(x, y, ink=TEXT):
    """A piece of film with two holes: the Film layer's glyph."""
    return (f'<rect x="{x}" y="{y}" width="22" height="16" rx="2" fill="none" stroke="{ink}" stroke-width="1.2"/>'
            f'<rect x="{x+3}" y="{y+3}" width="7.3" height="10" fill="{ink}" opacity="0.55"/>'
            f'<rect x="{x+11.7}" y="{y+3}" width="7.3" height="10" fill="{ink}" opacity="0.55"/>')


def layers(y, selected, left, right):
    """The Half-Frame Pair section: the film and its two holes, one selected at a time."""
    h, y = section(y, "Half-Frame Pair", None, open_=True)
    o = [h]
    rows = [("F", "Film", "Kodak Gold 200", None),
            ("L", "Left hole", LEFT_NAME if left else "Empty", left),
            ("R", "Right hole", RIGHT_NAME if right else "Empty", right)]
    y += 2
    for key, name, detail, pic in rows:
        on = key == selected
        if on:
            o.append(f'<rect x="10" y="{y}" width="{LR-20}" height="28" rx="14" fill="{SEL}"/>')
        ink, sub = (ONSEL, "#3a3a38") if on else (TEXT, DIM)
        if key == "F":
            o.append(film_glyph(20, y + 6, ink))
        elif pic:
            o.append(im(24, y + 4, 15, 20, pic))
        else:
            o.append(f'<rect x="24.5" y="{y+4.5}" width="14" height="19" rx="1.5" fill="none" stroke="{sub}" stroke-dasharray="2 2"/>'
                     f'<path d="M28 {y+14} h7 M31.5 {y+10.5} v7" stroke="{sub}" stroke-width="1.1"/>')
        o.append(t(50, y + 18.5, name, 12, ink, 600))
        o.append(t(LR - 22, y + 18.5, detail, 10.5, sub, 500, "end"))
        y += 30
    y += 4
    o.append(t(LX, y + 8, "Click a hole to pick it; the gap picks the film.", 9.5, DIM, 500))
    return "".join(o), y + 22


def navigator(y, left, right, gap):
    o = [f'<rect x="10" y="{y}" width="{LR-20}" height="150" rx="4" fill="{WELL}"/>']
    ph = 104
    hw, g = ph * 18 / 24, ph / 24
    x = LR / 2 - (2 * hw + g) / 2
    yy = y + 23
    o.append(im(x, yy, hw, ph, left or gap, slice_=bool(left)))
    o.append(im(x + hw, yy, g, ph, gap, slice_=False))
    o.append(im(x + hw + g, yy, hw, ph, right or gap, slice_=bool(right)))
    return "".join(o)


def left_head():
    return (f'<rect x="0" y="0" width="{LR}" height="{DH}" fill="{CARD}"/>' + t(LR / 2, 24, "Film and Print", 13, TEXT, 600, "middle")
            + f'<line x1="0" y1="{BAR}" x2="{LR}" y2="{BAR}" stroke="{RULE}"/>')


def left_close(y):
    return (f'<line x1="0" y1="{y}" x2="{LR}" y2="{y}" stroke="{RULE}"/>'
            f'<line x1="{LR}" y1="0" x2="{LR}" y2="{DH}" stroke="{RULE}"/>')


def enlarger_body(y, scope, bright, bright_u):
    o = []
    y += 6
    o.append(scope_row(LX, y, LW, scope))
    y += 40
    o.append(d_slider(LX, y, "Brightness", bright, bright_u, sub="stops", w=LW))
    y += 34
    o.append(d_slider(LX, y, "Yellow", "+0.00", 0.5, sub="← blue", w=LW, tint="#c9b24e"))
    y += 34
    o.append(d_slider(LX, y, "Magenta", "+0.00", 0.5, sub="← green", w=LW, tint="#a77fb0"))
    y += 34
    o.append(d_slider(LX, y, "Pre-flash", "0.00", 0.0, sub="×100", w=LW))
    y += 30
    return "".join(o), y


def left_rail_hole(left, right, gap, sel, scope="Frame", bright="+0.40", bright_u=0.57, crop_open=False):
    o = [left_head(), navigator(BAR + 6, left, right, gap)]
    y = BAR + 166
    b, y = layers(y, sel, left, right)
    o.append(b)
    if (sel == "R" and not right) or (sel == "L" and not left):
        g = [f'<g opacity="{DISABLED}">']
        for title, value in (("Film", "Kodak Gold 200 · set by pair"), ("Print", "—"), ("Crop", "—"), ("Enlarger", "—")):
            h, y = section(y, title, value)
            g.append(h)
        g.append('</g>')
        o += g
        o.append(t(LX, y + 22, "Add a frame to this hole to develop it.", 10.5, DIM, 500))
        o.append(left_close(y))
        return "".join(o)
    h, y = section(y, "Film", "Kodak Gold 200 · set by pair")
    o.append(h)
    h, y = section(y, "Print", "Supra Endura")
    o.append(h)
    if crop_open:
        h, y = section(y, "Crop", None, open_=True)
        o.append(h)
        y += 6
        o.append(l_label(y, "Hole") + t(CTL, y + 4, "18 × 24 mm  ·  3:4", 11, TEXT, 600))
        y += 26
        o.append(d_slider(LX, y, "Scale", "1.18×", 0.18, sub="1.00× fills the hole", w=LW))
        y += 34
        o.append(d_slider(LX, y, "Straighten", "0.0°", 0.5, sub="degrees", w=LW))
        y += 32
        o.append(l_label(y, "Rotate") + l_turn_icons(CTL, y))
        o.append(f'<rect x="{CTL+48}" y="{y-8}" width="20" height="16" rx="4" fill="{FIELD}"/>'
                 f'<path d="M{CTL+58} {y-5} v10 M{CTL+53} {y-3} l-2.5 3 2.5 3 M{CTL+63} {y-3} l2.5 3 -2.5 3" stroke="{TEXT}" stroke-width="1.1" fill="none"/>')
        y += 24
        o.append(t(LX, y + 4, "1,355 × 1,807 of the frame’s 1,600 × 2,400 px", 10, DIM, 500))
        o.append(t(LX, y + 17, "fill the hole. Grain follows: 24 mm across it.", 10, DIM, 500))
        y += 34
        h, y = section(y, "Enlarger", bright + " · " + scope)
        o.append(h)
    else:
        h, y = section(y, "Crop", "Placement · 3:4")
        o.append(h)
        h, y = section(y, "Enlarger", None, open_=True)
        o.append(h)
        b, y = enlarger_body(y, scope, bright, bright_u)
        o.append(b)
    o.append(left_close(y))
    return "".join(o)


STOCKS = [("Positive", None), ("Fujifilm Provia 100F", ""), ("Fujifilm Velvia 100", ""), ("Kodak Ektachrome 100", ""),
          ("Kodak Kodachrome 64", ""), ("Negative", None), ("Fujifilm C200", ""), ("Fujifilm Pro 400H", ""),
          ("Fujifilm X-Tra 400", ""), ("Kodak Ektar 100", ""), ("Kodak Gold 200", "sel"), ("Kodak Portra 160", ""),
          ("Kodak Portra 400", ""), ("Kodak Portra 800", ""), ("Kodak Ultramax 400", ""), ("Kodak Vision3 250D", "cine"),
          ("Kodak Vision3 500T", "cine")]


def left_rail_film(left, right, gap):
    o = [left_head(), navigator(BAR + 6, left, right, gap)]
    y = BAR + 166
    b, y = layers(y, "F", left, right)
    o.append(b)
    h, y = section(y, "Film", None, open_=True)
    o.append(h)
    y += 2
    for name, kind in STOCKS:
        if kind is None:
            o.append(t(21.3, y + 11, name, 10.5, DIM, 600))
        else:
            if kind == "sel":
                o.append(f'<rect x="12" y="{y}" width="{LR-36}" height="15.27" rx="7.63" fill="{SEL}"/>')
            o.append(t(21.3, y + 11, name, 10.5, ONSEL if kind == "sel" else TEXT, 600))
            if kind == "cine":
                o.append(f'<rect x="{LR-44}" y="{y+3}" width="26" height="10" rx="5" fill="none" stroke="{ACCENT}" stroke-width="0.9"/>'
                         + t(LR - 31, y + 10.6, "CINE", 6.5, ACCENT, 700, "middle"))
        y += 15.27
    y += 8
    o.append(t(LX, y + 4, "One stock for the whole piece: both holes change.", 10, DIM, 500))
    y += 18
    h, y = section(y, "Piece", None, open_=True)
    o.append(h)
    y += 6
    o.append(l_label(y, "Camera") + l_seg(CTL, y, ["Held level", "Turned"], "Held level", 71))
    y += 26
    o.append(d_slider(LX, y, "Spacing", "1.00", 0.33, sub="mm between frames", w=LW))
    y += 34
    o.append(l_label(y, "Holes") + f'<rect x="{CTL}" y="{y-8}" width="{LR-14-CTL}" height="16" rx="8" fill="{FIELD}"/>'
             + f'<path d="M{CTL+12} {y-2} h12 l-3 -2.5 M{CTL+24} {y+2} h-12 l3 2.5" stroke="{TEXT}" stroke-width="1.1" fill="none"/>'
             + t(CTL + 32, y + 3.8, "Swap Left and Right", 10.5, TEXT, 600))
    y += 24
    h, y = section(y, "Overscan", None, open_=True)
    o.append(h)
    y += 6
    o.append(t(LX, y + 4, "The unexposed film between the holes. Edits", 10, DIM, 500))
    o.append(t(LX, y + 17, "set to + Overscan land here too.", 10, DIM, 500))
    y += 36
    o.append(d_slider(LX, y, "Brightness", "+1.00", 0.67, sub="stops", w=LW))
    y += 34
    o.append(d_slider(LX, y, "Yellow", "+0.00", 0.5, sub="← blue", w=LW, tint="#c9b24e"))
    y += 34
    o.append(d_slider(LX, y, "Magenta", "+0.00", 0.5, sub="← green", w=LW, tint="#a77fb0"))
    y += 28
    o.append(left_close(y))
    return "".join(o)


# ---- right rail ----------------------------------------------------------------------------
def right_head():
    return "".join([f'<rect x="{RX0}" y="0" width="{RR}" height="{DH}" fill="{CARD}"/>',
                    f'<line x1="{RX0}" y1="0" x2="{RX0}" y2="{DH}" stroke="{RULE}"/>',
                    t(RX0 + 16, 24, "Parameters", 13, TEXT, 600),
                    f'<rect x="{RX0+108}" y="11" width="60" height="18" rx="9" fill="none" stroke="{ACCENT}" stroke-width="1.1"/>'
                    + t(RX0 + 138, 24, "Pre-Dev", 11, ACCENT, 600, "middle"),
                    f'<rect x="{RX0+174}" y="11" width="64" height="18" rx="9" fill="none" stroke="{RULE}" stroke-width="1.1"/>'
                    + t(RX0 + 206, 24, "Post-Dev", 11, DIM, 500, "middle"),
                    f'<line x1="{RX0}" y1="{BAR}" x2="{DW}" y2="{BAR}" stroke="{RULE}"/>'])


def which(y, side, name, pic):
    """Which layer this rail edits: the same pick as the canvas, named, so it is never ambiguous."""
    o = [f'<rect x="{RX0+10}" y="{y+6}" width="{RR-20}" height="32" rx="6" fill="{WELL}"/>']
    if pic:
        o.append(im(RX0 + 18, y + 10, 18, 24, pic))
    else:
        o.append(film_glyph(RX0 + 16, y + 14))
    o.append(t(RX0 + 46, y + 20, side, 11.5, TEXT, 600))
    o.append(t(RX0 + 46, y + 33, name, 10, DIM, 500))
    return "".join(o), y + 44


def right_rail_hole(side, name, pic, scope="Frame", exposure=("+0.6", 0.56), temp=("4385", 0.25)):
    x0, w = RX0 + 16, RR - 32
    o = [right_head()]
    b, y = which(BAR, side, name, pic)
    o.append(b)
    h, y = section(y, "Latitude", None, open_=True, x0=RX0, x1=DW)
    o.append(h)
    hx0, hx1, base, top = x0, DW - 16, y + 62, y + 8
    stop = (hx1 - hx0) / 16
    o.append(latitude_hist(hx0, hx1, base, top, hx0 + (8 - 4.1) * stop, hx0 + (8 + 2.3) * stop, "rr" + side[0]))
    o.append(f'<line x1="{hx0}" y1="{base}" x2="{hx1}" y2="{base}" stroke="{RULE}"/>')
    for k_, lab in ((0, "−8"), (4, "−4"), (8, "0"), (12, "+4"), (16, "+8")):
        o.append(t(hx0 + k_ * stop, base + 13, lab, 9, DIM, 500, "middle"))
    o.append(t(x0, base + 30, "Metered on this hole’s picture only.", 10, DIM, 500))
    y = base + 42
    h, y = section(y, "Input / Camera", None, open_=True, x0=RX0, x1=DW)
    o.append(h)
    yy = y + 10
    o.append(scope_row(x0, yy, w, scope))
    yy += 40
    o.append(l_label_at(x0, yy, "Metering") + l_pill(x0 + 88, yy, w - 88, "Custom"))
    yy += 26
    for lab, val, u, tint, ashot in (("Film Exposure", exposure[0], exposure[1], None, False),
                                     ("Temperature", temp[0], temp[1], "#c9a35e", True),
                                     ("Tint", "−2.1", 0.47, "#9a7fb0", True)):
        o.append(d_slider(x0, yy, lab, val, u, w=w, tint=tint))
        o.append(t(x0, yy + 16, "As Shot", 9.5, DIM, 500) + l_check(x0 + 44, yy + 7.5, ashot).replace('width="11" height="11"', 'width="9" height="9"'))
        yy += 34
    y = yy
    h, y = section(y, "Film Format", "set by pair", x0=RX0, x1=DW)
    o.append(h)
    h, y = section(y, "Scene Placement", None, open_=True, x0=RX0, x1=DW)
    o.append(h)
    yy = y + 10
    o.append(d_slider(x0, yy, "Highlight", "0.56", 0.56, w=w))
    yy += 24
    o.append(d_slider(x0, yy, "Shadow", "0.00", 0.0, w=w))
    o.append(f'<line x1="{RX0}" y1="{yy+20}" x2="{DW}" y2="{yy+20}" stroke="{RULE}"/>')
    yy += 40
    for i, line in enumerate(["Everything here, and in Print, Crop and Enlarger,",
                              "belongs to this hole alone. Only the film stock",
                              "is shared, and the film decides it."]):
        o.append(t(x0, yy + i * 13, line, 10, DIM, 500))
    return "".join(o)


def right_rail_empty():
    x0 = RX0 + 16
    o = [right_head()]
    b, y = which(BAR, "Right hole", "Empty", None)
    o.append(b)
    y += 30
    o.append(t(RX0 + RR / 2, y + 40, "This hole has no frame yet.", 12, TEXT2, 500, "middle"))
    o.append(t(RX0 + RR / 2, y + 58, "Its settings appear once one is added.", 11, DIM, 500, "middle"))
    o.append(d_button(RX0 + RR / 2 - 55, y + 76, 110, "Add Frame…"))
    return "".join(o)


def right_rail_film():
    x0, w = RX0 + 16, RR - 32
    o = [right_head()]
    b, y = which(BAR, "Film", "Kodak Gold 200 · the whole piece", None)
    o.append(b)
    h, y = section(y, "Film Format", None, open_=True, x0=RX0, x1=DW)
    o.append(h)
    yy = y + 10
    o.append(f'<g opacity="{DISABLED}">' + l_label_at(x0, yy, "Size") + l_pill(x0 + 88, yy, 90, "135 half") + '</g>')
    o.append(t(DW - 16, yy + 4, "18 × 24 mm", 10, TEXT2, 500, "end"))
    yy += 24
    o.append(f'<g opacity="{DISABLED}">' + l_label_at(x0, yy, "Side Length") + f'<rect x="{x0+88}" y="{yy-8}" width="48" height="16" rx="4.25" fill="{FIELD}"/>'
             + t(x0 + 112, yy + 4, "24", 10.5, TEXT, 600, "middle") + '</g>')
    o.append(t(DW - 16, yy + 4, "across each hole", 10, TEXT2, 500, "end"))
    yy += 30
    for i, line in enumerate(["Half frame is what makes it a pair, so the",
                              "format is fixed. Grain and halation are at",
                              "half-frame scale in both holes, at any placement."]):
        o.append(t(x0, yy + i * 13, line, 10, DIM, 500))
    yy += 54
    o.append(f'<line x1="{RX0}" y1="{yy}" x2="{DW}" y2="{yy}" stroke="{RULE}"/>')
    o.append(t(RX0 + RR / 2, yy + 40, "Pick a hole to edit its picture.", 12, TEXT2, 500, "middle"))
    return "".join(o)


# ---- filmstrip -----------------------------------------------------------------------------
def filmstrip(left, right, gap, pair_on=True, picked_street=True):
    o = [f'<rect x="{CX0}" y="{CY1}" width="{CX1-CX0}" height="{STRIP}" fill="{CARD}"/>',
         f'<line x1="{CX0}" y1="{CY1}" x2="{CX1}" y2="{CY1}" stroke="{RULE}"/>']
    x, y, h = CX0 + 22, CY1 + 22, 88
    o.append(f'<path d="M{CX0+10} {y+38} l-5 6 5 6" stroke="{TEXT}" fill="none" stroke-width="1.5"/>'
             f'<path d="M{CX1-10} {y+38} l5 6 -5 6" stroke="{TEXT}" fill="none" stroke-width="1.5"/>')
    x += 6
    cells = [("thumbs/t1.jpg", 132), ("half_street_full.jpg", 59), ("PAIR", 0), ("half_snow_full.jpg", 59),
             ("thumbs/t2.jpg", 132), ("thumbs/t5.jpg", 132), ("thumbs/t7.jpg", 59), ("thumbs/t8.jpg", 59), ("thumbs/t3.jpg", 88)]
    for name, w in cells:
        if name == "PAIR":
            hw, g = h * 18 / 24, h / 24
            o.append(im(x, y, hw, h, left or gap, slice_=bool(left)))
            o.append(im(x + hw, y, g, h, gap, slice_=False))
            o.append(im(x + hw + g, y, hw, h, right or gap, slice_=bool(right)))
            if not right:
                cx = x + hw + g + hw / 2
                o.append(f'<path d="M{cx-6} {y+h/2} h12 M{cx} {y+h/2-6} v12" stroke="{TEXT2}" stroke-width="1.5"/>')
            w = 2 * hw + g
            if pair_on:
                o.append(f'<rect x="{x-2}" y="{y-2}" width="{w+4}" height="{h+4}" fill="none" stroke="{SELFRAME}" stroke-width="2"/>')
        else:
            o.append(im(x, y, w, h, name))
            if name == "half_street_full.jpg" and picked_street:
                o.append(f'<rect x="{x-1.5}" y="{y-1.5}" width="{w+3}" height="{h+3}" fill="none" stroke="{SELFRAME}" stroke-width="1.2" opacity="0.5"/>')
        x += w + 14
    return "".join(o)


def add_popover(ax, ay):
    """Add Frame: the open folder's frames, as the Browse grid draws them."""
    w, hgt = 336, 392
    x, y = ax - w / 2, ay + 26
    o = [f'<rect x="{x+3}" y="{y+6}" width="{w}" height="{hgt}" rx="10" fill="#000" opacity="0.4"/>',
         f'<path d="M{ax-9} {y+0.5} L{ax} {y-9} L{ax+9} {y+0.5} Z" fill="{CARD}" stroke="{RULE}"/>',
         f'<rect x="{x}" y="{y}" width="{w}" height="{hgt}" rx="10" fill="{CARD}" stroke="{RULE}"/>',
         f'<rect x="{ax-10}" y="{y-1}" width="20" height="3" fill="{CARD}"/>',
         t(x + 16, y + 26, "Add to the Right Hole", 13, TEXT, 600),
         t(x + w - 16, y + 26, "样片日志01  ·  8", 10.5, DIM, 500, "end")]
    o.append(f'<rect x="{x+16}" y="{y+38}" width="{w-32}" height="22" rx="6" fill="{FIELD}"/>'
             f'<circle cx="{x+30}" cy="{y+49}" r="4.5" stroke="{DIM}" stroke-width="1.2" fill="none"/><path d="M{x+33.5} {y+52.5} l3 3" stroke="{DIM}" stroke-width="1.2"/>'
             + t(x + 42, y + 53, "Filter by name", 11, DIM, 500))
    grid = ["thumbs/t1.jpg", "half_street_full.jpg", "half_snow_full.jpg", "thumbs/t2.jpg", "thumbs/t5.jpg",
            "thumbs/t7.jpg", "thumbs/t8.jpg", "thumbs/t3.jpg"]
    cw, ch, gx = 96, 76, 8
    gx0, gy0 = x + 16, y + 72
    for i, name in enumerate(grid):
        cx, cy = gx0 + (i % 3) * (cw + gx), gy0 + (i // 3) * (ch + 24)
        o.append(f'<rect x="{cx}" y="{cy}" width="{cw}" height="{ch}" rx="4" fill="{WELL}"/>')
        o.append(im(cx + 4, cy + 4, cw - 8, ch - 8, name, slice_=True))
        if name == "half_street_full.jpg":
            o.append(f'<rect x="{cx}" y="{cy}" width="{cw}" height="{ch}" rx="4" fill="{CARD}" opacity="0.55"/>')
            o.append(t(cx + cw / 2, cy + ch + 14, "in the left hole", 9.5, DIM, 500, "middle"))
        if name == "half_snow_full.jpg":
            o.append(f'<rect x="{cx-1.5}" y="{cy-1.5}" width="{cw+3}" height="{ch+3}" rx="5" fill="none" stroke="{SELFRAME}" stroke-width="1.5"/>')
            o.append(t(cx + cw / 2, cy + ch + 14, RIGHT_NAME, 9.5, TEXT2, 500, "middle"))
    o.append(f'<line x1="{x}" y1="{y+hgt-40}" x2="{x+w}" y2="{y+hgt-40}" stroke="{RULE}"/>')
    o.append(t(x + 16, y + hgt - 16, "A frame can be in more than one pair.", 10.5, DIM, 500))
    o.append(d_button(x + w - 86, y + hgt - 31, 70, "Add", primary=True, h=22).replace('font-size="12.5"', 'font-size="11.5"'))
    return "".join(o)


# ---------------------------------------------------------------------------------------------
# the screens
# ---------------------------------------------------------------------------------------------
def canvas_bg():
    return f'<rect x="{CX0}" y="{CY0}" width="{CX1-CX0}" height="{CY1-CY0}" fill="{GROUND}"/>'


def s1_new_pair():
    L, R, G = "half_street_slot.jpg", None, "gap.jpg"
    o = [svg_open("Half-frame pair: a new pair from one picked frame, adding to the empty hole"),
         canvas_bg(), piece(L, R, G, sel="R"), add_hole(RXH), status("Left hole developed  ·  right hole empty", "Pair 3,289 × 2,133  ·  preview"),
         topbar(f"Half-Frame Pair  ·  {LEFT_NAME} + empty  ·  Kodak Gold 200"),
         left_rail_hole(L, R, G, "R", scope="Frame", bright="+0.00", bright_u=0.5).replace("Kodak Gold 200 · set by pair", "Kodak Gold 200 · set by pair"),
         right_rail_empty(), filmstrip(L, R, G), add_popover(RXH + HW / 2, PY + PH / 2 + 2)]
    o.append('</svg>\n')
    return "\n".join(o)


def s2_hole_selected():
    L, R, G = "half_street_slot.jpg", "half_snow_p10_slot.jpg", "gap.jpg"
    o = [svg_open("Half-frame pair: the right hole picked, its print one stop brighter, frame only"),
         canvas_bg(), piece(L, R, G, sel="R"), status("Developed  ·  Enlarger +1.00 on the right hole, frame only", "Pair 3,289 × 2,133  ·  preview"),
         topbar(f"Half-Frame Pair  ·  {LEFT_NAME} + {RIGHT_NAME}  ·  Kodak Gold 200"),
         left_rail_hole(L, R, G, "R", scope="Frame", bright="+1.00", bright_u=0.67),
         right_rail_hole("Right hole", RIGHT_NAME, R, scope="Frame", exposure=("+0.3", 0.52), temp=("5600", 0.42)),
         filmstrip(L, R, G, picked_street=False)]
    o.append('</svg>\n')
    return "\n".join(o)


def s3_film_selected():
    L, R, G = "half_street_slot.jpg", "half_snow_p10_slot.jpg", "gap_p10.jpg"
    o = [svg_open("Half-frame pair: the film picked: stock, piece, overscan"),
         canvas_bg(), piece(L, R, G, sel="F"), status("Developed  ·  Overscan +1.00", "Pair 3,289 × 2,133  ·  preview"),
         topbar(f"Half-Frame Pair  ·  {LEFT_NAME} + {RIGHT_NAME}  ·  Kodak Gold 200"),
         left_rail_film(L, R, G), right_rail_film(), filmstrip(L, R, G, picked_street=False)]
    o.append('</svg>\n')
    return "\n".join(o)


def s4_place():
    L, R, G = "half_street_slot.jpg", "half_snow_p10_slot.jpg", "gap.jpg"
    o = [svg_open("Half-frame pair: placing the right hole's picture; the hole stays, the picture moves"), canvas_bg()]
    # the whole frame under the hole, larger than it: 1.18x of "fills the hole"
    k = 1.18
    fw = HW * k
    fh = fw * 2400 / 1600
    fx = RXH + HW / 2 - fw / 2 + 34
    fy = PY + PH / 2 - fh / 2 + 30
    o.append(f'<clipPath id="cv"><rect x="{CX0}" y="{CY0}" width="{CX1-CX0}" height="{CY1-CY0}"/></clipPath>')
    o.append(f'<clipPath id="hole"><rect x="{RXH}" y="{PY}" width="{HW}" height="{PH}"/></clipPath>')
    o.append(piece(L, None, G, dim_left=True))
    o.append(f'<g clip-path="url(#cv)">' + im(fx, fy, fw, fh, "half_snow_p10_full.jpg", slice_=False, extra='opacity="0.32"') + '</g>')
    o.append(f'<g clip-path="url(#hole)">' + im(fx, fy, fw, fh, "half_snow_p10_full.jpg", slice_=False) + '</g>')
    o.append(f'<rect x="{fx:.1f}" y="{fy:.1f}" width="{fw:.1f}" height="{fh:.1f}" fill="none" stroke="#fff" stroke-opacity="0.45" stroke-dasharray="4 4"/>')
    for i in (1, 2):
        o.append(f'<line x1="{RXH+HW*i/3:.1f}" y1="{PY}" x2="{RXH+HW*i/3:.1f}" y2="{PY+PH}" stroke="#fff" stroke-opacity="0.35"/>')
        o.append(f'<line x1="{RXH}" y1="{PY+PH*i/3:.1f}" x2="{RXH+HW}" y2="{PY+PH*i/3:.1f}" stroke="#fff" stroke-opacity="0.35"/>')
    x0, y0, x1, y1, Lh = RXH, PY, RXH + HW, PY + PH, 20
    o.append(f'<rect x="{x0}" y="{y0}" width="{HW}" height="{PH}" fill="none" stroke="#fff" stroke-width="1"/>')
    o.append(f'<path d="M{x0} {y0+Lh} V{y0} H{x0+Lh} M{x1-Lh} {y0} H{x1} V{y0+Lh} M{x1} {y1-Lh} V{y1} H{x1-Lh} M{x0+Lh} {y1} H{x0} V{y1-Lh}" stroke="#fff" stroke-width="3.5" fill="none"/>')
    ccx = (CX0 + CX1) / 2
    msg = f"Placing {RIGHT_NAME} in the right hole. Drag to move, scroll to scale. Return develops; Esc puts it back."
    o.append(f'<rect x="{ccx-290}" y="{CY1-38}" width="580" height="24" rx="12" fill="{PANEL}" fill-opacity="0.88"/>'
             + t(ccx, CY1 - 22, msg, 11.5, TEXT2, 500, "middle"))
    o += [topbar(f"Half-Frame Pair  ·  {LEFT_NAME} + {RIGHT_NAME}  ·  Kodak Gold 200", crop=True),
          left_rail_hole(L, R, G, "R", scope="Frame", bright="+1.00", bright_u=0.67, crop_open=True),
          right_rail_hole("Right hole", RIGHT_NAME, R, scope="Frame", exposure=("+0.3", 0.52), temp=("5600", 0.42)),
          filmstrip(L, R, G, picked_street=False), '</svg>\n']
    return "\n".join(o)


# ---- concept sheet: layers, scope, what each holds, how it renders ---------------------------
def concept():
    W, H = 1920, 1380
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
         '<title>Half-frame pair: how it works</title>', f'<rect width="{W}" height="{H}" fill="{CARD}"/>',
         t(60, 74, "Half-frame pair", 30, TEXT, 700),
         t(60, 104, "Two neighbouring frames on one piece of half-frame film. The film is the canvas; each hole takes a frame as a layer.", 14, TEXT2, 500)]

    def head(x, y, s):
        return t(x, y, s, 15, ACCENT, 700)

    def mini(x, y, h, left, right, gap, outline=None):
        hw, g = h * 18 / 24, h / 24
        r = [im(x, y, hw, h, left or gap, slice_=bool(left)), im(x + hw, y, g, h, gap, slice_=False),
             im(x + hw + g, y, hw, h, right or gap, slice_=bool(right))]
        if outline:
            r.append(f'<rect x="{x-2}" y="{y-2}" width="{2*hw+g+4}" height="{h+4}" fill="none" stroke="{outline}" stroke-width="1.5"/>')
        return "".join(r), 2 * hw + g

    # A: the layers, exploded
    o.append(head(60, 160, "A · The film first, then a frame into each hole"))
    y0 = 190
    base, bw = mini(80, y0 + 30, 220, None, None, "gap.jpg")
    o.append(base + t(80 + bw / 2, y0 + 274, "Film: one stock, two empty holes", 12, TEXT, 600, "middle")
             + t(80 + bw / 2, y0 + 291, "18 × 24 mm each, 1.0 mm apart", 11, DIM, 500, "middle"))
    ax = 80 + bw + 40
    o.append(f'<path d="M{ax} {y0+140} h52" stroke="{TEXT2}" stroke-width="1.5"/><path d="M{ax+52} {y0+134} l9 6 -9 6z" fill="{TEXT2}"/>')
    lx = ax + 90
    o.append(im(lx, y0 + 30, 165, 220, "half_street_slot.jpg") + t(lx + 82, y0 + 274, "Left hole: Add Frame", 12, TEXT, 600, "middle")
             + t(lx + 82, y0 + 291, LEFT_NAME, 11, DIM, 500, "middle"))
    o.append(im(lx + 190, y0 + 30, 165, 220, "half_snow_slot.jpg") + t(lx + 272, y0 + 274, "Right hole: Add Frame", 12, TEXT, 600, "middle")
             + t(lx + 272, y0 + 291, RIGHT_NAME, 11, DIM, 500, "middle"))
    ax2 = lx + 380
    o.append(f'<path d="M{ax2} {y0+140} h52" stroke="{TEXT2}" stroke-width="1.5"/><path d="M{ax2+52} {y0+134} l9 6 -9 6z" fill="{TEXT2}"/>')
    res, rw = mini(ax2 + 90, y0 + 30, 220, "half_street_slot.jpg", "half_snow_slot.jpg", "gap.jpg")
    o.append(res + t(ax2 + 90 + rw / 2, y0 + 274, "The pair: one canvas, one export", 12, TEXT, 600, "middle")
             + t(ax2 + 90 + rw / 2, y0 + 291, "3,289 × 2,133 from two 1,600 × 2,400 frames", 11, DIM, 500, "middle"))
    nx = ax2 + 90 + rw + 50
    for i, line in enumerate(["The canvas fits the piece, never a photo:",
                              "adding, replacing or moving a picture",
                              "cannot resize anything. The picture moves",
                              "under its hole; the hole never moves.",
                              "",
                              "An empty hole is unexposed film: it prints",
                              "as the base does, near-black (engine render).",
                              "It never exports: both holes must be filled."]):
        o.append(t(nx, y0 + 60 + i * 19, line, 12.5, TEXT2 if line else TEXT2, 500))

    # B: exposure scope with real renders
    yb = 560
    o.append(head(60, yb, "B · Exposure scope: the frame, or the frame and the overscan"))
    cases = [("Right hole, Enlarger +1.00, Frame", "half_snow_p10_slot.jpg", "gap.jpg", "the gap stays as the film prints it"),
             ("Right hole, Enlarger +1.00, + Overscan", "half_snow_p10_slot.jpg", "gap_p10.jpg", "the same +1.00 lands on the overscan: the gap lifts"),
             ("Before: both at 0", "half_snow_slot.jpg", "gap.jpg", "")]
    x = 80
    for title, right, gap, note in cases[:2]:
        m, mw = mini(x, yb + 30, 250, "half_street_slot.jpg", right, gap)
        o.append(m + t(x, yb + 306, title, 12.5, TEXT, 600) + t(x, yb + 324, note, 11, DIM, 500))
        # the gap at 6x: the same three renders, viewed through a window around the gap
        zx, zh = x + mw + 20, 250
        hw_, g_ = 250 * 18 / 24, 250 / 24
        vb = f"{hw_ - 6} {125 - 125 / 6:.2f} {g_ + 12:.2f} {250 / 6:.2f}"
        o.append(f'<rect x="{zx}" y="{yb+30}" width="96" height="{zh}" fill="{WELL}"/>'
                 f'<svg x="{zx+4}" y="{yb+34}" width="88" height="{zh-8}" viewBox="{vb}" preserveAspectRatio="xMidYMid slice">'
                 + im(0, 0, hw_, 250, "half_street_slot.jpg") + im(hw_, 0, g_, 250, gap, slice_=False)
                 + im(hw_ + g_, 0, hw_, 250, right) + '</svg>'
                 + t(zx + 48, yb + 296, "the gap, 6×", 10.5, DIM, 500, "middle"))
        x += mw + 160
    rx = x + 10
    for i, line in enumerate(["Every exposure edit in a hole carries a scope:",
                              "Film Exposure (Input / Camera) and the Enlarger's",
                              "Brightness, Yellow, Magenta and Pre-flash.",
                              "",
                              "Frame: only that hole's picture changes.",
                              "+ Overscan: the same change also lands on the",
                              "Film layer's Overscan, which prints the gap.",
                              "It is a delta, so two holes can both push it,",
                              "and the Film layer shows the sum.",
                              "",
                              "Default: Frame, so the halves stay independent.",
                              "⌥ while dragging flips it for that one drag."]):
        o.append(t(rx, yb + 50 + i * 19, line, 12.5, TEXT2, 500))

    # C: what each layer holds
    yc = 930
    o.append(head(60, yc, "C · What each layer holds (the pair owns all of it except a frame's shot)"))
    rows = [("Film", "Film stock (the only shared setting) · format 135 half, fixed · camera held level / turned · spacing · swap holes · Overscan print", "the pair"),
            ("Each hole: the shot", "Metering · Film Exposure · Temperature / Tint (As Shot) · Scene Placement", "the frame's own file: the same shot everywhere it appears"),
            ("Each hole: the print", "Paper · Enlarger Brightness / Yellow / Magenta / Pre-flash · Tone Mask · grain / halation / glare strengths", "the pair, per hole"),
            ("Each hole: the rest", "Placement in the hole (scale, move, straighten, rotate, flip) · masks · Post-Dev", "the pair, per hole")]
    for i, (a, b, c) in enumerate(rows):
        y = yc + 22 + i * 38
        o.append(f'<rect x="60" y="{y}" width="{W-120}" height="34" rx="6" fill="{WELL if i % 2 == 0 else CARD}"/>')
        o.append(t(78, y + 22, a, 12.5, TEXT, 600) + t(290, y + 22, b, 12, TEXT2, 500) + t(W - 78, y + 22, c, 11.5, DIM, 500, "end"))

    # D: how it renders
    yd = 1130
    o.append(head(60, yd, "D · How it renders: no engine change"))
    rows3 = [("Left hole", "its frame · its shot · its print", "Engine render", "unchanged · 24 mm across the hole"),
             ("Right hole", "its frame · its shot · its print", "Engine render", "unchanged · 24 mm across the hole"),
             ("Film", "stock · Overscan print", "Overscan render", "unexposed film, the gap's size")]
    for i, (a, b, c, d) in enumerate(rows3):
        by = yd + 22 + i * 70
        o.append(f'<rect x="80" y="{by}" width="300" height="54" rx="8" fill="{WELL}" stroke="{RULE}"/>'
                 + t(230, by + 23, a, 12.5, TEXT, 600, "middle") + t(230, by + 41, b, 10.5, DIM, 500, "middle"))
        o.append(f'<rect x="440" y="{by}" width="300" height="54" rx="8" fill="{WELL}" stroke="{RULE}"/>'
                 + t(590, by + 23, c, 12.5, TEXT, 600, "middle") + t(590, by + 41, d, 10.5, DIM, 500, "middle"))
        o.append(f'<path d="M380 {by+27} h52" stroke="{TEXT2}" stroke-width="1.4"/><path d="M432 {by+22} l8 5 -8 5z" fill="{TEXT2}"/>')
        o.append(f'<path d="M740 {by+27} C 950 {by+27}, 1000 {yd+99}, 1172 {yd+99}" stroke="{TEXT2}" stroke-width="1.4" fill="none"/>')
    o.append(f'<path d="M1172 {yd+94} l8 5 -8 5z" fill="{TEXT2}"/>')
    o.append(f'<rect x="1180" y="{yd+72}" width="300" height="54" rx="8" fill="#3A342A" stroke="{ACCENT}"/>'
             + t(1330, yd + 95, "Pair compositor (Metal)", 12.5, TEXT, 600, "middle") + t(1330, yd + 113, "holes + gap → one image", 10.5, DIM, 500, "middle"))
    o.append(t(1520, yd + 70, "Canvas and export draw the same image.", 12, TEXT2, 500)
             + t(1520, yd + 89, "No wire field, no API-SPEC change, nothing", 12, TEXT2, 500)
             + t(1520, yd + 108, "in engine/: the mobile port is not touched.", 12, TEXT2, 500)
             + t(1520, yd + 138, "Hole size: the smaller picture's pixels across", 11, DIM, 500)
             + t(1520, yd + 155, "its hole, so neither is upscaled.", 11, DIM, 500))
    o.append('</svg>\n')
    return "\n".join(o)


# ---------------------------------------------------------------------------------------------
# Film Edge on: the pair as one engine canvas (scratch engine: mobile 371ad16 + pair_scratch.patch)
# ---------------------------------------------------------------------------------------------
SW_, SH_ = 3377, 3087                      # the engine's canvas for the pair
GATES = {"L": (34, 471, 1648, 2618), "R": (1723, 468, 3337, 2615)}   # from the engine's own coverage
SK = 790 / SH_
SX, SY = CX0 + (CX1 - CX0 - SW_ * SK) / 2, CY0 + 40


def strip(name, sel=None):
    o = [im(SX, SY, SW_ * SK, SH_ * SK, name, slice_=False)]
    if sel in GATES:
        x0, y0, x1, y1 = GATES[sel]
        o.append(f'<rect x="{SX+x0*SK-3:.1f}" y="{SY+y0*SK-3:.1f}" width="{(x1-x0)*SK+6:.1f}" height="{(y1-y0)*SK+6:.1f}" fill="none" stroke="{SELFRAME}" stroke-width="2"/>')
    elif sel == "F":
        o.append(f'<rect x="{SX-3:.1f}" y="{SY-3:.1f}" width="{SW_*SK+6:.1f}" height="{SH_*SK+6:.1f}" fill="none" stroke="{SELFRAME}" stroke-width="2"/>')
    return "".join(o)


def strip_status(line, size):
    y = SY + SH_ * SK
    return (f'<circle cx="{SX+6:.1f}" cy="{y+21:.1f}" r="3.5" fill="{TEXT2}"/>' + t(SX + 16, y + 25, line, 11.5, TEXT2, 500)
            + t(SX + SW_ * SK, y + 25, size, 11, DIM, 500, "end"))


def l_dice(x, y, w, label):
    return (f'<rect x="{x}" y="{y-8}" width="{w}" height="16" rx="8" fill="{FIELD}"/>'
            f'<rect x="{x+6}" y="{y-5}" width="10" height="10" rx="2" fill="none" stroke="{TEXT2}" stroke-width="1"/>'
            f'<circle cx="{x+8.6}" cy="{y-2.4}" r="0.9" fill="{TEXT2}"/><circle cx="{x+13.4}" cy="{y+2.4}" r="0.9" fill="{TEXT2}"/>'
            + t(x + 21, y + 3.8, label, 10.5, TEXT2, 600))


def film_edge_pair_body(y):
    o = []
    y += 6
    o.append(l_label(y, "Format") + l_pill(CTL, y, 98, "135 half · pair") + t(LR - 14, y + 4, "18 × 24", 10, DIM, 500, "end"))
    y += 24
    o.append(l_label(y, "View") + l_seg(CTL, y, ["Strip", "Filed"], "Strip", 71))
    y += 24
    o.append(l_label(y, "Holes") + l_seg(CTL, y, ["White", "Black"], "White", 71))
    y += 24
    o.append(l_label(y, "Numbers") + t(CTL, y + 4, "6 · 6A", 11, TEXT, 600) + l_dice(CTL + 56, y, LR - 14 - CTL - 56, "Another"))
    y += 24
    o.append(l_label(y, "Body") + t(CTL, y + 4, "No. 19", 11, TEXT, 600) + l_dice(CTL + 56, y, LR - 14 - CTL - 56, "Another"))
    y += 30
    o.append(d_slider(LX, y, "Edge fog", "1.0", 0.25, w=LW, tint="#b8865a"))
    y += 24
    o.append(d_slider(LX, y, "Spool leaks", "0.0", 0.0, w=LW, tint="#b8865a"))
    y += 22
    for i, line in enumerate(["One strip: the same gate twice, 19.00 mm", "apart (4 perforations). The numbers come",
                              "from the film; the edge print from the stock."]):
        o.append(t(LX, y + 4 + i * 13, line, 10, DIM, 500))
    y += 48
    return "".join(o), y


def strip_nav(y):
    return (f'<rect x="10" y="{y}" width="{LR-20}" height="150" rx="4" fill="{WELL}"/>'
            + im(LR / 2 - 70, y + 6, 140, 128, "strip_c.jpg", slice_=False))


def left_rail_film_edge():
    o = [left_head(), strip_nav(BAR + 6)]
    y = BAR + 166
    b, y = layers(y, "F", "half_street_slot.jpg", "half_snow_slot.jpg")
    o.append(b.replace(f'xlink:href="#', 'xlink:href="#'))
    h, y = section(y, "Film", "Kodak Gold 200")
    o.append(h)
    h, y = section(y, "Film Edge", None, open_=True, check=True)
    o.append(h)
    b, y = film_edge_pair_body(y)
    o.append(b)
    h, y = section(y, "Piece", "Held level · set by Film Edge")
    o.append(h)
    h, y = section(y, "Overscan", "+0.00 · the rebate and gap")
    o.append(h)
    h, y = section(y, "Date Back", "Off", check=False)
    o.append(h)
    o.append(left_close(y))
    return "".join(o)


def left_rail_hole_edge():
    """A hole picked with Film Edge on: Enlarger set to + Overscan."""
    o = [left_head(), strip_nav(BAR + 6)]
    y = BAR + 166
    b, y = layers(y, "R", "half_street_slot.jpg", "half_snow_p10_slot.jpg")
    o.append(b)
    h, y = section(y, "Film", "Kodak Gold 200 · set by pair")
    o.append(h)
    h, y = section(y, "Film Edge", "135 half pair · 6 · 6A", check=True)
    o.append(h)
    h, y = section(y, "Print", "Supra Endura")
    o.append(h)
    h, y = section(y, "Crop", "Placement · 3:4")
    o.append(h)
    h, y = section(y, "Enlarger", None, open_=True)
    o.append(h)
    b, y = enlarger_body(y, "+ Overscan", "+1.00", 0.67)
    o.append(b)
    o.append(t(LX, y + 4, "+ Overscan: the rebate, edge print and gap", 10, DIM, 500))
    o.append(t(LX, y + 17, "print +1.00 with this frame. The left frame", 10, DIM, 500))
    o.append(t(LX, y + 30, "keeps its own print.", 10, DIM, 500))
    y += 44
    o.append(left_close(y))
    return "".join(o)


def filmstrip_edge():
    o = [f'<rect x="{CX0}" y="{CY1}" width="{CX1-CX0}" height="{STRIP}" fill="{CARD}"/>',
         f'<line x1="{CX0}" y1="{CY1}" x2="{CX1}" y2="{CY1}" stroke="{RULE}"/>']
    x, y, h = CX0 + 28, CY1 + 22, 88
    o.append(f'<path d="M{CX0+10} {y+38} l-5 6 5 6" stroke="{TEXT}" fill="none" stroke-width="1.5"/>'
             f'<path d="M{CX1-10} {y+38} l5 6 -5 6" stroke="{TEXT}" fill="none" stroke-width="1.5"/>')
    for name, w in (("thumbs/t1.jpg", 132), ("half_street_full.jpg", 59), ("STRIP", 96), ("half_snow_full.jpg", 59),
                    ("thumbs/t2.jpg", 132), ("thumbs/t5.jpg", 132), ("thumbs/t7.jpg", 59), ("thumbs/t8.jpg", 59), ("thumbs/t3.jpg", 88)):
        if name == "STRIP":
            o.append(im(x, y, w, h, "strip_c.jpg", slice_=False))
            o.append(f'<rect x="{x-2}" y="{y-2}" width="{w+4}" height="{h+4}" fill="none" stroke="{SELFRAME}" stroke-width="2"/>')
        else:
            o.append(im(x, y, w, h, name))
        x += w + 14
    return "".join(o)


def s5_film_edge():
    o = [svg_open("Half-frame pair with Film Edge: one strip, frames 6 and 6A, the film picked"), canvas_bg(),
         strip("strip_c.jpg", sel="F"),
         strip_status("Developed  ·  Film Edge  ·  135 half pair, frames 6 and 6A", "Film 3,377 × 3,087  ·  preview"),
         topbar(f"Half-Frame Pair  ·  {LEFT_NAME} + {RIGHT_NAME}  ·  Kodak Gold 200  ·  Film Edge"),
         left_rail_film_edge(), right_rail_film(), filmstrip_edge(), '</svg>\n']
    return "\n".join(o)


def s6_scope_overscan():
    o = [svg_open("Half-frame pair with Film Edge: the right hole's print +1.00 at + Overscan"), canvas_bg(),
         strip("strip_over_c.jpg", sel="R"),
         strip_status("Developed  ·  Enlarger +1.00 on the right hole, + Overscan", "Film 3,377 × 3,087  ·  preview"),
         topbar(f"Half-Frame Pair  ·  {LEFT_NAME} + {RIGHT_NAME}  ·  Kodak Gold 200  ·  Film Edge"),
         left_rail_hole_edge(),
         right_rail_hole("Right hole", RIGHT_NAME, "half_snow_p10_slot.jpg", scope="Frame", exposure=("+0.3", 0.52), temp=("5600", 0.42)),
         filmstrip_edge(), '</svg>\n']
    return "\n".join(o)


def concept_edge():
    W, H = 1920, 1250
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
         '<title>Half-frame pair with Film Edge: one engine canvas</title>', f'<rect width="{W}" height="{H}" fill="{CARD}"/>',
         t(60, 74, "Half-frame pair with Film Edge", 30, TEXT, 700),
         t(60, 104, "One strip, rendered by the engine: the same gate exposed twice, 19.00 mm apart. Frames 6 and 6A, Kodak Gold 200 on Supra Endura, camera No. 19.", 14, TEXT2, 500)]
    h = 600
    w = h * SW_ / SH_
    o.append(im(60, 150, w, h, "strip_c.jpg", slice_=False))
    o.append(t(60, 150 + h + 28, "Engine render (scratch build: mobile 371ad16 + pair_scratch.patch). Nothing drawn by hand.", 12.5, TEXT, 600))
    o.append(t(60, 150 + h + 47, "Top band: 6, then the stock name. Bottom band: the DX code twice (one per half frame), 6, then 6A with its arrow.", 11.5, DIM, 500))
    x2 = 60 + w + 60
    lines = ["Why one canvas, not two renders butted together:",
             "• each render has its own scan rotation and weave, so the",
             "  strip's edges and perforations would step at the seam;",
             "• the numbers walk in half-frame steps across one canvas",
             "  (6 then 6A); two seeds can only land whole frames apart;",
             "• halation, edge fog and leaks cross the gap, as on film.",
             "",
             "The camera exposes one gate twice, so the kernel's gate",
             "is the union of the gate and the same gate one advance on:",
             "the corners, wobble and penumbra repeat exactly.",
             "",
             "Measured on this render: each gate 1,615 × 2,148 px (the",
             "1,600 × 2,133 picture and its penumbra); the gap 75 px,",
             "0.84 mm (the 1 mm between frames, less the soft edges)."]
    for i, line in enumerate(lines):
        o.append(t(x2, 172 + i * 21, line, 13, TEXT2 if line.startswith(("•", " ")) or not line else TEXT, 500 if line.startswith(("•", " ")) else 600))
    yb = 150 + h + 90
    o.append(t(60, yb, "Exposure scope on the strip: the right hole's print +1.00", 15, ACCENT, 700))
    hh = 300
    ww = hh * SW_ / SH_
    o.append(im(60, yb + 18, ww, hh, "strip_frame_c.jpg", slice_=False) + t(60, yb + hh + 42, "Frame: only the right picture", 12.5, TEXT, 600))
    o.append(im(60 + ww + 40, yb + 18, ww, hh, "strip_over_c.jpg", slice_=False) + t(60 + ww + 40, yb + hh + 42, "+ Overscan: the rebate, edge print and gap with it", 12.5, TEXT, 600))
    x3 = 60 + 2 * ww + 100
    for i, line in enumerate(["The negative is the same in both: a print-only change.",
                              "So each region is a reprint of one developed canvas",
                              "(a reprint, not a re-develop), cut together along the",
                              "engine's own gate coverage. Left gate, right gate, overscan:",
                              "three regions, each with its own print. That is how",
                              "every hole keeps its own print and paper on one strip.",
                              "",
                              "With Film Edge the scope is plainly visible; without it,",
                              "the gap alone sits near paper black and barely moves."]):
        o.append(t(x3, yb + 40 + i * 21, line, 13, TEXT2, 500))
    o.append('</svg>\n')
    return "\n".join(o)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in (("pair_1_new_v2.svg", s1_new_pair), ("pair_2_hole_v2.svg", s2_hole_selected),
                     ("pair_3_film_v2.svg", s3_film_selected), ("pair_4_place_v2.svg", s4_place),
                     ("pair_concept_v2.svg", concept), ("pair_5_film_edge_v2.svg", s5_film_edge),
                     ("pair_6_scope_edge_v2.svg", s6_scope_overscan), ("pair_concept_edge_v2.svg", concept_edge)):
        with open(os.path.join(OUT, name), "w") as f:
            f.write(flush_defs(fn()))
        print(name)
