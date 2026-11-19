#!/usr/bin/env python3
"""Digitise motion-picture negative data sheets (Kodak H-1 / TI sheets, Fujifilm ETERNA/F-series curve
sheets) from the PDF's vector paths.

    python digitise_cine.py SHEETS.json OUT_DIR [--plots]

SHEETS.json: [{"stock": ..., "name": ..., "pdf": ..., "tungsten": bool, ...}, ...]. Every framed chart
on every page is found (a stroked rectangle, or a tinted filled one), its kind read from the titles
around it (wavelength + sensitivity, wavelength + density, exposure/camera stops + density), its axes
fitted through its grid lines and tick labels, and its curves sampled from the paths. A characteristic
chart on camera stops is put on log H with the exact 0.30103 per stop, the offset from the log-exposure
labels Kodak sets above it.
"""
from __future__ import annotations

import argparse
import colorsys
import json
import re
import sys
from pathlib import Path

import numpy as np
import pymupdf

sys.path.insert(0, str(Path(__file__).resolve().parent))
from digitise import Half, numeric, sample_items, chain, dash_kind  # noqa: E402

LOG2 = float(np.log10(2.0))


def colour_kind(c):
    if c is None:
        return "k"
    r, g, b = c
    if max(c) - min(c) < 0.15:
        return "k"
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    h *= 360
    if h < 30 or h >= 300:
        return "r"
    if 70 <= h < 170:
        return "g"
    if 170 <= h < 200:
        return "c"
    if 200 <= h < 270:
        return "b"
    return "o"


def frames(page):
    W, H = page.rect.width, page.rect.height
    out = []
    for d in page.get_drawings():
        cands = [it[1] for it in d["items"] if it[0] == "re"]
        if not cands and d["type"] in ("f", "fs") and len(d["items"]) <= 5:
            cands = [d["rect"]]
        for r in cands:
            if r.width < 70 or r.height < 55 or r.width * r.height > 0.4 * W * H:
                continue
            stroked = d["type"] in ("s", "fs") and (d.get("color") is not None)
            tinted = d["type"] in ("f", "fs") and d.get("fill") is not None and min(d["fill"]) < 0.97 and max(d["fill"]) > 0.6
            if stroked or tinted:
                out.append(pymupdf.Rect(r))
    # boxes drawn as four separate lines (Kodak's 1990s sheets)
    hs, vs, linebox = [], [], []
    for d in page.get_drawings():
        if d["type"] not in ("s", "fs"):
            continue
        for it in d["items"]:
            if it[0] != "l":
                continue
            p, q = it[1], it[2]
            if abs(p.y - q.y) < 0.05 and abs(p.x - q.x) > 70:
                hs.append((min(p.x, q.x), max(p.x, q.x), p.y))
            if abs(p.x - q.x) < 0.05 and abs(p.y - q.y) > 55:
                vs.append((min(p.y, q.y), max(p.y, q.y), p.x))
    for (ax0, ax1, ay) in hs:
        for (bx0, bx1, by) in hs:
            if by - ay < 55 or abs(ax0 - bx0) > 2 or abs(ax1 - bx1) > 2:
                continue
            left = any(abs(vx - ax0) < 2 and vy0 <= ay + 2 and vy1 >= by - 2 for vy0, vy1, vx in vs)
            right = any(abs(vx - ax1) < 2 and vy0 <= ay + 2 and vy1 >= by - 2 for vy0, vy1, vx in vs)
            if left and right:
                linebox.append(pymupdf.Rect(ax0, ay, ax1, by))
    # boxes between grid lines are inside the chart's own: keep only the outermost
    for r in linebox:
        if not any(k is not r and k.contains(r) and k.width * k.height > r.width * r.height for k in linebox):
            out.append(r)
    # dedupe near-identical rects
    keep = []
    for r in sorted(out, key=lambda r: -r.width * r.height):
        if not any(abs(r.x0 - k.x0) < 3 and abs(r.y0 - k.y0) < 3 and abs(r.x1 - k.x1) < 3 and abs(r.y1 - k.y1) < 3 for k in keep):
            keep.append(r)
    # a frame nested in a bigger one on the same chart (a tint behind the plot): keep the inner
    keep2 = []
    for r in keep:
        inner = [k for k in keep if k is not r and k.x0 >= r.x0 - 1 and k.x1 <= r.x1 + 1 and k.y0 >= r.y0 - 1 and k.y1 <= r.y1 + 1
                 and k.width * k.height > 0.5 * r.width * r.height]
        if not inner:
            keep2.append(r)
    return keep2


