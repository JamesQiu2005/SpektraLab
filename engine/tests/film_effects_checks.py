#!/usr/bin/env python3
"""API-SPEC §21.1-§21.4 (2026-11-09; in this engine 2026-11-11): the film-side effects -- light leaks in the picture,
the Pentax MZ-S data line between the perforations, 120 cut from 65 mm cine film
(`ks65`), and the full-width 135 frame (`135_sprocket`) with its falloff and
X-Tra 400's edge stripes. Needs only `build.sh dylib`.

    python3 engine/tests/film_effects_checks.py [--dylib path] [--base-dylib path] [--before-retune-dylib path]

`--base-dylib` is an engine from before these effects (af5173b9,
which has none of the fields): every existing render must be that engine's byte
for byte, with each new field at its default. Without it those checks are skipped.

The engine does not band (no RFC-035 bands), so there are no banded-against-whole
cases; its RFC-020 strips are checked, where a strip can run.

The B&W check needs the product's Tri-X profile, which nothing installs: the
profiles of `engine/resources_product/` are laid over `engine/resources/` in a
scratch directory (as `bw_checks.py` does).
"""
import argparse, colorsys, os, sys, tempfile
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes as spk  # noqa: E402

ENGINE = Path(__file__).resolve().parents[1]
BASE = {"film_stock": "kodak_portra_400", "print_stock": "kodak_supra_endura", "grain_active": False,
        "glare_active": False, "auto_exposure": False}
NEW_DEFAULTS = {"leak_kind": "off", "leak_amount": 1.0, "leak_rate": 1.0, "leak_front": -1.0,
                "date_imprint_data_placement": "gap", "date_imprint_data_leader": "",
                "overscan_perforation": "none", "overscan_falloff": 0.0}

failures = 0


def check(ok, what, detail=""):
    global failures
    print(("PASS " if ok else "FAIL ") + what + (f" -- {detail}" if detail else ""))
    failures += 0 if ok else 1


def overlay(tmp):
    res = Path(tmp) / "resources"
    (res / "profiles").mkdir(parents=True)
    for f in (ENGINE / "resources").iterdir():
        if f.name != "profiles":
            os.symlink(f, res / f.name)
    for d in (ENGINE / "resources" / "profiles", ENGINE / "resources_product" / "profiles"):
        for f in d.glob("*.json"):
            if not (res / "profiles" / f.name).exists():
                os.symlink(f, res / "profiles" / f.name)
    return res


