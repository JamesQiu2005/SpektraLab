#!/usr/bin/env python3
"""Develop's icon (desktop/src-tauri/icons/develop.svg: red, green and blue light, screen-blended) as exact vector
regions, for Android adaptive icons (VectorDrawable has no blend modes) and SVG previews.

    python3 -I make-icons.py <out dir>
"""
import math, pathlib, sys

R = 112.0
CIRCLES = {"r": ((256.0, 196.0), (0xff, 0x2a, 0x2a)), "g": ((316.6, 301.0), (0x22, 0xe0, 0x4a)),
           "b": ((195.4, 301.0), (0x2a, 0x5c, 0xff))}
# The 3 circles fit a radius 182 around their centroid (256, 266); Android's safe zone is a 66 dp circle on a
# 108 dp canvas: scale so that radius is 30 dp, centred.
CX, CY = 256.0, 266.0
S = 30.0 / 182.0

def tx(p): return (54.0 + (p[0] - CX) * S, 54.0 + (p[1] - CY) * S)
def screen(*cs): return tuple(round(255 * (1 - math.prod(1 - c[i] / 255 for c in cs))) for i in range(3))
def hexc(c): return "#%02X%02X%02X" % c
def inside(p, k): (x, y), _ = CIRCLES[k]; return math.hypot(p[0] - x, p[1] - y) < R - 1e-6

def meet(a, b):
    (x1, y1), _ = CIRCLES[a]; (x2, y2), _ = CIRCLES[b]
    d = math.hypot(x2 - x1, y2 - y1); h = math.sqrt(R * R - (d / 2) ** 2)
    mx, my = (x1 + x2) / 2, (y1 + y2) / 2; ux, uy = (x2 - x1) / d, (y2 - y1) / d
    return (mx - uy * h, my + ux * h), (mx + uy * h, my - ux * h)

def arc(k, p, q, within):
    """SVG arc on circle k from p to q, the way whose midpoint lies inside every circle in `within`."""
    (cx, cy), _ = CIRCLES[k]
    a1, a2 = math.atan2(p[1] - cy, p[0] - cx), math.atan2(q[1] - cy, q[0] - cx)
    d = (a2 - a1) % (2 * math.pi)
    for sweep, span, mid in ((1, d, a1 + d / 2), (0, 2 * math.pi - d, a1 - (2 * math.pi - d) / 2)):
        m = (cx + R * math.cos(mid), cy + R * math.sin(mid))
        if all(inside(m, w) for w in within):
            e = tx(q); r = R * S
            return "A%.4f,%.4f 0 %d,%d %.4f,%.4f" % (r, r, 1 if span > math.pi else 0, sweep, e[0], e[1])
    raise SystemExit("no arc")

def circle(k):
    (x, y), _ = CIRCLES[k]; c = tx((x, y)); r = R * S
    return "M%.4f,%.4f a%.4f,%.4f 0 1,0 %.4f,0 a%.4f,%.4f 0 1,0 %.4f,0 Z" % (c[0] - r, c[1], r, r, 2 * r, r, r, -2 * r)

def regions():
    out = [(circle(k), hexc(CIRCLES[k][1])) for k in "rgb"]
    for a, b in ("rg", "rb", "gb"):
        p, q = meet(a, b); s = tx(p)
        out.append(("M%.4f,%.4f %s %s Z" % (s[0], s[1], arc(a, p, q, [b]), arc(b, q, p, [a])),
                    hexc(screen(CIRCLES[a][1], CIRCLES[b][1]))))
    third = {"rg": "b", "rb": "g", "gb": "r"}
    v = {}
    for pair, k in third.items():
        v[pair] = next(p for p in meet(*pair) if inside(p, k) or math.hypot(p[0] - CIRCLES[k][0][0], p[1] - CIRCLES[k][0][1]) < R)
    # centre: V_rg -(on r)- V_rb -(on b)- V_gb -(on g)- V_rg
    s = tx(v["rg"])
    centre = "M%.4f,%.4f %s %s %s Z" % (s[0], s[1], arc("r", v["rg"], v["rb"], ["g", "b"]),
                                         arc("b", v["rb"], v["gb"], ["r", "g"]), arc("g", v["gb"], v["rg"], ["r", "b"]))
    out.append((centre, hexc(screen(*(c for _, c in CIRCLES.values())))))
    return out

BACKGROUNDS = {"camera": ("#F1E6CF", "#E3D4B6"), "editor": ("#5A7A50", "#3D5636")}  # centre, edge (cream / green)

def vector(paths, body=""):
    return ('<?xml version="1.0" encoding="utf-8"?>\n<!-- Develop\'s icon: red, green and blue light overlapping '
            '(made by make-icons.py). -->\n<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            '    xmlns:aapt="http://schemas.android.com/aapt"\n    android:width="108dp" android:height="108dp"\n'
            '    android:viewportWidth="108" android:viewportHeight="108">\n' + body +
            "".join('    <path android:fillColor="%s" android:pathData="%s"/>\n' % (c, d) for d, c in paths) + "</vector>\n")

def background(centre, edge):
    return vector([], '    <path android:pathData="M0,0h108v108h-108z">\n        <aapt:attr name="android:fillColor">\n'
                  '            <gradient android:type="radial" android:centerX="54" android:centerY="43.2"\n'
                  '                android:gradientRadius="86.4" android:startColor="%s" android:endColor="%s"/>\n'
                  '        </aapt:attr>\n    </path>\n' % (centre, edge))

def monochrome():
    return vector([], "".join('    <path android:fillColor="#FFFFFFFF" android:fillAlpha="0.5" android:pathData="%s"/>\n'
                              % circle(k) for k in "rgb"))

ADAPTIVE = ('<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@drawable/ic_launcher_background"/>\n'
            '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
            '    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n</adaptive-icon>\n')

def preview(paths, centre, edge):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" width="432" height="432">'
            '<defs><radialGradient id="bg" cx="0.5" cy="0.4" r="0.8"><stop offset="0" stop-color="%s"/>'
            '<stop offset="1" stop-color="%s"/></radialGradient></defs>'
            '<circle cx="54" cy="54" r="54" fill="url(#bg)"/>' % (centre, edge) +
            "".join('<path fill="%s" d="%s"/>' % (c, d) for d, c in paths) + "</svg>\n")

def main():
    out = pathlib.Path(sys.argv[1]); paths = regions()
    for app, (centre, edge) in BACKGROUNDS.items():
        res = out / app / "res"
        (res / "drawable").mkdir(parents=True, exist_ok=True); (res / "mipmap-anydpi").mkdir(parents=True, exist_ok=True)
        (res / "drawable/ic_launcher_foreground.xml").write_text(vector(paths))
        (res / "drawable/ic_launcher_background.xml").write_text(background(centre, edge))
        (res / "drawable/ic_launcher_monochrome.xml").write_text(monochrome())
        (res / "mipmap-anydpi/ic_launcher.xml").write_text(ADAPTIVE)
        (res / "mipmap-anydpi/ic_launcher_round.xml").write_text(ADAPTIVE)
        (out / app / "preview.svg").write_text(preview(paths, centre, edge))
    print("\n".join("%s %s" % (c, d[:50]) for d, c in paths))

main()
