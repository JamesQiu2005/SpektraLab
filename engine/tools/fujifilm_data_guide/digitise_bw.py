#!/usr/bin/env python3
"""Digitise black-and-white film data sheets (HARMAN/Ilford fact sheets, Kodak F- and H- publications,
FUJIFILM's Professional Data Guide) from the PDF's vector paths.

    python digitise_bw.py SHEETS.json OUT_DIR [stock ...]

Each sheet entry names the charts to read by a point inside each frame:

    {"stock": ..., "name": ..., "pdf": ..., "iso": 125,
     "sens": {"page": 0, "at": [x, y], "axes": "ilford" | "labels", "pick": "top" | "solid" | "dash" | i},
     "char": {"page": 3, "at": [x, y], "axes": "ilford" | "labels", "times": [5, 7, 9] (optional, ascending)},
     "ci":   {"page": 7, "at": [x, y], "axes": "labels", "pick": ...}  (optional: contrast index vs time)}

Axes:
  "labels": numbers set as text below / left / right of the frame, each claiming its nearest grid line
            (digitise_cine.fit_axis; label centres where the chart has no inner grid).
  "ilford": HARMAN's 2001-2004 fact sheets set many axis numbers as outlines, so the axes come from the
            chart's own marks, in the layout every one of these sheets shares (checked against the sheets
            whose numbers are text: Pan F Plus, XP2 Super, Ortho Plus):
              spectrogram: six ticks under the frame = 400, 450 ... 650 nm; two ticks right of it = 1.0
                           (upper) and 0.5 'Sensitivity'. A sheet without those ticks (XP2 Super 2001) takes
                           its ordinate from the spec ("y_rel": [[offset below frame top, value], ...]).
              characteristic curve: grid lines every 0.5 relative log exposure (the frame's left edge 0)
                           and every 0.5 density (the bottom edge 0).
  "decade_grid": x from labels; y one decade per grid interval (FUJIFILM's spectrograms, "1.0" bar).
Curves are sampled from the Bezier paths (digitise.sample_items) and chained per line style.
"""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

import numpy as np
import pymupdf

sys.path.insert(0, str(Path(__file__).resolve().parent))
import digitise_cine as dc  # noqa: E402
from digitise import numeric  # noqa: E402


def tokens(page):
    return [{"text": w[4], "bbox": w[:4]} for w in page.get_text("words")]


def frame_at(page, at):
    x, y = at
    fs = [r for r in dc.frames(page) if r.x0 <= x <= r.x1 and r.y0 <= y <= r.y1]
    if not fs:
        raise SystemExit(f"no frame at {at} on page {page.number}")
    return min(fs, key=lambda r: r.width * r.height)


def lin(pairs):
    P = np.array(sorted(pairs), float)
    A = np.vstack([P[:, 0], np.ones(len(P))]).T
    (a, b), *_ = np.linalg.lstsq(A, P[:, 1], rcond=None)
    res = P[:, 1] - (a * P[:, 0] + b)
    return {"a": float(a), "b": float(b), "n": len(P), "residual_max": float(np.abs(res).max())}


def short_lines(page, r):
    """Tick marks: short straight strokes just outside the frame."""
    bottom, right = set(), set()
    for d in page.get_drawings():
        for it in d["items"]:
            if it[0] != "l":
                continue
            p, q = it[1], it[2]
            if abs(p.x - q.x) < 0.05 and 2 < abs(p.y - q.y) < 6 and min(p.y, q.y) >= r.y1 - 0.5 and max(p.y, q.y) < r.y1 + 6 \
                    and r.x0 < p.x < r.x1:
                bottom.add(round(p.x, 2))
            if abs(p.y - q.y) < 0.05 and 2 < abs(p.x - q.x) < 6 and min(p.x, q.x) >= r.x1 - 0.5 and max(p.x, q.x) < r.x1 + 6 \
                    and r.y0 < p.y < r.y1:
                right.add(round(p.y, 2))
    return sorted(bottom), sorted(right)


def right_labels(tk, r):
    out = []
    for t in tk:
        v = numeric(t)
        if v is None:
            continue
        b = t["bbox"]
        cy = (b[1] + b[3]) / 2
        if r.x1 - 2 <= b[0] <= r.x1 + 24 and r.y0 - 6 <= cy <= r.y1 + 6:
            out.append((cy, v))
    return out


