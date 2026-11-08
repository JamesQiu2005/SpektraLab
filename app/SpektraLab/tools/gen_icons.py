#!/usr/bin/env python3
"""gen_icons.py -- the drawings' own glyphs, as Swift.

    tools/gen_icons.py [--design DIR] [--check] [--sheet SVG]

The drawings (`design/src/gen.py`, `gen_flow.py`) draw every glyph themselves: a few
strokes in a 22 pt box centred on (cx, cy). This runs those functions at the origin,
reads the SVG they return, and writes the same geometry as
`Sources/DesignSystem/DrawnIcons.swift` -- so a glyph in the app is the drawing's own,
to the stroke, and not a system symbol that looks like it.

Arcs are turned into cubic curves here, so the Swift side is move / line / curve only.
`--check` writes nothing and fails if the file on disk is not what would be written.

`gen_flow.py` was not yet committed on 2026-10-03: without `--design` or DESIGN_DIR the
repository's `design/src` is used, and the main worktree's when this one has no gen_flow.py.
"""
from __future__ import annotations

import argparse
import contextlib
import importlib
import io
import math
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.dont_write_bytecode = True   # never leave a .pyc in a design folder that is not ours
HERE = Path(__file__).resolve().parent.parent
REPO = HERE.parent.parent
OUT = HERE / "Sources" / "DesignSystem" / "DrawnIcons.swift"
CURRENT = "CURRENT"              # the colour the caller chooses


def design_dir(arg: str | None) -> Path:
    if arg:
        return Path(arg)
    if os.environ.get("DESIGN_DIR"):
        return Path(os.environ["DESIGN_DIR"]) / "src"
    here = REPO / "design" / "src"
    if (here / "gen_flow.py").exists():
        return here
    try:
        out = subprocess.run(["git", "-C", str(REPO), "worktree", "list", "--porcelain"],
                             capture_output=True, text=True, check=True).stdout
        main = next(line[9:] for line in out.splitlines() if line.startswith("worktree "))
        cand = Path(main) / "design" / "src"
        if (cand / "gen_flow.py").exists():
            return cand
    except Exception:
        pass
    return here


# ---------------------------------------------------------------------------- the glyphs
# The website's Loupe tool (SpektraLab Website, lighttable/index.html; gen_lighttable.STAND_LOUPE): a stand loupe
# seen from the side in a 16 pt box. Stated here, as the pair's glyph is, because transforms are not read.
STAND_LOUPE = ((4.6, 2.1), (11.4, 2.1)), ((5.1, 2.1), (2.5, 13.9), (13.5, 13.9), (10.9, 2.1)), ((4.1, 6.7), (11.9, 6.7))


def stand_loupe(c: str, stroke: float) -> str:
    """The website's 16 pt glyph in the drawings' 22 pt box, about its centre, round caps and joins."""
    k = 22 / 16
    d = " ".join("M" + " L".join(f"{(x - 8) * k:.5g} {(y - 8) * k:.5g}" for x, y in run) for run in STAND_LOUPE)
    return (f'<path d="{d}" stroke="{c}" stroke-width="{stroke}" fill="none" stroke-linecap="round" '
            f'stroke-linejoin="round"/>')


