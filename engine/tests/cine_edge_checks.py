#!/usr/bin/env python3
"""API-SPEC §24 (2026-11-15): the cine film-edge gauges -- Super 8 (`8_super`), 16 mm single-perf Super 16
(`16_super`), 35 mm 4-perf (`35_4perf`), 65 mm 5-perf (`65_5perf`) and 15-perf (`65_15perf`). The engine does not band
the canvas, so there are no banded cases. Needs only `build.sh dylib`.

    python3 engine/tests/cine_edge_checks.py [--dylib path] [--base-dylib path]

`--base-dylib` is the engine from before these gauges (cc20c683, 2.4.1's integration branch): every existing format,
with every existing setting, film edge on and off, must render that engine's bytes. Without it that part is skipped.

Each gauge, read back off its own render (flat grey, white holes, halation and grain off):
  * the canvas: the film's whole width by the frame and a sliver of each neighbour (Super 8 3:2, 16 mm 16:9), or by
    one frame's advance (35 mm, 70 mm and 15-perf: single frames, the owner's 2026-11-12 decision), in mm;
  * the frame (the gate) in mm;
  * the holes: the pitch, their size along and across, how many a frame (1 / 1 / 4 / 5 / 15), one row on Super 8
    (the picture's right) and on 16 mm (the picture's left, as on the owner's scan) and two elsewhere, sprocket-locked
    (Super 8's hole centred on its frame, 16 mm's on the frame line, the others' frame line midway between two
    holes), the Bell & Howell shape on 35 mm;
  * the neighbours: the same picture again, its far end before the frame and its near end after it (Super 8 and
    16 mm); none on the single-frame gauges; on 16 mm each neighbour's strip is 5.5-8.5 % of the canvas along
    (the owner's scan: 5.9 % and 7.3 %), the frame line between them 0.07-0.15 mm (the scan: 0.09-0.10), and the
    strip is the same picture pixel for pixel, one advance along;
  * 16 mm portrait: the film runs across the picture;
  * nothing printed: an edge text, a frame number, a date in the frame, the rebate or the perforations, and a Fujifilm
    negative's stock change nothing on the rebate;
  * `pair` and `ks65` refused, a `spot`, `band` and `edge` leak drawn, a `wash` drawn with the film edge off; `filed`
    accepted (as 135_sprocket); the edge burn's hole light on a one-row gauge's perforated edge only.
"""
import argparse, sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes as spk  # noqa: E402

BASE = {"film_stock": "kodak_portra_400", "print_stock": "kodak_supra_endura", "grain_active": False,
        "glare_active": False, "auto_exposure": False, "halation_active": False}
# rows: 1 the t-low edge (the picture's right on a film running down it), 2 the t-high edge (the picture's left)
CINE = {
    "8_super":   dict(film=7.976, along=4.01, across=5.79, pitch=4.234, h_along=1.143, h_across=0.914, edge=0.51,
                      perfs=1, rows=1, bh=False, aspect=(3, 2), down=True, reg=0.08),
    "16_super":  dict(film=15.95, along=7.50, across=12.35, pitch=7.605, h_along=1.270, h_across=1.829, edge=0.902,
                      perfs=1, rows=2, bh=False, aspect=(16, 9), down=True, reg=0.04, at_line=True),
    "35_4perf":  dict(film=35.0, along=18.67, across=24.89, pitch=4.740, h_along=1.854, h_across=2.794, edge=2.01,
                      perfs=4, rows=0, bh=True, aspect=(3, 2), down=True, reg=0.03, single=True),
    "65_5perf":  dict(film=64.97, along=23.01, across=52.63, pitch=4.75, h_along=1.981, h_across=2.794, edge=2.97,
                      perfs=5, rows=0, bh=False, aspect=(20, 9), down=True, reg=0.03, single=True),
    "65_15perf": dict(film=64.97, along=70.41, across=52.63, pitch=4.75, h_along=1.981, h_across=2.794, edge=2.97,
                      perfs=15, rows=0, bh=False, aspect=(4, 3), down=False, reg=0.03, single=True),
}
failures = 0


def check(ok, what, detail=""):
    global failures
    print(("PASS " if ok else "FAIL ") + what + (f" -- {detail}" if detail else ""))
    failures += 0 if ok else 1


