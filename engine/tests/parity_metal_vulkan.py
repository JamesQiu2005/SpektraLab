#!/usr/bin/env python3
"""Whole-image parity: the Vulkan engine against the Metal engine, on identical input.

Only a Mac can run this, because only a Mac has both: the Metal engine
(`engine/build.sh dylib`, the macOS product's) and the Vulkan engine built
natively through MoltenVK (`cmake -DSPEKTRALAB_VULKAN_ON_APPLE=ON`, see
`engine/LINUX_WINDOWS.md` §7). Each engine renders in its own process (two
copies of the C ABI in one process would share nothing but would make a crash
in one look like a failure of both), into an output directory of `.npy`
frames; `compare` grades one directory against the other.

    # 1. render the catalogue with each engine
    python3 engine/tests/parity_metal_vulkan.py render --library <metal dylib> \
        --resources <metal resources> --out build/parity/metal
    python3 engine/tests/parity_metal_vulkan.py render --library <vulkan dylib> \
        --resources <vulkan resources> --out build/parity/vulkan
    # 2. grade
    python3 engine/tests/parity_metal_vulkan.py compare build/parity/metal build/parity/vulkan

The input is synthetic, linear sRGB, and the same bytes for both: a chart,
an exposure wedge, a hue sweep at three levels, a block of dark saturated
reds (GitHub issue #12), hard edges, and point lights for halation and the
headroom. Grain and glare are off for every pixel comparison (their draws are
compared as statistics in the `grain_*` cases, never pixel by pixel).

What `compare` reports per case, on the 16-bit sRGB-encoded result: the max
and mean absolute difference in 8-bit code values (u16 / 257), the 99.9th
percentile, and CIEDE2000 (mean, p99.9, max). Film-edge cases are also graded
inside the picture's own frame alone (`frame` rows), because the edge print's
typeface differs by design off Apple (Liberation Sans / DejaVu Sans Mono Bold
via stb_truetype against CoreText's Helvetica Neue / Menlo); the whole-canvas
row then shows how much that typography moves.

Pass bar (deterministic cases): max |d| <= 1 code, mean |d| <= 0.01 code,
CIEDE2000 p99.9 <= 0.1 and max <= 1.0. Why these numbers: they are set from
what was measured, with margin, not from what would be comfortable. On
2026-10-29 (Apple M6, MoltenVK against the 1.3.4 metallib) every deterministic
non-edge case landed at max <= 0.38 code and mean < 0.0001 code: both
backends run float32 with safe math and the shaders are transliterations. The
bar is tight enough that a +0.02 EV exposure change (mean 0.058 code) and a 2 %
print exposure change both FAIL it -- run with `--extra` to see that. A looser
bar (2 codes / 0.1 mean) passed the 0.02 EV control and was rejected.
`--strict` lowers max to 0.5 code.

Cases flagged `raster` carry CPU-rasterised marks inside the picture (the date
back on a half-frame pair): their 8-bit masks come from CoreGraphics on Metal
and from the portable exact-area rasterizer off Apple, and a mask level of
difference in a dark gap between two LCD segments moves a few pixels by
several codes after the print's toe. Their bar drops the max and asks for
p99.9 <= 1 code instead; the max is still printed.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

BASE = {
    "input_color_space": "sRGB", "input_cctf_decoding": False,
    "output_color_space": "sRGB", "output_cctf_encoding": True,
    "grain_active": False, "glare_active": False, "auto_exposure": False,
    "film_format_mm": 36.0,
}

W, H = 1536, 1024

COLOR_FILMS = [
    "fujifilm_c200", "fujifilm_pro_400h", "fujifilm_provia_100f", "fujifilm_velvia_100",
    "fujifilm_xtra_400", "kodak_ektachrome_100", "kodak_ektar_100", "kodak_gold_200",
    "kodak_kodachrome_64", "kodak_portra_160", "kodak_portra_400", "kodak_portra_800",
    "kodak_portra_800_push1", "kodak_portra_800_push2", "kodak_ultramax_400", "kodak_verita_200d",
    "kodak_vision3_200t", "kodak_vision3_250d", "kodak_vision3_500t", "kodak_vision3_50d",
    "cinestill_800t",
]
PAPERS = ["kodak_2383", "kodak_2393", "kodak_endura_premier", "kodak_ektacolor_edge",
          "kodak_portra_endura", "kodak_supra_endura", "kodak_ultra_endura",
          "fujifilm_crystal_archive_typeii"]
BW_FILMS = ["kodak_tri_x_400", "kodak_tmax_100", "fujifilm_neopan_acros_100_ii", "ilford_hp5_plus_400"]
BW = {"print_stock": "ilford_multigrade_iv_rc"}


# --- the input -----------------------------------------------------------

def srgb_to_linear(v):
    v = np.asarray(v, np.float64)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


# ColorChecker Classic, sRGB 8-bit (X-Rite's published values, D65-adapted).
CHECKER = [
    (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
    (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
    (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
    (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
]


def hsv(h, s, v):
    i = int(h * 6) % 6
    f = h * 6 - int(h * 6)
    p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    return [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]


def make_input(w=W, h=H) -> np.ndarray:
    img = np.empty((h, w, 3), np.float64)
    # background: a smooth diagonal gradient around mid-grey
    yy, xx = np.mgrid[0:h, 0:w]
    img[:] = (0.184 * 2.0 ** (-2.0 + 3.0 * (xx / w) * (1 - 0.3 * yy / h)))[..., None]
    # 1. the chart, 6 x 4 patches in the top-left
    pw, ph = w // 16, h // 10
    for k, c in enumerate(CHECKER):
        r, q = divmod(k, 6)
        img[ph // 4 + r * ph: ph // 4 + (r + 1) * ph - 4, pw // 4 + q * pw: pw // 4 + (q + 1) * pw - 4] = \
            srgb_to_linear(np.array(c) / 255.0)
    # 2. the exposure wedge, -8 .. +6 EV over mid-grey, along the bottom
    x0, x1, y0 = w // 16, w - w // 16, h - h // 6
    n = 29
    for k in range(n):
        a = x0 + (x1 - x0) * k // n
        b = x0 + (x1 - x0) * (k + 1) // n
        img[y0: y0 + h // 14, a: b - 2] = 0.184 * 2.0 ** (-8.0 + 14.0 * k / (n - 1))
    # 3. the hue sweep, three levels, right half
    for row, v in enumerate((0.05, 0.25, 0.9)):
        for k in range(36):
            c = srgb_to_linear(np.array(hsv(k / 36.0, 0.95, 1.0))) * v
            a = w // 2 + k * (w // 2 - w // 32) // 36
            img[ph // 4 + row * ph: ph // 4 + (row + 1) * ph - 4, a: a + (w // 2 - w // 32) // 36 - 2] = c
    # 4. dark saturated reds (issue #12: dark red developing purple)
    reds = [(0.06, 0.004, 0.004), (0.12, 0.008, 0.01), (0.25, 0.015, 0.02), (0.08, 0.0, 0.012),
            (0.18, 0.02, 0.0), (0.04, 0.002, 0.006), (0.35, 0.03, 0.05), (0.5, 0.06, 0.04)]
    for k, c in enumerate(reds):
        a = w // 2 + k * (w // 2 - w // 32) // 8
        img[ph // 4 + 3 * ph + 8: ph // 4 + 4 * ph, a: a + (w // 2 - w // 32) // 8 - 4] = c
    # 5. hard edges: a black/white checkerboard block
    cb = ((yy // 8 + xx // 8) % 2).astype(np.float64)
    blk = (slice(h // 2, h // 2 + h // 6), slice(w // 16, w // 16 + w // 6))
    img[blk] = (0.002 + 1.2 * cb[blk])[..., None]
    # 6. lights: a +3.5 EV clipped-looking lamp, a bright red tube, small points
    rr = np.hypot(xx - 0.62 * w, yy - 0.62 * h)
    img[rr <= 6] = 0.184 * 2 ** 3.5
    img[int(0.55 * h): int(0.55 * h) + 6, int(0.72 * w): int(0.90 * w)] = (0.184 * 2 ** 3.4, 0.03, 0.02)
    for k in range(5):
        r2 = np.hypot(xx - (0.35 + 0.07 * k) * w, yy - 0.72 * h)
        img[r2 <= 1.5] = 0.184 * 2 ** (1.0 + k)
    return np.ascontiguousarray(img, np.float32)


# --- the cases -----------------------------------------------------------

def catalogue() -> list[dict]:
    """Each case: name, delta, and optional kind/shape. Deterministic unless kind says so."""
    cases = []
    for f in COLOR_FILMS:
        cases.append({"name": f"film/{f}", "delta": {"film_stock": f, "print_stock": "kodak_2383"}})
    for p in PAPERS:
        cases.append({"name": f"paper/{p}", "delta": {"film_stock": "kodak_portra_400", "print_stock": p}})
    for f in BW_FILMS:
        cases.append({"name": f"bw/{f}", "delta": {"film_stock": f, **BW}})
    cases += [
        # stage taps: the negative alone, scanned (film side only), no halation
        {"name": "stage/scan_film_portra400", "delta": {"film_stock": "kodak_portra_400", "scan_film": True}},
        {"name": "stage/scan_film_cinestill", "delta": {"film_stock": "cinestill_800t", "scan_film": True}},
        {"name": "stage/no_halation_portra400", "delta": {"film_stock": "kodak_portra_400", "halation_active": False}},
        {"name": "stage/no_couplers_portra400", "delta": {"film_stock": "kodak_portra_400", "dir_couplers_active": False}},
        {"name": "stage/export_di_portra400", "kind": "export_di", "delta": {"film_stock": "kodak_portra_400"}},
        {"name": "stage/export_di_cinestill", "kind": "export_di", "delta": {"film_stock": "cinestill_800t"}},
        # CineStill 800T: the back-reflection halo, and its headroom
        {"name": "cinestill/headroom_0", "delta": {"film_stock": "cinestill_800t", "halation_headroom_ev": 0.0}},
        {"name": "cinestill/headroom_8", "delta": {"film_stock": "cinestill_800t", "halation_headroom_ev": 8.0}},
        {"name": "cinestill/amount_4", "delta": {"film_stock": "cinestill_800t", "halation_amount": 4.0}},
        {"name": "cinestill/antihalation_removed_500t",
         "delta": {"film_stock": "kodak_vision3_500t", "antihalation_removed": True}},
        # 1.3.4's other engine changes
        {"name": "camera_filter/tri_x_w25", "delta": {"film_stock": "kodak_tri_x_400", **BW, "camera_filter": "w25"}},
        {"name": "camera_filter/tri_x_w47", "delta": {"film_stock": "kodak_tri_x_400", **BW, "camera_filter": "w47"}},
        {"name": "camera_filter/portra_w8", "delta": {"film_stock": "kodak_portra_400", "camera_filter": "w8"}},
        # the rest of the controls a user moves
        {"name": "ctl/print_exposure_dark", "delta": {"film_stock": "kodak_portra_400", "print_exposure": 0.3}},
        {"name": "ctl/exposure_minus3", "delta": {"film_stock": "kodak_portra_400", "exposure_compensation_ev": -3.0}},
        {"name": "ctl/exposure_plus3", "delta": {"film_stock": "kodak_portra_400", "exposure_compensation_ev": 3.0}},
        {"name": "ctl/filters", "delta": {"film_stock": "kodak_gold_200", "m_filter_shift": 0.4, "y_filter_shift": -0.3}},
        {"name": "ctl/auto_exposure", "delta": {"film_stock": "kodak_portra_400", "auto_exposure": True}},
        {"name": "ctl/output_p3", "delta": {"film_stock": "kodak_portra_400", "output_color_space": "Display P3"}},
        {"name": "ctl/geometry", "delta": {"film_stock": "kodak_portra_400", "geometry_rotation_deg": 3.0,
                                            "geometry_quarter_turns": 1, "geometry_flip_h": True}},
        {"name": "ctl/scene_latitude", "delta": {"film_stock": "kodak_portra_400", "scene_latitude_active": True}},
        {"name": "ctl/edr", "delta": {"film_stock": "kodak_portra_400", "extended_dynamic_range": True}},
        {"name": "ctl/digital_intermediate", "delta": {"film_stock": "kodak_vision3_250d", "digital_intermediate": True}},
        # issue #12's settings: enlarger brightness -1.76 (print_exposure in stops?) on Portra 400 / Supra Endura
        {"name": "issue12/portra400_supra", "delta": {"film_stock": "kodak_portra_400", "print_stock": "kodak_supra_endura"}},
        # film edge, date back, half-frame pair
        {"name": "edge/135_portra400", "kind": "edge", "delta": {"film_stock": "kodak_portra_400", "overscan_active": True,
                                                                    "overscan_edge_text": "KODAK PORTRA 400"}},
        {"name": "edge/135_cinestill", "kind": "edge", "delta": {"film_stock": "cinestill_800t", "overscan_active": True,
                                                                    "overscan_edge_text": "CINESTILL 800T"}},
        {"name": "edge/120_6x7_cinestill", "kind": "edge", "shape": (1390, 1120),
         "delta": {"film_stock": "cinestill_800t", "overscan_active": True, "overscan_format": "120_6x7",
                   "overscan_edge_text": "CINESTILL 800T"}},
        {"name": "edge/135_tri_x", "kind": "edge", "delta": {"film_stock": "kodak_tri_x_400", **BW, "overscan_active": True,
                                                                "overscan_edge_text": "KODAK 400TX"}},
        {"name": "edge/135_hp5", "kind": "edge", "delta": {"film_stock": "ilford_hp5_plus_400", **BW, "overscan_active": True,
                                                              "overscan_edge_text": "HP5 PLUS"}},
        {"name": "edge/135_acros", "kind": "edge", "delta": {"film_stock": "fujifilm_neopan_acros_100_ii", **BW,
                                                                "overscan_active": True,
                                                                "overscan_edge_text": "FUJI 100 ACROS II"}},
        {"name": "edge/120_645_tri_x", "kind": "edge", "shape": (1400, 1050),
         "delta": {"film_stock": "kodak_tri_x_400", **BW, "overscan_active": True, "overscan_format": "120_645",
                   "overscan_edge_text": "KODAK 400TX"}},
        {"name": "edge/135_vision3_fog_leaks", "kind": "edge",
         "delta": {"film_stock": "kodak_vision3_250d", "overscan_active": True, "overscan_leaks": 1.0,
                   "overscan_edge_text": "EASTMAN 5207", "overscan_holes": "black", "overscan_carrier": "black"}},
        {"name": "date/lcd_in_frame", "delta": {"film_stock": "kodak_gold_200", "date_imprint_active": True,
                                                 "date_imprint_text": "'26 10 29"}},
        {"name": "date/dots_rebate", "kind": "edge",
         "delta": {"film_stock": "kodak_gold_200", "overscan_active": True, "date_imprint_active": True,
                   "date_imprint_style": "dots", "date_imprint_placement": "rebate", "date_imprint_text": "26 10 29",
                   "overscan_edge_text": "KODAK GOLD 200"}},
        {"name": "pair/135_half_edge", "kind": "edge", "raster": True, "shape": (1110, 720),
         "delta": {"film_stock": "kodak_portra_400", "overscan_active": True, "overscan_format": "135_half",
                   "overscan_pair": True, "overscan_edge_text": "KODAK PORTRA 400", "date_imprint_active": True,
                   "date_imprint_text": "'26 10 29", "date_imprint_text_b": "'26 10 30"}},
        {"name": "pair/135_half_no_edge", "raster": True, "shape": (1110, 720),
         "delta": {"film_stock": "kodak_portra_400", "overscan_format": "135_half", "overscan_pair": True,
                   "date_imprint_active": True, "date_imprint_text": "'26 10 29", "date_imprint_text_b": "'26 10 30"}},
        # stochastic: compared as statistics, never pixel by pixel
        {"name": "grain_portra400", "kind": "stats", "delta": {"film_stock": "kodak_portra_400", "grain_active": True}},
        {"name": "grain_tri_x", "kind": "stats", "delta": {"film_stock": "kodak_tri_x_400", **BW, "grain_active": True}},
        {"name": "glare_portra400", "kind": "stats", "delta": {"film_stock": "kodak_portra_400", "glare_active": True}},
    ]
    return cases


# --- rendering -------------------------------------------------------------

def cmd_render(a) -> int:
    import spk_ctypes as spk
    a.out.mkdir(parents=True, exist_ok=True)
    inputs = {}
    log = {"library": str(a.library), "resources": str(a.resources), "cases": {}}
    with spk.Engine(library=a.library, resources=a.resources) as e:
        log["build_info"] = e.build_info
        log["render_core"] = e.capabilities().get("backend", {}).get("render_core")
        log["math_mode"] = e.capabilities().get("backend", {}).get("math_mode")
        for case in catalogue():
            if a.only and not any(s in case["name"] for s in a.only):
                continue
            shape = case.get("shape", (W, H))
            if shape not in inputs:
                inputs[shape] = make_input(*shape)
            img = inputs[shape]
            t = time.time()
            entry = {"delta": case["delta"]}
            try:
                s = e.open(img, {**BASE, **case["delta"], **a.extra})
                try:
                    if case.get("kind") == "export_di":
                        out, info = s.export_di()
                        entry["info"] = info
                    else:
                        out, _ = s.render(a.tier)
                    if case.get("kind") == "edge":
                        try:
                            entry["geometry"] = s.overscan_geometry()
                        except Exception as ex:  # noqa: BLE001
                            entry["geometry_error"] = str(ex)
                finally:
                    s.close()
                np.save(a.out / (case["name"].replace("/", "__") + ".npy"), out)
                entry["shape"] = list(out.shape)
                entry["ms"] = round(1000 * (time.time() - t))
                print(f"{case['name']:<40} {out.shape[1]}x{out.shape[0]}  {entry['ms']} ms", flush=True)
            except Exception as ex:  # noqa: BLE001
                entry["error"] = str(ex)
                print(f"{case['name']:<40} ERROR {ex}", flush=True)
            log["cases"][case["name"]] = entry
    (a.out / "log.json").write_text(json.dumps(log, indent=1))
    return 0


# --- grading ---------------------------------------------------------------

def srgb_u16_to_lab(rgb16: np.ndarray) -> np.ndarray:
    v = rgb16.astype(np.float64) / 65535.0
    lin = np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750],
                  [0.0193339, 0.1191920, 0.9503041]])
    xyz = lin @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(xyz), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def ciede2000(lab1: np.ndarray, lab2: np.ndarray) -> np.ndarray:
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1, C2 = np.hypot(a1, b1), np.hypot(a2, b2)
    Cm = (C1 + C2) / 2
    G = 0.5 * (1 - np.sqrt(Cm ** 7 / (Cm ** 7 + 25.0 ** 7)))
    a1p, a2p = a1 * (1 + G), a2 * (1 + G)
    C1p, C2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp, dCp = L2 - L1, C2p - C1p
    dhp = h2p - h1p
    dhp = np.where(dhp > 180, dhp - 360, np.where(dhp < -180, dhp + 360, dhp))
    dhp = np.where(C1p * C2p == 0, 0, dhp)
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dhp) / 2)
    Lpm, Cpm = (L1 + L2) / 2, (C1p + C2p) / 2
    hsum = h1p + h2p
    hpm = np.where(C1p * C2p == 0, hsum,
                   np.where(np.abs(h1p - h2p) <= 180, hsum / 2,
                            np.where(hsum < 360, (hsum + 360) / 2, (hsum - 360) / 2)))
    T = (1 - 0.17 * np.cos(np.radians(hpm - 30)) + 0.24 * np.cos(np.radians(2 * hpm))
         + 0.32 * np.cos(np.radians(3 * hpm + 6)) - 0.20 * np.cos(np.radians(4 * hpm - 63)))
    dtheta = 30 * np.exp(-(((hpm - 275) / 25) ** 2))
    Rc = 2 * np.sqrt(Cpm ** 7 / (Cpm ** 7 + 25.0 ** 7))
    Sl = 1 + 0.015 * (Lpm - 50) ** 2 / np.sqrt(20 + (Lpm - 50) ** 2)
    Sc, Sh = 1 + 0.045 * Cpm, 1 + 0.015 * Cpm * T
    Rt = -np.sin(np.radians(2 * dtheta)) * Rc
    return np.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh))


def grade(a: np.ndarray, b: np.ndarray, colour: bool = True) -> dict:
    d = np.abs(a[..., :3].astype(np.float64) - b[..., :3].astype(np.float64)) / 257.0
    out = {"max": float(d.max()), "mean": float(d.mean()), "p999": float(np.quantile(d, 0.999)),
           "px_over_1": float((d.max(-1) > 1.0).mean())}
    if colour:
        de = ciede2000(srgb_u16_to_lab(a[..., :3]), srgb_u16_to_lab(b[..., :3]))
        out.update({"de_mean": float(de.mean()), "de_p999": float(np.quantile(de, 0.999)), "de_max": float(de.max())})
    return out


def frame_box(geometry: dict, shape):
    """A mask of the picture's own frame(s) inside an overscan canvas, each gate's
    inner box shrunk by 3 % so the gate's penumbra and flare stay out."""
    gates = (geometry or {}).get("gates") or []
    if not gates:
        return None
    mask = np.zeros(shape[:2], bool)
    for q in gates:
        # the inner box of a slightly tilted quad, whatever its corner order
        xs, ys = sorted(q[0::2]), sorted(q[1::2])
        x0, x1 = xs[1] * shape[1], xs[2] * shape[1]
        y0, y1 = ys[1] * shape[0], ys[2] * shape[0]
        mx, my = 0.03 * (x1 - x0), 0.03 * (y1 - y0)
        mask[int(y0 + my): int(y1 - my), int(x0 + mx): int(x1 - mx)] = True
    return mask if mask.any() else None