def text_in(page, rect):
    return page.get_text("text", clip=rect).lower()


def classify(page, r):
    below = text_in(page, pymupdf.Rect(r.x0 - 10, r.y1, r.x1 + 10, r.y1 + 40))
    above = text_in(page, pymupdf.Rect(r.x0 - 10, r.y0 - 45, r.x1 + 10, r.y0))
    left = text_in(page, pymupdf.Rect(r.x0 - 45, r.y0, r.x0, r.y1))
    right = text_in(page, pymupdf.Rect(r.x1, r.y0, r.x1 + 45, r.y1))
    allt = below + above + left + right
    # skip granularity and MTF charts by their own axis titles (a page header above a chart does not count)
    if ("granularity" in left + right or "sigma" in left + right or "spatial" in below or "response" in left
            or "modulation" in above):
        return None
    if "wavelength" in below:
        if "sensitiv" in left or "sensitiv" in above:
            return "sens"
        if "densit" in left or "densit" in above:
            return "dye"
    if ("exposure" in below or "log h" in below or "camera stops" in below or "exposure" in above) and "densit" in left:
        return "char"
    return None


def gridlines(page, r):
    xs, ys = {r.x0, r.x1}, {r.y0, r.y1}
    for d in page.get_drawings():
        if d["type"] not in ("s", "fs"):
            continue
        for it in d["items"]:
            if it[0] != "l":
                continue
            p, q = it[1], it[2]
            if (abs(p.x - q.x) < 0.05 and r.x0 - 1 <= p.x <= r.x1 + 1
                    and min(p.y, q.y) < r.y0 + 0.3 * r.height and max(p.y, q.y) > r.y1 - 0.3 * r.height):
                xs.add(p.x)
            if (abs(p.y - q.y) < 0.05 and r.y0 - 1 <= p.y <= r.y1 + 1
                    and min(p.x, q.x) < r.x0 + 0.3 * r.width and max(p.x, q.x) > r.x1 - 0.3 * r.width):
                ys.add(p.y)
    def dd(v):
        v = sorted(v)
        o = [v[0]]
        for a in v[1:]:
            if a - o[-1] > 0.6:
                o.append(a)
        return np.array(o)
    return dd(xs), dd(ys)


def labels(tokens, r, where):
    out = []
    for t in tokens:
        v = numeric(t)
        if v is None and where == "below" and t["text"].upper() == "N":
            v = 0.0      # Kodak marks the normal exposure on a camera-stop axis "N"
        if v is None:
            continue
        b = t["bbox"]
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        txt = t["text"]
        w = (b[2] - b[0]) / max(len(txt), 1)
        if txt.startswith("-"):
            cx += w / 2
        if where == "below" and r.y1 - 2 <= b[1] <= r.y1 + 12 and r.x0 - 6 <= cx <= r.x1 + 6:
            out.append((cx, v))
        if where == "above" and r.y0 - 22 <= b[3] <= r.y0 + 2 and r.x0 - 12 <= cx <= r.x1 + 12:
            out.append((cx, v))
        if where == "left" and r.x0 - 22 <= b[2] <= r.x0 + 2 and r.y0 - 6 <= cy <= r.y1 + 6:
            out.append((cy, v))
    return out