def guarded(what):
    """A check whose render failed is a failure, named, not a crash: the engine before these gauges refuses them."""
    def deco(fn):
        def run(*a, **k):
            try:
                return fn(*a, **k)
            except spk.EngineError as err:
                check(False, what, f"refused: {str(err)[:120]}")
            except Exception as err:   # noqa: BLE001 -- a measurement that found nothing is a failure too
                check(False, what, f"{type(err).__name__}: {str(err)[:120]}")
        return run
    return deco


def render(e, img, extra, geometry=False):
    p = dict(BASE); p.update(extra)
    s = e.open(img, p)
    try:
        rgba, _ = s.render("full")
        geo = s.overscan_geometry() if geometry else None
    finally:
        s.close()
    return (rgba, geo) if geometry else rgba


def refuses(e, img, extra, needle):
    try:
        render(e, img, extra)
        return False, "rendered"
    except spk.EngineError as err:
        return needle in str(err), str(err)[:110]


def v8(rgba):
    return rgba[..., :3].astype(np.float64) / 257.0


def frame_for(key, long_px=1200, value=0.18, picture=None, portrait=False):
    f = CINE[key]
    landscape = not portrait   # the gate's long edge on the picture's long edge (15-perf: the film runs across)
    lng, sht = max(f["along"], f["across"]), min(f["along"], f["across"])
    w, h = (long_px, int(round(long_px * sht / lng))) if landscape else (int(round(long_px * sht / lng)), long_px)
    if picture is None:
        return np.full((h, w, 3), value, np.float32)
    return picture(w, h)


def film_coords(geo, shape):
    """Each canvas pixel's (s, t) in mm relative to the gate's first corner, from the gate's corners."""
    g = np.array(geo["gates"][0]).reshape(4, 2) * [geo["canvas_w"], geo["canvas_h"]]
    us = (g[1] - g[0]) / np.linalg.norm(g[1] - g[0])
    ut = (g[3] - g[0]) / np.linalg.norm(g[3] - g[0])
    y, x = np.mgrid[0:shape[0], 0:shape[1]]
    dx, dy = x + 0.5 - g[0][0], y + 0.5 - g[0][1]
    mm = geo["mm_per_px"]
    return (dx * us[0] + dy * us[1]) * mm, (dx * ut[0] + dy * ut[1]) * mm


def runs1d(vals, mask):
    """(start, end) intervals of `vals` (sorted) where mask is true, split at gaps."""
    out = []
    order = np.argsort(vals)
    v, m = vals[order], mask[order]
    start = None
    for i in range(len(v)):
        if m[i] and start is None:
            start = v[i]
        if (not m[i]) and start is not None:
            out.append((start, v[i - 1]))
            start = None
    if start is not None:
        out.append((start, v[-1]))
    return out