def collect(src: Path) -> tuple[dict[str, str], str]:
    """(name -> the SVG the drawing's function returns at (0, 0), the card colour)."""
    sys.path.insert(0, str(src))
    with contextlib.redirect_stdout(io.StringIO()):
        G = importlib.import_module("gen")
        F = importlib.import_module("gen_flow")
        GO = importlib.import_module("gen_overscan")
    C = CURRENT
    card = F.CARD
    stroke = f'stroke="{C}" stroke-width="1.6" fill="none" stroke-linecap="round" stroke-linejoin="round"'
    bolt = G.ic_bolt(0, 0, C)
    icons = {
        # gen.py
        "share": G.ic_share(0, 0, C),
        "back": G.ic_chevron_left(0, 0, C),
        "dotsVertical": G.ic_dots(0, 0, C, vertical=True),
        "dots": G.ic_dots(0, 0, C, vertical=False),
        "flipCamera": G.ic_flip(0, 0, C),
        "flashOff": bolt,
        # The drawings only draw the flash off: on is the same bolt without its stroke.
        "flashOn": bolt[: bolt.index("/>") + 2],
        "reset": G.ic_reset(0, 0, C),
        "copy": G.ic_copy(0, 0, C),
        "compare": G.ic_compare(0, 0, C),
        "focus": G.ic_focus(0, 0, C),
        "aperture": G.ic_aperture(0, 0, C),
        "temperature": G.ic_thermo(0, 0, C),
        "loupe": G.ic_loupe(0, 0, C),
        "wbCloud": G.ic_wb_preset("cloud", 0, 0, C),
        "wbSun": G.ic_wb_preset("sun", 0, 0, C),
        "wbFluorescent": G.ic_wb_preset("fluor", 0, 0, C),
        "wbBulb": G.ic_wb_preset("bulb", 0, 0, C),
        "info": G.ic_info(0, 0, C),
        "heart": G.ic_heart(0, 0, C),
        "trash": G.ic_trash(0, 0, C),
        "develop": G.ic_develop(0, 0, C),
        # gen_flow.py
        "importPhotos": F.ic_import(0, 0, C),
        "gear": F.ic_gear(0, 0, C),
        "folder": F.ic_folder(0, 0, C),
        "photos": F.ic_photos(0, 0, C),
        "crop": F.ic_crop(0, 0, C),
        "rotate": F.ic_rotate_left(0, 0, C),
        "flip": F.ic_flip_h(0, 0, C),
        "orientation": F.ic_orient(0, 0, C),
        "paste": F.ic_paste(0, 0, C),
        "save": F.ic_save(0, 0, C),
        "search": F.ic_search(0, 0, C),
        "grid": F.ic_grid(0, 0, C),
        "stop": F.ic_stop(0, 0, C),
        "folderLink": F.ic_folder_link(0, 0, C),
        "copyIn": F.ic_copy_in(0, 0, C),
        "disk": F.ic_disk(0, 0, C),
        "diskOff": F.ic_disk(0, 0, C, off=True),
        "cloud": F.ic_cloud(0, 0, C),
        "alert": F.ic_alert(0, 0, C),
        "alertSmall": F.ic_alert(0, 0, C, r=7),                          # on a library tile
        # drawn in place by the drawings, not as a function
        "chevron": F.chev(-2.5, 0, C),                                    # chev(): tip at x + 5
        "close": f'<path d="M-4.5 -4.5 l9 9 M4.5 -4.5 l-9 9" stroke="{C}" stroke-width="1.8" stroke-linecap="round"/>',   # close_x()
        "check": f'<path d="M-4.5 0.3 l3 3 l6 -6.5" stroke="{C}" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',   # pick_circle()
        # tick_box(s=20): the box's centre is the origin
        "tick": f'<path d="M-5.2 0.4 l4 4 l6.8 -8" stroke="{C}" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
        # menu_box(): the check at x + 16 … x + 26.5, about its own centre
        "menuCheck": f'<path d="M-5.25 0.25 l3.5 3.5 l7 -8" stroke="{C}" stroke-width="1.8" fill="none" stroke-linecap="round" stroke-linejoin="round"/>',
        "stepCheck": GO.ic_check(0, 0, C),                                # a finished stage, in Exporting
        "filmEdge": GO.ic_filmedge(0, 0, C),                              # the Film Edge tool: a frame between two rows of holes
        # tab_effects(): the Format pill's chevron, about its own centre
        "chevronDown": f'<path d="M-4 -2 l4 4 l4 -4" stroke="{C}" stroke-width="1.5" fill="none" stroke-linecap="round"/>',
        # gen_pair_v2.ic_pair(): two half frames on one piece of film (design/pair v2; stated here because
        # the pair's generators may not be in the design folder this reads)
        "pair": (f'<g stroke="{C}" stroke-width="1.6" fill="none" stroke-linejoin="round">'
                 f'<rect x="-9.5" y="-7.5" width="8.5" height="15" rx="1.6"/><rect x="1" y="-7.5" width="8.5" height="15" rx="1.6"/></g>'),
        # gen_lighttable.ic_stand_loupe(): the light table's stand loupe, the website's Loupe tool glyph and the
        # one exception to Apple's own symbols (design/lighttable/README.md). At the drawings' 1.6, as every glyph
        # on a disc: the table's Loupe disc and the Library's way in, a disc beside Import since 2026-10-17.
        "standLoupe": stand_loupe(C, 1.6),
    }
    # The heart, filled: a favourite. The drawings draw the outline; the fill is its own path.
    heart = icons["heart"]
    icons["heartFilled"] = heart.replace('fill="none"', f'fill="{C}"')
    return icons, card


# ---------------------------------------------------------------------------- SVG -> segments
NUM = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")
CMD = re.compile(r"[MmLlHhVvCcQqAaZz]")


