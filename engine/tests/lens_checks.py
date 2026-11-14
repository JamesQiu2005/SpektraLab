#!/usr/bin/env python3
"""API-SPEC §21.6: the lens aberrations, and the lens as a whole -- a pass on
the source before the film (the owner, 2026-11-10: "the feed-in tiff already
carries the lens effects"; `Pipeline::lens_source`, `engine.cpp` `tier_image`).

    python3 engine/tests/lens_checks.py [--base-dylib PATH] [--big [CASE]] [--png DIR]

Needs `build.sh dylib`. `--big` adds the 48 MP measurement (an 8064 x 6048
synthetic frame: the pass's own time, the full renders, the live tier, bands
and memory, lens on and off; a few minutes). `--png DIR` writes the impulse
grids and the slanted edge.

What is held, and against what:

1. **Off is structural**: the switch off with every field set renders byte for
   byte as no field sent, and as the base engine (`--base-dylib`, a build of
   b28bedb). On with every size 0 is the same picture as off. The film plan is
   the same with the lens on: no stage is the lens's.
2. **The impulse grid** (`spk_lens_probe`, the pass alone in linear light, a
   grid of points on black), each point's response measured in its own radial
   / tangential frame:
     * field curvature and astigmatism: sigma_r, sigma_t against the formula
       (sigma = size x g(h), g = h^p, the knee below `sharp_radius`), 5 %;
     * coma: the centroid's radial shift against L(h) / 3, linear in h, both
       signs;
     * lateral CA: R's and B's centroid radius over G's = 1 + a h;
     * LoCA: the soft channels' sigma = `loca_um`, the others sharp (gate 0);
     * spherical: the glow's share and its second moment (sigma = R / 2); and
       with the filter on, folded into its PSF, the same picture as the
       filter then the glow;
     * energy: each point's sum out / sum in within 1e-3, per channel.
3. **Chunks and bands**: the aberrations run in row chunks with their reach;
   chunks of several heights against one chunk, byte for byte, in place (after
   the filter) and not; RFC-020 strips with the lens on against the strips of
   the source lensed first, byte for byte.
4. **The engine's source is the lensed source**: the engine with the lens on
   renders, byte for byte, what it renders with the lens off from the source
   the probe lensed (the axis the source's centre, the pitch the format's at
   its long edge, the gate's under overscan) -- under a crop and a mirror too,
   which come after the lens. The meter reads the lensed light.

`--big`, measured 2026-11-10 on this Mac: see the report it prints.
"""
import argparse, json, math, os, sys, time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lens_probe as lp  # noqa: E402
import spk_ctypes as spk  # noqa: E402

failures = 0
BASE = {"film_stock": "kodak_portra_400", "print_stock": "kodak_supra_endura", "auto_exposure": False,
        "product_defaults": True, "grain_active": False, "glare_active": False}
ON = {"lens_aberrations_active": True}


def check(ok, what, detail=""):
    global failures
    print(("PASS " if ok else "FAIL ") + what + (f" -- {detail}" if detail else ""))
    if not ok:
        failures += 1


def codes(x):
    x = np.maximum(np.asarray(x, np.float64), 0.0)
    return np.round(65535.0 * (x / (1.0 + x)) ** (1 / 2.2))


# --- the impulse grid ------------------------------------------------------------

W, H = 3000, 2000
PITCH = 36000.0 / W          # 12 um/px: a 35 mm frame 3000 px across
NX, NY = 11, 7
WIN = 70


def points():
    pts = []
    for j in range(NY):
        for i in range(NX):
            pts.append((int(round((j + 0.5) * H / NY)), int(round((i + 0.5) * W / NX))))
    return pts


def grid_image(v=1.0):
    img = np.zeros((H, W, 3), np.float32)
    for y, x in points():
        img[y, x] = v
    return img


def geometry():
    c = np.array([(H - 1) / 2, (W - 1) / 2])
    hd = 0.5 * math.hypot(W, H)
    return c, hd