def axes(page, r, kind, how, y_rel=None, x_vals=None):
    if how == "ilford" and kind == "sens":
        bt, rt = short_lines(page, r)
        x_vals = x_vals or [400 + 50 * i for i in range(6)]     # SFX 200: 400, 500 ... 800 (its own spec)
        if len(bt) != len(x_vals):
            raise SystemExit(f"ilford spectrogram: ticks {bt}")
        ax = lin(list(zip(bt, x_vals)))
        if y_rel:
            # no ticks on this sheet's ordinate: (offset below the frame top, value) pairs from the spec
            ay = lin([(r.y0 + d, v) for d, v in y_rel])
        elif len(rt) == 2:
            # the two ticks alone (the frame's bottom edge is not 0 on every sheet: FP4 Plus, Delta 400/3200)
            ay = lin([(rt[0], 1.0), (rt[1], 0.5)])
        else:
            raise SystemExit(f"ilford spectrogram: right ticks {rt}")
        return ax, ay
    if how == "ilford":
        xs, ys = dc.gridlines(page, r)
        ax = lin([(x, 0.5 * i) for i, x in enumerate(xs)])
        ay = lin([(y, 0.5 * (len(ys) - 1 - j)) for j, y in enumerate(ys)])
        return ax, ay
    tk = tokens(page)
    xs, ys = dc.gridlines(page, r)
    if how == "decade_grid":
        # FUJIFILM's guide: "Relative Sensitivity (log)" with one "1.0" bar spanning one grid interval, i.e. one
        # decade per interval (as its colour negatives); the zero is arbitrary (the bottom edge)
        ax = dc.fit_axis(xs, dc.labels(tk, r, "below"))
        ay = lin([(y, float(len(ys) - 1 - j)) for j, y in enumerate(ys)])
        return ax, ay
    lb = dc.labels(tk, r, "below")
    if kind == "char":
        lb = dc.sign_fix(lb)
    ax = dc.fit_axis(xs, lb)
    ly = dc.labels(tk, r, "left") or right_labels(tk, r)
    if kind == "sens":
        ly = dc.sign_fix(ly, increasing=False)     # "2 1 0 1 2": the minus signs of the lower half not set
    ay = dc.fit_axis(ys, ly)
    if ax is None or ay is None:
        raise SystemExit(f"axes not found: below {lb} left/right {ly}")
    return ax, ay


def filled_curve(page, r, dpi=600):
    """A curve set as filled outlines of its stroke (Ortho Plus's spectrogram): the frame's inside rendered at
    600 dpi and the stroke's centre taken per pixel column (median of its dark pixels)."""
    clip = pymupdf.Rect(r.x0 + 1.0, r.y0 + 1.0, r.x1 - 1.0, r.y1 - 1.0)
    pix = page.get_pixmap(dpi=dpi, clip=clip, colorspace=pymupdf.csGRAY)
    im = np.frombuffer(pix.samples, np.uint8).reshape(pix.height, pix.width) < 128
    sc = 72.0 / dpi
    xs, ys = [], []
    for j in range(im.shape[1]):
        k = np.where(im[:, j])[0]
        if len(k):
            xs.append(j); ys.append(np.median(k))
    return np.column_stack([clip.x0 + (np.array(xs) + 0.5) * sc, clip.y0 + (np.array(ys) + 0.5) * sc])