def fit_axis(lines, labs, tol=4.0):
    pairs = []
    for pos, val in labs:
        k = int(np.argmin(np.abs(lines - pos)))
        if abs(lines[k] - pos) <= tol:
            pairs.append((lines[k], val, abs(lines[k] - pos)))
    on = [p for p in pairs if p[2] <= 1.5]
    dropped = []
    if len(on) >= 2 and len(on) < len(pairs):
        dropped = [p[1] for p in pairs if p[2] > 1.5]
        pairs = on
    pairs = sorted(set((a, v) for a, v, _ in pairs))
    if len(pairs) < 2:
        # no grid under the labels: fit the labels' own centres
        if len(labs) < 2:
            return None
        P = np.array(sorted(labs))
        src = "label centres"
    else:
        P = np.array(pairs)
        src = "grid lines"
    A = np.vstack([P[:, 0], np.ones(len(P))]).T
    (a, b), *_ = np.linalg.lstsq(A, P[:, 1], rcond=None)
    res = P[:, 1] - (a * P[:, 0] + b)
    if abs(a) < 1e-12:
        return None
    return {"a": float(a), "b": float(b), "n": len(P), "residual_max": float(np.abs(res).max()), "source": src,
            "dropped": dropped}


def sign_fix(labs, increasing=True):
    labs = sorted(labs)
    vals = [v for _, v in labs]
    if 0.0 in vals:
        k = vals.index(0.0)
        if increasing:
            labs = [(p, -abs(v)) if i < k else (p, v) for i, (p, v) in enumerate(labs)]
        else:
            labs = [(p, -abs(v)) if i > k else (p, v) for i, (p, v) in enumerate(labs)]
    return labs


def curves(page, r):
    out = []
    # a curve drawn as a run of tiny filled segments (Kodak's VISION2 Expression 500T yellow dye): collect the
    # pieces of one colour inside the frame and take the mean height in 0.5 pt columns
    tiny = {}
    for d in page.get_drawings():
        rr = d["rect"]
        if (d["type"] == "fs" and d.get("color") is not None and len(d["items"]) <= 6 and rr.width < 6 and rr.height < 14
                and r.x0 - 2 <= rr.x0 and rr.x1 <= r.x1 + 2 and r.y0 - 2 <= rr.y0 and rr.y1 <= r.y1 + 2):
            pts = [pp for it in d["items"] for pp in it[1:] if hasattr(pp, "x")]
            tiny.setdefault(colour_kind(d.get("color")), []).extend((pp.x, pp.y) for pp in pts)
    for ck, pts in tiny.items():
        if len(pts) < 40 or ck == "k":
            continue
        P = np.array(pts)
        xb = np.round(P[:, 0] * 2) / 2
        xs = np.unique(xb)
        ys = np.array([P[xb == x, 1].mean() for x in xs])
        out.append({"pts": np.column_stack([xs, ys]), "colour": ck, "dash": "solid", "width": 1.0})
    for d in page.get_drawings():
        if d["type"] != "s" or any(it[0] == "re" for it in d["items"]):
            continue
        items = [it for it in d["items"] if it[0] in "lc"]
        # a curve: some Beziers (Fujifilm draws a whole curve with two or three), or a long polyline
        if not (any(it[0] == "c" for it in items) or len(items) >= 6):
            continue
        # a grid drawn as one path: every item horizontal or vertical
        hv = sum(1 for it in items if it[0] == "l" and (abs(it[1].x - it[2].x) < 0.05 or abs(it[1].y - it[2].y) < 0.05))
        if hv > 0.8 * len(items):
            continue
        rr = d["rect"]
        if rr.x0 < r.x0 - 14 or rr.x1 > r.x1 + 14 or rr.y0 < r.y0 - 14 or rr.y1 > r.y1 + 14:
            continue
        ck = colour_kind(d.get("color"))
        ck = COLOUR_MAP.get(ck, ck)
        dk = dash_kind(d.get("dashes"))
        subs = sample_items(items)
        lens = [float(np.hypot(*np.ptp(x, axis=0))) for x in subs]
        if len(subs) > 8 and np.median(lens) < 6:
            # a dashed line drawn as hundreds of separate strokes (Kodak's 1990s sheets): stitch strokes that
            # follow on (gap < 8 pt, moving right) back into curves
            dk = "drawn-dash"
            merged, cur = [], [subs[0]]
            for x in subs[1:]:
                gap = np.hypot(*(x[0] - cur[-1][-1]))
                if gap < 8 and x[0, 0] >= cur[-1][-1, 0] - 0.5:
                    cur.append(x)
                else:
                    merged.append(np.vstack(cur))
                    cur = [x]
            merged.append(np.vstack(cur))
            subs = merged
        for s in subs:
            m = (s[:, 0] >= r.x0 - 0.01) & (s[:, 0] <= r.x1 + 0.01) & (s[:, 1] >= r.y0 - 0.01) & (s[:, 1] <= r.y1 + 0.01)
            if m.sum() > 2:
                out.append({"pts": s[m], "colour": ck, "dash": dk, "width": d.get("width") or 0})
    return out