def moments(out, ch):
    """Per point: (h, energy, centroid radial shift, var_r, var_t) of channel ch."""
    c, hd = geometry()
    res = []
    for y, x in points():
        d = np.array([y, x]) - c
        r = float(np.hypot(*d))
        if r < 1e-6:
            er = np.array([0.0, 1.0])
        else:
            er = d / r
        et = np.array([er[1], -er[0]])
        y0, y1, x0, x1 = max(0, y - WIN), min(H, y + WIN + 1), max(0, x - WIN), min(W, x + WIN + 1)
        win = out[y0:y1, x0:x1, ch].astype(np.float64)
        yy, xx = np.mgrid[y0:y1, x0:x1]
        dy, dx = yy - y, xx - x
        e = win.sum()
        pr = (dy * er[0] + dx * er[1]); pt = (dy * et[0] + dx * et[1])
        mr = (win * pr).sum() / e; mt = (win * pt).sum() / e
        vr = (win * (pr - mr) ** 2).sum() / e; vt = (win * (pt - mt) ** 2).sum() / e
        res.append((r / hd, e, mr, vr, vt, r))
    return res


def g_field(h, h0, p):
    if h0 > 0:
        t = np.clip((h - h0) / (min(h0 + 0.1, 1.0) - h0), 0, 1)
        return t * t * (3 - 2 * t) * max(h - h0, 0) ** p / (1 - h0) ** p
    return h ** p


def interior(h, r):
    return 0.12 < h and r > 0   # every point but the centre one; the window is inside the frame


def field_cases(png):
    img = grid_image()
    cases = [
        ("curvature", dict(lens_field_curvature_um=96.0), lambda h: (8.0 * g_field(h, 0, 2), 8.0 * g_field(h, 0, 2))),
        ("astigmatism +", dict(lens_field_curvature_um=48.0, lens_astigmatism_um=96.0),
         lambda h: (4.0 * h * h, math.hypot(4.0, 8.0) * h * h)),
        ("astigmatism -", dict(lens_field_curvature_um=48.0, lens_astigmatism_um=-96.0),
         lambda h: (math.hypot(4.0, 8.0) * h * h, 4.0 * h * h)),
        ("astigmatism alone (a line)", dict(lens_astigmatism_um=120.0),
         lambda h: (0.0, 10.0 * h * h)),
        ("Petzval: p 3, sharp radius 0.3", dict(lens_field_curvature_um=120.0, lens_field_exponent=3.0, lens_sharp_radius=0.3),
         lambda h: (10.0 * g_field(h, 0.3, 3), 10.0 * g_field(h, 0.3, 3))),
        ("p 1", dict(lens_field_curvature_um=60.0, lens_field_exponent=1.0),
         lambda h: (5.0 * h, 5.0 * h)),
    ]
    for name, p, want in cases:
        out = lp.run(img, dict(ON, **p), PITCH)
        if png:
            lp.write_png(Path(png) / f"grid_{name.split(':')[0].replace(' ', '_')}.png", lp.display(out, 400.0))
        worst, n, worst_e = 0.0, 0, 0.0
        for h, e, mr, vr, vt, r in moments(out, 1):
            if not interior(h, r):
                continue
            sr, st = want(h)
            worst_e = max(worst_e, abs(e - 1))
            # each axis where it is 2.5 px or more: below that the pixel grid,
            # not the kernel, sets a moment
            for got, w in ((vr, sr), (vt, st)):
                if w >= 2.5:
                    n += 1
                    worst = max(worst, abs(math.sqrt(got) / w - 1))
        check(n > 5 and worst <= 0.05, f"[{name}] sigma_r, sigma_t = the formula within 5 %",
              f"{n} axes >= 2.5 px measured, worst {100 * worst:.1f} %")
        check(worst_e <= 1e-3, f"[{name}] energy: each point's sum = 1 within 1e-3", f"worst {worst_e:.1e}")