@guarded("geometry and holes")
def geometry(e, key):
    f = CINE[key]
    rgba, geo = render(e, frame_for(key), {"overscan_active": True, "overscan_format": key, "overscan_holes": "white",
                                           "overscan_camera_seed": 3, "overscan_frame_seed": 2}, geometry=True)
    mm = geo["mm_per_px"]
    a, b = f["aspect"]
    along_c = f["film"] * b / a if f["down"] else f["film"] * a / b
    if f.get("single"):
        along_c = f["perfs"] * f["pitch"]   # one frame: the canvas is one frame's advance along
    cw, ch = geo["canvas_w"] * mm, geo["canvas_h"] * mm
    want = (f["film"], along_c) if f["down"] else (along_c, f["film"])
    check(abs(cw - want[0]) < 2.5 * mm and abs(ch - want[1]) < 2.5 * mm and geo["vertical"] == f["down"],
          f"{key}: the canvas is the film's width by " + ("one frame's advance" if f.get("single") else f"the frame and two slivers, {a}:{b}"),
          f"{cw:.3f} x {ch:.3f} mm, want {want[0]:.3f} x {want[1]:.3f} (aspect {max(cw, ch) / min(cw, ch):.4f})")
    ga, gx = geo["gate_mm"]
    check(abs(ga - f["along"]) < 0.01 * f["along"] and abs(gx - f["across"]) < 0.01 * f["across"],
          f"{key}: the frame is {f['across']} x {f['along']} mm", f"gate {gx:.3f} across x {ga:.3f} along")
    check(("neighbours_mm" in geo) and ((geo["neighbours_mm"] == [0, 0]) == bool(f.get("single"))),
          f"{key}: the geometry reports its neighbours (" + ("none" if f.get("single") else "one advance each") + ")",
          str(geo.get("neighbours_mm")))
    s, t = film_coords(geo, rgba.shape)
    L = v8(rgba).mean(-1)
    # a hole's edge at half its light over the rebate (the edge is soft: the scan's 17 um, RFC-032 §31)
    rebate = np.median(L[(t < -0.3) | (t > gx + 0.3)])
    bright = L > 0.5 * (rebate + np.percentile(L, 99.9))
    # where the film's edges are, relative to the gate: from the rebate's own end (the canvas is the film's width)
    t_lo, t_hi = t.min() + 0.5 * mm, t.max() - 0.5 * mm
    rows = []
    for side in (0, 1):
        tc = (t_lo + f["edge"] + 0.5 * f["h_across"]) if side == 0 else (t_hi - f["edge"] - 0.5 * f["h_across"])
        sel = np.abs(t - tc) < 0.75 * mm
        rr = [(a0, b0) for a0, b0 in runs1d(s[sel], bright[sel]) if b0 - a0 > 0.5 * f["h_along"]]
        rows.append((tc, rr))
    if f["rows"] == 1:
        check(len(rows[0][1]) >= 1 and len(rows[1][1]) == 0, f"{key}: one row of holes, on the picture's right",
              f"rows: {len(rows[0][1])} and {len(rows[1][1])} holes")
    elif f["rows"] == 2:
        check(len(rows[1][1]) >= 1 and len(rows[0][1]) == 0, f"{key}: one row of holes, on the picture's left",
              f"rows: {len(rows[0][1])} and {len(rows[1][1])} holes")
    else:
        check(len(rows[0][1]) >= 2 and len(rows[1][1]) >= 2, f"{key}: a row of holes on each edge",
              f"{len(rows[0][1])} and {len(rows[1][1])} holes")
    tc, rr = rows[1 if f["rows"] == 2 else 0]
    full = [(a0, b0) for a0, b0 in rr if a0 > s.min() + 0.02 and b0 < s.max() - 0.02]
    centres = np.array([(a0 + b0) / 2 for a0, b0 in full])
    lengths = np.array([b0 - a0 + mm for a0, b0 in full])
    if len(centres) >= 2:
        pitch = np.median(np.diff(centres))
        check(abs(pitch - f["pitch"]) < 0.02, f"{key}: pitch {f['pitch']} mm", f"{pitch:.4f}")
    check(len(lengths) > 0 and abs(np.median(lengths) - f["h_along"]) < max(0.03, 1.5 * mm),
          f"{key}: a hole is {f['h_along']} mm along", f"{np.median(lengths) if len(lengths) else float('nan'):.3f}")
    centre_s = 0.5 * ga
    k = int(np.argmin(np.abs(centres - centre_s)))
    sel = np.abs(s - centres[k]) < 0.75 * mm
    tr = [(a0, b0) for a0, b0 in runs1d(t[sel], bright[sel]) if abs((a0 + b0) / 2 - tc) < f["h_across"]]
    across = tr[0][1] - tr[0][0] + mm if tr else float("nan")
    check(abs(across - f["h_across"]) < max(0.03, 1.5 * mm), f"{key}: a hole is {f['h_across']} mm across", f"{across:.3f}")
    # its place across the film: this far from the film's edge, read on an open carrier (white past the film's
    # edges, so the edge shows; the canvas reaches 0.4 mm past each) along the hole's own middle
    o, go = render(e, frame_for(key), {"overscan_active": True, "overscan_format": key, "overscan_holes": "white",
                                       "overscan_camera_seed": 3, "overscan_frame_seed": 2, "overscan_carrier": "open"},
                   geometry=True)
    so, to = film_coords(go, o.shape)
    Lo = v8(o).mean(-1)
    lit = Lo > 0.5 * np.percentile(Lo, 99.9)   # the carrier's and the holes' light against the film
    near = float("nan")
    if tr:
        sel = np.abs(so - centres[k]) < 0.6 * mm
        runs = runs1d(to[sel], ~lit[sel])   # the film between the carrier's light and the hole's
        dark = [(a0, b0) for a0, b0 in runs if (a0 < 0 if f["rows"] != 2 else b0 > gx) and b0 - a0 < 3 * f["edge"]]
        if dark:
            a0, b0 = (dark[0] if f["rows"] != 2 else dark[-1])
            near = b0 - a0 + mm
    check(abs(near - f["edge"]) < max(0.05, 2.5 * mm), f"{key}: the holes are {f['edge']} mm from the film's edge",
          f"{near:.3f}")
    # how many a frame, and where they sit on it
    adv = f["perfs"] * f["pitch"]
    n = int(np.sum((centres >= centre_s - 0.5 * adv) & (centres < centre_s + 0.5 * adv))) if not f.get("at_line") \
        else int(np.sum((centres >= centre_s) & (centres < centre_s + adv)))
    off = centres[k] - centre_s
    line = f.get("at_line") or f["perfs"] % 2 == 0
    want_off = 0.5 * f["pitch"] if line else 0.0
    check(n == f["perfs"] and abs(abs(off) - want_off) < f["reg"] + 0.06,
          f"{key}: {f['perfs']} hole(s) a frame, sprocket-locked (" +
          ("the hole centred on the frame line" if f.get("at_line") else
           "the hole centred on its frame" if f["perfs"] % 2 else "the frame line midway between two holes") + ")",
          f"{n} in one advance; nearest centre {off:+.3f} mm from the frame's centre (want ±{want_off:.3f})")
    if f["bh"]:
        # Bell & Howell: a disc cut flat along; 90 % of the way out across, the hole is much shorter than at its middle
        R = 0.5 * f["h_across"]
        t_hole = 0.5 * (tr[0][0] + tr[0][1]) if tr else tc
        ext = []
        for dt in (0.0, 0.9 * R):
            sel = np.abs(t - (t_hole + dt)) < 0.75 * mm
            seg = [(a0, b0) for a0, b0 in runs1d(s[sel], bright[sel]) if abs((a0 + b0) / 2 - centres[k]) < f["pitch"] / 2]
            ext.append(max(b0 - a0 + mm for a0, b0 in seg) if seg else 0.0)
        check(ext[0] > 0 and ext[1] / ext[0] < 0.75, f"{key}: Bell & Howell holes (round sides, flat ends)",
              f"along at the middle {ext[0]:.3f}, at 0.9 R {ext[1]:.3f} mm (KS would keep ~0.9)")