def arc_to_cubics(x1, y1, rx, ry, phi_deg, large, sweep, x2, y2):
    """An SVG endpoint arc as cubic Bezier segments (the SVG implementation notes, F.6)."""
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [("L", x2, y2)]
    phi = math.radians(phi_deg)
    cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    rx, ry = abs(rx), abs(ry)
    lam = x1p ** 2 / rx ** 2 + y1p ** 2 / ry ** 2
    if lam > 1:
        rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num = rx ** 2 * ry ** 2 - rx ** 2 * y1p ** 2 - ry ** 2 * x1p ** 2
    den = rx ** 2 * y1p ** 2 + ry ** 2 * x1p ** 2
    co = math.sqrt(max(0.0, num / den)) * (-1 if large == sweep else 1)
    cxp, cyp = co * rx * y1p / ry, -co * ry * x1p / rx
    cx, cy = cp * cxp - sp * cyp + (x1 + x2) / 2, sp * cxp + cp * cyp + (y1 + y2) / 2

    def angle(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    t1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi
    n = max(1, math.ceil(abs(dt) / (math.pi / 2) - 1e-9))
    step = dt / n
    k = 4 / 3 * math.tan(step / 4)
    out = []
    for i in range(n):
        a0, a1 = t1 + i * step, t1 + (i + 1) * step

        def pt(a, da=0.0, sign=0):
            # a point on the ellipse, plus `sign * k` along its tangent
            ex, ey = rx * math.cos(a), ry * math.sin(a)
            tx, ty = -rx * math.sin(a), ry * math.cos(a)
            px, py = ex + sign * k * tx, ey + sign * k * ty
            return cp * px - sp * py + cx, sp * px + cp * py + cy
        c1 = pt(a0, sign=1)
        c2 = pt(a1, sign=-1)
        e = pt(a1)
        out.append(("C", *c1, *c2, *e))
    return out


def parse_path(d: str):
    """SVG path data -> [("M", x, y) | ("L", x, y) | ("C", x1, y1, x2, y2, x, y) | ("Z",)], absolute."""
    tokens = re.findall(r"[MmLlHhVvCcQqAaZz]|" + NUM.pattern, d)
    out, i = [], 0
    x = y = sx = sy = 0.0
    cmd = None

    def take(n):
        nonlocal i
        vals = [float(tokens[i + k]) for k in range(n)]
        i += n
        return vals
    while i < len(tokens):
        if CMD.fullmatch(tokens[i]):
            cmd = tokens[i]
            i += 1
            if cmd in "Zz":
                out.append(("Z",))
                x, y = sx, sy
                continue
        if cmd is None:
            raise ValueError(f"path data starts without a command: {d!r}")
        rel = cmd.islower()
        c = cmd.upper()
        if c == "M":
            px, py = take(2)
            x, y = (x + px, y + py) if rel else (px, py)
            sx, sy = x, y
            out.append(("M", x, y))
            cmd = "l" if rel else "L"       # further pairs are lines
        elif c == "L":
            px, py = take(2)
            x, y = (x + px, y + py) if rel else (px, py)
            out.append(("L", x, y))
        elif c == "H":
            (px,) = take(1)
            x = x + px if rel else px
            out.append(("L", x, y))
        elif c == "V":
            (py,) = take(1)
            y = y + py if rel else py
            out.append(("L", x, y))
        elif c == "C":
            v = take(6)
            if rel:
                v = [v[0] + x, v[1] + y, v[2] + x, v[3] + y, v[4] + x, v[5] + y]
            out.append(("C", *v))
            x, y = v[4], v[5]
        elif c == "Q":
            v = take(4)
            if rel:
                v = [v[0] + x, v[1] + y, v[2] + x, v[3] + y]
            qx, qy, ex, ey = v
            out.append(("C", x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y), ex + 2 / 3 * (qx - ex), ey + 2 / 3 * (qy - ey), ex, ey))
            x, y = ex, ey
        elif c == "A":
            rx, ry, rot, large, sweep, ex, ey = take(7)
            if rel:
                ex, ey = ex + x, ey + y
            out += arc_to_cubics(x, y, rx, ry, rot, bool(large), bool(sweep), ex, ey)
            x, y = ex, ey
        else:
            raise ValueError(f"unsupported path command {cmd!r} in {d!r}")
    return out