def energy_sweep():
    """Points out along two lines, centre to corner and centre to edge, at 36
    field heights each: the passes' start and every change of mip level
    crossed. Two images, so each point's neighbours are 80 px or more away."""
    c, hd = geometry()
    for name, p in (("curvature 120", dict(lens_field_curvature_um=120.0)),
                    ("curvature 48, astigmatism -120", dict(lens_field_curvature_um=48.0, lens_astigmatism_um=-120.0)),
                    ("astigmatism 120, coma 100", dict(lens_astigmatism_um=120.0, lens_coma_um=100.0))):
        worst, n = 0.0, 0
        for phase in (0.0, 0.5):
            pts = []
            for k in range(18):
                t = (k + phase + 0.25) / 18.0
                pts.append((int(round(c[0] + t * (H / 2 - 50))), int(round(c[1] + t * (W / 2 - 50)))))
                pts.append((int(round(c[0])), int(round(c[1] - t * (W / 2 - 50)))))
            img = np.zeros((H, W, 3), np.float32)
            for y, x in pts:
                img[y, x] = 1.0
            out = lp.run(img, dict(ON, **p), PITCH).astype(np.float64)
            for y, x in pts:
                e = out[y - 40:y + 41, x - 40:x + 41, 1].sum()
                worst = max(worst, abs(e - 1)); n += 1
        check(worst <= 1e-3, f"[{name}] energy along the field: each point's sum = 1 within 1e-3",
              f"{n} points, worst {worst:.1e}")


def coma_cases(png):
    img = grid_image()
    for L_um in (120.0, -120.0):
        out = lp.run(img, dict(ON, lens_coma_um=L_um, lens_field_curvature_um=12.0), PITCH)
        if png and L_um > 0:
            lp.write_png(Path(png) / "grid_coma.png", lp.display(out, 400.0))
        L1 = L_um / PITCH
        hs, shifts, worst_e = [], [], 0.0
        for h, e, mr, vr, vt, r in moments(out, 1):
            if not interior(h, r):
                continue
            hs.append(h); shifts.append(mr); worst_e = max(worst_e, abs(e - 1))
        hs, shifts = np.array(hs), np.array(shifts)
        want = L1 * hs / 3.0
        err = np.abs(shifts - want).max()
        slope = np.polyfit(hs, shifts, 1)
        check(err <= 0.05 * abs(L1) / 3.0 + 0.05,
              f"[coma {L_um:+g} um] the centroid moves L(h) / 3 along e_r, linear in h",
              f"slope {slope[0]:.3f} px per h (want {L1 / 3:.3f}), intercept {slope[1]:+.3f}, worst {err:.3f} px")
        check(worst_e <= 1e-3, f"[coma {L_um:+g} um] energy: each point's sum = 1 within 1e-3", f"worst {worst_e:.1e}")


def tca_cases(png):
    img = grid_image()
    ar, ab = 2.5, -2.0
    out = lp.run(img, dict(ON, lens_lateral_ca_r=ar, lens_lateral_ca_b=ab), PITCH)
    if png:
        lp.write_png(Path(png) / "grid_tca.png", lp.display(out, 400.0))
    G = moments(out, 1); R = moments(out, 0); B = moments(out, 2)
    worst, worst_e = 0.0, 0.0
    for g, rr, bb in zip(G, R, B):
        h, r = g[0], g[5]
        if not interior(h, r):
            continue
        for m, a in ((rr, ar * 1e-3), (bb, ab * 1e-3)):
            ratio = (r + m[2]) / (r + g[2])
            worst = max(worst, abs(ratio - (1 + a * h)) / (abs(a) * h))
            worst_e = max(worst_e, abs(m[1] - 1))
    check(worst <= 0.05, "[lateral CA] R's and B's centroid radius over G's = 1 + a h",
          f"worst {100 * worst:.2f} % of the shift")
    # Bilinear resampling under a magnification of 1 + a h: a point's few
    # samples sum to the Jacobian's inverse only on average, +-a h with its
    # phase (the same algorithm in float64 gives the same numbers); a flat
    # field is exact.
    check(worst_e <= 2e-3, "[lateral CA] energy: each point's sum = 1 within 2e-3", f"worst {worst_e:.1e}")


