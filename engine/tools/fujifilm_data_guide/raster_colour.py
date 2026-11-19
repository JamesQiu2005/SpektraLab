#!/usr/bin/env python3
"""Curves from a colour raster chart in a PDF (Kodak's EKTACHROME 100D sheet: R/G/B sensitometry and
sensitivity, coloured dye curves), by colour.

    python raster_colour.py SPEC.json OUT_DIR

SPEC: {"pdf": ..., "charts": [{"name": "sens", "page": 2, "clip": [x0, y0, x1, y1],
        "grid": {"x0": v, "dx": step, "y0": v, "dy": step}, "x_scale": 1.0,
        "curves": {"log_sensitivity_b": "blue", ...}}, ...]}

The chart is rendered at 600 dpi. Its grid is the rows/columns of neutral (unsaturated) dark-to-mid grey pixels that
run across more than half of it; the first line found takes grid x0 / y0 (top line y0) and the others are numbered
by the smallest spacing, so a line hidden under a label does not shift the rest. Each named colour is a hue band
(saturated pixels only; "black": dark unsaturated pixels off the grid lines); its curve is the median row of the run of its
pixels per column that continues the curve (a label in the curve's colour is skipped). x values are multiplied by x_scale
(0.30103 for a camera-stop axis).
"""
from __future__ import annotations

import colorsys
import json
import sys
from pathlib import Path

import numpy as np
import pymupdf

HUES = {"red": [(0, 20), (335, 360)], "green": [(85, 175)], "blue": [(195, 265)], "yellow": [(40, 70)],
        "magenta": [(280, 330)], "cyan": [(175, 195)]}


def lin(pairs):
    P = np.array(sorted(pairs), float)
    A = np.vstack([P[:, 0], np.ones(len(P))]).T
    (a, b), *_ = np.linalg.lstsq(A, P[:, 1], rcond=None)
    return float(a), float(b), float(np.abs(P[:, 1] - (a * P[:, 0] + b)).max())


def centres(ix):
    out, cur = [], [ix[0]]
    for i in ix[1:]:
        if i - cur[-1] <= 2:
            cur.append(i)
        else:
            out.append(np.mean(cur)); cur = [i]
    out.append(np.mean(cur))
    return np.array(out)


def trace(page, c, dpi=600):
    clip = pymupdf.Rect(c["clip"])
    pix = page.get_pixmap(dpi=dpi, clip=clip, colorspace=pymupdf.csRGB)
    im = np.frombuffer(pix.samples, np.uint8).reshape(pix.height, pix.width, 3).astype(float) / 255
    mx, mn = im.max(2), im.min(2)
    sat = (mx - mn) / np.maximum(mx, 1e-6)
    hue = np.zeros(mx.shape)
    r, g, b = im[..., 0], im[..., 1], im[..., 2]
    d = np.maximum(mx - mn, 1e-6)
    hue = np.where(mx == r, (60 * (g - b) / d) % 360, np.where(mx == g, 60 * (b - r) / d + 120, 60 * (r - g) / d + 240))
    neutral = (sat < 0.15) & (mx < 0.80)
    G = c["grid"]
    rows = np.where(neutral.mean(1) > G.get("frac", 0.5))[0]
    cols = np.where(neutral.mean(0) > G.get("frac", 0.5))[0]
    gy, gx = centres(rows), centres(cols)
    nx = np.round((gx - gx[0]) / np.min(np.diff(gx))).astype(int)
    ny = np.round((gy - gy[0]) / np.min(np.diff(gy))).astype(int)
    ax = lin([(x, G["x0"] + G["dx"] * i) for i, x in zip(nx, gx)])
    ay = lin([(y, G["y0"] - G["dy"] * j) for j, y in zip(ny, gy)])
    gridmask = np.zeros(mx.shape, bool)
    for i in rows:
        gridmask[max(i - 3, 0):i + 4, :] = True
    for j in cols:
        gridmask[:, max(j - 3, 0):j + 4] = True
    lo, hi = int(gx[0]) + 4, int(gx[-1]) - 3
    top, bot = int(gy[0]) + 4, int(gy[-1]) - 3
    out = {}
    for name, colour in c["curves"].items():
        if colour == "black":
            m = (mx < 0.45) & (sat < 0.25) & ~gridmask
        else:
            m = (sat > 0.35) & (mx > 0.25) & np.any([(hue >= h0) & (hue < h1) for h0, h1 in HUES[colour]], axis=0)
        xs, ys = [], []
        for j in range(lo, hi):
            k = np.where(m[top:bot, j])[0]
            if len(k) >= 2:
                runs = [q for q in np.split(k, np.where(np.diff(k) > 2)[0] + 1) if len(q) >= 2]
                if not runs:
                    continue
                # the run that continues the curve (a label set in the curve's colour is not it); the first column
                # takes the longest run
                if ys and j - xs[-1] < 40:
                    q = min(runs, key=lambda q: abs(np.median(q) + top - ys[-1]))
                    if abs(np.median(q) + top - ys[-1]) > 12 + 2 * (j - xs[-1]):
                        continue
                else:
                    q = max(runs, key=len)
                xs.append(j); ys.append(np.median(q) + top)
        xs, ys = np.array(xs, float), np.array(ys, float)
        X = (ax[0] * xs + ax[1]) * c.get("x_scale", 1.0)
        Y = ay[0] * ys + ay[1]
        out[name] = np.column_stack([X, Y])
    info = {"clip": c["clip"], "raster_dpi": dpi,
            "x": {"a": ax[0], "b": ax[1], "residual_max": ax[2], "n": len(gx),
                  "source": f"raster grid lines at {dpi} dpi ({len(gx)} found, numbered by their spacing)"},
            "y": {"a": ay[0], "b": ay[1], "residual_max": ay[2], "n": len(gy),
                  "source": f"raster grid lines at {dpi} dpi ({len(gy)} found, numbered by their spacing)"}}
    return out, info


def main():
    spec = json.loads(Path(sys.argv[1]).read_text())
    dst = Path(sys.argv[2])
    dst.mkdir(parents=True, exist_ok=True)
    doc = pymupdf.open(spec["pdf"])
    info = {}
    for c in spec["charts"]:
        curves, info[c["name"]] = trace(doc[c["page"]], c)
        for n, v in curves.items():
            np.savetxt(dst / f"{n}.csv", v, delimiter=",", fmt="%.5f")
            print(c["name"], n, len(v), v[:, 0].min().round(2) if len(v) else None, v[:, 0].max().round(2) if len(v) else None,
                  v[:, 1].min().round(3) if len(v) else None, v[:, 1].max().round(3) if len(v) else None)
    (dst / "raster.json").write_text(json.dumps(info, indent=1))


if __name__ == "__main__":
    main()