def cmd_compare(a) -> int:
    la = json.loads((a.ref / "log.json").read_text())
    lb = json.loads((a.test / "log.json").read_text())
    max_bar = 0.5 if a.strict else 1.0
    rows, fails = [], 0
    print(f"reference {la.get('render_core')} ({la.get('math_mode')})\n"
          f"test      {lb.get('render_core')} ({lb.get('math_mode')})\n")
    hdr = f"{'case':<40} {'max':>6} {'mean':>7} {'p99.9':>6} {'>1code':>7} {'dE mean':>8} {'dE p99.9':>8} {'dE max':>7}  verdict"
    print(hdr)
    print("-" * len(hdr))
    for name, ea in la["cases"].items():
        eb = lb["cases"].get(name)
        if eb is None:
            continue
        if "error" in ea or "error" in eb:
            ok = ("error" in ea) == ("error" in eb)
            verdict = "both refused" if ok else "FAIL: " + (eb.get("error") or "reference refused: " + ea["error"])
            fails += 0 if ok else 1
            print(f"{name:<40} {'':>6} {'':>7} {'':>6} {'':>7} {'':>8} {'':>8} {'':>7}  {verdict[:90]}")
            rows.append({"case": name, "verdict": verdict})
            continue
        fa = a.ref / (name.replace("/", "__") + ".npy")
        fb = a.test / (name.replace("/", "__") + ".npy")
        A, B = np.load(fa), np.load(fb)
        if A.shape != B.shape:
            fails += 1
            print(f"{name:<40} FAIL shape {A.shape} vs {B.shape}")
            rows.append({"case": name, "verdict": f"FAIL shape {A.shape} vs {B.shape}"})
            continue
        kind, raster = None, False
        for c in catalogue():
            if c["name"] == name:
                kind, raster = c.get("kind"), c.get("raster", False)
        if kind == "stats":
            fa_, fb_ = A[..., :3].astype(np.float64) / 257, B[..., :3].astype(np.float64) / 257
            # flat regions: 32 x 32 tiles, mean and std per tile, compared tile by tile
            t = 32
            hh, ww = (fa_.shape[0] // t) * t, (fa_.shape[1] // t) * t
            ta = fa_[:hh, :ww].reshape(hh // t, t, ww // t, t, 3)
            tb = fb_[:hh, :ww].reshape(hh // t, t, ww // t, t, 3)
            dm = np.abs(ta.mean((1, 3)) - tb.mean((1, 3)))
            sa, sb = ta.std((1, 3)), tb.std((1, 3))
            sd = np.abs(sa - sb) / np.maximum(0.5, 0.5 * (sa + sb))
            r = {"tile_mean_med": float(np.median(dm)), "tile_mean_p95": float(np.quantile(dm, 0.95)),
                 "tile_std_rel_med": float(np.median(sd)), "tile_std_rel_p95": float(np.quantile(sd, 0.95)),
                 "global_mean_diff": float(abs(fa_.mean() - fb_.mean()))}
            ok = r["tile_mean_med"] <= 1.0 and r["tile_std_rel_med"] <= 0.15 and r["global_mean_diff"] <= 0.5
            verdict = "pass (stats)" if ok else "FAIL (stats)"
            fails += 0 if ok else 1
            print(f"{name:<40} tile mean |d| med {r['tile_mean_med']:.3f} p95 {r['tile_mean_p95']:.3f}; "
                  f"tile std rel med {r['tile_std_rel_med']:.3f} p95 {r['tile_std_rel_p95']:.3f}; "
                  f"global {r['global_mean_diff']:.3f}  {verdict}")
            rows.append({"case": name, **r, "verdict": verdict})
            continue
        g = grade(A, B)

        def passes(r):
            if raster:   # CPU-rasterised marks in the frame: CoreGraphics vs the portable coverage raster
                return r["mean"] <= 0.01 and r["p999"] <= 1.0 and r["de_p999"] <= 0.1
            return r["max"] <= max_bar and r["mean"] <= 0.01 and r["de_p999"] <= 0.1 and r["de_max"] <= 1.0
        ok = passes(g)
        sub = None
        if kind == "edge":
            box = frame_box(ea.get("geometry"), A.shape)
            if box is not None:
                sub = grade(A[box], B[box])
                okf = passes(sub)
                verdict = ("pass" if ok else "typography (canvas)") if okf else "FAIL (frame)"
                fails += 0 if okf else 1
            else:
                verdict = "pass" if ok else "FAIL (no frame box)"
                fails += 0 if ok else 1
        elif kind == "export_di":
            verdict = "pass" if (g["max"] <= max_bar and g["mean"] <= 0.01) else "FAIL"
            fails += 0 if verdict == "pass" else 1
        else:
            verdict = ("pass (raster bar)" if raster else "pass") if ok else "FAIL"
            fails += 0 if ok else 1
        print(f"{name:<40} {g['max']:6.2f} {g['mean']:7.4f} {g['p999']:6.2f} {100*g['px_over_1']:6.3f}% "
              f"{g['de_mean']:8.4f} {g['de_p999']:8.3f} {g['de_max']:7.3f}  {verdict}")
        rows.append({"case": name, **g, "verdict": verdict})
        if sub is not None:
            print(f"{'  ' + name + ' [frame]':<40} {sub['max']:6.2f} {sub['mean']:7.4f} {sub['p999']:6.2f} "
                  f"{100*sub['px_over_1']:6.3f}% {sub['de_mean']:8.4f} {sub['de_p999']:8.3f} {sub['de_max']:7.3f}")
            rows.append({"case": name + " [frame]", **sub})
    if a.json:
        a.json.write_text(json.dumps(rows, indent=1))
    print(f"\n{fails} failing case(s); bar: max <= {max_bar} code, mean <= 0.01 code, "
          f"dE2000 p99.9 <= 0.1, max <= 1.0")
    return 1 if fails else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render")
    r.add_argument("--library", type=Path, required=True)
    r.add_argument("--resources", type=Path, required=True)
    r.add_argument("--out", type=Path, required=True)
    r.add_argument("--tier", default="full")
    r.add_argument("--only", nargs="*", help="substrings of case names")
    r.add_argument("--extra", type=json.loads, default={},
                   help="JSON delta laid over every case: a negative control (e.g. '{\"print_exposure\": 1.02}') "
                        "to show the grading reacts")
    c = sub.add_parser("compare")
    c.add_argument("ref", type=Path)
    c.add_argument("test", type=Path)
    c.add_argument("--strict", action="store_true")
    c.add_argument("--json", type=Path)
    a = ap.parse_args()
    return cmd_render(a) if a.cmd == "render" else cmd_compare(a)


if __name__ == "__main__":
    raise SystemExit(main())