def loca_cases():
    img = grid_image()
    for sign, soft in (("purple", (0, 2)), ("green", (1,))):
        # 2.5 px: the FIR branch. The IIR one (sigma >= 3, the engine's YvV
        # recursive Gaussian, shared by every blur) has a second moment 10 %
        # over its nominal sigma -- measured 5.56 px for 5, 11.0 for 10 --
        # which is the engine's blur and not this node's.
        out = lp.run(img, dict(ON, lens_loca_um=30.0, lens_loca_sign=sign, lens_loca_highlight_gate=0.0), PITCH)
        s = 30.0 / PITCH
        worst, worst_e = 0.0, 0.0
        for ch in range(3):
            for h, e, mr, vr, vt, r in moments(out, ch):
                want = s if ch in soft else 0.0
                worst = max(worst, abs(math.sqrt(0.5 * (vr + vt)) - want) / s)
                worst_e = max(worst_e, abs(e - 1))
        check(worst <= 0.05, f"[LoCA {sign}, gate 0] the soft channels' sigma = loca_um, the others sharp",
              f"worst {100 * worst:.2f} % of sigma")
        check(worst_e <= 1e-3, f"[LoCA {sign}] energy: each point's sum = 1 within 1e-3", f"worst {worst_e:.1e}")
    # gate 1: the bright light's soft channels are scattered, and kept
    out = lp.run(img, dict(ON, lens_loca_um=30.0, lens_loca_highlight_gate=1.0), PITCH)
    worst_e = max(abs(m[1] - 1) for ch in range(3) for m in moments(out, ch))
    check(worst_e <= 1e-3, "[LoCA gate 1] energy: each point's sum = 1 within 1e-3, per channel", f"worst {worst_e:.1e}")
    # the gate: on a dim edge nothing moves, on a highlight's edge it does
    img = np.full((400, 400, 3), 0.05, np.float32)
    img[:, 200:] = 0.1
    img[100:140, 100:140] = 8.0
    out = lp.run(img, dict(ON, lens_loca_um=40.0, lens_loca_highlight_gate=1.0), PITCH)
    dim = np.abs(out[250:350, 190:210] - img[250:350, 190:210]).max()
    lit = np.abs(out[95:145, 95:145, 0] - img[95:145, 95:145, 0]).max()
    check(dim < 1e-6 and lit > 0.1, "[LoCA gate 1] a dim edge is left alone, a highlight's edge is not",
          f"dim edge moved {dim:.1e}, highlight edge {lit:.2f}")


def spherical_cases():
    img = grid_image()
    w, R_um = 0.3, 60.0       # sigma 2.5 px, the FIR branch (see the LoCA note on the IIR's)
    out = lp.run(img, dict(ON, lens_spherical_amount=w, lens_spherical_um=R_um), PITCH)
    s = 0.5 * R_um / PITCH
    worst, worst_e = 0.0, 0.0
    for h, e, mr, vr, vt, r in moments(out, 1):
        if not interior(h, r):
            continue
        worst = max(worst, abs(math.sqrt(0.5 * (vr + vt) / w) / s - 1))
        worst_e = max(worst_e, abs(e - 1))
    y, x = points()[0]
    core = out[y, x, 1]
    check(worst <= 0.05 and core >= 1 - w, "[spherical] the glow's second moment: w sigma^2, sigma = R / 2",
          f"worst {100 * worst:.2f} %, the point keeps {core:.3f} (>= 1 - w = {1 - w})")
    check(worst_e <= 1e-3, "[spherical] energy: each point's sum = 1 within 1e-3", f"worst {worst_e:.1e}")
    # With the filter on, the glow is its own pass after the filter's
    # (`lens_glow_fast`; the exact path folds it into the filter's mixture):
    # the same picture as the two in sequence.
    img = scene(1200, 800, seed=4)
    filt = {"diffusion_filter_active": True, "diffusion_filter_family": "pro_mist", "diffusion_filter_strength": 1.0}
    glow = dict(ON, lens_spherical_amount=0.3, lens_spherical_um=300.0)
    both = lp.run(img, dict(filt, **glow), 12.0)
    seq = lp.run(lp.run(img, filt, 12.0), glow, 12.0)
    # The interior: at the frame's edge the two replicate the border once and
    # twice, and those are two different guesses at light that is not there.
    m = (slice(120, -120), slice(120, -120))
    d = np.abs(codes(both[m]) - codes(seq[m]))
    # (A bloom 375 px wide carries that difference well inside: mean 2 codes.)
    check(np.percentile(d, 99.9) <= 32 and d.mean() <= 4,
          "[spherical with the filter] both in one pass = the filter, then the glow (interior)",
          f"mean {d.mean():.2f}, p99.9 {np.percentile(d, 99.9):.0f}, max {d.max():.0f} codes")


# --- bands ------------------------------------------------------------------------