def scene(w, h, seed=1):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    img = 0.04 + 0.4 * (x / w)[..., None] * np.array([1.0, 0.9, 0.7]) + 0.3 * (y / h)[..., None]
    img[h // 3:h // 3 + 30, w // 2:w // 2 + 30] = 4.0
    return (img + 0.01 * rng.standard_normal((h, w, 3))).astype(np.float32)


def flat(w, h, v):
    return np.full((h, w, 3), v, np.float32)


def render(e, img, extra, tier="full", geometry=False):
    p = dict(BASE); p.update(extra)
    s = e.open(img, p)
    try:
        rgba, _ = s.render(tier)
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


def lum(rgba):
    return v8(rgba).mean(-1)


def gate_box(geo):
    """The first gate's (x0, y0, x1, y1) in canvas px, for a level (not vertical) film."""
    g = np.array(geo["gates"][0])
    xs, ys = g[0::2] * geo["canvas_w"], g[1::2] * geo["canvas_h"]
    return xs[[0, 3]].mean(), ys[[0, 1]].mean(), xs[[1, 2]].mean(), ys[[2, 3]].mean()


def runs(mask):
    """(start, length) of each True run in a 1-D mask."""
    m = np.concatenate([[False], mask, [False]]).astype(np.int8)
    d = np.diff(m)
    s, e = np.flatnonzero(d == 1), np.flatnonzero(d == -1)
    return list(zip(s, e - s))


def sub_runs(prof, thr, min_len=0.0):
    """(start, length) of each run of `prof` over `thr`, its ends found to a
    fraction of a pixel by linear interpolation across the threshold. Pixel
    i covers [i, i + 1), its value at i + 0.5."""
    out = []
    for s, n in runs(prof > thr):
        a = (s - 0.5 + (thr - prof[s - 1]) / (prof[s] - prof[s - 1])) if s > 0 else 0.0
        e = s + n - 1
        b = e + 0.5 + ((prof[e] - thr) / (prof[e] - prof[e + 1]) if e + 1 < len(prof) else 0.5)
        if b - a >= min_len:
            out.append((a, b - a))
    return out


# --- 1. off is structural ---------------------------------------------------------
BYTE_CASES = [
    ("frame alone", (900, 600), {}),
    ("135, fog and spool leaks", (1200, 800), {"overscan_active": True, "overscan_format": "135", "overscan_fog": 1.0,
                                               "overscan_leaks": 2.0, "overscan_edge_text": "PORTRA 400"}),
    ("135 half pair with dates", (925, 600), {"overscan_active": True, "overscan_format": "135_half", "overscan_pair": True,
                                              "date_imprint_active": True, "date_imprint_text": "'26 11 9",
                                              "date_imprint_text_b": "'26 11 10"}),
    ("135 data between frames", (1200, 800), {"overscan_active": True, "overscan_format": "135", "date_imprint_active": True,
                                              "date_imprint_text": "'26 11 9", "date_imprint_data_text": "P 1/180 F8 +0.0"}),
    ("X-Tra 400 on 135", (1200, 800), {"film_stock": "fujifilm_xtra_400", "overscan_active": True, "overscan_format": "135",
                                       "overscan_edge_text": "S-400"}),
    ("X-Tra 400 half frame", (600, 800), {"film_stock": "fujifilm_xtra_400", "overscan_active": True,
                                          "overscan_format": "135_half"}),
    ("X-Tra 400 XPan", (1300, 480), {"film_stock": "fujifilm_xtra_400", "overscan_active": True, "overscan_format": "135_xpan",
                                     "overscan_holes": "black"}),
    ("date alone", (900, 600), {"date_imprint_active": True, "date_imprint_text": "'26 11 9"}),
    # Fujifilm's positives carry no stripes (the owner, 2026-11-11): the base engine's, byte for byte
    ("Velvia 100 on 135", (1200, 800), {"film_stock": "fujifilm_velvia_100", "overscan_active": True, "overscan_format": "135"}),
    ("Provia 100F XPan", (1300, 480), {"film_stock": "fujifilm_provia_100f", "overscan_active": True, "overscan_format": "135_xpan"}),
    ("C200 on 135 (Kodak-made, Kodak's edge)", (1200, 800), {"film_stock": "fujifilm_c200", "overscan_active": True,
                                                             "overscan_format": "135"}),
    ("Pro 400H on 135", (1200, 800), {"film_stock": "fujifilm_pro_400h", "overscan_active": True, "overscan_format": "135"}),
]
for name, size, fmt in (("120_645", (560, 747), "120_645"), ("120_6x6", (700, 700), "120_6x6"),
                        ("120_6x7", (834, 672), "120_6x7"), ("120_6x8", (912, 672), "120_6x8"),
                        ("120_6x9", (1008, 672), "120_6x9"), ("120_6x12", (1120, 560), "120_6x12"),
                        ("120_6x17", (1500, 500), "120_6x17")):
    BYTE_CASES.append((f"{name}, Vision3, date and data in the margin", size,
                       {"film_stock": "kodak_vision3_250d", "overscan_active": True, "overscan_format": fmt,
                        "overscan_holes": "black", "overscan_fog": 1.0, "date_imprint_active": True,
                        "date_imprint_text": "'26 11 9", "date_imprint_data_text": "F8 1/125"}))


# Fujifilm's factory edge stripes: every Fujifilm colour negative with Fujifilm's 135 edge (Edge135::FujiNeg:
# X-Tra 400, Pro 400H), on every 135-gauge format; never a positive (Velvia, Provia), never 120 (the owner, 2026-11-11).
STRIPED = ("fujifilm_xtra_400", "fujifilm_pro_400h")
NOT_STRIPED = ("kodak_portra_400", "fujifilm_c200", "fujifilm_velvia_100", "fujifilm_provia_100f")
STRIPE_G, STRIPE_R = 2.83, 3.73   # mm from each film edge


def film_t(geo, shape):
    """Each canvas pixel's signed distance (mm) across the film from the first gate's centre line,
    for a level film: the film's edges are at about +-film_w / 2."""
    g = np.array(geo["gates"][0])
    xs, ys = g[0::2] * geo["canvas_w"], g[1::2] * geo["canvas_h"]
    (lx, ly), (rx, ry) = ((xs[0] + xs[3]) / 2, (ys[0] + ys[3]) / 2), ((xs[1] + xs[2]) / 2, (ys[1] + ys[2]) / 2)
    ux, uy = (rx - lx), (ry - ly)
    n = np.hypot(ux, uy)
    yy, xx = np.mgrid[0:shape[0], 0:shape[1]] + 0.5
    return ((yy - ly) * ux - (xx - lx) * uy) / n * geo["mm_per_px"]


def stripes_only(name, a, b, geo):
    """A striped stock against the base engine: every pixel that moves lies in the stripes' bands."""
    t = np.abs(film_t(geo, a.shape))
    moved = np.abs(v8(a) - v8(b)).max(-1) > 1.0
    # (the film's place across the gate varies +-0.1 mm; halation spreads a bright line a few tenths)
    lo, hi = 17.5 - STRIPE_R - 0.65 - 2 * geo["mm_per_px"], 17.5 - STRIPE_G + 0.9 + 2 * geo["mm_per_px"]
    band = (t > lo) & (t < hi)
    check(moved.any() and not (moved & ~band).any(),
          f"a striped stock moves only in its stripes' bands against the base engine: {name}",
          f"{int(moved.sum())} px moved, {int((moved & ~band).sum())} outside |t| {lo:.2f}-{hi:.2f} mm")


def byte_identity(e, base):
    for name, (w, h), extra in BYTE_CASES:
        img = scene(w, h)
        with_defaults = dict(extra, **NEW_DEFAULTS)
        a = render(e, img, with_defaults)
        if base is None:
            check(np.array_equal(a, render(e, img, extra)), f"defaults sent = none sent: {name}")
            continue
        if extra.get("film_stock") in STRIPED and extra.get("overscan_active"):
            # The owner, 2026-11-11: Fujifilm's stripes on every 135 edge -- the frame moves there only.
            a, geo = render(e, img, with_defaults, geometry=True)
            stripes_only(name, a, render(base, img, extra), geo)
            continue
        if not extra.get("date_imprint_active"):
            b = render(base, img, extra)
            check(np.array_equal(a, b), f"byte for byte the base engine, each new field at its default: {name}",
                  "" if np.array_equal(a, b) else f"max |d| {np.abs(a.astype(int) - b.astype(int)).max()}")
            continue
        # The camera's imprints changed on purpose (2026-11-10: the date back's
        # light scatters in the base). Without them the frame is the base
        # engine's byte for byte; with them, nothing moves away from them.
        undated = dict(extra, date_imprint_active=False)
        a0, b0 = render(e, img, dict(undated, **NEW_DEFAULTS)), render(base, img, undated)
        check(np.array_equal(a0, b0), f"byte for byte the base engine with the date back off: {name}")
        b = render(base, img, extra)
        foot = (np.abs(v8(a) - v8(a0)).max(-1) > 1.0) | (np.abs(v8(b) - v8(b0)).max(-1) > 1.0)
        if not foot.any():
            # no date drawn on this format (the panoramic rule): the frame is the base engine's
            check(np.array_equal(a, b), f"no imprint drawn, byte for byte the base engine: {name}")
            continue
        px = 36.25 / max(w, h) if "135" in str(extra.get("overscan_format", "135")) else 0.083
        near = foot.copy()
        for _ in range(int(np.ceil(1.0 / px))):
            near[1:] |= near[:-1]; near[:-1] |= near[1:]; near[:, 1:] |= near[:, :-1]; near[:, :-1] |= near[:, 1:]
        far = np.abs(v8(a) - v8(b)).max(-1)[~near]
        check(foot.any() and far.max() <= 1.0,
              f"the camera's imprint changes nothing more than 1 mm from it (the factory print, fog, holes): {name}",
              f"max {far.max():.2f}/255 beyond 1 mm")


# --- 2. leaks ----------------------------------------------------------------------
def leak_profile(e, img, extra):
    """The leak's added light, frame-edge off: (diff in 8-bit, column profile)."""
    on = v8(render(e, img, dict(extra)))
    off = v8(render(e, img, {k: v for k, v in extra.items() if not k.startswith("leak_")}))
    d = on - off
    return d, d.sum(-1).sum(0)


def leaks(e):
    W, H = 1200, 800
    px = 36.25 / W
    dark = flat(W, H, 0.03)
    band = {"leak_kind": "band", "leak_amount": 1.0, "leak_front": 0.0, "halation_active": False}

    a = render(e, dark, dict(band, overscan_camera_seed=5, overscan_frame_seed=3))
    b = render(e, dark, dict(band, overscan_camera_seed=5, overscan_frame_seed=3))
    check(np.array_equal(a, b), "a leak renders the same twice (seeded)")

    # rate 0 and amount 0 are no leak at all, film edge off and on
    plain = render(e, dark, {"halation_active": False})
    for what, extra in (("rate 0", dict(band, leak_rate=0.0)), ("amount 0", dict(band, leak_amount=0.0))):
        check(np.array_equal(render(e, dark, extra), plain), f"a leak at {what} is byte for byte none (film edge off)")
    edge = {"overscan_active": True, "overscan_format": "135", "halation_active": False}
    check(np.array_equal(render(e, dark, dict(edge, **dict(band, leak_rate=0.0))), render(e, dark, edge)),
          "a leak at rate 0 is byte for byte none (film edge on)")

    # seed levels: the camera's leak keeps its place, its edge and its width over frames
    centres, edges, cams = [], [], []
    for fs in (1, 2, 3, 4, 5):
        d, prof = leak_profile(e, dark, dict(band, overscan_camera_seed=11, overscan_frame_seed=fs))
        k = int(np.argmax(prof))
        centres.append(k * px)
        col = d[:, max(0, k - 3):k + 4].sum(-1).mean(1)
        edges.append(int(col[: H // 8].mean() < col[-H // 8:].mean()))
    for cs in (11, 12, 13, 14):
        d, prof = leak_profile(e, dark, dict(band, overscan_camera_seed=cs, overscan_frame_seed=1))
        cams.append(int(np.argmax(prof)) * px)
    spread = max(centres) - min(centres)
    check(spread <= 3.2 and len(set(edges)) == 1,
          "the frame seed moves the camera's band only by its wobble (+-1.5 mm), and never its bright edge",
          f"centres {np.round(centres, 2)} mm, bright edge {edges}")
    check(max(cams) - min(cams) > 4.0, "the camera seed moves the band", f"centres {np.round(cams, 2)} mm")

    # the hue path on Portra 400: rear light walks red -> orange -> yellow, blue stays low.
    # Held with the negative-hue node off (`SPK_NEGATIVE_HUE=0`): the default
    # print takes its hue from the negative (2026-11-11), which holds a strong
    # leak's hue near orange -- a print-stage decision, reported, not a leak
    # to retune (the material model is not the place to fix a print).
    def hue_walk():
        hues, rgbs = [], []
        darker = flat(W, H, 0.02)
        for amt in (0.25, 0.5, 1.0, 2.0, 4.0):
            hue = dict(band, leak_amount=amt, overscan_camera_seed=5, overscan_frame_seed=3)
            d, prof = leak_profile(e, darker, hue)
            k = int(np.argmax(prof))
            c = v8(render(e, darker, hue))[:, k].mean(0)
            rgbs.append(c)
            hues.append(colorsys.rgb_to_hsv(*(c / 255.0))[0] * 360.0)
        return hues, rgbs
    walk = lambda hues, rgbs: "; ".join(f"{np.round(c).astype(int).tolist()} {h:.1f}°" for c, h in zip(rgbs, hues))
    os.environ["SPK_NEGATIVE_HUE"] = "0"
    try:
        hues, rgbs = hue_walk()
    finally:
        del os.environ["SPK_NEGATIVE_HUE"]
    mono = all(b >= a - 0.5 for a, b in zip(hues, hues[1:]))
    check(mono and hues[0] < 22.0 and hues[-1] > 28.0 and max(c[2] for c in rgbs) < 45.0
          and all(c[0] > c[1] > c[2] for c in rgbs),
          "Portra 400 (negative hue off, SPK_NEGATIVE_HUE=0): a rear leak's hue rises red -> orange -> yellow, blue under 45",
          walk(hues, rgbs))
    hues, rgbs = hue_walk()
    print("INFO Portra 400, the default print (hue from the negative): " + walk(hues, rgbs))
    check(all(c[0] > c[1] > c[2] for c in rgbs) and hues[0] < 22.0 and hues[-1] > hues[0],
          "Portra 400 (the default print): a rear leak stays red-orange and is warmer than it is red at amount 4")
    core = v8(render(e, dark, dict(band, leak_amount=4.0, leak_front=0.5, overscan_camera_seed=5, overscan_frame_seed=1)))
    k = int(np.argmax(core.sum(-1).sum(0)))
    c = core[:, k].mean(0)
    check(c.min() > 0.9 * c.max(), "Portra 400: with a front share the core goes to white", str(np.round(c).astype(int)))

    # spot is the 120 window's: refused elsewhere
    ok, msg = refuses(e, dark, {"leak_kind": "spot"}, "spot")
    check(ok, "leak_kind = spot is refused on a 135 format", msg)
    img67 = flat(834, 672, 0.03)
    d, prof = leak_profile(e, img67, {"leak_kind": "spot", "overscan_format": "120_6x7", "overscan_camera_seed": 3})
    check(d.max() > 20, "leak_kind = spot draws on 120_6x7", f"max {d.max():.0f}")
    for kind in ("wash", "auto"):
        d, _ = leak_profile(e, dark, {"leak_kind": kind, "overscan_camera_seed": 3})
        check(d.max() > 20, f"leak_kind = {kind} draws", f"max {d.max():.0f}")

    # film edge on vs off: the same light inside the gate
    grey = flat(W, H, 0.18)
    lk = {"leak_kind": "band", "leak_amount": 1.0, "leak_front": 0.5, "overscan_camera_seed": 21,
          "overscan_frame_seed": 4, "halation_active": False}
    off_d = v8(render(e, grey, lk)) - v8(render(e, grey, {"halation_active": False}))
    edge = {"overscan_active": True, "overscan_format": "135", "overscan_fog": 0.0, "overscan_leaks": 0.0}
    on, geo = render(e, grey, dict(edge, **lk), geometry=True)
    on0 = render(e, grey, dict(edge, halation_active=False, overscan_camera_seed=21, overscan_frame_seed=4))
    on_d = v8(on) - v8(on0)
    x0, y0, x1, y1 = gate_box(geo)
    m = int(np.ceil(1.0 / px))
    ys, xs = np.mgrid[m:H - m:4, m:W - m:4]
    cx = np.clip(np.round(x0 + (xs + 0.5) * (x1 - x0) / W - 0.5).astype(int), 0, on.shape[1] - 1)
    cy = np.clip(np.round(y0 + (ys + 0.5) * (y1 - y0) / H - 0.5).astype(int), 0, on.shape[0] - 1)
    a, b = on_d[cy, cx], off_d[ys, xs]
    err, size = np.abs(a - b).mean(), np.abs(b).mean()
    check(size > 5.0 and err < 0.1 * size and np.abs(a - b).max() < 0.35 * np.abs(b).max(),
          "the leak with the film edge on is the leak with it off, inside the gate (1 mm margin)",
          f"mean |on - off| {err:.2f} of a mean leak {size:.1f} (8-bit), max {np.abs(a - b).max():.1f} of {np.abs(b).max():.1f}")

    # RFC-020's strips: a leak with the film edge off is the whole frame's
    img = scene(900, 600)
    whole = render(e, img, lk)
    strips = render(e, img, dict(lk, striped=True, strip_rows=64))
    check(np.array_equal(whole, strips), "a leak in 64-row strips is the whole frame's (film edge off)")



# --- 2b. the wash's and the spot's shape (2026-11-11 retune) ----------------------------
def leak_shapes(e):
    """Wash: a graded flood from one end that leaves the picture's far end its own colour at
    amount 1 (it flooded the 135 frame: an e-length of 8-25 mm against a peak 2^6 over grey).
    Spot: the 120 window's light -- a hot core past red, an edge that is not a circle, a bounded
    reach (it was one round Gaussian ~20 mm across). Each check below was red on 5c5b890d."""
    W, H = 1200, 800
    dark = flat(W, H, 0.05)
    off = v8(render(e, dark, {}))
    n = W // 10
    keeps, lit, halves = [], [], []
    for cs in range(1, 9):
        for fs in (1, 2, 3):
            on = v8(render(e, dark, {"leak_kind": "wash", "leak_amount": 1.0, "overscan_camera_seed": cs,
                                     "overscan_frame_seed": fs}))
            d = np.abs(on - off).mean(-1).mean(0)
            near, far = (d[:n].mean(), d[-n:].mean()) if d[:n].mean() > d[-n:].mean() else (d[-n:].mean(), d[:n].mean())
            keeps.append(1.0 - far / off.mean())
            lit.append(near)
            halves.append(d[W // 2] / max(near, 1e-9))
    check(min(keeps) >= 0.80 and min(lit) >= 25.0 and max(halves) <= 0.5,
          "wash at amount 1 (8 camera x 3 frame seeds, a dark frame): lit at its end, half of it or less at the "
          "frame's middle, and the far end keeps more than 80 % of its unleaked value",
          f"far end keeps >= {min(keeps):.2f}, end lit >= {min(lit):.0f}/255, middle <= {max(halves):.2f} of the end")

    W6, H6 = 834, 672
    px = 70.0 / W6
    dark6 = flat(W6, H6, 0.03)
    fmt = {"overscan_format": "120_6x7"}
    off6 = v8(render(e, dark6, fmt))
    yy, xx = np.mgrid[0:H6, 0:W6]
    hot, rough, reach = [], [], []
    for cs in range(1, 9):
        on = v8(render(e, dark6, dict(fmt, leak_kind="spot", leak_amount=1.0, overscan_camera_seed=cs)))
        dl = (on - off6).mean(-1)
        mask = dl > 0.5 * dl.max()
        cy, cx = yy[mask].mean(), xx[mask].mean()
        r = np.hypot(yy - cy, xx - cx)
        sector = ((np.arctan2(yy - cy, xx - cx) + np.pi) / (2 * np.pi) * 72).astype(int) % 72
        rad = np.array([r[mask & (sector == k)].max() for k in range(72) if (mask & (sector == k)).any()])
        R = np.median(rad)
        core, rim = on[r < 0.3 * R].mean(0), on[(r > 0.9 * R) & (r < 1.1 * R)].mean(0)
        # the core brighter than the rim, and past red: its green at least 0.65 of its red
        hot.append(min(dl[r < 0.3 * R].mean() / max(dl[(r > 0.9 * R) & (r < 1.1 * R)].mean(), 1e-9), 2.0 * core[1] / core[0]))
        rough.append(rad.std() / rad.mean())
        reach.append(((dl > 5.0).mean(), dl.clip(0).sum() / 1e6))
    check(min(hot) >= 1.3, "spot at amount 1 (8 camera seeds): its core brighter than its rim, and hot -- past red, "
          "green >= 0.65 of red", f"min(core/rim, 2 G/R) {min(hot):.2f} (needs 1.3)")
    check(min(rough) >= 0.045, "spot: its edge is not a circle (the half-maximum contour's radius varies)",
          f"radius CV >= {min(rough):.3f} (a disc reads under 0.025)")
    # the seeds as before: the same frame the same leak; another frame or another camera another
    for kind, im, x in (("wash", dark, {}), ("spot", dark6, fmt)):
        lk = dict(x, leak_kind=kind, overscan_camera_seed=3, overscan_frame_seed=1)
        a, b = render(e, im, lk), render(e, im, lk)
        other_frame = render(e, im, dict(lk, overscan_frame_seed=2))
        other_camera = render(e, im, dict(lk, overscan_camera_seed=4))
        check(np.array_equal(a, b) and not np.array_equal(a, other_frame) and not np.array_equal(a, other_camera),
              f"{kind}: the same seeds the same leak, byte for byte; another frame seed or camera seed another")
    a4 = v8(render(e, dark6, dict(fmt, leak_kind="spot", leak_amount=4.0, overscan_camera_seed=7)))
    area4 = ((a4 - off6).mean(-1) > 5.0).mean()
    check(max(a for a, _ in reach) <= 0.15 and max(s for _, s in reach) <= 3.0 and area4 <= 0.30,
          "spot: its light is bounded -- at amount 1 under 15 % of the 6x7 frame lifted by 5/255 and under 3 M "
          "8-bit units in all; at amount 4 under 30 %",
          f"amount 1: area <= {max(a for a, _ in reach):.3f}, energy <= {max(s for _, s in reach):.2f} M; amount 4: {area4:.3f}")


def band_unchanged(e, before):
    """The retune touched the wash and the spot only: the band, film edge off and on, 135 and 120,
    is the engine before it (5c5b890d) byte for byte, and so is auto where the camera draws a band."""
    img, img67 = scene(1200, 800), scene(834, 672)
    edge = {"overscan_active": True, "overscan_format": "135", "overscan_fog": 1.0, "overscan_leaks": 1.0}
    cases = []
    for cs in (1, 5, 11, 21):
        for amt, fr in ((0.5, -1.0), (1.0, 0.0), (4.0, 0.5)):
            band = {"leak_kind": "band", "leak_amount": amt, "leak_front": fr, "overscan_camera_seed": cs, "overscan_frame_seed": 3}
            cases += [(img, band), (img, dict(edge, **band)), (img67, dict(band, overscan_format="120_6x7"))]
    same = sum(np.array_equal(render(e, i, x), render(before, i, x)) for i, x in cases)
    check(same == len(cases), "band: byte for byte the engine before the retune (film edge off and on, 135 and 120_6x7)",
          f"{same} of {len(cases)} renders")


def leak_bw(dylib):
    with tempfile.TemporaryDirectory() as tmp, spk.Engine(dylib=dylib, resources=overlay(tmp)) as e:
        img = flat(1200, 800, 0.06)
        p = {"film_stock": "kodak_tri_x_400", "print_stock": "ilford_multigrade_iv_rc", "leak_kind": "band",
             "leak_amount": 2.0, "leak_front": 0.3, "overscan_camera_seed": 5, "halation_active": False}
        on = v8(render(e, img, p))
        off = v8(render(e, img, {k: v for k, v in p.items() if not k.startswith("leak_")}))
        d = (on - off).mean(-1)
        lit = d > 10
        chroma_on = (on.max(-1) - on.min(-1))[lit]
        chroma_off = (off.max(-1) - off.min(-1))[lit]
        check(lit.mean() > 0.05 and np.abs(chroma_on - chroma_off).max() < 3.0,
              "Tri-X 400 on Multigrade: a leak is light without a hue",
              f"{100 * lit.mean():.1f}% lit, chroma change max {np.abs(chroma_on - chroma_off).max():.2f} (8-bit)")


# --- 3. MZ-S ----------------------------------------------------------------------
def mzs(e):
    W, H = 2400, 1600
    px = 36.25 / W
    img = flat(W, H, 0.03)
    base = {"film_stock": "kodak_gold_200", "overscan_active": True, "overscan_format": "135", "overscan_holes": "white",
            "halation_active": False, "overscan_camera_seed": 3, "overscan_frame_seed": 8, "overscan_frame_number": 7}
    data = dict(base, date_imprint_active=True, date_imprint_text="", date_imprint_data_placement="perfs",
                date_imprint_data_text="P|{meter:multi}|180|F8|±0.0")
    with_d, geo = render(e, img, data, geometry=True)
    without = render(e, img, base)
    d = lum(with_d) - lum(without)
    x0, y0, x1, y1 = gate_box(geo)
    # the top perforation row: the white holes, above the gate
    L = lum(without)
    top = L[: int(y0)]
    frac = (top > 0.5 * L.max()).mean(1)
    yc = int(np.argmax(frac))
    holes = [(s, n) for s, n in runs(L[yc] > 0.5 * L.max()) if n * px > 1.5]
    gaps = [((s0 + n0) + s1) / 2.0 for (s0, n0), (s1, _) in zip(holes, holes[1:])]
    lit = d > 0.4 * d.max()
    lit[int(y0):] = False
    cols = lit.any(0)
    fields = [(s, n) for s, n in runs(cols) if n > 1]
    # merge parts of one field (a gap under 0.3 mm)
    merged = []
    for s, n in fields:
        if merged and s - (merged[-1][0] + merged[-1][1]) < 0.3 / px:
            merged[-1] = (merged[-1][0], s + n - merged[-1][0])
        else:
            merged.append((s, n))
    offs, inside = [], True
    for s, n in merged:
        w = np.clip(d[:int(y0), s:s + n], 0, None).sum(0)
        c = s + (w * np.arange(n)).sum() / w.sum() + 0.5
        g = min(gaps, key=lambda q: abs(q - c))
        offs.append((c - g) * px)
    check(len(merged) == 5 and max(abs(o) for o in offs) < 0.05,
          "MZ-S: five fields, each centred in its gap between perforations to 0.05 mm",
          f"{len(merged)} fields, offsets {np.round(offs, 3).tolist()} mm")
    rows = np.flatnonzero(lit.any(1))
    prof = np.clip(d[:int(y0)], 0, None)[:, cols].sum(1)
    above = np.flatnonzero(prof > 0.5 * prof.max())
    h = (above.max() - above.min() + 1) * px
    check(abs(h - 0.82) <= 0.05, "MZ-S: the glyphs stand 0.82 +- 0.05 mm (size 1)", f"{h:.3f} mm")
    foot = (y0 - (above.max() + 1)) * px
    check(0.6 < foot < 0.95, "MZ-S: the line's foot ~0.76 mm above the gate", f"{foot:.2f} mm")
    first_hole_after_gate = min(s for s, n in holes if s >= x0 - 1e-6)
    check(merged[0][0] > first_hole_after_gate, "MZ-S: the first field is in the gap after the frame's first hole",
          f"field at {merged[0][0] * px:.2f} mm, hole at {first_hole_after_gate * px:.2f} mm, gate at {x0 * px:.2f} mm")

    # the leader: frame 1 only, in the gaps before
    lead = dict(data, date_imprint_data_leader="NO.012|ISO 200|F15 3")
    d7 = lum(render(e, img, lead)) - lum(without)
    d1 = lum(render(e, img, dict(lead, overscan_frame_number=1))) - lum(render(e, img, dict(base, overscan_frame_number=1)))
    lead_cols = slice(0, merged[0][0] - int(0.5 / px))
    check(d1[:int(y0), lead_cols].max() > 0.4 * d.max() and d7[:int(y0), lead_cols].max() < 0.05 * d.max(),
          "MZ-S: the roll's leader is drawn before the first field on frame 1 only")

    # The MZ-S line alone, as the app sends it (the owner, 2026-11-11): style
    # `data` with the line in `date_imprint_text`, on 135 and on the half frame.
    for fmt, size in (("135", (W, H)), ("135_half", (900, 1200))):
        im = flat(size[0], size[1], 0.03)
        q = dict(base, overscan_format=fmt)
        alone = dict(q, date_imprint_active=True, date_imprint_style="data", date_imprint_data_placement="perfs",
                     date_imprint_text="P|{meter:multi}|180|F8|±0.0")
        ra, ga = render(e, im, alone, geometry=True)
        dd = lum(ra) - lum(render(e, im, q))
        gx0, gy0, gx1, gy1 = (min(a, b) for a, b in zip(gate_box(ga)[:2], gate_box(ga)[2:])), None, None, None
        g = np.array(ga["gates"][0])
        xs, ys = g[0::2] * ga["canvas_w"], g[1::2] * ga["canvas_h"]
        lit = dd > 20
        yy, xx = np.nonzero(lit)
        inside = (xx > xs.min() + 2) & (xx < xs.max() - 2) & (yy > ys.min() + 2) & (yy < ys.max() - 2)
        check(lit.sum() > 200 and not inside.any(),
              f"MZ-S alone (style data, the line in text) on {fmt}: drawn on the rebate, none in the picture",
              f"{lit.sum()} lit px, {inside.sum()} inside the gate")
    # perfs needs a perforated 135 film edge
    for what, img2, extra in (("film edge off", flat(1200, 800, 0.03), {"overscan_active": False}),
                              ("120_6x7", flat(834, 672, 0.03), {"overscan_format": "120_6x7"})):
        a = render(e, img2, dict(data, **extra))
        b = render(e, img2, dict(base, **extra, date_imprint_active=True, date_imprint_text=""))
        check(np.array_equal(a, b), f"MZ-S: no data line on {what}")
    # a field longer than its gap is cut, not run under the next hole
    long = dict(data, date_imprint_data_text="P|1234567890ABCDEF|180")
    dl = lum(render(e, img, long)) - lum(without)
    lit2 = dl[:int(y0)] > 0.4 * dl.max()
    span = [n * px for s, n in runs(lit2.any(0)) if n > 1]
    check(max(span) < 4.75 - 1.98, "MZ-S: a field longer than its gap is cut to it", f"longest {max(span):.2f} mm")


# --- 3b. the camera's imprints: light through the base (2026-11-10) -----------------
def grow(mask, n):
    """Distance in 8-neighbour steps from `mask`, up to n (n + 1 beyond)."""
    d = np.full(mask.shape, n + 1, int)
    cur = mask.copy()
    d[cur] = 0
    for k in range(1, n + 1):
        g = cur.copy()
        g[1:] |= cur[:-1]; g[:-1] |= cur[1:]; g[:, 1:] |= cur[:, :-1]; g[:, :-1] |= cur[:, 1:]
        g[1:, 1:] |= cur[:-1, :-1]; g[:-1, :-1] |= cur[1:, 1:]; g[1:, :-1] |= cur[:-1, 1:]; g[:-1, 1:] |= cur[1:, :-1]
        d[g & ~cur] = k
        cur = g
    return d


def rim(v, region):
    """Red over the background 1, 2 and 3 px outside a mark's half-red edge, in 8-bit."""
    b = v[region]
    r = b[..., 0]
    hole = grow(b.min(-1) > 235, 4) <= 4
    bg = np.median(r[~hole])
    ink = (r > 0.5 * (bg + np.percentile(r[~hole], 99.5))) & ~hole
    d = grow(ink, 4)
    return [r[(d == k) & ~hole].mean() - bg for k in (1, 2, 3)]


def imprints(e):
    """The date back and the MZ-S line are an LED behind the film: the light
    spreads in the base before it reaches the emulsion, so each mark glows a
    little past its edge and its core can go yellow while its rim stays
    orange. The factory's edge print is a contact exposure and stays sharp."""
    W, H = 1200, 800
    img = scene(W, H)
    mz = {"film_stock": "kodak_gold_200", "overscan_active": True, "overscan_format": "135", "overscan_holes": "white",
          "overscan_edge_text": "GB 200-7 KODAK", "date_imprint_active": True, "date_imprint_text": "",
          "date_imprint_ev": 5.5, "date_imprint_data_text": "P|{meter:multi}|180|F8|±0.0",
          "date_imprint_data_placement": "perfs"}
    v = v8(render(e, img, mz))
    Hc = v.shape[0]
    band = (slice(int(0.10 * Hc), int(0.15 * Hc)), slice(100, 900))
    g = rim(v, band)
    check(g[0] > 30 and g[1] > 8 and g[0] > g[1] > g[2] >= 0,
          "MZ-S: each mark glows past its edge, falling off over ~0.1 mm (the owner's strip: +86, +34, +13)",
          f"red over the background 1, 2, 3 px (0.03 mm) out: {np.round(g, 1).tolist()}")
    b = v[band]
    r = b[..., 0]
    hole = grow(b.min(-1) > 235, 4) <= 4
    ink = (r > 0.5 * (np.median(r[~hole]) + np.percentile(r[~hole], 99.5))) & ~hole
    dist_in = grow(~ink & ~hole, 4)
    core, edge = b[ink & (dist_in >= 3)].mean(0), b[ink & (dist_in == 1)].mean(0)
    check(core[1] / core[0] > edge[1] / edge[0] + 0.1 and core[0] > edge[0],
          "MZ-S: the core goes toward yellow, the rim stays orange (the strip: g/r 0.66 and 0.52)",
          f"core {np.round(core).astype(int).tolist()}, rim {np.round(edge).astype(int).tolist()}")
    # the film's own halation reaches past them too (small: the print's toe crushes it)
    vh = v8(render(e, img, dict(mz, halation_active=False)))
    rr = grow((vh[band][..., 0] > 100), 8)
    ring = (rr >= 2) & (rr <= 8)
    dh = (v[band] - vh[band])[..., 0][ring].mean()
    check(dh > 0.2, "MZ-S: the film's halation adds light around the marks", f"+{dh:.2f}/255 red, 2-8 px out")
    # the factory's edge print keeps its sharp contact edge
    top = v[:int(0.05 * Hc), :]
    gf = rim(v, (slice(0, int(0.06 * Hc)), slice(0, v.shape[1])))
    check(gf[1] < 0.35 * g[1] + 3 or gf[1] < 4.0,
          "the factory's edge print has no such glow", f"edge print 1, 2, 3 px out: {np.round(gf, 1).tolist()}")
    del top
    # the in-frame date, the same mechanism
    dark = flat(W, H, 0.02)
    dt = {"film_stock": "kodak_gold_200", "date_imprint_active": True, "date_imprint_text": "'26 11 10",
          "date_imprint_ev": 5.5}
    vd = v8(render(e, dark, dt))
    gd = rim(vd, (slice(int(0.8 * H), H), slice(int(0.55 * W), W)))
    check(gd[0] > 25 and gd[1] > 8, "the in-frame date glows past its edge too",
          f"red over the background 1, 2, 3 px out: {np.round(gd, 1).tolist()}")


# --- 4. ks65 --------------------------------------------------------------------
def ks65_measure(e, extra, img):
    rgba, geo = render(e, img, dict({"film_stock": "kodak_vision3_250d", "overscan_active": True,
                                     "overscan_format": "120_6x7", "overscan_holes": "white",
                                     "overscan_carrier": "black", "overscan_perforation": "ks65",
                                     "halation_active": False}, **extra), geometry=True)
    px = geo["mm_per_px"]
    L = lum(rgba)
    v = rgba[..., :3].astype(np.float64) / 65535.0
    lin = np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4).mean(-1)
    bright = L > 0.5 * L.max()
    x0, y0, x1, y1 = gate_box(geo)
    out = {"px": px, "gate": (x0, y0, x1, y1), "rows": []}
    # the film's edges: the black carrier is past them (0.4 mm), the rebate inside them is not black
    film = L > 3.0
    col = film[:, int(0.5 * (x0 + x1))]
    t_top, t_bot = np.flatnonzero(col)[0], np.flatnonzero(col)[-1] + 1
    out["film"] = (t_top, t_bot)
    for top in (True, False):
        band = slice(t_top, int(y0) + 40) if top else slice(int(y1) - 40, t_bot)
        frac = bright[band].mean(1)
        yc = band.start + int(np.argmax(frac))
        half = 0.5 * lin.max()
        rr = sub_runs(lin[yc], half, 1.2 / px)
        starts = np.array([s for s, n in rr])
        lens = np.array([n for s, n in rr])
        across, outer, inner = [], [], []
        for s, n in rr[1:-1]:
            c = lin[:, int(s + n / 2)]
            segs = sub_runs(c[band], half, 1.5 / px)
            a, m = segs[0]
            a += band.start
            across.append(m)
            outer.append((a - t_top) if top else (t_bot - (a + m)))
            inner.append(((a + m) - y0) if top else (y1 - a))
        out["rows"].append({"pitch": np.median(np.diff(starts)) * px, "along": np.median(lens) * px,
                            "across": np.median(across) * px, "outer": np.median(outer) * px,
                            "bite": np.median(inner) * px, "first": (starts[0] - x0) * px})
    return out


def ks65(e):
    img = flat(1390, 1120, 0.004)
    m = ks65_measure(e, {"overscan_camera_seed": 5, "overscan_frame_seed": 1}, img)
    for name, r in zip(("top", "bottom"), m["rows"]):
        check(abs(r["pitch"] - 4.75) <= 0.02 and abs(r["along"] - 1.981) <= 0.03 and abs(r["across"] - 2.794) <= 0.03,
              f"ks65 on 120_6x7 ({name} row): pitch 4.75, holes 1.981 x 2.794 mm",
              f"pitch {r['pitch']:.3f}, {r['along']:.3f} x {r['across']:.3f} mm")
        check(abs(r["outer"] - 0.985) <= 0.3 and abs(r["bite"] - 1.27) <= 0.3,
              f"ks65 ({name} row): 0.98 mm from the film's edge, biting ~1.27 mm into the gate",
              f"edge {r['outer']:.3f} mm, bite {r['bite']:.3f} mm")
    # seed levels: the slitter's offset is the camera's, the phase the frame's
    deltas, phases = [], []
    for fs in (1, 2, 3, 4):
        mm = ks65_measure(e, {"overscan_camera_seed": 5, "overscan_frame_seed": fs}, img)
        deltas.append(0.5 * (mm["rows"][0]["outer"] - mm["rows"][1]["outer"]))
        phases.append(mm["rows"][0]["first"] % 4.75)
    cam = []
    for cs in (5, 6, 7, 8):
        mm = ks65_measure(e, {"overscan_camera_seed": cs, "overscan_frame_seed": 1}, img)
        cam.append(0.5 * (mm["rows"][0]["outer"] - mm["rows"][1]["outer"]))
    check(max(deltas) - min(deltas) < 0.04 and max(cam) - min(cam) > 0.08,
          "ks65: the slitter's offset is the camera's -- the frame seed never moves it",
          f"over frames {np.round(deltas, 3).tolist()}, over cameras {np.round(cam, 3).tolist()} mm")
    check(max(phases) - min(phases) > 1.0, "ks65: the hole phase is the frame's", f"{np.round(phases, 2).tolist()} mm")
    # No 120 backing-paper-era print on ks65, for any stock.
    # The engine has no `overscan_edge_gain`, so the probe is a stock whose 120
    # print reads `overscan_edge_text` (Fujifilm's): with ks65 the text moves
    # nothing; without it, it does (so the check can fail).
    fj = {"film_stock": "fujifilm_pro_400h", "overscan_active": True, "overscan_format": "120_6x7",
          "overscan_holes": "white"}
    def by_text(extra):
        return [render(e, img, dict(fj, **extra, overscan_edge_text=t)) for t in ("FUJI PRO400H", "FUJI XYZ 9")]
    a, b = by_text({})
    check(not np.array_equal(a, b), "the probe: without ks65, Fujifilm's 120 print shows overscan_edge_text")
    a, b = by_text({"overscan_perforation": "ks65"})
    check(np.array_equal(a, b), "ks65: no 120 edge print on a non-cine stock (Fujifilm's text moves nothing)")
    # Every stock's 120 may carry ks65 (the owner, 2026-11-11): Portra 400 on 6x7.
    pm = ks65_measure(e, {"film_stock": "kodak_portra_400", "overscan_camera_seed": 5, "overscan_frame_seed": 1}, img)
    r = pm["rows"][0]
    check(abs(r["pitch"] - 4.75) <= 0.02 and abs(r["along"] - 1.981) <= 0.03 and abs(r["bite"] - 1.27) <= 0.3,
          "ks65 on Portra 400 120_6x7: the same KS holes, biting into the gate",
          f"pitch {r['pitch']:.3f}, along {r['along']:.3f}, bite {r['bite']:.3f} mm")
    ok, msg = refuses(e, flat(1200, 800, 0.1), {"overscan_active": True, "overscan_format": "135",
                                                "overscan_perforation": "ks65"}, "ks65")
    check(ok, "ks65 is refused on a 135 format", msg)
    # the margin date may overlap the holes: drawn, and the hole wins
    dated = render(e, img, {"film_stock": "kodak_vision3_250d", "overscan_active": True, "overscan_format": "120_6x7",
                            "overscan_perforation": "ks65", "overscan_holes": "white", "date_imprint_active": True,
                            "date_imprint_text": "'26 11 9", "date_imprint_data_text": "F8 1/125"})
    plain = render(e, img, {"film_stock": "kodak_vision3_250d", "overscan_active": True, "overscan_format": "120_6x7",
                            "overscan_perforation": "ks65", "overscan_holes": "white"})
    dd = lum(dated) - lum(plain)
    holes = lum(plain) > 0.9 * lum(plain).max()
    check(dd.max() > 20 and np.abs(dd[holes]).max() < 2.0,
          "ks65: the 120 margin date is drawn and the holes stay clear of it",
          f"date max {dd.max():.0f}, inside holes max {np.abs(dd[holes]).max():.2f} (8-bit)")


# --- 5. 135_sprocket, falloff, stripes ----------------------------------------------
def sprocket(e, base=None):
    W, H = 2400, 1200
    grey = flat(W, H, 0.18)
    sp = {"overscan_active": True, "overscan_format": "135_sprocket", "overscan_fog": 0.0, "overscan_leaks": 0.0,
          "halation_active": False}
    rgba, geo = render(e, grey, dict(sp, overscan_holes="black"), geometry=True)
    px = geo["mm_per_px"]
    L = lum(rgba)
    Hc = L.shape[0]
    x0, y0, x1, y1 = gate_box(geo)
    check(y0 < 0 and y1 > Hc and abs((x1 - x0) * px - 72.0) < 0.3,
          "135_sprocket: a 72 mm gate wider than the film", f"gate {(x1 - x0) * px:.2f} x {(y1 - y0) * px:.2f} mm")
    centre = np.median(L[Hc // 2 - 20:Hc // 2 + 20])

    def edge_rows(img_l):
        top = np.median(img_l[int(0.3 / px):int(1.9 / px)], axis=1)
        bot = np.median(img_l[Hc - int(1.9 / px):Hc - int(0.3 / px)], axis=1)
        return np.concatenate([top, bot])
    er = edge_rows(L)
    normal, gn = render(e, flat(1200, 800, 0.18), {"overscan_active": True, "overscan_format": "135",
                                                   "overscan_fog": 0.0, "halation_active": False}, geometry=True)
    Ln = lum(normal)
    rebate = np.median(Ln[int(0.3 / gn["mm_per_px"]):int(1.9 / gn["mm_per_px"])])
    check(er.min() > 0.8 * centre and rebate < 0.3 * np.median(Ln[Ln.shape[0] // 2]),
          "135_sprocket: the picture runs to both film edges (a 135 frame's rebate does not)",
          f"edge rows {er.min():.0f}-{er.max():.0f} against the centre's {centre:.0f}; a 135 rebate {rebate:.0f}")
    dark = L < 0.25 * centre
    for name, t in (("top", 3.4), ("bottom", 35.0 - 3.4)):
        y = int(round(t / px))
        rr = [(s, n) for s, n in runs(dark[y]) if n * px > 1.2]
        pitch = np.median(np.diff([s for s, n in rr])) * px
        along = np.median([n for s, n in rr]) * px
        check(len(rr) >= 14 and abs(pitch - 4.75) < 0.02 and abs(along - 1.98) < 0.04,
              f"135_sprocket: holes at 4.75 mm on the {name} row, through the picture",
              f"{len(rr)} holes, pitch {pitch:.3f}, {along:.3f} mm along")
    phases = []
    for fs in (1, 2, 3, 4, 5, 6):
        r2, g2 = render(e, flat(1200, 600, 0.18), dict(sp, overscan_holes="black", overscan_frame_seed=fs), geometry=True)
        p2 = g2["mm_per_px"]
        L2 = lum(r2)
        y = int(round(3.4 / p2))
        rr = [(s, n) for s, n in runs(L2[y] < 0.25 * np.median(L2[L2.shape[0] // 2])) if n * p2 > 1.2]
        phases.append(((rr[0][0] - gate_box(g2)[0]) * p2) % 4.75)
    check(max(phases) - min(phases) > 2.0, "135_sprocket: the perforation phase is the frame's, over the whole pitch",
          f"{np.round(phases, 2).tolist()} mm")
    img = flat(1200, 600, 0.1)
    ok, msg = refuses(e, img, dict(sp, overscan_pair=True), "pair")
    check(ok, "135_sprocket refuses overscan_pair", msg)
    a = render(e, img, dict(sp, date_imprint_active=True, date_imprint_text="'26 11 9",
                            date_imprint_data_text="F8", date_imprint_data_placement="perfs"))
    check(np.array_equal(a, render(e, img, sp)), "135_sprocket carries no date (the panoramic rule)")

    # falloff: cos^4 of a 30 mm lens, -2.6 EV at the ends of 72 mm
    cal_ev = np.arange(-4.0, 1.01, 0.25)
    cal = []
    for ev in cal_ev:
        r = render(e, flat(1200, 600, 0.18 * 2.0 ** ev), sp)
        cal.append(lum(r)[r.shape[0] // 2 - 5:r.shape[0] // 2 + 5, 590:610].mean())
    cal = np.array(cal)
    fo, gf = render(e, flat(1200, 600, 0.18), dict(sp, overscan_falloff=1.0), geometry=True)
    pf = gf["mm_per_px"]
    gx0, gy0, gx1, gy1 = gate_box(gf)
    Lf = lum(fo)
    yc = int(0.5 * (gy0 + gy1))
    xc = int(0.5 * (gx0 + gx1))
    xe = int(round(gx0 + 0.5 / pf))
    to_ev = lambda v: float(np.interp(v, cal, cal_ev))
    ev_c = to_ev(Lf[yc - 3:yc + 4, xc - 3:xc + 4].mean())
    ev_e = to_ev(Lf[yc - 3:yc + 4, xe - 2:xe + 3].mean())
    check(abs(ev_c) < 0.1 and abs((ev_e - ev_c) + 2.6) <= 0.3,
          "falloff 1 on 135_sprocket: about -2.6 EV at the frame's ends (cos^4, 30 mm lens)",
          f"centre {ev_c:+.2f} EV, 0.5 mm from the end {ev_e - ev_c:+.2f} EV")
    check(np.array_equal(render(e, img, dict(sp, overscan_falloff=0.0)), render(e, img, sp)),
          "falloff 0 is byte for byte no falloff")
    # picture only: a 135 frame's rebate, edge print and fog do not move
    f135 = {"overscan_active": True, "overscan_format": "135", "overscan_fog": 1.0, "halation_active": False,
            "overscan_edge_text": "PORTRA 400"}
    a, ga = render(e, flat(1200, 800, 0.18), dict(f135, overscan_falloff=1.5), geometry=True)
    b = render(e, flat(1200, 800, 0.18), f135)
    top = int(gate_box(ga)[1] - 0.5 / ga["mm_per_px"])
    # (to 2 codes of 65535: the couplers' diffusion in the emulsion reaches a hair past the gate)
    dmax = np.abs(a[:top, :, :3].astype(np.int64) - b[:top, :, :3].astype(np.int64)).max()
    check(dmax <= 2 and not np.array_equal(a, b),
          "falloff touches the picture only: the rebate, its print and fog do not move",
          f"rebate max {dmax} codes of 65535")

    # X-Tra 400's stripes: on 135_sprocket only
    darkf = flat(1200, 600, 0.004)
    xs = lum(render(e, darkf, dict(sp, film_stock="fujifilm_xtra_400", overscan_holes="black")))
    xv = v8(render(e, darkf, dict(sp, film_stock="fujifilm_xtra_400", overscan_holes="black")))
    pv = v8(render(e, darkf, dict(sp, film_stock="kodak_portra_400", overscan_holes="black")))
    p6 = 35.0 / xv.shape[0]

    def row_green(v, t):
        y = int(round(t / p6))
        r = v[y - 1:y + 2].mean(0)
        return np.percentile(r[:, 1] - r[:, 0], 75), np.percentile(r[:, 0] - r[:, 1], 75)
    g_x, _ = row_green(xv, 2.83)
    _, r_x = row_green(xv, 3.73)
    g_p, _ = row_green(pv, 2.83)
    _, r_p = row_green(pv, 3.73)
    gb, _ = row_green(xv, 35.0 - 2.83)
    check(g_x > 25 and r_x > 25 and gb > 25 and g_p < 10 and r_p < 10,
          "X-Tra 400 on 135_sprocket: a green and a red stripe in the perforation rows, both edges; none on Portra",
          f"green {g_x:.0f}/{gb:.0f}, red {r_x:.0f}; Portra {g_p:.0f}, {r_p:.0f} (8-bit)")
    del xs

    # ... and on every 135-gauge format for X-Tra 400 and Pro 400H (the owner, 2026-11-11); not on 120
    for fmt, (w, h) in (("135", (1200, 800)), ("135_half", (600, 800)), ("135_xpan", (1300, 480)),
                        ("135_sprocket", (1200, 600))):
        got = {}
        for stock in STRIPED + NOT_STRIPED:
            rgba, geo = render(e, flat(w, h, 0.004), {"film_stock": stock, "overscan_active": True, "overscan_format": fmt,
                                                     "overscan_holes": "black", "overscan_fog": 0.0}, geometry=True)
            v, t = v8(rgba), film_t(geo, rgba.shape)
            sides = []
            for sign in (-1, 1):
                g_rows = np.abs(t - sign * (17.5 - STRIPE_G)) < 0.08
                r_rows = np.abs(t - sign * (17.5 - STRIPE_R)) < 0.15
                sides.append((np.percentile((v[..., 1] - v[..., 0])[g_rows], 75),
                              np.percentile((v[..., 0] - v[..., 1])[r_rows], 75)))
            got[stock] = sides
        striped = all(g > 25 and r > 25 for st in STRIPED for g, r in got[st])
        plain = all(g < 10 and r < 10 for st in NOT_STRIPED for g, r in got[st])
        check(striped and plain, f"{fmt}: X-Tra 400 and Pro 400H carry a green and a red stripe on both edges; "
              "Portra 400, C200, Velvia 100 and Provia 100F none",
              "; ".join(f"{st.split('_', 1)[1]} " + " / ".join(f"g{g:.0f} r{r:.0f}" for g, r in got[st]) for st in got))
    if base is not None:
        p67 = {"film_stock": "fujifilm_pro_400h", "overscan_active": True, "overscan_format": "120_6x7",
               "overscan_edge_text": "PRO 400H"}
        img = scene(834, 672)
        check(np.array_equal(render(e, img, dict(p67, **NEW_DEFAULTS)), render(base, img, p67)),
              "Pro 400H on 120_6x7: no stripes, byte for byte the base engine")



def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib", type=Path)
    ap.add_argument("--base-dylib", type=Path)
    ap.add_argument("--before-retune-dylib", type=Path,
                    help="an engine from before the wash/spot retune (5c5b890d): the band must be its, byte for byte")
    a = ap.parse_args()
    e = spk.Engine(a.dylib)
    base = spk.Engine(a.base_dylib) if a.base_dylib else None
    if base is None:
        print("SKIP the af5173b9 comparison (no --base-dylib); defaults are compared with none sent instead")
    try:
        byte_identity(e, base)
        leaks(e)
        leak_shapes(e)
        if a.before_retune_dylib:
            before = spk.Engine(a.before_retune_dylib)
            try:
                band_unchanged(e, before)
            finally:
                before.close()
        else:
            print("SKIP the band against the engine before the retune (no --before-retune-dylib)")
        leak_bw(a.dylib)
        mzs(e)
        imprints(e)
        ks65(e)
        sprocket(e, base)
    finally:
        for x in (e, base):
            if x is not None:
                x.close()
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