def has_area(segs) -> bool:
    """True if any subpath could enclose something: a path of bare line segments does not."""
    pts = []
    for s in segs + [("M", 0, 0)]:
        if s[0] == "M":
            if len(pts) >= 3:
                (x0, y0), (x1, y1) = pts[0], pts[1]
                if any(abs((x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)) > 1e-6 for px, py in pts[2:]):
                    return True
            pts = [(s[1], s[2])] if len(s) > 1 else []
        elif s[0] == "L":
            pts.append((s[1], s[2]))
        elif s[0] == "C":
            return True
        elif s[0] == "Z" and len(pts) >= 3:
            return True
    return False


INHERIT = ("stroke", "stroke-width", "fill", "stroke-linecap", "stroke-linejoin", "stroke-dasharray",
           "opacity", "stroke-opacity", "fill-opacity")


def layers_of(svg: str, name: str, card: str):
    """The fragment as paint layers, in drawing order."""
    root = ET.fromstring(f"<svg>{svg}</svg>")
    out = []

    def walk(el, inherited):
        style = dict(inherited)
        for k in INHERIT:
            if k in el.attrib:
                style[k] = el.attrib[k]
        tag = el.tag
        if tag in ("svg", "g"):
            if "transform" in el.attrib:
                raise ValueError(f"{name}: transforms are not handled")
            for child in el:
                walk(child, style)
            return
        shape = None
        if tag == "path":
            segs = parse_path(el.attrib["d"])
            shape = ("path", segs)
            area = has_area(segs)
        elif tag == "circle":
            cx, cy, r = (float(el.attrib.get(k, 0)) for k in ("cx", "cy", "r"))
            shape = ("ellipse", cx - r, cy - r, 2 * r, 2 * r)
            area = True
        elif tag == "rect":
            x, y, w, h = (float(el.attrib.get(k, 0)) for k in ("x", "y", "width", "height"))
            shape = ("rect", x, y, w, h, float(el.attrib.get("rx", 0)))
            area = True
        elif tag == "line":
            x1, y1, x2, y2 = (float(el.attrib.get(k, 0)) for k in ("x1", "y1", "x2", "y2"))
            shape = ("path", [("M", x1, y1), ("L", x2, y2)])
            area = False
        elif tag == "polygon":
            nums = [float(v) for v in NUM.findall(el.attrib["points"])]
            pts = list(zip(nums[0::2], nums[1::2]))
            shape = ("path", [("M", *pts[0])] + [("L", *p) for p in pts[1:]] + [("Z",)])
            area = True
        else:
            raise ValueError(f"{name}: unsupported element <{tag}>")
        fill = style.get("fill")          # SVG's default is black; a bare line has nothing to fill
        if fill is None:
            if area:
                raise ValueError(f"{name}: a shape with area and no fill attribute would fill black")
            fill = "none"
        opacity = float(style.get("opacity", 1))
        if fill != "none":
            out.append(dict(shape=shape, paint="fill", ink=fill, opacity=opacity * float(style.get("fill-opacity", 1))))
        stroke = style.get("stroke", "none")
        if stroke != "none":
            dash = [float(v) for v in NUM.findall(style.get("stroke-dasharray", ""))]
            out.append(dict(shape=shape, paint="stroke", ink=stroke, width=float(style.get("stroke-width", 1)),
                            cap=style.get("stroke-linecap", "butt"), join=style.get("stroke-linejoin", "miter"),
                            dash=dash, opacity=opacity * float(style.get("stroke-opacity", 1))))
    walk(root, {})
    for layer in out:
        ink = layer["ink"]
        layer["ink"] = "current" if ink == CURRENT else "ground" if ink.lower() == card.lower() else ink
    return out


# ---------------------------------------------------------------------------- Swift
def n(v: float) -> str:
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def swift_shape(shape) -> str:
    kind = shape[0]
    if kind == "ellipse":
        _, x, y, w, h = shape
        return f".ellipse({n(x)}, {n(y)}, {n(w)}, {n(h)})"
    if kind == "rect":
        _, x, y, w, h, r = shape
        return f".rect({n(x)}, {n(y)}, {n(w)}, {n(h)}, {n(r)})"
    parts = []
    for s in shape[1]:
        if s[0] == "M":
            parts.append(f".m({n(s[1])}, {n(s[2])})")
        elif s[0] == "L":
            parts.append(f".l({n(s[1])}, {n(s[2])})")
        elif s[0] == "C":
            parts.append(".c(" + ", ".join(n(v) for v in s[1:]) + ")")
        else:
            parts.append(".z")
    return ".path([" + ", ".join(parts) + "])"