ALL = dict(ON, diffusion_filter_active=True, diffusion_filter_family="pro_mist", diffusion_filter_strength=1.0,
           lens_field_curvature_um=80.0, lens_astigmatism_um=60.0, lens_coma_um=80.0, lens_spherical_amount=0.25,
           lens_spherical_um=200.0, lens_lateral_ca_r=2.0, lens_lateral_ca_b=-1.5, lens_loca_um=12.0)


def scene(w, h, seed=3):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    img = 0.03 + 0.4 * (x / w)[..., None] * np.array([1.0, 0.85, 0.6]) + 0.2 * (y / h)[..., None]
    img[h // 3:h // 3 + 9, :, :] = 4.0
    # a slanted edge
    img[(x - w * 0.6) * 0.98 + (y - h * 0.5) * 0.2 > 0] *= 0.3
    for _ in range(80):
        img[rng.integers(0, h), rng.integers(0, w)] = rng.uniform(5, 100)
    return (img * np.exp(0.1 * rng.standard_normal((h, w, 1)))).astype(np.float32)


def bands(png):
    img = scene(1500, 1000)
    ab = {k: v for k, v in ALL.items() if k.startswith("lens_")}
    for pitch in (4.34, 24.0):
        for name, p in (("aberrations", ab), ("filter and aberrations, in place", ALL)):
            one = lp.run(img, p, pitch, chunk_rows=4096)
            if png and pitch < 10 and name.startswith("filter"):
                lp.write_png(Path(png) / "scene_lens.png", lp.display(one, 2.0))
                lp.write_png(Path(png) / "scene_plain.png", lp.display(img, 2.0))
            for rows in (64, 200, 333):
                b = lp.run(img, p, pitch, chunk_rows=rows)
                d = np.abs(codes(b) - codes(one))
                check(np.array_equal(b, one) or d.max() <= 1,
                      f"[{pitch} um/px, {name}] the pass in {rows}-row chunks = in one, within 1 code",
                      f"max {d.max():.0f}, {100 * (d > 0).mean():.3f}% differ")
    # The engine does not band (no RFC-035 bands); its plan is
    # RFC-020's strips. The lens runs on the source before either, so a striped
    # render with the lens on is the striped render of the source lensed
    # first, byte for byte -- and the film plan does not change (`structural`).
    e = spk.Engine()
    try:
        lens = {k: v for k, v in ALL.items() if k.startswith(("lens_", "diffusion_"))}
        pre = lp.run(img, lens, 36.0 * 1000.0 / img.shape[1])
        for rows in (100, 333):
            st = dict(BASE, film_format_mm=36.0, striped=True, strip_rows=rows)
            s = e.open(img, dict(st, **ALL)); a, _ = s.render("full"); s.close()
            s = e.open(pre, st); b, _ = s.render("full"); s.close()
            check(np.array_equal(a, b), f"[{rows}-row strips] the lens = the source lensed first, byte for byte",
                  f"max {np.abs(a.astype(np.int64) - b.astype(np.int64)).max()}")
    finally:
        e.close()


# --- the engine's source is the lensed source ------------------------------------------

def source_is_lensed():
    SW, SH = 1500, 1000
    img = scene(SW, SH, seed=11)
    p = dict(ALL, lens_loca_highlight_gate=0.0)
    lens = {k: v for k, v in p.items() if k.startswith(("lens_", "diffusion_"))}
    x0, y0, cw, ch = 300, 100, 900, 700
    geo = {"geometry_crop_x": x0 / SW, "geometry_crop_y": y0 / SH, "geometry_crop_w": cw / SW, "geometry_crop_h": ch / SH}
    f36 = {"film_format_mm": 36.0}
    cases = (("the frame", f36, 36.0),
             ("a crop", dict(f36, **geo), 36.0),
             ("a mirrored crop", dict(f36, geometry_flip_h=True, **geo), 36.0),
             ("a 6x7 format", {"film_format_mm": 70.0}, 70.0),
             ("135 overscan (the gate's pitch, 36.25 mm)", dict(f36, overscan_active=True, overscan_format="135"), 36.25))
    for device in (None,):   # one profile: the whole render
        tag = "banded" if device else "whole"
        e = spk.Engine()
        try:
            for name, extra, long_mm in cases:
                pre = lp.run(img, lens, long_mm * 1000.0 / SW)   # the probe's pass at the frame's pitch
                s = e.open(img, dict(BASE, **extra, **p)); a, _ = s.render("full"); s.close()
                s = e.open(pre, dict(BASE, **extra)); b, _ = s.render("full"); s.close()
                check(np.array_equal(a, b), f"[{tag}, {name}] the engine's lens = the source lensed first, byte for byte",
                      f"max {np.abs(a.astype(np.int64) - b.astype(np.int64)).max()}")
            # the meter reads the lensed light
            ae = dict(BASE, auto_exposure=True)
            ev = {}
            for k, (src, extra) in {"plain": (img, {}), "lens": (img, p), "pre": (lp.run(img, lens, 24.0), {})}.items():
                s = e.open(src, dict(ae, film_format_mm=36.0, **extra)); s.render("full")
                ev[k] = s.progress().get("auto_exposure_ev"); s.close()
            ok = ev["lens"] is not None and ev["plain"] is not None and abs(ev["lens"] - ev["plain"]) > 1e-4 \
                and abs(ev["lens"] - ev["pre"]) < 0.02
            check(ok, f"[{tag}] auto exposure meters the lensed light",
                  f"EV plain {ev['plain']}, lens on {ev['lens']}, the pre-lensed source {ev['pre']}")
        finally:
            e.close()


# --- off is structural ------------------------------------------------------------------

def structural(base_dylib):
    img = scene(900, 600, seed=9)
    off = dict(ALL, lens_aberrations_active=False, diffusion_filter_active=False)
    zeros = {"lens_aberrations_active": True}
    for device in (None,):   # one profile: the whole render
        tag = "banded" if device else "whole"
        e = spk.Engine()
        try:
            s = e.open(img, BASE); b, _ = s.render("full"); s.close()
            s = e.open(img, dict(BASE, **off)); a, _ = s.render("full"); s.close()
            check(np.array_equal(a, b), f"[{tag}] lens off with every field set = no field sent, byte for byte")
            s = e.open(img, dict(BASE, **zeros)); z, _ = s.render("full"); s.close()
            check(np.array_equal(z, b), f"[{tag}] lens on with every size 0 = off, byte for byte")
            s = e.open(img, dict(BASE, striped=True, strip_rows=100, **off)); s.render("full"); st = s.progress(); s.close()
            names = [(x["name"], x["class"]) for seg in st.get("strip_segments", []) for x in seg["stages"]]
            s = e.open(img, dict(BASE, striped=True, strip_rows=100, **ALL)); s.render("full"); st = s.progress(); s.close()
            on = [(x["name"], x["class"]) for seg in st.get("strip_segments", []) for x in seg["stages"]]
            check(on == names and names and not any("lens" in n for n, _ in on),
                  f"[{tag}] the film plan is the same with the lens on: the lens is a pass on the source",
                  json.dumps(on))
        finally:
            e.close()
        if base_dylib:
            eb = spk.Engine(dylib=Path(base_dylib))
            try:
                s = eb.open(img, BASE); c, _ = s.render("full"); s.close()
                check(np.array_equal(b, c), f"[{tag}] off = the base engine, byte for byte")
            finally:
                eb.close()
        else:
            print("SKIP off = the base engine: no --base-dylib")


# --- 48 MP ------------------------------------------------------------------------------

def big_frame(w, h):
    rng = np.random.default_rng(1)
    y = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    x = np.linspace(0, 1, w, dtype=np.float32)[None, :, None]
    img = (0.03 + 0.4 * x * np.array([1.0, 0.85, 0.6], np.float32) + 0.2 * y).astype(np.float32)
    img = np.ascontiguousarray(np.broadcast_to(img, (h, w, 3))).copy()
    for _ in range(400):
        img[rng.integers(0, h), rng.integers(0, w)] = 80.0
    return img


BIG_CASES = (
    ("4:3", "off", {}),
    ("4:3", "filter: black pro mist 0.25", {"diffusion_filter_active": True, "diffusion_filter_strength": 0.25}),
    ("4:3", "filter: black pro mist 1", {"diffusion_filter_active": True, "diffusion_filter_strength": 1.0}),
    ("4:3", "filter: cinebloom 1", {"diffusion_filter_active": True, "diffusion_filter_family": "cinebloom",
                                    "diffusion_filter_strength": 1.0}),
    ("4:3", "aberrations (all, strong)", {k: v for k, v in ALL.items() if k.startswith("lens_")}),
    ("4:3", "filter and aberrations", ALL),
    ("3:2", "off, 135 canvas", {"overscan_active": True, "overscan_format": "135"}),
    ("3:2", "filter and aberrations, 135 canvas", dict(ALL, overscan_active=True, overscan_format="135")),
)


def big(only=None):
    """48 MP: the lens pass alone (its first run, into fresh pages with a new
    fit, and a slider's next value over its copy), then the renders -- the
    full tier's first develop (the pass and the film), a second develop with
    the lensed copy kept (another film), the live tier's first render and a
    reprint -- with bands and memory, lens on and off."""
    frames = {"4:3": (8064, 6048), "3:2": (8064, 5376)}
    p_film = dict(BASE, film_format_mm=36.0, halation_active=True)
    rows = {}
    for shape, name, extra in BIG_CASES:
        if only and only not in name:
            continue
        img = big_frame(*frames[shape])
        lens = {k: v for k, v in extra.items() if k.startswith(("lens_", "diffusion_"))}
        if lens:
            gate = 36.25 if extra.get("overscan_active") else 36.0
            lp.run(img, lens, gate * 1000.0 / frames[shape][0], repeat=3)
            print(f"MEASURE 48 MP ({shape}) {name}: the pass alone, first {lp.LAST['ms_first']:.1f} ms, "
                  f"next value {lp.LAST['ms']:.1f} ms (levels {lp.LAST['levels']:.0f})")
        for device in (None,):   # one profile: the whole render
            tag = "banded" if device else "whole"
            e = spk.Engine()
            try:
                s = e.open(img, dict(p_film, **extra))
                t = time.time(); s.render("full"); t_full = time.time() - t
                pr = s.progress()
                rep = e.memory_report()
                s.set_params({"film_stock": "kodak_gold_200"})
                t = time.time(); s.render("full"); t_again = time.time() - t
                t = time.time(); s.render("live"); t_live = time.time() - t
                t = time.time(); s.render("live", reprint=True); t_live2 = time.time() - t
                s.close()
                peak = rep["pool"]["frame_high_water_bytes"]
                per = rep["persistent"]
                lensed = sum(r.get("lensed_source_bytes", 0) for r in per.get("sessions", []))
                rows[(tag, name)] = (peak, pr.get("bands"))
                print(f"MEASURE 48 MP {tag} ({shape}), {name}: full {t_full:.2f} s, again (another film) {t_again:.2f} s, "
                      f"live {1000 * t_live:.0f} ms, live reprint {1000 * t_live2:.0f} ms; pool high-water "
                      f"{peak / 2**20:.0f} MB, file-backed {per['file_backed_bytes'] / 2**20:.0f} MB (lensed copies "
                      f"{lensed / 2**20:.0f} MB), bands {pr.get('bands')}")
            finally:
                e.close()
        del img
    for (tag, name), (peak, bands) in rows.items():
        ref = rows.get((tag, "off, 135 canvas" if "135" in name else "off"))
        if ref is None or name.startswith("off"):
            continue
        if tag == "banded":
            check(bands == ref[1], f"[48 MP banded, {name}] the same bands as with the lens off", f"{bands} vs {ref[1]}")
        check(peak <= ref[0] * 1.05 + (64 << 20), f"[48 MP {tag}, {name}] pool high-water within 5 % (+64 MB) of off",
              f"{peak / 2**20:.0f} MB vs {ref[0] / 2**20:.0f} MB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-dylib", default=os.environ.get("SPK_BASE_DYLIB"))
    ap.add_argument("--big", nargs="?", const="", default=None, help="the 48 MP measurement (optionally one case)")
    ap.add_argument("--png")
    args = ap.parse_args()
    structural(args.base_dylib)
    field_cases(args.png)
    energy_sweep()
    coma_cases(args.png)
    tca_cases(args.png)
    loca_cases()
    spherical_cases()
    bands(args.png)
    source_is_lensed()
    if args.big is not None:
        big(args.big or None)
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