def raster_chart(page, clip, dpi=600):
    """A chart that is a raster image (DELTA 100's 2002 characteristic curve): rendered, its grid lines are the
    rows/columns mostly dark, the curve the remaining dark pixels (median per column). Returns grid lines and the
    curve in page coordinates."""
    pix = page.get_pixmap(dpi=dpi, clip=pymupdf.Rect(clip), colorspace=pymupdf.csGRAY)
    im = np.frombuffer(pix.samples, np.uint8).reshape(pix.height, pix.width) < 128
    sc = 72.0 / dpi
    rows = np.where(im.mean(1) > 0.5)[0]
    cols = np.where(im.mean(0) > 0.5)[0]

    def centres(ix):
        out, cur = [], [ix[0]]
        for i in ix[1:]:
            if i - cur[-1] <= 2:
                cur.append(i)
            else:
                out.append(np.mean(cur)); cur = [i]
        out.append(np.mean(cur))
        return np.array(out)
    gy, gx = centres(rows), centres(cols)
    m = im.copy()
    for i in rows:
        m[max(i - 1, 0):i + 2, :] = False
    for j in cols:
        m[:, max(j - 1, 0):j + 2] = False
    # columns on or next to a vertical grid line are skipped; in each column the dark run nearest the last
    # point is the curve (stray grid pixels never win)
    xs, ys = [], []
    top, bot = int(gy[0]) + 4, int(gy[-1]) - 3
    for j in range(int(gx[0]) + 4, int(gx[-1]) - 3):
        if np.min(np.abs(gx - j)) < 7:
            continue
        k = np.where(m[top:bot, j])[0]
        if len(k) < 3:
            continue
        runs = np.split(k, np.where(np.diff(k) > 1)[0] + 1)
        runs = [q for q in runs if len(q) >= 3]
        if not runs:
            continue
        cand = [float(np.mean(q)) for q in runs]
        y = cand[int(np.argmin([abs(c - ys[-1] + top) for c in cand]))] if ys else max(cand)
        xs.append(j); ys.append(y + top)
    x0, y0 = clip[0], clip[1]
    curve = np.column_stack([x0 + np.array(xs) * sc, y0 + np.array(ys) * sc])
    return x0 + gx * sc, y0 + gy * sc, curve


def raster_track(page, c, dpi=600):
    """One curve among several on a raster chart (Double-X 5222): the chart's long lines (frame and grid: rows or
    columns more than half dark) give the axes from the spec's values for the first line and the spacing; the
    curve is followed from a seed point column by column, taking the dark run nearest the curve's own straight
    continuation (a column with nothing within 6 px of it is bridged, 60 such columns in a row end it; the seed need only be within 40 px)."""
    clip = pymupdf.Rect(c["clip"])
    pix = page.get_pixmap(dpi=dpi, clip=clip, colorspace=pymupdf.csGRAY)
    im = np.frombuffer(pix.samples, np.uint8).reshape(pix.height, pix.width) < 140
    sc = 72.0 / dpi

    def centres(ix):
        out, cur = [], [ix[0]]
        for i in ix[1:]:
            if i - cur[-1] <= 2:
                cur.append(i)
            else:
                out.append(np.mean(cur)); cur = [i]
        out.append(np.mean(cur))
        return np.array(out)
    g = c["grid"]
    rows = np.where(im.mean(1) > g.get("frac", 0.5))[0]
    cols = np.where(im.mean(0) > g.get("frac", 0.5))[0]
    gy, gx = centres(rows), centres(cols)
    # a line hidden under a text box is missing: number the lines by the smallest spacing, not by their order
    nx = np.round((gx - gx[0]) / np.min(np.diff(gx))).astype(int) if len(gx) > 1 else np.zeros(1, int)
    ny = np.round((gy - gy[0]) / np.min(np.diff(gy))).astype(int) if len(gy) > 1 else np.zeros(1, int)
    ax = lin([(clip.x0 + x * sc, g["x0"] + g["dx"] * i) for i, x in zip(nx, gx)])
    ay = lin([(clip.y0 + y * sc, g["y0"] - g["dy"] * j) for j, y in zip(ny, gy)])
    m = im.copy()
    for i in rows:
        m[max(i - 2, 0):i + 3, :] = False
    for j in cols:
        m[:, max(j - 2, 0):j + 3] = False
    to_px = lambda xv, yv: (((xv - ax["b"]) / ax["a"] - clip.x0) / sc, ((yv - ay["b"]) / ay["a"] - clip.y0) / sc)
    sx, sy = to_px(*c["seed"])
    lo, hi = [to_px(v, 0)[0] for v in c["x_range"]]
    pts = {}
    for step in (1, -1):
        hist = [(int(sx), sy)]
        j, gap = int(sx), 0
        while lo <= j + step <= hi and gap < 60:
            j += step
            slope = 0.0
            if len(hist) >= 6:
                (j1, y1), (j2, y2) = hist[-6], hist[-1]
                slope = (y2 - y1) / (j2 - j1)
                pred = y2 + slope * (j - j2)
            else:
                pred = hist[-1][1]
            k = np.where(m[:, j])[0]
            runs = [q for q in np.split(k, np.where(np.diff(k) > 1)[0] + 1) if len(q)]
            # where the curve is steep, a long run that covers the prediction is the curve (one long run per column); otherwise a
            # run much longer than the stroke is a (hidden) grid line or a crossing and is passed over
            dist = lambda q: 0.0 if q[0] - 3 <= pred <= q[-1] + 3 else min(abs(q[0] - pred), abs(q[-1] - pred))
            runs = [q for q in runs if len(q) <= 30 or (dist(q) == 0.0 and abs(slope) > 1.0)]
            tol = (6 if len(hist) > 3 else 40) + 0.5 * gap
            q = min(runs, key=dist) if runs else None
            best = float(np.mean(q)) if q is not None else None
            if best is None or dist(q) > tol:
                gap += 1                       # under a grid line, a hidden grid line or a label: bridge it
                continue
            gap = 0
            hist.append((j, best))
            pts[j] = best
    J = np.array(sorted(pts))
    cur = np.column_stack([clip.x0 + (J + 0.5) * sc, clip.y0 + (np.array([pts[j] for j in J]) + 0.5) * sc])
    return dc.to_values(cur, ax, ay), {"clip": c["clip"], "raster_dpi": dpi, "x": ax, "y": ay, "grid": [len(gx), len(gy)],
                                       "seed": c["seed"], "tracked": [len(J), float(J.min()), float(J.max())]}