def swift_ink(ink: str) -> str:
    if ink in ("current", "ground"):
        return "." + ink
    if re.fullmatch(r"#[0-9a-fA-F]{6}", ink):
        return f".fixed(0x{ink[1:].upper()})"
    raise ValueError(f"unknown colour {ink!r}")


def swift_layer(layer) -> str:
    shape = swift_shape(layer["shape"])
    ink = swift_ink(layer["ink"])
    op = "" if layer["opacity"] == 1 else f", opacity: {n(layer['opacity'])}"
    if layer["paint"] == "fill":
        return f"DrawnIconLayer({shape}, .fill, {ink}{op})"
    cap = {"butt": ".butt", "round": ".round", "square": ".square"}[layer["cap"]]
    join = {"miter": ".miter", "round": ".round", "bevel": ".bevel"}[layer["join"]]
    dash = "" if not layer["dash"] else ", dash: [" + ", ".join(n(v) for v in layer["dash"]) + "]"
    return f"DrawnIconLayer({shape}, .stroke({n(layer['width'])}, {cap}, {join}{dash}), {ink}{op})"


HEADER = '''//  DrawnIcons.swift — the drawings' own glyphs.
//
//  GENERATED by tools/gen_icons.py from design/src/gen.py and gen_flow.py.
//  Do not edit: change the drawing, then run the tool.
//
//  Each glyph is the drawing's own geometry, in the drawing's 22 pt box centred
//  on (0, 0). `Icon` (SpkIcon.swift) draws them.

import CoreGraphics

enum DrawnIcon: String, CaseIterable, Sendable {
'''


def render(icons: dict[str, str], card: str) -> str:
    names = sorted(icons)
    out = [HEADER]
    for name in names:
        out.append(f"    case {name}\n")
    out.append("\n    var layers: [DrawnIconLayer] {\n        switch self {\n")
    for name in names:
        layers = layers_of(icons[name], name, card)
        out.append(f"        case .{name}: return [\n")
        for layer in layers:
            out.append(f"            {swift_layer(layer)},\n")
        out.append("        ]\n")
    out.append("        }\n    }\n}\n")
    return "".join(out)


# The board both sides draw (`DesignGalleryGlyphs` in DesignGallery.swift): six to a row,
# each glyph on a card disc, in the order of `DrawnIcon.allCases`.
BOARD_COLUMNS, BOARD_TOP, BOARD_PITCH, BOARD_DISC = 6, 100, 62, 17


def board(icons: dict[str, str]) -> str:
    """The glyphs as the drawings draw them, on one 393 x 852 page: what DS3 is held against."""
    G = importlib.import_module("gen")
    cell = G.W / BOARD_COLUMNS
    o = [G.frame_open("SpektraLab Mobile: the glyphs"), G.status_bar()]
    for i, name in enumerate(sorted(icons)):
        cx, cy = cell * (i % BOARD_COLUMNS + 0.5), BOARD_TOP + BOARD_PITCH * (i // BOARD_COLUMNS)
        o.append(f'<circle cx="{cx:.2f}" cy="{cy}" r="{BOARD_DISC}" fill="{G.CARD}"/>')
        o.append(f'<g transform="translate({cx:.2f} {cy})">{icons[name].replace(CURRENT, G.TEXT)}</g>')
    o += [G.home_indicator(), G.frame_close()]
    return "\n".join(o)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--design", default=None, help="the folder holding gen.py and gen_flow.py")
    ap.add_argument("--check", action="store_true", help="write nothing; fail if the file is out of date")
    ap.add_argument("--sheet", default=None, metavar="SVG",
                    help="also write every glyph on one page, drawn by the drawings' own code (for tools/compare.sh)")
    args = ap.parse_args()
    src = design_dir(args.design)
    if not (src / "gen_flow.py").exists():
        raise SystemExit(f"no gen_flow.py in {src}: pass --design or set DESIGN_DIR")
    icons, card = collect(src)
    text = render(icons, card)
    if args.sheet:
        Path(args.sheet).parent.mkdir(parents=True, exist_ok=True)
        Path(args.sheet).write_text(board(icons))
    if args.check:
        if not OUT.exists() or OUT.read_text() != text:
            raise SystemExit(f"{OUT.name} is not what {src} draws: run tools/gen_icons.py")
        print(f"{OUT.name}: {len(icons)} glyphs, up to date with {src}")
        return
    OUT.write_text(text)
    print(f"wrote {OUT} ({len(icons)} glyphs from {src})")


if __name__ == "__main__":
    main()