def to_values(pts, ax, ay):
    x = ax["a"] * pts[:, 0] + ax["b"]
    y = ay["a"] * pts[:, 1] + ay["b"]
    if x[-1] < x[0]:
        x, y = x[::-1], y[::-1]
    keep = np.zeros(len(x), bool)
    last = -np.inf
    for i, v in enumerate(x):
        if v > last + 1e-6:
            keep[i] = True
            last = v
    return np.column_stack([x[keep], y[keep]])


def group(cs):
    """Curves of one style chained into continuous pieces; returns [(key, [pts...])]."""
    by = {}
    for c in cs:
        by.setdefault((c["colour"], c["dash"]), []).append(c["pts"])
    out = {}
    for k, v in by.items():
        # a piece that already spans most of the chart is a whole curve: never chain it to another
        # (VISION 200T's three dyes meet at one corner and were glued into one)
        span = max(np.ptp(p[:, 0]) for p in v)
        whole = [p for p in v if np.ptp(p[:, 0]) > 0.6 * span and span > 60]
        parts = chain([p for p in v if not any(p is w for w in whole)])
        # a whole curve may still take a short continuation (Elite Chrome 400's red, split at its peak)
        for i, w in enumerate(whole):
            for q in list(parts):
                if np.hypot(*(w[-1] - q[0])) < 0.8:
                    whole[i] = w = np.vstack([w, q[1:]]); parts = [x for x in parts if x is not q]
                elif np.hypot(*(q[-1] - w[0])) < 0.8:
                    whole[i] = w = np.vstack([q, w[1:]]); parts = [x for x in parts if x is not q]
        out[k] = [p for p in whole + parts if np.ptp(p[:, 0]) > 4]
    return out


COLOUR_MAP = {}