def read_chart(doc, c, kind):
    if c.get("pdf"):
        doc = pymupdf.open(c["pdf"])        # a chart taken from another edition of the sheet
    page = doc[c["page"]]
    if c.get("raster") and "seed" in c:
        v, info = raster_track(page, c)
        return [{"style": "solid", "colour": "k", "v": v}], info
    if c.get("raster"):
        gx, gy, cur = raster_chart(page, c["clip"])
        ax = lin([(x, 0.5 * i) for i, x in enumerate(gx)])
        ay = lin([(y, 0.5 * (len(gy) - 1 - j)) for j, y in enumerate(gy)])
        v = dc.to_values(cur, ax, ay)
        return [{"style": "solid", "colour": "k", "v": v}], {"clip": c["clip"], "raster_dpi": 600, "x": ax, "y": ay,
                                                             "grid": [len(gx), len(gy)]}
    r = frame_at(page, c["at"])
    if c.get("path"):
        # one path picked by its own dash pattern and line width (a legend that tells developers apart by both:
        # T-MAX P3200's and PLUS-X 125's contrast-index charts), its legend sample (a single stroke) excluded
        from digitise import sample_items
        ax, ay = axes(page, r, kind, c.get("axes", "labels"))
        want = [float(t) for t in c["path"]["dashes"]]
        for d in page.get_drawings():
            rr = d["rect"]
            if d["type"] != "s" or not r.contains(rr) or len(d["items"]) < 2:
                continue
            got = [float(t) for t in (d.get("dashes") or "[] 0").split("]")[0].strip("[ ").split()]
            if len(got) == len(want) and np.allclose(got, want, atol=0.01) and abs((d.get("width") or 0) - c["path"]["width"]) < 0.01:
                subs = sample_items([it for it in d["items"] if it[0] in "lc"])
                pts = np.vstack(subs)
                pts = pts[np.argsort(pts[:, 0])]
                v = dc.to_values(pts, ax, ay)
                return [{"style": "path", "colour": "k", "v": v}], {"frame": [round(t, 2) for t in r], "x": ax, "y": ay,
                                                                    "path": c["path"]}
        raise SystemExit(f"no path {c['path']}")
    if c.get("filled"):
        ax, ay = axes(page, r, kind, c.get("axes", "labels"), c.get("y_rel"), c.get("x_vals"))
        v = dc.to_values(filled_curve(page, r), ax, ay)
        return [{"style": "solid", "colour": "k", "v": v}], {"frame": [round(t, 2) for t in r], "x": ax, "y": ay,
                                                             "curve": "filled outline, centre of stroke"}
    ax, ay = axes(page, r, kind, c.get("axes", "labels"), c.get("y_rel"), c.get("x_vals"))
    groups = dc.group(dc.curves(page, r))
    out = []
    for (col, dash), pieces in groups.items():
        for p in pieces:
            v = dc.to_values(p, ax, ay)
            if len(v) > 3:
                out.append({"style": dash, "colour": col, "v": v})
    return out, {"frame": [round(t, 2) for t in r], "x": ax, "y": ay}


