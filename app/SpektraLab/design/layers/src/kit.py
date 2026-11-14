"""kit.py — the drawing kit under gen_layers.py: tokens, text, SF Symbols, and the Mac column's own parts.

Units. One unit is one **scene point** of the develop page (`PAGES.md` §1): at the 100 % interface scale it
stands at 0.9625 of a Mac point, so the 393-unit column is 378 Mac points — measured against
`screenshots/Screenshot_v2.png` (the column's wall at 377 Mac points) before anything here was drawn. Every
number of an existing part is that part's own, from its Swift file (named beside each function).

Text is `<text>` in the system font. SF Symbols are Apple's own, drawn by AppKit (`sf_symbols.swift`) and
embedded as images, one definition a drawing. Text widths are CoreText's (`text_width.swift`).
"""
import base64, hashlib, os, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.environ.get("LAYERS_BUILD") or os.path.join(tempfile.gettempdir(), "spk-layers-drawings")
os.makedirs(os.path.join(BUILD, "sym"), exist_ok=True)

# Theme.swift, dark.
BG, CARD, PLOT, RULE, FIELD, PANEL = "#1A1D22", "#30343B", "#22262C", "#3A3F47", "#3A3F47", "#14161A"
TEXT, TEXT2, DIM, FAINT = "#F9F7F3", "#DAD8D4", "#898989", "#6D6D6B"
ACCENT, SEL, ONSEL, SELFRAME, DANGER = "#E1A95F", "#FFFFFF", "#0F0E0E", "#FAF8F4", "#E8796B"
WALL, TOGGLE_OFF = "#0E1013", "#3E434B"
DISABLED = 0.38
FONT = "-apple-system, 'SF Pro Text', 'PingFang SC', 'Helvetica Neue', sans-serif"
WEIGHT = {400: "regular", 500: "medium", 600: "semibold", 700: "bold"}


def tool(name):
    """A helper beside this file, built once into BUILD."""
    out = os.path.join(BUILD, name)
    src = os.path.join(HERE, name + ".swift")
    if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
        subprocess.run(["swiftc", "-O", src, "-o", out], check=True, stderr=subprocess.DEVNULL)
    return out


_tw_proc = None
_tw_cache = {}