def read(spec):
    # a sheet that draws a record in an unusual colour (VISION 800T: the blue record in yellow)
    COLOUR_MAP.clear()
    COLOUR_MAP.update(spec.get("colour_map", {}))
    doc = pymupdf.open(spec["pdf"])
    sheet = {"stock": spec["stock"], "name": spec["name"], "source": spec["source"], "warnings": [], "charts": {}}
    data = {}
    for pno, page in enumerate(doc):
        if spec.get("pages") and pno + 1 not in spec["pages"]:
            continue
        h = Half(page, 0, page.rect.width)
        over = {k: v for k, v in spec.get("charts", {}).items() if v.get("page") == pno + 1}
        for r in frames(page):
            kind = classify(page, r)
            for k, v in over.items():
                f = v.get("frame")
                if f and abs(r.x0 - f[0]) < 6 and abs(r.y0 - f[1]) < 6:
                    kind = k
            pinned = spec.get("charts", {}).get(kind or "", {}).get("frame") if kind else None
            if pinned and not (abs(r.x0 - pinned[0]) < 6 and abs(r.y0 - pinned[1]) < 6 and spec["charts"][kind].get("page") == pno + 1):
                continue
            if kind is None or kind in sheet["charts"]:
                continue
            o = spec.get("charts", {}).get(kind, {})
            gx, gy = gridlines(page, r)
            cs = curves(page, r)
            if not cs:
                continue
            ylab = sign_fix(labels(h.tokens, r, "left"), increasing=False)
            ay = fit_axis(gy, ylab)
            if "y" in o:   # [value at the bottom edge, value at the top edge], read off the sheet
                y0, y1 = o["y"]
                ay = {"a": (y1 - y0) / (r.y0 - r.y1), "b": y0 - (y1 - y0) / (r.y0 - r.y1) * r.y1, "n": 2,
                      "residual_max": 0.0, "source": "frame edges, values read off the sheet (labels not text)"}
            ax_info = {}
            if kind == "char":
                below = text_in(page, pymupdf.Rect(r.x0 - 10, r.y1, r.x1 + 10, r.y1 + 40))
                xb = sign_fix(labels(h.tokens, r, "below"))
                axb = fit_axis(gx, xb)
                if "camera stops" in below or "stops" in below:
                    top = sorted(labels(h.tokens, r, "above"))
                    # log exposure rises to the right; a run that falls lost its minus signs in the text
                    tv = [v for _, v in top]
                    if len(tv) >= 2 and all(x2 <= x1 for x1, x2 in zip(tv, tv[1:])):
                        top = [(p_, -abs(v)) for p_, v in top]
                    if axb is None or len(top) < 2:
                        sheet["warnings"].append("char: camera stops without log-exposure labels")
                        continue
                    # stops -> log H: slope exactly log10(2), offset from the top labels
                    st = np.array([axb["a"] * p + axb["b"] for p, _ in top])
                    lh = np.array([v for _, v in top])
                    off = lh - LOG2 * st
                    c0 = float(np.median(off))
                    ax = {"a": axb["a"] * LOG2, "b": axb["b"] * LOG2 + c0, "n": axb["n"],
                          "residual_max": float(np.abs(off - c0).max()), "source": "camera stops x 0.30103 + top labels"}
                    ax_info["stops_axis"] = axb
                else:
                    ax = axb
                    if o.get("x_zero_step") and axb is not None:
                        # labels whose minus signs are not in the text (Fujifilm ETERNA sheets: "4.0 4.5 3.0 3.5 ...
                        # 0.0 0.5" for -4.0 ... 0.5): the grid is regular; anchor the 0.0 label, step per line
                        step = o["x_zero_step"]
                        zero = [p for p, v in labels(h.tokens, r, "below") if v == 0.0]
                        if zero:
                            gl = np.array(sorted(gx))
                            i0 = int(np.argmin(np.abs(gl - zero[0])))
                            vals = (np.arange(len(gl)) - i0) * step
                            A = np.vstack([gl, np.ones(len(gl))]).T
                            (a_, b_), *_ = np.linalg.lstsq(A, vals, rcond=None)
                            ax = {"a": float(a_), "b": float(b_), "n": len(gl),
                                  "residual_max": float(np.abs(vals - (a_ * gl + b_)).max()),
                                  "source": f"grid lines, {step} log H per line from the 0.0 label (minus signs not in the text)"}
            else:
                ax = fit_axis(gx, labels(h.tokens, r, "below"))
            if "x" in o:
                x0, x1 = o["x"]
                ax = {"a": (x1 - x0) / (r.x1 - r.x0), "b": x0 - (x1 - x0) / (r.x1 - r.x0) * r.x0, "n": 2,
                      "residual_max": 0.0, "source": "frame edges, values read off the sheet (labels not text)"}
            if ax is None or ay is None:
                sheet["warnings"].append(f"{kind} on page {pno + 1}: axes not found")
                continue
            sheet["charts"][kind] = {"page": pno + 1, "frame": list(r), "x": ax, "y": ay, **ax_info}
            if kind == "char":
                # Kodak labels a slide's records "B", "G", "R" where the curves start: keep where, in data units
                lab = {}
                for t in h.tokens:
                    tx = t["text"].strip()
                    if tx in ("R", "G", "B") and r.x0 - 22 <= t["bbox"][0] <= r.x1 and r.y0 - 4 <= t["bbox"][1] <= r.y1:
                        cx, cy = (t["bbox"][0] + t["bbox"][2]) / 2, (t["bbox"][1] + t["bbox"][3]) / 2
                        lab[tx.lower()] = (ax["a"] * cx + ax["b"], ay["a"] * cy + ay["b"])
                sheet["charts"][kind]["rgb_labels"] = lab
            g = group(cs)
            sheet["charts"][kind]["styles"] = {f"{k[0]}/{k[1]}": len(v) for k, v in g.items()}
            vals = {k: [to_values(p, ax, ay) for p in v] for k, v in g.items()}
            data[kind] = vals
    return sheet, data