def pick(curves, how):
    if len(curves) == 1:
        return curves[0]
    if isinstance(how, dict):
        # {"style": "dash", "order": k}: the k-th curve of that style counted from the left (a legend that tells
        # the developers apart only by dash pattern: T-MAX 400's contrast-index chart, D-76 second from the left)
        cs = sorted([c for c in curves if c["style"] == how["style"]], key=lambda c: c["v"][0, 0])
        return cs[how["order"]]
    if isinstance(how, int):
        return sorted(curves, key=lambda c: -np.ptp(c["v"][:, 0]))[how]
    if how in ("solid", "dash", "drawn-dash"):
        cs = [c for c in curves if c["style"] == how]
        return max(cs, key=lambda c: np.ptp(c["v"][:, 0]))
    if how == "reddest":
        # the curve reaching furthest into the red (SFX 200 beside the sheet's "conventional film")
        return max(curves, key=lambda c: c["v"][-1, 0])
    if how in ("top", "bottom"):
        long = [c for c in curves if np.ptp(c["v"][:, 0]) > 0.5 * max(np.ptp(k["v"][:, 0]) for k in curves)]
        lo = max(c["v"][0, 0] for c in long); hi = min(c["v"][-1, 0] for c in long)
        mid = (lo + hi) / 2
        key = lambda c: np.interp(mid, c["v"][:, 0], c["v"][:, 1])
        return max(long, key=key) if how == "top" else min(long, key=key)
    raise SystemExit(f"pick {how}")


def char_family(curves, n, min_span):
    """The n development-time curves, ascending in contrast (density at the right end)."""
    long = [c for c in curves if np.ptp(c["v"][:, 0]) >= min_span]
    if len(long) < n:
        raise SystemExit(f"{len(long)} long curves, want {n}")
    long = sorted(long, key=lambda c: -np.ptp(c["v"][:, 0]))[:n]
    hi = min(c["v"][-1, 0] for c in long)
    return sorted(long, key=lambda c: np.interp(hi, c["v"][:, 0], c["v"][:, 1]))


def main():
    specs = json.loads(Path(sys.argv[1]).read_text())
    out = Path(sys.argv[2])
    want = set(sys.argv[3:])
    for s in specs:
        if want and s["stock"] not in want:
            continue
        doc = pymupdf.open(s["pdf"])
        dst = out / s["stock"]
        if dst.exists():
            shutil.rmtree(dst)
        dst.mkdir(parents=True)
        sheet = {k: v for k, v in s.items() if k not in ("sens", "char", "ci")}
        cs, info = read_chart(doc, s["sens"], "sens")
        c = pick(cs, s["sens"].get("pick", "top"))
        np.savetxt(dst / "log_sensitivity.csv", c["v"], delimiter=",", fmt="%.5f")
        sheet["sens_axes"] = info
        cs, info = read_chart(doc, s["char"], "char")
        times = s["char"].get("times")
        if times:
            fam = char_family(cs, len(times), s["char"].get("min_span", 1.0))
            for t, c in zip(times, fam):
                np.savetxt(dst / f"density_curve_{t}.csv", c["v"], delimiter=",", fmt="%.5f")
        else:
            c = pick(cs, s["char"].get("pick", 0))
            np.savetxt(dst / "density_curve.csv", c["v"], delimiter=",", fmt="%.5f")
        sheet["char_axes"] = info
        if "ci" in s:
            cs, info = read_chart(doc, s["ci"], "ci")
            c = pick(cs, s["ci"].get("pick", "solid"))
            np.savetxt(dst / "contrast_index.csv", c["v"], delimiter=",", fmt="%.5f")
            sheet["ci_axes"] = info
        (dst / "sheet.json").write_text(json.dumps(sheet, indent=1))
        print(s["stock"], "sens", sheet["sens_axes"]["x"]["residual_max"], sheet["sens_axes"]["y"]["residual_max"],
              "char", sheet["char_axes"]["x"]["residual_max"], sheet["char_axes"]["y"]["residual_max"])


if __name__ == "__main__":
    main()
