#!/usr/bin/env python3
"""Digitise the colour-film data sheets of FUJIFILM's "Professional Data Guide" (AF3-207U) from the
PDF's vector paths.

    python digitise.py GUIDE.pdf OUT_DIR [--plots]

Every chart is calibrated from its own drawing: the grid lines (and the frame) are the positions,
the tick labels say which value each grid line carries, and a least-squares line through those
pairs is the axis. The curves are the cubic Beziers the PDF stores, sampled densely, so the only
error left is the publisher's own drawing. Per film this writes the raw curves in the layout
spektrafilm's profile factory (commit 9428440) reads, plus `sheet.json` with what was read and
the calibration residuals.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np
import pymupdf

SPREADS = list(range(24, 35)) + [53, 54]          # 1-based PDF pages holding the colour sheets


# --------------------------------------------------------------------------------------------- geometry

def is_grey(c):
    return c is not None and all(0.74 < v < 0.9 for v in c) and max(c) - min(c) < 0.03


def is_dark(c):
    return c is not None and max(c) < 0.3


def sample_items(items):
    """Split a path into sub-paths (a new one wherever an item does not start at the last end)
    and sample each densely: 48 points per cubic."""
    subs, cur, last = [], [], None
    t = np.linspace(0, 1, 48)[:, None]
    for it in items:
        kind = it[0]
        if kind == "l":
            p0, p1 = np.array(it[1]), np.array(it[2])
            pts = np.vstack([p0, p1])
        elif kind == "c":
            p0, p1, p2, p3 = (np.array(p) for p in it[1:5])
            pts = ((1 - t) ** 3) * p0 + 3 * ((1 - t) ** 2) * t * p1 + 3 * (1 - t) * t * t * p2 + t ** 3 * p3
        else:
            continue
        if last is not None and np.hypot(*(pts[0] - last)) > 0.05:
            if cur:
                subs.append(np.vstack(cur))
            cur = []
        cur.append(pts if not cur else pts[1:])
        last = pts[-1]
    if cur:
        subs.append(np.vstack(cur))
    return subs


def chain(subs, tol=0.8):
    """Join sub-paths whose ends meet (within tol pt), in either direction."""
    subs = [s for s in subs if len(s) > 1]
    changed = True
    while changed:
        changed = False
        for i in range(len(subs)):
            for j in range(len(subs)):
                if i == j:
                    continue
                a, b = subs[i], subs[j]
                for aa in (a,):
                    for bb in (b,):
                        if np.hypot(*(aa[-1] - bb[0])) < tol:
                            subs[i] = np.vstack([aa, bb[1:]])
                            del subs[j]
                            changed = True
                            break
                    if changed:
                        break
                if changed:
                    break
            if changed:
                break
    return subs


# --------------------------------------------------------------------------------------------- page model

class Half:
    def __init__(self, page, x0, x1):
        self.page, self.x0, self.x1 = page, x0, x1
        self.drawings = [d for d in page.get_drawings() if x0 - 2 <= d["rect"].x0 and d["rect"].x1 <= x1 + 2]
        self.tokens = self._tokens()

    def _tokens(self):
        """Words rebuilt from single glyphs: the PDF splits one number over several spans and
        lines ('2.' and '0'), so glyphs on one baseline that touch are joined, wherever they sit."""
        chars = []
        raw = self.page.get_text("rawdict")
        for b in raw["blocks"]:
            for l in b.get("lines", []):
                upright = abs(l["dir"][0] - 1) < 1e-3
                for s in l["spans"]:
                    for ch in s["chars"]:
                        bb = ch["bbox"]
                        if not (self.x0 - 2 <= bb[0] <= self.x1 + 2) or not ch["c"].strip():
                            continue
                        chars.append((upright, round(bb[1], 1), bb, ch["c"], s["size"]))
        chars.sort(key=lambda c: (not c[0], c[1], c[2][0]))
        toks, cur = [], None
        for upright, y, bb, c, size in chars:
            if (cur is not None and upright and cur["upright"] and abs(bb[1] - cur["bbox"][1]) < 1.0
                    and -0.5 < bb[0] - cur["bbox"][2] < 1.2):
                cur["text"] += c
                cur["bbox"] = [min(cur["bbox"][0], bb[0]), min(cur["bbox"][1], bb[1]),
                               max(cur["bbox"][2], bb[2]), max(cur["bbox"][3], bb[3])]
            else:
                cur = {"text": c, "bbox": list(bb), "size": size, "upright": upright}
                toks.append(cur)
        return toks

    def text(self):
        return [t["text"] for t in self.tokens]

    def frames(self):
        out = []
        for d in self.drawings:
            if d["type"] in ("f", "fs") and is_grey(d.get("fill")):
                r = d["rect"]
                if r.width * r.height > 3000:
                    out.append(r)
        return out


def numeric(tok):
    s = tok["text"].replace("−", "-").replace("–", "-")
    if re.fullmatch(r"-?\d+(\.\d+)?", s):
        return float(s)
    return None


def gridlines(half, r):
    xs, ys = {r.x0, r.x1}, {r.y0, r.y1}
    for d in half.drawings:
        if d["type"] not in ("s", "fs") or (d.get("width") or 1) > 0.45:
            continue
        for it in d["items"]:
            if it[0] == "re":
                q = it[1]
                if abs(q.x0 - r.x0) < 1.5 and abs(q.x1 - r.x1) < 1.5:
                    xs |= {q.x0, q.x1}
                    ys |= {q.y0, q.y1}
                continue
            if it[0] != "l":
                continue
            p, q = it[1], it[2]
            # a grid line runs across this frame: it lies inside it and covers most of its span
            if (abs(p.x - q.x) < 0.05 and r.x0 - 1 <= p.x <= r.x1 + 1
                    and min(p.y, q.y) < r.y0 + 0.3 * r.height and max(p.y, q.y) > r.y1 - 0.3 * r.height):
                xs.add(p.x)
            if (abs(p.y - q.y) < 0.05 and r.y0 - 1 <= p.y <= r.y1 + 1
                    and min(p.x, q.x) < r.x0 + 0.3 * r.width and max(p.x, q.x) > r.x1 - 0.3 * r.width):
                ys.add(p.y)
    def dedupe(v):
        v = sorted(v)
        out = [v[0]]
        for a in v[1:]:
            if a - out[-1] > 0.6:
                out.append(a)
        return np.array(out)
    return dedupe(xs), dedupe(ys)


def axis_fit(lines, labels, tol):
    """labels: [(position, value)]. Each label claims the nearest grid line; value = a*pos + b."""
    pairs, off = [], []
    for pos, val in labels:
        k = int(np.argmin(np.abs(lines - pos)))
        if abs(lines[k] - pos) <= tol:
            pairs.append((lines[k], val, abs(lines[k] - pos)))
    # A label set off its grid line (Nexia 400's dye chart: 1.0 and 0.0 sit 7 pt above theirs while
    # 3.0 and 2.0 sit on them) is a typesetting slip, not a scale: keep the labels that sit on lines.
    on = [q for q in pairs if q[2] <= 1.5]
    if len(on) >= 2 and len(on) < len(pairs):
        off = [q[1] for q in pairs if q[2] > 1.5]
        pairs = on
    pairs = sorted(set((a, v) for a, v, _ in pairs))
    if len(pairs) < 2:
        return None
    P = np.array(pairs)
    A = np.vstack([P[:, 0], np.ones(len(P))]).T
    (a, b), *_ = np.linalg.lstsq(A, P[:, 1], rcond=None)
    res = P[:, 1] - (a * P[:, 0] + b)
    # grid lines with no label still sit on the same scale: report their spacing regularity too
    vals = a * lines + b
    return {"a": float(a), "b": float(b), "n_labels": len(P), "residual_max": float(np.abs(res).max()),
            "labels_off_grid_dropped": off,
            "grid_values": np.round(vals, 4).tolist()}


def x_labels(half, r):
    out = []
    for t in half.tokens:
        v = numeric(t)
        bb = t["bbox"]
        if v is None or not (r.y1 - 2 <= bb[1] <= r.y1 + 9) or not (r.x0 - 14 <= bb[0] <= r.x1 + 10):
            continue
        txt = t["text"]
        # centre on the digits: a leading minus sign hangs to the left of the number's centre
        w = (bb[2] - bb[0]) / max(len(txt), 1)
        c0 = bb[0] + (w if txt.startswith("-") else 0)
        out.append(((c0 + bb[2]) / 2, v))
    out.sort()
    # some sheets set the minus sign as a separate glyph: an exposure axis reads -4 3 2 1 0 1.
    # Labels increase to the right, so everything left of the 0 label is negative.
    vals = [v for _, v in out]
    if 0.0 in vals:
        k = vals.index(0.0)
        out = [(p, -abs(v)) if i < k else (p, v) for i, (p, v) in enumerate(out)]
    return out


def y_labels(half, r):
    out = []
    for t in half.tokens:
        v = numeric(t)
        bb = t["bbox"]
        if v is None or not (r.x0 - 16 <= bb[2] <= r.x0 + 3) or not (r.y0 - 6 <= bb[1] <= r.y1 + 2):
            continue
        out.append(((bb[1] + bb[3]) / 2, v))
    out.sort()
    # values fall downwards; a minus sign set as its own glyph is lost, so below the 0 label is negative
    vals = [v for _, v in out]
    if 0.0 in vals:
        k = vals.index(0.0)
        out = [(p, -abs(v)) if i > k else (p, v) for i, (p, v) in enumerate(out)]
    return out


def curves_in(half, r, min_width=0.6):
    """Stroked dark paths inside the frame. Returns [(points Nx2, dash signature)]."""
    out = []
    for d in half.drawings:
        if d["type"] != "s" or (d.get("width") or 0) < min_width or not is_dark(d.get("color")):
            continue
        if any(it[0] == "re" for it in d["items"]):
            continue
        rr = d["rect"]
        # curves may overhang the frame a little (Fujifilm lets them run past the axes); they may not
        # belong to another chart: the path's box must sit on this frame give or take 9 pt
        if rr.x0 < r.x0 - 14 or rr.x1 > r.x1 + 14 or rr.y0 < r.y0 - 14 or rr.y1 > r.y1 + 14:
            continue
        dash = dash_kind(d.get("dashes"))
        for s in sample_items(d["items"]):
            inside = (s[:, 0] >= r.x0 - 0.01) & (s[:, 0] <= r.x1 + 0.01) & (s[:, 1] >= r.y0 - 0.01) & (s[:, 1] <= r.y1 + 0.01)
            if inside.sum() > 1:
                out.append((s[inside], dash))
    return out


def dash_kind(d):
    """'solid', 'dash' or 'dashdot' from a PDF dash array: the legend and the curves use the same
    kind of line at different scales."""
    nums = re.findall(r"[0-9.]+", (d or "").split("]")[0])
    return {0: "solid", 2: "dash", 4: "dashdot"}.get(len(nums), f"n{len(nums)}")


def legend_dashes(half, r):
    """Slide characteristic charts: a legend to the right of the frame pairs a line style with a
    channel name. Returns {dash signature: 'r'|'g'|'b'}."""
    names = {"Red": "r", "Green": "g", "Blue": "b"}
    out = {}
    for t in half.tokens:
        if t["text"] not in names or t["bbox"][0] < r.x1:
            continue
        cy = (t["bbox"][1] + t["bbox"][3]) / 2
        best = None
        for d in half.drawings:
            if d["type"] != "s" or not is_dark(d.get("color")):
                continue
            rr = d["rect"]
            if rr.x1 <= t["bbox"][0] + 1 and t["bbox"][0] - rr.x1 < 12 and abs((rr.y0 + rr.y1) / 2 - cy) < 3 and rr.height < 1:
                best = dash_kind(d.get("dashes"))
        if best is not None:
            out[best] = names[t["text"]]
    return out


def to_values(pts, ax, ay):
    x = ax["a"] * pts[:, 0] + ax["b"]
    y = ay["a"] * pts[:, 1] + ay["b"]
    # Walk the path in its own order (oriented left to right) and keep only points that advance:
    # where a drawn stroke doubles back (a hook at a curve's end) the first pass is kept.
    if x[-1] < x[0]:
        x, y = x[::-1], y[::-1]
    keep = np.zeros(len(x), bool)
    last = -np.inf
    for i, v in enumerate(x):
        if v > last + 1e-6:
            keep[i] = True
            last = v
    return np.column_stack([x[keep], y[keep]])


# --------------------------------------------------------------------------------------------- one sheet

def read_sheet(page, x0, x1, page_numbers):
    h = Half(page, x0, x1)
    titles = [t for t in h.tokens if t["size"] > 8.5 and t["bbox"][1] < 70]
    title = " ".join(t["text"] for t in sorted(titles, key=lambda t: (round(t["bbox"][1]), t["bbox"][0])))
    lines = page.get_text("text", clip=pymupdf.Rect(x0, 40, x1, 75)).splitlines()
    head = [l.strip() for l in lines if l.strip()]
    body = page.get_text("text", clip=pymupdf.Rect(x0, 0, x1, page.rect.height))
    sheet = {"title": head[0] if head else title, "subtitle": head[1] if len(head) > 1 else "",
             "printed_page": page_numbers, "warnings": []}
    m = re.search(r"VALUE\s*\.+\s*(\d+)", body)
    sheet["rms_granularity"] = int(m.group(1)) if m else None
    m = re.search(r"Process\s*:\s*([A-Z0-9\-/]+)", body)
    sheet["process"] = m.group(1) if m else None
    sheet["densitometry"] = "Status A" if "Status A" in body else "Status M"
    m = re.search(r"Density\s*:\s*([0-9.]+)\s*above", body)
    sheet["sensitivity_density_over_min"] = float(m.group(1)) if m else None
    sheet["positive"] = "FUJICHROME" in sheet["title"].upper()

    fr = sorted(h.frames(), key=lambda r: (r.y0, r.x0))
    top = [r for r in fr if r.y0 < 200]
    mid = [r for r in fr if 200 <= r.y0 < 390]
    if len(top) != 2 or not mid:
        raise RuntimeError(f"{sheet['title']}: frames {fr}")
    sens_r, dye_r = sorted(top, key=lambda r: r.x0)
    char_r = max(mid, key=lambda r: r.width * r.height)
    out = {}

    # --- spectral sensitivity
    gx, gy = gridlines(h, sens_r)
    ax = axis_fit(gx, x_labels(h, sens_r), 4.0)
    ylab = y_labels(h, sens_r)
    ylab_num = [p for p in ylab if True]
    ay = axis_fit(gy, ylab_num, 4.0) if len(ylab_num) >= 2 else None
    if ay is None:
        # Relative scale: no numbered axis, only a "1.0" bar. The bar spans the two inner horizontal
        # grid lines, so one grid interval is one decade; the level is arbitrary (fitted later).
        inner = [y for y in gy if sens_r.y0 + 1 < y < sens_r.y1 - 1]
        if len(inner) < 2:
            inner = list(gy)
        sp = float(np.median(np.diff(sorted(inner))))
        ay = {"a": -1.0 / sp, "b": sorted(inner)[0] / sp, "n_labels": 0, "residual_max": None,
              "grid_values": None, "relative": True, "decade_pt": sp, "spacing_spread_pt": float(np.ptp(np.diff(sorted(inner))))}
        bar = bar_length(h, sens_r)
        if bar is not None:
            ay["bar_tip_to_tip_pt"] = bar
    sheet["axes_sensitivity"] = {"x": ax, "y": ay}
    cs = curves_in(h, sens_r)
    solid = chain([p for p, d in cs if d == "solid"])
    dashed = chain([p for p, d in cs if d != "solid"])
    solid = [c for c in solid if np.ptp(c[:, 0]) > 8]
    if len(solid) != 3:
        sheet["warnings"].append(f"sensitivity: {len(solid)} solid curves")
    solid = sorted(solid, key=lambda c: c[np.argmin(c[:, 1]), 0])        # by the x of each peak
    for ch, c in zip("bgr", solid):
        out[f"log_sensitivity_{ch}"] = to_values(c, ax, ay)
    if dashed:
        sheet["extra_dashed_sensitivity"] = "a dashed fourth (cyan-sensitive) layer is drawn; not used"
        out["log_sensitivity_extra"] = to_values(dashed[0], ax, ay)

    # --- spectral dye density
    gx, gy = gridlines(h, dye_r)
    ax2 = axis_fit(gx, x_labels(h, dye_r), 4.0)
    ay2 = axis_fit(gy, y_labels(h, dye_r), 4.0)
    sheet["axes_dye"] = {"x": ax2, "y": ay2}
    cd = chain([p for p, d in curves_in(h, dye_r)])
    cd = [c for c in cd if np.ptp(c[:, 0]) > 20]
    if sheet["positive"]:
        if len(cd) != 3:
            sheet["warnings"].append(f"dye: {len(cd)} curves")
        cd = sorted(cd, key=lambda c: c[np.argmin(c[:, 1]), 0])[:3]
        for ch, c in zip("ymc", cd):
            out[f"dye_density_{ch}"] = to_values(c, ax2, ay2)
    else:
        if len(cd) != 2:
            sheet["warnings"].append(f"dye: {len(cd)} curves")
        cd = sorted(cd, key=lambda c: np.mean(c[:, 1]))[:2]            # smaller y = higher density
        out["dye_density_mid"] = to_values(cd[0], ax2, ay2)
        out["dye_density_min"] = to_values(cd[1], ax2, ay2)

    # --- characteristic curves
    gx, gy = gridlines(h, char_r)
    ax3 = axis_fit(gx, x_labels(h, char_r), 4.0)
    ay3 = axis_fit(gy, y_labels(h, char_r), 4.0)
    sheet["axes_characteristic"] = {"x": ax3, "y": ay3}
    cc = curves_in(h, char_r)
    if sheet["positive"]:
        leg = legend_dashes(h, char_r)
        sheet["legend"] = leg
        by = {}
        for p, d in cc:
            by.setdefault(d, []).append(p)
        pieces = {}
        for d, ps in by.items():
            if d not in leg:
                sheet["warnings"].append(f"characteristic: dash {d} not in legend {leg}")
                continue
            pieces[leg[d]] = [to_values(c, ax3, ay3) for c in chain(ps) if np.ptp(c[:, 0]) > 1.0]
        # Where the three records coincide Fujifilm draws one line (the solid one) and the dashed
        # ones stop: a dashed record is its own pieces where drawn, and the line it is hidden
        # under elsewhere. The base is the record drawn over the widest span.
        span = {k: sum(np.ptp(v[:, 0]) for v in vs) for k, vs in pieces.items()}
        base_k = max(span, key=span.get)
        base = max(pieces[base_k], key=lambda v: np.ptp(v[:, 0]))
        sheet["characteristic_hidden_fill"] = {}
        for k, vs in pieces.items():
            if k == base_k:
                out[f"density_curve_{k}"] = base
                sheet["characteristic_hidden_fill"][k] = 0.0
                continue
            x = base[:, 0].copy()
            y = base[:, 1].copy()
            own = np.zeros(len(x), bool)
            extra = []
            for v in vs:
                m = (x >= v[0, 0]) & (x <= v[-1, 0])
                y[m] = np.interp(x[m], v[:, 0], v[:, 1])
                own |= m
                extra.append(v[(v[:, 0] < x[0]) | (v[:, 0] > x[-1])])
            xy = np.vstack([np.column_stack([x, y])] + extra)
            xy = xy[np.argsort(xy[:, 0])]
            out[f"density_curve_{k}"] = xy
            sheet["characteristic_hidden_fill"][k] = round(float(1 - own.mean()), 3)
        sheet["characteristic_base_record"] = base_k
    else:
        ch = [c for c in chain([p for p, d in cc]) if np.ptp(c[:, 0]) > 30]
        if len(ch) != 3:
            sheet["warnings"].append(f"characteristic: {len(ch)} curves")
        ch = sorted(ch, key=lambda c: np.mean(c[:, 1]))                  # B highest density, then G, R
        names = {"Blue": "b", "Green": "g", "Red": "r"}
        lab = {names[t["text"]]: ((t["bbox"][0] + t["bbox"][2]) / 2, (t["bbox"][1] + t["bbox"][3]) / 2)
               for t in h.tokens if t["text"] in names and char_r.contains(pymupdf.Point(t["bbox"][0], t["bbox"][1]))}
        # check the order against the labels Fujifilm sets beside each curve
        for k, c in zip("bgr", ch):
            if k in lab:
                lx, ly = lab[k]
                dist = [np.min(np.hypot(cc_[:, 0] - lx, cc_[:, 1] - ly)) for cc_ in ch]
                if int(np.argmin(dist)) != "bgr".index(k):
                    sheet["warnings"].append(f"characteristic: label {k} is nearest another curve")
        for k, c in zip("bgr", ch):
            out[f"density_curve_{k}"] = to_values(c, ax3, ay3)
    for key in ("axes_sensitivity", "axes_dye", "axes_characteristic"):
        for a in ("x", "y"):
            if sheet[key][a] is None:
                sheet["warnings"].append(f"{key}.{a}: no calibration")
    sheet["frames"] = {"sensitivity": list(sens_r), "dye": list(dye_r), "characteristic": list(char_r)}
    return sheet, out


def bar_length(h, r):
    """Tip-to-tip length of the vertical '1.0' bar left of a relative sensitivity chart."""
    ys = []
    for d in h.drawings:
        rr = d["rect"]
        if rr.x1 < r.x0 and r.x0 - rr.x1 < 8 and rr.width < 3 and r.y0 - 2 < rr.y0 and rr.y1 < r.y1 + 2:
            ys += [rr.y0, rr.y1]
    return float(max(ys) - min(ys)) if len(ys) >= 4 else None


STOCKS = [  # (pattern in the sheet's title, stock id, display name)
    (r"Velvia for Professionals", "fujifilm_velvia_50", "Fujifilm Velvia 50"),
    (r"Velvia 100F", "fujifilm_velvia_100f", "Fujifilm Velvia 100F"),
    (r"Velvia 100 ", "fujifilm_velvia_100", "Fujifilm Velvia 100"),
    (r"PROVIA 100F", "fujifilm_provia_100f", "Fujifilm Provia 100F"),
    (r"PROVIA 400F", "fujifilm_provia_400f", "Fujifilm Provia 400F"),
    (r"ASTIA 100F", "fujifilm_astia_100f", "Fujifilm Astia 100F"),
    (r"64 ?T", "fujifilm_64t_type_ii", "Fujifilm 64T Type II"),
    (r"Sensia 100", "fujifilm_sensia_100", "Fujifilm Sensia 100"),
    (r"Sensia 200", "fujifilm_sensia_200", "Fujifilm Sensia 200"),
    (r"Sensia 400", "fujifilm_sensia_400", "Fujifilm Sensia 400"),
    (r"PRO 160S", "fujifilm_pro_160s", "Fujifilm Pro 160S"),
    (r"PRO 160C", "fujifilm_pro_160c", "Fujifilm Pro 160C"),
    (r"NPL 160", "fujifilm_npl_160", "Fujifilm NPL 160"),
    (r"PRO 400H", "fujifilm_pro_400h", "Fujifilm Pro 400H"),
    (r"PRO 800Z", "fujifilm_pro_800z", "Fujifilm Pro 800Z"),
    (r"REALA", "fujifilm_superia_reala", "Fujifilm Superia Reala"),
    (r"SUPERIA 100", "fujifilm_superia_100", "Fujifilm Superia 100"),
    (r"SUPERIA 200", "fujifilm_superia_200", "Fujifilm Superia 200"),
    (r"X-?TRA 400", "fujifilm_xtra_400", "Fujifilm Superia X-TRA 400"),
    (r"X-?TRA 800", "fujifilm_superia_xtra_800", "Fujifilm Superia X-TRA 800"),
    (r"SUPERIA 1600", "fujifilm_superia_1600", "Fujifilm Superia 1600"),
    (r"TRUE DEFINITION 400", "fujifilm_true_definition_400", "Fujifilm True Definition 400"),
    (r"nexia A200", "fujifilm_nexia_a200", "Fujifilm Nexia A200"),
    (r"nexia 400", "fujifilm_nexia_400", "Fujifilm Nexia 400"),
    (r"nexia 800", "fujifilm_nexia_800", "Fujifilm Nexia 800"),
]


def stock_id(title):
    for pat, sid, _ in STOCKS:
        if re.search(pat, title + " ", re.I):
            return sid
    return slug(title)


def slug(title):
    t = title.upper()
    t = re.sub(r"\[.*?\]", "", t)
    t = t.replace("FUJICHROME", "").replace("FUJICOLOR", "").replace("PROFESSIONAL", "").replace("FOR PROFESSIONALS", "")
    t = re.sub(r"[^A-Z0-9]+", "_", t).strip("_").lower()
    return "fujifilm_" + t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("out")
    ap.add_argument("--plots", action="store_true")
    args = ap.parse_args()
    doc = pymupdf.open(args.pdf)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    index = {}
    for pno in SPREADS:
        page = doc[pno - 1]
        W = page.rect.width
        # the printed page numbers are the two digits in each bottom corner
        corner = page.get_text("words", clip=pymupdf.Rect(0, 512, W, 532))
        lw = "".join(w[4] for w in sorted(corner) if w[0] < W / 2 and w[4].isdigit())
        left_no = int(lw) if lw else None
        for side, (x0, x1) in enumerate(((0, W / 2), (W / 2, W))):
            h_has = page.get_text("text", clip=pymupdf.Rect(x0, 40, x1, 70)).strip()
            if not h_has:
                continue
            sheet, data = read_sheet(page, x0, x1, (left_no + side) if left_no else None)
            sheet["pdf_page"] = pno
            sheet["pdf_half"] = "left" if side == 0 else "right"
            stock = stock_id(sheet["title"])
            d = out / stock
            d.mkdir(exist_ok=True)
            for k, v in data.items():
                np.savetxt(d / f"{k}.csv", v, delimiter=",", fmt="%.6f")
            (d / "sheet.json").write_text(json.dumps(sheet, indent=1))
            (d / "info.txt").write_text(f"{sheet['title']}\nFUJIFILM Professional Data Guide AF3-207U, p. {sheet['printed_page']}\n")
            sheet["stock"] = stock
            sheet["name"] = next((n for p_, s_, n in STOCKS if s_ == stock), stock)
            (d / "sheet.json").write_text(json.dumps(sheet, indent=1))
            index[stock] = {"title": sheet["title"], "page": sheet["printed_page"], "pdf_page": pno,
                            "warnings": sheet["warnings"], "rms": sheet["rms_granularity"],
                            "positive": sheet["positive"], "process": sheet["process"]}
            print(f"{stock:40s} p{sheet['printed_page']} {sheet['process']} rms {sheet['rms_granularity']} "
                  f"{'WARN ' + '; '.join(sheet['warnings']) if sheet['warnings'] else 'ok'}")
            if args.plots:
                plot(d, sheet, data)
    (out / "index.json").write_text(json.dumps(index, indent=1))


def plot(d, sheet, data):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, axs = plt.subplots(1, 3, figsize=(15, 4))
    col = {"r": "tab:red", "g": "tab:green", "b": "tab:blue", "c": "tab:cyan", "m": "m", "y": "gold",
           "min": "grey", "mid": "k", "extra": "tab:cyan"}
    for k, v in data.items():
        ch = k.split("_")[-1]
        i = 0 if k.startswith("log_sens") else (2 if k.startswith("dye") else 1)
        axs[i].plot(v[:, 0], v[:, 1], color=col[ch], ls="--" if ch == "extra" else "-")
    axs[0].set_title("log sensitivity")
    axs[1].set_title("characteristic")
    axs[2].set_title("dye density")
    fig.suptitle(sheet["title"])
    fig.savefig(d / "check.png", dpi=70)
    plt.close(fig)


if __name__ == "__main__":
    main()