def assign(sheet, data, spec):
    out = {}
    W = sheet["warnings"]
    # ---- sensitivity
    s = data.get("sens", {})
    coloured = {k: v for k, v in s.items() if k[0] in "rgb"}
    if len(coloured) == 3:
        for k, v in coloured.items():
            out[f"log_sensitivity_{k[0]}"] = max(v, key=lambda a: np.ptp(a[:, 0]))
        extra = [k for k in s if k[0] not in "rgb"]
        if extra:
            sheet["extra_sensitivity"] = [f"{k[0]}/{k[1]}" for k in extra]
    else:
        pieces = [p for k, v in s.items() for p in v if k[0] in "kro" or True]
        main = [p for k, v in s.items() for p in v if k[1] == "solid"] or pieces
        main = sorted(main, key=lambda a: np.ptp(a[:, 0]), reverse=True)
        main = [p for p in main if np.ptp(p[:, 0]) > 25]
        if len(main) > 3:
            W.append(f"sens: {len(main)} solid curves, the 3 widest kept")
            main = main[:3]
        if len(main) != 3:
            W.append(f"sens: {len(main)} curves")
        main = sorted(main, key=lambda a: a[np.argmax(a[:, 1]), 0])
        for ch, p in zip("bgr", main):
            out[f"log_sensitivity_{ch}"] = p
    # ---- characteristic
    c = data.get("char", {})
    lab = sheet["charts"].get("char", {}).get("rgb_labels", {})
    if spec.get("positive") and len(lab) == 3 and not any(k[0] in "rgb" for k in c):
        # black slide curves: each record is the curve nearest its letter (Kodak sets B, G, R at the curves' start)
        pieces = sorted([p for v in c.values() for p in v], key=lambda a: np.ptp(a[:, 0]), reverse=True)[:3]
        xr = max(np.ptp(p[:, 0]) for p in pieces); yr = max(np.ptp(p[:, 1]) for p in pieces)
        def dist(p, xy):
            return float(np.min(np.hypot((p[:, 0] - xy[0]) / xr, (p[:, 1] - xy[1]) / yr)))
        free = list(range(len(pieces)))
        pairs = sorted(((dist(pieces[i], xy), ch, i) for ch, xy in lab.items() for i in free))
        used_ch, used_i = set(), set()
        for d_, ch, i in pairs:
            if ch in used_ch or i in used_i:
                continue
            out[f"density_curve_{ch}"] = pieces[i]; used_ch.add(ch); used_i.add(i)
        sheet["char_assignment"] = "by the B/G/R letters"
        c = {}
    coloured = {k: v for k, v in c.items() if k[0] in "rgb"}
    if len(coloured) == 3:
        for k, v in coloured.items():
            out[f"density_curve_{k[0]}"] = max(v, key=lambda a: np.ptp(a[:, 0]))
    else:
        pieces = sorted([p for v in c.values() for p in v], key=lambda a: np.ptp(a[:, 0]), reverse=True)
        pieces = [p for p in pieces if np.ptp(p[:, 0]) > 1.0][:3]
        if len(pieces) != 3 and not sheet.get("char_assignment"):
            W.append(f"char: {len(pieces)} curves")
        pieces = sorted(pieces, key=lambda a: -np.mean(a[:, 1]))
        for ch, p in zip("bgr", pieces):
            out[f"density_curve_{ch}"] = p
    # ---- dye density
    sheet.setdefault("dyes_published", False)
    sheet.setdefault("mid_min_published", False)
    d = data.get("dye", {})
    pieces = [(k, p) for k, v in d.items() for p in v if np.ptp(p[:, 0]) > 60]
    if any(k[0] != "k" for k, _ in pieces):
        # colour-coded (Kodak Vision2): coloured = the three dyes, black solid = midscale, black dashed = D-min
        # the three dyes: coloured, peak-normalised curves with distinct peaks (Kodak draws a dye twice in some
        # brochures, once in the panel's yellow; a duplicate peak keeps its non-yellow copy)
        cand = sorted([(k, p) for k, p in pieces if k[0] != "k" and 0.85 <= p[:, 1].max() <= 1.12],
                      key=lambda kp: (kp[1][np.argmax(kp[1][:, 1]), 0], kp[0][0] == "o"))
        col = []
        for kp in cand:
            pk = kp[1][np.argmax(kp[1][:, 1]), 0]
            if col and abs(pk - col[-1][1][np.argmax(col[-1][1][:, 1]), 0]) < 15:
                continue
            col.append(kp)
        blk = [(k, p) for k, p in pieces if k[0] == "k"]
        if len(col) >= 3:
            for ch, (k, p) in zip("ymc", col[:3]):
                out[f"dye_density_{ch}"] = p
            sheet["dyes_published"] = True
        sol = [p for k, p in blk if k[1] == "solid"]
        das = [p for k, p in blk if k[1] != "solid"]
        rest = [p for k, p in pieces if k[0] != "k" and not (0.85 <= p[:, 1].max() <= 1.12)]
        if not blk and len(col) < 3 and len(rest) == 2:
            # midscale and D-min drawn in colour, no dyes (KODAK SUPRA 400): the higher one is the midscale
            rest = sorted(rest, key=lambda a: -np.mean(a[:, 1]))
            out["dye_density_mid"], out["dye_density_min"] = rest
            sheet["mid_min_published"] = True
        elif sol and das:
            out["dye_density_mid"] = max(sol, key=lambda a: np.mean(a[:, 1]))
            out["dye_density_min"] = max(das, key=lambda a: np.ptp(a[:, 0]))
            sheet["mid_min_published"] = True
        else:
            sheet["mid_min_published"] = False
        pieces = []
    dyes = [(k, p) for k, p in pieces if 0.85 <= p[:, 1].max() <= 1.12]
    others = [(k, p) for k, p in pieces if not (0.85 <= p[:, 1].max() <= 1.12)]
    if pieces and len(dyes) >= 4:
        # Kodak, all black: the midscale neutral is the one well above 1; the D-min is the dashed one, or else
        # the one highest at its blue end (the orange mask) rather than peaking inside the band like a dye
        mid = [kp for kp in others if kp[1][:, 1].max() > 1.2]
        das = [kp for kp in dyes if kp[0][1] != "solid"]
        if das:
            mn = das[0]
        else:
            mn = max(dyes, key=lambda kp: kp[1][0, 1] / max(kp[1][:, 1].max(), 1e-6) - kp[1][np.argmax(kp[1][:, 1]), 0] / 1000)
        dyes = [kp for kp in dyes if kp is not mn]
        others = ([max(mid, key=lambda kp: np.mean(kp[1][:, 1]))] if mid else []) + [mn]
    if not pieces:
        pass
    elif spec.get("positive") and len(pieces) == 4:
        # Kodak slide dyes, normalised to a visual neutral of 1.0, drawn with that neutral: the neutral is the
        # one with the highest mean; the other three are the dyes by peak
        neu = max(pieces, key=lambda kp: np.mean(kp[1][:, 1]))
        dy = sorted([kp for kp in pieces if kp is not neu], key=lambda kp: kp[1][np.argmax(kp[1][:, 1]), 0])
        for ch, (k, p) in zip("ymc", dy):
            out[f"dye_density_{ch}"] = p
        out["dye_density_visual_neutral"] = neu[1]
        sheet["dyes_published"] = True
        others = []
    elif len(dyes) >= 3:
        dyes = sorted(dyes, key=lambda kp: kp[1][np.argmax(kp[1][:, 1]), 0])[:3]
        for ch, (k, p) in zip("ymc", dyes):
            out[f"dye_density_{ch}"] = p
        sheet["dyes_published"] = True
    else:
        sheet["dyes_published"] = False
        others = pieces
    if not pieces:
        pass
    elif len(others) >= 2:
        others = sorted(others, key=lambda kp: -np.mean(kp[1][:, 1]))
        out["dye_density_mid"] = others[0][1]
        out["dye_density_min"] = others[-1][1]
        sheet["mid_min_published"] = True
    else:
        sheet["mid_min_published"] = False
        if not sheet["dyes_published"]:
            W.append("dye: neither dyes nor midscale/minimum found")
    for k in ("log_sensitivity_r", "log_sensitivity_g", "log_sensitivity_b", "density_curve_r", "density_curve_g", "density_curve_b"):
        if k not in out:
            W.append(f"missing {k}")
    return out