@guarded("the neighbours")
def neighbours(e, key):
    """A picture red at its first end and blue at its last (along the film): the sliver before the frame shows the
    picture's last end, the sliver after it the first."""
    f = CINE[key]

    def picture(w, h):
        img = np.full((h, w, 3), 0.05, np.float32)
        if f["down"]:   # the film runs down the picture: the first end is its top
            img[: h // 2] = [0.5, 0.03, 0.03]; img[h // 2:] = [0.03, 0.03, 0.5]
        else:
            img[:, : w // 2] = [0.5, 0.03, 0.03]; img[:, w // 2:] = [0.03, 0.03, 0.5]
        return img
    rgba, geo = render(e, frame_for(key, picture=picture), {"overscan_active": True, "overscan_format": key,
                                                          "overscan_frame_seed": 4}, geometry=True)
    s, t = film_coords(geo, rgba.shape)
    ga, gx = geo["gate_mm"]
    v = v8(rgba)
    mm = geo["mm_per_px"]
    inside_t = (t > 0.1 * gx) & (t < 0.9 * gx)
    before = inside_t & (s < -1.0 * mm - 0.15) & (s > s.min() + 2 * mm)
    after = inside_t & (s > ga + 1.0 * mm + 0.15) & (s < s.max() - 2 * mm)
    if f.get("single"):
        # no neighbour's picture: outside the gate, unexposed film only (the gate's own flare, a thin line of the
        # frame's nearest edge, stays: before the gate it is red, after it blue -- a neighbour would be the other way)
        bo, af = inside_t & (s < -2 * mm), inside_t & (s > ga + 2 * mm)
        cb = v[bo].astype(float).mean(0) if bo.any() else np.zeros(3)
        ca = v[af].astype(float).mean(0) if af.any() else np.zeros(3)
        check(bo.any() and af.any() and cb[2] <= cb[0] + 3 and ca[0] <= ca[2] + 3,
              f"{key}: one frame, no neighbour's picture outside the gate",
              f"before {np.round(cb).astype(int).tolist()} ({int(bo.sum())} px), after {np.round(ca).astype(int).tolist()} ({int(af.sum())} px)")
        return
    cb, ca = v[before].mean(0), v[after].mean(0)
    check(before.any() and after.any() and cb[2] > cb[0] + 20 and ca[0] > ca[2] + 20,
          f"{key}: the neighbours are the same picture again (before: its far end; after: its near end)",
          f"before {np.round(cb).astype(int).tolist()}, after {np.round(ca).astype(int).tolist()}")


@guarded("16 mm against the owner's scan")
def sixteen(e):
    """16 mm (the owner's research/v2.4.1/16mm_film.png): each neighbour's strip a clear part of the canvas, a thin
    frame line, the strip the same picture one advance along, and a portrait picture turning the film."""
    key = "16_super"
    f = CINE[key]

    def picture(w, h):   # a ramp along the film plus texture: a pixel's place is recognisable
        rng = np.random.default_rng(3)
        y, x = np.mgrid[0:h, 0:w]
        img = 0.05 + 0.5 * (y / h)[..., None] * np.array([1.0, 0.6, 0.3]) + 0.1 * (x / w)[..., None]
        return (img + 0.08 * rng.random((h, w, 3))).astype(np.float32)
    rgba, geo = render(e, frame_for(key, long_px=1600, picture=picture),
                       {"overscan_active": True, "overscan_format": key, "overscan_camera_seed": 5,
                        "overscan_frame_seed": 3}, geometry=True)
    s, t = film_coords(geo, rgba.shape)
    ga, gx = geo["gate_mm"]
    mm = geo["mm_per_px"]
    L = v8(rgba).mean(-1)
    along = (geo["canvas_h"] if geo["vertical"] else geo["canvas_w"]) * mm
    nb_prev, nb_next = geo["neighbours_mm"]
    mid = 0.5 * ga
    # the strips: picture past each frame line, out to the canvas's end, in the middle of the gate across
    col = (t > 0.3 * gx) & (t < 0.7 * gx)
    lit = L > 0.5 * (np.median(L[col & (s > 0.2 * ga) & (s < 0.8 * ga)]) + L[(t > gx + 0.2)].min())
    s_lo, s_hi = s[col].min(), s[col].max()
    to_line = (mid - 0.5 * nb_prev) - s_lo   # from the canvas's end to the frame line's middle
    first_pic = s[col & lit & (s < -0.02)]
    last_pic = s[col & lit & (s > ga + 0.02)]
    top = (first_pic.max() - s_lo) / along if first_pic.size else 0.0
    bot = (s_hi - last_pic.min()) / along if last_pic.size else 0.0
    check(0.055 <= top <= 0.085 and 0.055 <= bot <= 0.085,
          "16_super: each neighbour's strip is 5.5-8.5 % of the canvas along (the scan: 5.9 % and 7.3 %)",
          f"{100 * top:.1f} % and {100 * bot:.1f} % of {along:.3f} mm; the canvas's end to the frame line {to_line:.3f} mm")
    # the frame line: unexposed film between the frame and each neighbour
    gap_prev = -(first_pic.max() if first_pic.size else 0.0)
    gap_next = (last_pic.min() - ga) if last_pic.size else 0.0
    fl0 = nb_prev - ga   # the frame line itself: one advance less the frame
    check(0.07 <= gap_prev <= 0.16 and 0.07 <= gap_next <= 0.16,
          "16_super: a thin frame line between the frame and each neighbour (the scan: 0.09-0.10 mm)",
          f"{gap_prev:.3f} and {gap_next:.3f} mm of unexposed film; one advance less the frame {fl0:.3f}")
    # the same picture, one advance along: the strip before the frame is the frame's last end
    v = v8(rgba)
    strip = col & (s < -0.08) & (s > s_lo + 2 * mm)
    a_xy = np.argwhere(strip)
    diffs = []
    g = np.array(geo["gates"][0]).reshape(4, 2) * [geo["canvas_w"], geo["canvas_h"]]
    us = (g[1] - g[0]) / np.linalg.norm(g[1] - g[0])
    for yy, xx in a_xy[:: max(1, len(a_xy) // 400)]:
        dx = us * nb_prev / mm
        y2, x2 = int(round(yy + dx[1])), int(round(xx + dx[0]))
        if 0 <= y2 < v.shape[0] and 0 <= x2 < v.shape[1]:
            diffs.append(np.abs(v[yy, xx] - v[y2, x2]).mean())
    ref = np.abs(np.diff(v[strip][:, 0])).mean() if strip.any() else 0.0
    check(len(diffs) > 50 and np.median(diffs) < 4.0, "16_super: each neighbour is the same picture, one advance along",
          f"median |difference| {np.median(diffs) if diffs else float('nan'):.2f} of 255 over {len(diffs)} px "
          f"(the picture's own texture {ref:.1f})")
    # portrait: the film runs across the picture, the canvas the film's width tall
    _, gp = render(e, frame_for(key, portrait=True), {"overscan_active": True, "overscan_format": key}, geometry=True)
    check(not gp["vertical"] and abs(gp["canvas_h"] * gp["mm_per_px"] - f["film"]) < 2.5 * gp["mm_per_px"],
          "16_super portrait: the film runs across the picture", f"vertical {gp['vertical']}, "
          f"{gp['canvas_w'] * gp['mm_per_px']:.3f} x {gp['canvas_h'] * gp['mm_per_px']:.3f} mm")


@guarded("nothing printed")
def nothing_printed(e, key):
    img = frame_for(key)
    base = {"overscan_active": True, "overscan_format": key, "overscan_camera_seed": 7, "overscan_frame_seed": 1}
    plain = render(e, img, base)
    for what, extra in (
            ("an edge text, a frame number and a strong factory print",
             {"overscan_edge_text": "KODAK 5219 EXR", "overscan_frame_number": 12}),
            ("a date in the frame", {"date_imprint_active": True, "date_imprint_text": "'26 11 12"}),
            ("a date and data in the rebate", {"date_imprint_active": True, "date_imprint_text": "'26 11 12",
                                               "date_imprint_placement": "rebate", "date_imprint_data_text": "F8 1/125"}),
            ("a data line between the perforations", {"date_imprint_active": True, "date_imprint_style": "data",
                                                     "date_imprint_text": "P|180|F8", "date_imprint_data_placement": "perfs"})):
        check(np.array_equal(render(e, img, dict(base, **extra)), plain), f"{key}: {what} prints nothing")
    rgba, geo = render(e, img, dict(base, film_stock="fujifilm_xtra_400", overscan_holes="black"), geometry=True)
    s, t = film_coords(geo, rgba.shape)
    v = v8(rgba)
    t_lo = t.min() + 0.5 * geo["mm_per_px"]
    vals = []
    for dt in (2.83, 3.73):
        if t_lo + dt >= -0.3:   # only where it is rebate (not inside the gate)
            continue
        r = v[np.abs(t - (t_lo + dt)) < 0.75 * geo["mm_per_px"]]
        vals.append(max(np.percentile(r[:, 1] - r[:, 0], 75), np.percentile(r[:, 0] - r[:, 1], 75)))
    check(all(x_ < 10 for x_ in vals), f"{key}: X-TRA 400 carries no Fujifilm stripes here",
          f"{np.round(vals, 1).tolist()} (8-bit, rows at 2.83 / 3.73 mm that are rebate)" if vals else "(no rebate there)")


@guarded("refusals and the strip view")
def refusals(e, key):
    img = frame_for(key)
    base = {"overscan_active": True, "overscan_format": key}
    for field, extra, needle in (("overscan_pair", {"overscan_pair": True}, "pair"),
                                 ("overscan_perforation = ks65", {"overscan_perforation": "ks65"}, "ks65")):
        ok, msg = refuses(e, img, dict(base, **extra), needle)
        check(ok, f"{key}: {field} is refused", msg)
    plain = render(e, img, dict(base, overscan_camera_seed=2))
    # (the edge burn is `leak_edge` beside the kind since 2026-11-16, API-SPEC §21.9)
    for kind in ("spot", "band", "edge"):
        lk = {"leak_edge": 1.0} if kind == "edge" else {"leak_kind": kind}
        check(not np.array_equal(render(e, img, dict(base, **lk, overscan_camera_seed=2)), plain),
              f"{key}: a {kind} leak draws")
    a, ga = render(e, img, dict(base, overscan_mode="filed"), geometry=True)
    b, gb = render(e, img, base, geometry=True)
    across = lambda g: (g["canvas_w"] if g["vertical"] else g["canvas_h"]) * g["mm_per_px"]
    # (filed's 1.1 mm a side is past both edges of Super 8's 7.976 mm film: there it is the strip's width)
    want = across(ga) < across(gb) if key != "8_super" else abs(across(ga) - (CINE[key]["across"] + 2.2)) < 0.05
    check(want, f"{key}: filed is accepted (as 135_sprocket): the gate and 1.1 mm a side",
          f"{across(ga):.2f} against the strip's {across(gb):.2f} mm")
    off = {"overscan_active": False, "overscan_format": key, "overscan_camera_seed": 2}
    check(not np.array_equal(render(e, img, dict(off, leak_kind="wash")), render(e, img, off)),
          f"{key}: a wash leak draws with the film edge off (the format's nominal gate)")


@guarded("the edge burn's holes")
def edge_burn_rows(e, key):
    """The edge burn lets light in at the holes (API-SPEC §21.9): on a one-row gauge only at the perforated edge,
    with the film edge on and off (the gauge's own rows, not 135's 2.00 / 2.80)."""
    f = CINE[key]
    if f["rows"] == 0:
        return
    img = frame_for(key, value=0.02)
    q = {"overscan_active": True, "overscan_format": key, "leak_edge": 0.5,
         "overscan_camera_seed": 11, "overscan_holes": "black"}
    rgba, geo = render(e, img, q, geometry=True)
    s, t = film_coords(geo, rgba.shape)
    d0, d1 = t - t.min(), t.max() - t   # from each edge
    v = v8(rgba).mean(-1)
    row = lambda d: np.median(v[(d > f["edge"] + 0.15 * f["h_across"]) & (d < f["edge"] + 0.85 * f["h_across"])])
    inward = lambda d: np.median(v[(d > f["edge"] + f["h_across"] + 0.05) & (d < f["edge"] + f["h_across"] + 0.25)])
    other_d = d1 if f["rows"] == 1 else d0
    # the unperforated edge has no row to light: what lies where a row would be is no brighter than just inward
    # of it plus the burn's own fall (the burn falls off inward, so the outer band is a little brighter anyway)
    outer = lambda d: np.median(v[(d > 0.3 * f["edge"]) & (d < 0.6 * f["edge"])])
    check(row(other_d) <= max(inward(other_d), outer(other_d)) + 1.0, f"{key}: no hole light on the unperforated edge",
          f"where a row would be {row(other_d):.1f}; just inward {inward(other_d):.1f}; nearer the edge {outer(other_d):.1f}")
    # with the film edge off the burn runs (the gauge's own rows; a frame alone shows no rebate to read them from)
    off = render(e, img, dict(q, overscan_active=False))
    check(not np.array_equal(off, render(e, img, {"overscan_format": key})), f"{key}: an edge burn draws with the film edge off")


@guarded("the format table")
def table(e):
    """`spk_overscan_formats` (API-SPEC §24): the engine's own table, no session -- what a host lays a film out with
    before it develops. Each gauge's row as this file has it, and its `neighbours` the render's own."""
    rows = {f["name"]: f for f in e.overscan_formats()["formats"]}
    for key, f in CINE.items():
        r = rows.get(key, {})
        c = r.get("cine", {})
        want = {"film_mm": f["film"], "across_mm": f["across"], "along_mm": f["along"]}
        want_c = {"pitch_mm": f["pitch"], "hole_along_mm": f["h_along"], "hole_across_mm": f["h_across"],
                  "hole_edge_mm": f["edge"], "perfs": f["perfs"], "rows": f["rows"], "shape": 1 if f["bh"] else 0,
                  "aspect": list(f["aspect"]), "neighbours": not f.get("single"), "at_line": bool(f.get("at_line"))}
        bad = [k for k, v in want.items() if abs(r.get(k, -1) - v) > 1e-9] + \
              [k for k, v in want_c.items() if c.get(k) != v and not (isinstance(v, float) and abs(c.get(k, -1) - v) < 1e-9)]
        check(not bad and r.get("perforated") is False, f"{key}: the engine's table row", f"differs: {bad}" if bad else "")
    still = [n for n, r in rows.items() if "cine" not in r]
    check(still == ["135", "135_half", "120_645", "120_6x6", "120_6x7", "120_6x8", "120_6x9", "135_xpan", "120_6x12",
                    "120_6x17", "135_sprocket"], "the still formats carry no cine row, in the engine's order", str(still))


# --- off is off: every existing format, byte for byte ----------------------------------------------------------------------
OLD = [("135", (1200, 800)), ("135_half", (600, 800)), ("120_645", (560, 747)), ("120_6x6", (700, 700)),
       ("120_6x7", (834, 672)), ("120_6x8", (912, 672)), ("120_6x9", (1008, 672)), ("135_xpan", (1300, 480)),
       ("120_6x12", (1120, 560)), ("120_6x17", (1500, 500)), ("135_sprocket", (1200, 600))]


def scene(w, h, seed=1):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    img = 0.04 + 0.4 * (x / w)[..., None] * np.array([1.0, 0.9, 0.7]) + 0.3 * (y / h)[..., None]
    img[h // 3:h // 3 + 30, w // 2:w // 2 + 30] = 4.0
    return (img + 0.01 * rng.standard_normal((h, w, 3))).astype(np.float32)


def byte_identity(e, base):
    full = dict(BASE, halation_active=True)
    n_ok, n, bad = 0, 0, []
    for fmt, (w, h) in OLD:
        img = scene(w, h)
        cases = [{"overscan_active": True, "overscan_format": fmt, "overscan_fog": 1.0, "overscan_leaks": 2.0,
                  "overscan_edge_text": "PORTRA 400", "overscan_holes": "black", "overscan_camera_seed": 9},
                 {"overscan_active": True, "overscan_format": fmt, "film_stock": "fujifilm_xtra_400", "leak_kind": "band",
                  "overscan_mode": "filed", "date_imprint_active": True, "date_imprint_text": "'26 11 12"},
                 {"overscan_active": True, "overscan_format": fmt, "leak_kind": "edge", "overscan_camera_seed": 4},
                 {"overscan_format": fmt, "leak_kind": "edge", "overscan_camera_seed": 4},
                 {"overscan_format": fmt, "leak_kind": "wash", "leak_seed": 99}]
        if fmt.startswith("120"):
            cases.append({"overscan_active": True, "overscan_format": fmt, "film_stock": "kodak_vision3_250d",
                          "overscan_perforation": "ks65", "leak_kind": "spot"})
        if fmt == "135_half":
            cases.append({"overscan_active": True, "overscan_format": fmt, "overscan_pair": True})
        for extra in cases:
            ww, hh = (w + int(round(w * 19.0 / 18.0)), h) if extra.get("overscan_pair") else (w, h)
            im = scene(ww, hh) if extra.get("overscan_pair") else img
            p = dict(full, **extra)
            # the base's `leak_kind = edge` is this engine's off + `leak_edge` at its amount (API-SPEC §21.9, 2026-11-16)
            pe = p if p.get("leak_kind") != "edge" else dict({k: v for k, v in p.items() if k != "leak_kind"},
                                                             leak_edge=p.get("leak_amount", 1.0))
            a, b = render(e, im, pe), render(base, im, p)
            n += 1
            if np.array_equal(a, b):
                n_ok += 1
            else:
                bad.append(f"{fmt} {sorted(extra)}")
    check(n_ok == n, "every existing format renders the engine before the cine gauges byte for byte",
          f"{n_ok}/{n} identical" + (f"; differ: {bad[:4]}" if bad else ""))
    for extra in ({"date_imprint_active": True, "date_imprint_text": "'26 11 12"},
                  {"leak_kind": "wash", "overscan_format": "120_6x7", "overscan_camera_seed": 4},
                  {}):
        img = scene(900, 600)
        p = dict(full, **extra)
        check(np.array_equal(render(e, img, p), render(base, img, p)),
              f"film edge off, byte for byte the engine before: {sorted(extra) or 'nothing'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib", type=Path)
    ap.add_argument("--base-dylib", type=Path)
    a = ap.parse_args()
    e = spk.Engine(a.dylib)
    base = spk.Engine(a.base_dylib) if a.base_dylib else None
    try:
        if base is not None:
            byte_identity(e, base)
        else:
            print("SKIP the byte comparison with the engine before (no --base-dylib)")
        table(e)
        for key in CINE:
            geometry(e, key)
            neighbours(e, key)
            nothing_printed(e, key)
            refusals(e, key)
            edge_burn_rows(e, key)
        sixteen(e)
    finally:
        for x in (e, base):
            if x is not None:
                x.close()
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