def tw(text, size, weight=500):
    """The line's width in the system font, in units."""
    global _tw_proc
    key = (text, size, weight)
    if key in _tw_cache:
        return _tw_cache[key]
    if _tw_proc is None:
        _tw_proc = subprocess.Popen([tool("text_width")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    _tw_proc.stdin.write(f"{size}\t{WEIGHT[weight]}\t{text}\n")
    _tw_proc.stdin.flush()
    w = float(_tw_proc.stdout.readline())
    _tw_cache[key] = w
    return w


_sym_proc = None
_sym_cache = {}


def symbol_png(name, pt, weight, color):
    """(id, width, height, base64 PNG) of an SF Symbol at a point size, weight and colour."""
    global _sym_proc
    key = (name, pt, weight, color)
    if key in _sym_cache:
        return _sym_cache[key]
    if _sym_proc is None:
        _sym_proc = subprocess.Popen([tool("sf_symbols")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    ident = "s" + hashlib.md5(repr(key).encode()).hexdigest()[:10]
    path = os.path.join(BUILD, "sym", ident + ".png")
    _sym_proc.stdin.write(f"{name}\t{pt}\t{WEIGHT[weight]}\t{color.lstrip('#')}\t4\t{path}\n")
    _sym_proc.stdin.flush()
    answer = _sym_proc.stdout.readline().split()
    if not answer or answer[0] == "MISSING":
        raise SystemExit(f"SF Symbol not on this Mac: {name}")
    w, h = float(answer[-2]), float(answer[-1])
    with open(path, "rb") as f:
        data = base64.b64encode(f.read()).decode()
    _sym_cache[key] = (ident, w, h, data)
    return _sym_cache[key]


def wrap(text, size, weight, room):
    """The lines a paragraph takes in `room`, as `Note` wraps it: at a word in English, at a character in
    Chinese (never leaving a closing mark to start a line)."""
    lines, line = [], ""
    tokens, word = [], ""
    for ch in text:
        if ch == " ":
            if word:
                tokens.append(word)
            tokens.append(" ")
            word = ""
        elif ord(ch) > 0x2E7F:
            if word:
                tokens.append(word)
                word = ""
            if ch in "，。：；、」）！？" and tokens:
                tokens[-1] += ch
            else:
                tokens.append(ch)
        else:
            word += ch
    if word:
        tokens.append(word)
    for tk in tokens:
        if tw((line + tk).rstrip(), size, weight) > room - 1 and line.strip():
            lines.append(line.rstrip())
            line = "" if tk == " " else tk
        else:
            line += tk
    if line.strip():
        lines.append(line.rstrip())
    return lines


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Drawing:
    def __init__(self, w, h, ground="#08090B"):
        self.w, self.h = w, h
        self.parts, self.defs, self.used = [], [], set()
        self.n = 0
        self.rect(0, 0, w, h, ground)

    # -- primitives
    def add(self, s):
        self.parts.append(s)

    def uid(self, p="u"):
        self.n += 1
        return f"{p}{self.n}"

    def rect(self, x, y, w, h, fill, r=0, stroke=None, sw=1, op=1, dash=None):
        a = f'<rect x="{x:.2f}" y="{y:.2f}" width="{max(w, 0):.2f}" height="{max(h, 0):.2f}" fill="{fill or "none"}"'
        if r:
            a += f' rx="{min(r, h / 2, w / 2):.2f}"'
        if stroke:
            a += f' stroke="{stroke}" stroke-width="{sw}"'
        if dash:
            a += f' stroke-dasharray="{dash}"'
        if op != 1:
            a += f' opacity="{op}"'
        self.add(a + "/>")

    def line(self, x1, y1, x2, y2, stroke=RULE, sw=1, op=1, dash=None, cap=None):
        a = f'<line x1="{x1:.2f}" y1="{y1:.2f}" x2="{x2:.2f}" y2="{y2:.2f}" stroke="{stroke}" stroke-width="{sw}"'
        if dash:
            a += f' stroke-dasharray="{dash}"'
        if cap:
            a += f' stroke-linecap="{cap}"'
        if op != 1:
            a += f' opacity="{op}"'
        self.add(a + "/>")

    def circle(self, cx, cy, r, fill, stroke=None, sw=1, op=1):
        a = f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{r:.2f}" fill="{fill or "none"}"'
        if stroke:
            a += f' stroke="{stroke}" stroke-width="{sw}"'
        if op != 1:
            a += f' opacity="{op}"'
        self.add(a + "/>")

    def path(self, dstr, fill="none", stroke=None, sw=1, op=1, join="round", cap="round"):
        a = f'<path d="{dstr}" fill="{fill}"'
        if stroke:
            a += f' stroke="{stroke}" stroke-width="{sw}" stroke-linejoin="{join}" stroke-linecap="{cap}"'
        if op != 1:
            a += f' opacity="{op}"'
        self.add(a + "/>")

    def text(self, x, y, s, size=13, weight=500, fill=TEXT, anchor="start", op=1, spacing=None, mono=False):
        """A line with its baseline at y."""
        a = (f'<text x="{x:.2f}" y="{y:.2f}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" '
             f'fill="{fill}"')
        if anchor != "start":
            a += f' text-anchor="{anchor}"'
        if spacing:
            a += f' letter-spacing="{spacing}"'
        if mono:
            a += ' style="font-variant-numeric: tabular-nums"'
        if op != 1:
            a += f' opacity="{op}"'
        self.add(a + f">{esc(s)}</text>")

    def ctext(self, x, cy, s, size=13, weight=500, fill=TEXT, anchor="start", op=1, mono=False):
        """A line centred on cy (the system font's x-height and a Chinese glyph's box agree on 0.35 em)."""
        self.text(x, cy + size * 0.35, s, size, weight, fill, anchor, op, mono=mono)

    def sym(self, name, cx, cy, pt=13, weight=500, color=TEXT, op=1, rotate=0):
        ident, w, h, data = symbol_png(name, pt, weight, color)
        if ident not in self.used:
            self.used.add(ident)
            self.defs.append(f'<image id="{ident}" width="{w}" height="{h}" href="data:image/png;base64,{data}"/>')
        a = f'<use href="#{ident}" x="{cx - w / 2:.2f}" y="{cy - h / 2:.2f}"'
        if rotate:
            a += f' transform="rotate({rotate} {cx:.2f} {cy:.2f})"'
        if op != 1:
            a += f' opacity="{op}"'
        self.add(a + "/>")
        return w, h

    def open(self, op=None, clip=None, translate=None, extra=""):
        a = "<g"
        if op is not None:
            a += f' opacity="{op}"'
        if clip:
            a += f' clip-path="url(#{clip})"'
        if translate:
            a += f' transform="translate({translate[0]:.2f},{translate[1]:.2f})"'
        self.add(a + extra + ">")

    def close(self):
        self.add("</g>")

    def clip(self, x, y, w, h, r=0):
        ident = self.uid("c")
        self.defs.append(f'<clipPath id="{ident}"><rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" '
                         f'rx="{r:.2f}"/></clipPath>')
        return ident

    def gradient(self, stops, x1=0, y1=0, x2=0, y2=1):
        ident = self.uid("g")
        s = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
        self.defs.append(f'<linearGradient id="{ident}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{s}</linearGradient>')
        return f"url(#{ident})"

    def svg(self):
        return (f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
                f'width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}">\n<defs>'
                + "".join(self.defs) + "</defs>\n" + "\n".join(self.parts) + "\n</svg>\n")


# ---------------------------------------------------------------------------------------------------------
# Stand-in photographs: vector, so a drawing is a few kilobytes and depends on nobody's pictures. They stand
# for the engine's develop, which a drawing does not run.

def pic_city(d, x, y, w, h):
    sky = d.gradient([(0, "#16264a"), (0.55, "#6b5a7a"), (0.74, "#e0935a"), (0.75, "#1b2a45"), (1, "#0c1322")])
    d.rect(x, y, w, h, sky)
    hz = y + h * 0.745
    seq = [0.30, 0.52, 0.38, 0.78, 0.46, 0.34, 0.62, 0.27, 0.56, 0.90, 0.42, 0.36, 0.66, 0.31, 0.48, 0.58, 0.29, 0.40]
    n = len(seq)
    bw = w / n
    for i, f in enumerate(seq):
        bh = h * 0.42 * f
        d.rect(x + i * bw + bw * 0.08, hz - bh, bw * 0.84, bh, "#0f1730")
        if i % 3 != 1:
            d.rect(x + i * bw + bw * 0.3, hz - bh * 0.8, bw * 0.4, bh * 0.55, "#f1c27b", op=0.55)
    d.rect(x + w * 0.535, y + h * 0.08, w * 0.012, h * 0.3, "#f1c27b", op=0.5)


def pic_portrait(d, x, y, w, h):
    ground = d.gradient([(0, "#e6dfd2"), (1, "#b3aa9a")])
    d.rect(x, y, w, h, ground)
    cx = x + w * 0.5
    r = min(w, h) * 0.19
    d.circle(cx, y + h * 0.36, r, "#1d1a18")
    d.path(f"M{cx - r * 2.3:.1f},{y + h:.1f} C{cx - r * 2.2:.1f},{y + h * 0.62:.1f} {cx - r * 1.1:.1f},{y + h * 0.57:.1f} "
           f"{cx:.1f},{y + h * 0.57:.1f} C{cx + r * 1.1:.1f},{y + h * 0.57:.1f} {cx + r * 2.2:.1f},{y + h * 0.62:.1f} "
           f"{cx + r * 2.3:.1f},{y + h:.1f} Z", fill="#1d1a18")


def pic_hills(d, x, y, w, h):
    sky = d.gradient([(0, "#9fb6cf"), (1, "#e9d9c4")])
    d.rect(x, y, w, h, sky)
    d.circle(x + w * 0.72, y + h * 0.3, min(w, h) * 0.09, "#fbeecf")
    d.path(f"M{x:.1f},{y + h:.1f} L{x:.1f},{y + h * 0.7:.1f} L{x + w * 0.28:.1f},{y + h * 0.42:.1f} L{x + w * 0.5:.1f},{y + h * 0.66:.1f} "
           f"L{x + w * 0.7:.1f},{y + h * 0.5:.1f} L{x + w:.1f},{y + h * 0.74:.1f} L{x + w:.1f},{y + h:.1f} Z", fill="#4d6076")
    d.path(f"M{x:.1f},{y + h:.1f} L{x:.1f},{y + h * 0.86:.1f} L{x + w * 0.4:.1f},{y + h * 0.7:.1f} L{x + w:.1f},{y + h * 0.9:.1f} "
           f"L{x + w:.1f},{y + h:.1f} Z", fill="#2f3d4f")


def pic_street(d, x, y, w, h):
    ground = d.gradient([(0, "#40342c"), (0.5, "#a0764d"), (1, "#2a2320")])
    d.rect(x, y, w, h, ground)
    d.rect(x + w * 0.12, y + h * 0.2, w * 0.3, h * 0.8, "#211b18")
    d.rect(x + w * 0.6, y + h * 0.32, w * 0.3, h * 0.68, "#2e2622")
    d.rect(x + w * 0.2, y + h * 0.3, w * 0.12, h * 0.16, "#ffd89a", op=0.8)
    d.rect(x + w * 0.68, y + h * 0.44, w * 0.1, h * 0.12, "#ffd89a", op=0.6)


PICS = {"city": pic_city, "portrait": pic_portrait, "hills": pic_hills, "street": pic_street}


def picture(d, kind, x, y, w, h, r=0, op=1, blend=None):
    c = d.clip(x, y, w, h, r)
    d.open(op=None if op == 1 else op, clip=c, extra=f' style="mix-blend-mode:{blend}"' if blend else "")
    PICS[kind](d, x, y, w, h)
    d.close()


def double_picture(d, x, y, w, h, share=0.5, bottom="portrait", top="city", r=0, flipped=False, top_zoom=1.0):
    """Two exposures on one frame: the bottom, and the top's light added over it at its share (a stand-in for
    the engine's sum on film: `screen` where the renderer has it, plain opacity where it has not)."""
    c = d.clip(x, y, w, h, r)
    d.open(clip=c)
    d.rect(x, y, w, h, "#000")
    d.open(op=0.35 + 0.65 * min((1 - share) / 0.5, 1))
    PICS[bottom](d, x, y, w, h)
    d.close()
    zw, zh = w * top_zoom, h * top_zoom
    zx, zy = x - (zw - w) / 2, y - (zh - h) / 2
    extra = ' style="mix-blend-mode:screen"'
    if flipped:
        extra += f' transform="translate({2 * x + w:.2f},0) scale(-1,1)"'
    d.open(op=min(0.25 + share * 1.1, 1), extra=extra)
    PICS[top](d, zx, zy, zw, zh)
    d.close()
    d.close()


def pair_picture(d, x, y, w, h, left="hills", right="street", turned=False, gap=0.03, r=0, empty=None):
    """A half-frame pair's piece: two frames on one piece of film, side by side, or one over the other."""
    c = d.clip(x, y, w, h, r)
    d.open(clip=c)
    d.rect(x, y, w, h, "#0a0a0b")
    if turned:
        g = h * gap
        hh = (h - g) / 2
        boxes = [(x, y, w, hh), (x, y + hh + g, w, hh)]
    else:
        g = w * gap
        hw = (w - g) / 2
        boxes = [(x, y, hw, h), (x + hw + g, y, hw, h)]
    for i, (kind, b) in enumerate(zip([left, right], boxes)):
        if empty == i:
            d.rect(*b, "#141210")
        else:
            cc = d.clip(*b)
            d.open(clip=cc)
            PICS[kind](d, *b)
            d.close()
    d.close()
    return boxes


# ---------------------------------------------------------------------------------------------------------
# The Mac column's existing parts (their Swift files named), and the window round it.

CW = 393          # WindowLayout.columnWidth


def chevron(d, cx, cy, open_, color=DIM, pt=10, weight=700):
    """FoldHeader's chevron.right, turned down while open (Rows.swift)."""
    d.sym("chevron.right", cx, cy, pt, weight, color, rotate=90 if open_ else 0)


def fold_rule(d, y, x0=0, x1=CW):
    d.rect(x0, y, x1 - x0, 0.5, RULE)
    return 0.5


def fold_header(d, y, title, open_=True, rule=True, indent=0, title_color=None, op=1, symbol=None):
    """ColumnSectionHeader over FoldHeader (FilmEdgeColumn.swift, Rows.swift): 0.5 pt rule, 32 pt header,
    the chevron in a 12 pt frame from 16, the name from 34. Returns (height, centre y)."""
    h = 0
    if rule:
        h += fold_rule(d, y)
    cy = y + h + 16
    if op != 1:
        d.open(op=op)
    chevron(d, 16 + indent + 6, cy, open_)
    x = 16 + indent + 12 + 6
    if symbol:
        d.sym(symbol, x + 9, cy, 12, 500, TEXT if open_ else TEXT2)
        x += 18 + 6
    d.ctext(x, cy, title, 12.5, 600 if open_ else 500, title_color or (TEXT if open_ else TEXT2))
    if op != 1:
        d.close()
    return h + 32, cy


def toggle(d, xr, cy, on, compact=True, op=1):
    """SpkToggle (Indicators.swift): compact is 34 × 20, right edge at xr."""
    w, h = (34, 20) if compact else (51, 31)
    if op != 1:
        d.open(op=op)
    d.rect(xr - w, cy - h / 2, w, h, ACCENT if on else TOGGLE_OFF, r=h / 2)
    k = h - 4
    d.circle((xr - 2 - k / 2) if on else (xr - w + 2 + k / 2), cy, k / 2, "#FFFFFF")
    if op != 1:
        d.close()
    return w


def small_round(d, cx, cy, symbol, diameter=22, color=TEXT, fill=CARD, op=1, pt=10, weight=600):
    """AdjustSectionHeader's small button: a 10 pt semibold symbol on a 22 pt disc."""
    if op != 1:
        d.open(op=op)
    d.circle(cx, cy, diameter / 2, fill)
    d.sym(symbol, cx, cy, pt, weight, color)
    if op != 1:
        d.close()


def slider(d, y, title, frac, value, sub=None, rest=0.5, tint=None, x0=16, x1=CW - 16, label_w=92, field_w=78,
           op=1, knob_big=False, height=40):
    """ValueSlider (ValueSlider.swift): the label right-aligned in `label_w`, 8, a 3 pt track with the knob
    (9 × 19) at the value and a hairline at rest, 8, the number's box (24 high). Row 40 high; returns 40."""
    cy = y + height / 2
    if op != 1:
        d.open(op=op)
    lx = x0 + label_w
    if sub:
        d.text(lx, cy - 1.5, title, 13.5, 600, TEXT, "end")
        d.text(lx, cy + 11.5, sub, 10.5, 500, DIM, "end")
    else:
        d.ctext(lx, cy, title, 13.5, 600, TEXT, "end")
    tx0, tx1 = lx + 8, x1 - field_w - 8
    if tint:
        d.rect(tx0, cy - 1.5, tx1 - tx0, 3, d.gradient([(0, tint[0]), (1, tint[1])], 0, 0, 1, 0))
    else:
        d.rect(tx0, cy - 1.5, tx1 - tx0, 3, RULE)
    if rest is not None:
        d.rect(tx0 + (tx1 - tx0) * rest - 0.5, cy - 5.5, 1, 11, TEXT2, op=0.55)
    kx = tx0 + (tx1 - tx0) * frac
    s = 1.12 if knob_big else 1
    d.rect(kx - 4.5 * s, cy - 9.5 * s, 9 * s, 19 * s, "#FFFFFF", r=3)
    d.rect(x1 - field_w, cy - 12, field_w, 24, CARD, r=6)
    d.ctext(x1 - 7, cy, value, 12.5, 600, TEXT, "end", mono=True)
    if op != 1:
        d.close()
    return height


def chip(d, x, cy, title, on=False, dim=False, h=28, size=12.5, pad=12, fill=CARD, color=None, symbol=None):
    """Chip (Chips.swift), at Decode's size (28 high, 12.5, 12 of padding). Returns its width."""
    w = tw(title, size, 600 if on else 500) + 2 * pad + (16 if symbol else 0)
    d.rect(x, cy - h / 2, w, h, SEL if on else fill, r=h / 2)
    ink = ONSEL if on else (color or (DIM if dim else TEXT2))
    tx = x + pad
    if symbol:
        d.sym(symbol, tx + 5.5, cy, 11, 600, ink)
        tx += 16
    d.ctext(tx, cy, title, size, 600 if on else 500, ink)
    return w


def chips(d, x, cy, titles, on=None, dim=(), gap=8, **kw):
    for i, t_ in enumerate(titles):
        x += chip(d, x, cy, t_, on=(i == on), dim=(i in dim), **kw) + gap
    return x - gap


def pill_menu(d, xr, cy, label, op=1):
    """PillMenu (PairPanels.swift): a value and its chevron in a 22 pt card capsule; right edge at xr."""
    w = 12 + tw(label, 12, 500) + 5.5 + 7 + 9.5
    if op != 1:
        d.open(op=op)
    d.rect(xr - w, cy - 11, w, 22, CARD, r=11)
    d.ctext(xr - w + 12, cy, label, 12, 500, TEXT2)
    d.sym("chevron.down", xr - 9.5 - 3.5, cy, 8, 600, TEXT2)
    if op != 1:
        d.close()
    return w


def segmented(d, xr, cy, titles, on, seg=76, h=28, track=CARD, size=12.5):
    """SegmentedSwitch (Segmented.swift): one track, the white thumb 2 pt inside; right edge at xr."""
    w = seg * len(titles)
    x = xr - w
    d.rect(x, cy - h / 2, w, h, track, r=h / 2)
    for i, t_ in enumerate(titles):
        if i == on:
            d.rect(x + i * seg + 2, cy - h / 2 + 2, seg - 4, h - 4, SEL, r=(h - 4) / 2)
        d.ctext(x + i * seg + seg / 2, cy, t_, size, 600 if i == on else 500, ONSEL if i == on else TEXT2, "middle")
    return w


def note(d, x, y, lines, size=11.5, color=DIM, lead=None, op=1):
    """Note (Rows.swift): lines `lead` apart (1.42 × the size). `y` is the first line's top. Returns the height."""
    lead = lead or size * 1.42
    for i, ln in enumerate(lines):
        d.text(x, y + size * 0.92 + i * lead, ln, size, 400, color, op=op)
    return lead * len(lines)


def capsule_button(d, x, cy, title, w=None, h=28, primary=False, size=12.5, op=1, symbol=None):
    """A small capsule button: the accent for the one action, the card otherwise."""
    w = w or tw(title, size, 600) + 28 + (16 if symbol else 0)
    if op != 1:
        d.open(op=op)
    d.rect(x, cy - h / 2, w, h, ACCENT if primary else CARD, r=h / 2)
    ink = ONSEL if primary else TEXT
    if symbol:
        tx = x + (w - tw(title, size, 600) - 16) / 2
        d.sym(symbol, tx + 5.5, cy, 11, 600, ink)
        d.ctext(tx + 16, cy, title, size, 600, ink)
    else:
        d.ctext(x + w / 2, cy, title, size, 600, ink, "middle")
    if op != 1:
        d.close()
    return w


def disc(d, cx, cy, symbol, diameter=36, lit=False, op=1, color=TEXT):
    """A round bar button (Theme.Metric.barRound, 36): the symbol at 36/44 of the 44 pt disc's 19."""
    if op != 1:
        d.open(op=op)
    d.circle(cx, cy, diameter / 2, ACCENT if lit else CARD)
    d.sym(symbol, cx, cy, 15, 500, ONSEL if lit else color)
    if op != 1:
        d.close()


def histogram_card(d, y, folded=True):
    """HistogramPanel (HistogramPanel.swift): head 32, plot 84, footer 22, the card 12 from each side and 6
    above and below. Returns its height in the column."""
    h = 32 + (0 if folded else 84 + 22)
    d.rect(12, y + 6, CW - 24, h, PLOT, r=12)
    cy = y + 6 + 16
    d.sym("chevron.down", 26 + 6.5, cy, 10, 600, TEXT2, rotate=-90 if folded else 0)
    return h + 12, cy


def nav_band(d, y, titles, on):
    """DevelopWorkspace.navigationBand: a 30 pt card capsule 16 from each side, the chosen step a 26 pt white
    capsule, then a half-point rule 8 under the row's 44. 56 high in the column."""
    cy = y + 22
    d.rect(16, cy - 15, CW - 32, 30, CARD, r=15)
    seg = (CW - 32) / len(titles)
    for i, t_ in enumerate(titles):
        cx = 16 + seg * i + seg / 2
        if i == on:
            w = max(tw(t_, 13, 600) + 20, 44)
            d.rect(cx - w / 2, cy - 13, w, 26, SEL, r=13)
        d.ctext(cx, cy, t_, 13, 600 if i == on else 500, ONSEL if i == on else TEXT2, "middle")
    d.rect(0, y + 52, CW, 0.5, RULE)
    return 56