def plot(dst, sheet, out):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, axs = plt.subplots(1, 3, figsize=(15, 4))
    col = {"r": "tab:red", "g": "tab:green", "b": "tab:blue", "c": "tab:cyan", "m": "m", "y": "gold", "min": "grey", "mid": "k", "neutral": "k"}
    for k, v in out.items():
        ch = k.split("_")[-1]
        i = 0 if k.startswith("log_sens") else (2 if k.startswith("dye") else 1)
        axs[i].plot(v[:, 0], v[:, 1], color=col[ch])
    fig.suptitle(sheet["name"])
    fig.savefig(dst / "check.png", dpi=60)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sheets")
    ap.add_argument("out")
    ap.add_argument("--plots", action="store_true")
    ap.add_argument("--only", nargs="*")
    a = ap.parse_args()
    specs = json.loads(Path(a.sheets).read_text())
    for spec in specs:
        if a.only and spec["stock"] not in a.only:
            continue
        sheet, data = read(spec)
        out = assign(sheet, data, spec)
        sheet.update({k: v for k, v in spec.items() if k not in sheet})
        dst = Path(a.out) / spec["stock"]
        dst.mkdir(parents=True, exist_ok=True)
        for k, v in out.items():
            np.savetxt(dst / f"{k}.csv", v, delimiter=",", fmt="%.6f")
        (dst / "sheet.json").write_text(json.dumps(sheet, indent=1, default=float))
        (dst / "info.txt").write_text(f"{spec['name']}\n{spec['source']}\n")
        ch = sheet["charts"]
        ax = " ".join(f"{k}:{ch[k]['x']['residual_max']:.3f}/{ch[k]['y']['residual_max']:.3f}" for k in ("sens", "dye", "char") if k in ch)
        print(f"{spec['stock']:32s} charts {sorted(ch)} dyes {sheet['dyes_published']} midmin {sheet['mid_min_published']} "
              f"axes {ax} {'WARN ' + '; '.join(sheet['warnings']) if sheet['warnings'] else ''}", flush=True)
        if a.plots:
            plot(dst, sheet, out)


if __name__ == "__main__":
    main()
