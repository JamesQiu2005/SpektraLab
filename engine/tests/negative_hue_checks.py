"""The print's hue, from the negative (`core/negative_hue.hpp`): what it must do and what it must not touch.

    python3 engine/tests/negative_hue_checks.py [--dylib PATH] [--pairs all] [--json out.json]

Needs numpy and the built dylib; no fixture, no Python oracle. Every input is made here: a chart of
Oklab hues, chromas and lightnesses, a grey ramp, a chroma ramp. Grain, glare and halation are off
for the measurements (trap 1, and so a patch's centre is a flat field).

What is checked, and why each one can fail:

  hue           the print's Oklab hue against the hue that went in, mean |dh| over the chart. The
                optical print is 9-11 degrees out on every pair; with the node it is ~1. The same
                chart with `SPK_NEGATIVE_HUE=0` must be *worse* than the bar, or the bar measures
                nothing (an engine without the node fails here: that is the red run).
  lightness     the node may not move tone: |dL| against the optical print, same chart.
  neutral       a grey ramp is the optical print to the bit, every exposure.
  continuity    a chroma ramp through the take-over threshold has no step the optical print lacks.
  one print     the fused pass and the node-by-node print are the same picture to the bit.
  not mine      a catalogued (minilab) pair, a scanned negative, a slide and the Digital
                Intermediate render the same bits with the node on and off.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes as spk  # noqa: E402

BASE = {
    "film_stock": "kodak_portra_400", "print_stock": "kodak_supra_endura",
    "auto_exposure": False, "exposure_compensation_ev": 0.0, "product_defaults": True,
    "grain_active": False, "glare_active": False, "halation_active": False,
    "input_color_space": "ProPhoto RGB", "input_cctf_decoding": False,
    "output_color_space": "Display P3", "output_cctf_encoding": True,
}
PAIRS = [("kodak_portra_400", "kodak_supra_endura"), ("kodak_gold_200", "kodak_endura_premier"),
         ("fujifilm_pro_400h", "fujifilm_crystal_archive_typeii"), ("kodak_vision3_250d", "kodak_2383"),
         ("kodak_ektar_100", "kodak_portra_endura")]
ALL_FILMS = ["fujifilm_c200", "fujifilm_pro_400h", "fujifilm_xtra_400", "kodak_ektar_100", "kodak_gold_200",
             "kodak_portra_160", "kodak_portra_400", "kodak_portra_800", "kodak_portra_800_push1",
             "kodak_portra_800_push2", "kodak_ultramax_400", "kodak_verita_200d", "kodak_vision3_200t",
             "kodak_vision3_250d", "kodak_vision3_500t", "kodak_vision3_50d"]
ALL_PAPERS = ["fujifilm_crystal_archive_typeii", "kodak_2383", "kodak_2393", "kodak_ektacolor_edge",
              "kodak_endura_premier", "kodak_portra_endura", "kodak_supra_endura", "kodak_ultra_endura"]

# The bars. Measured 2026-11-11 on the five pairs above: hue 1.0-1.3 with the node, 8.9-11.4 without.
HUE_MEAN_MAX = 3.0        # degrees, node on
HUE_OFF_MIN = 6.0         # degrees, node off: the chart has to be able to show the fault
LIGHTNESS_MAX = 0.01      # Oklab L, node on against node off
PATCH = 32

M1 = np.array([[0.8189330101, 0.3618667424, -0.1288597137],
               [0.0329845436, 0.9293118715, 0.0361456387],
               [0.0482003018, 0.2643662691, 0.6338517070]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
               [1.9779984951, -2.4285922050, 0.4505937099],
               [0.0259040371, 0.7827717662, -0.8086757660]])
P3_TO_XYZ = np.array([[0.4865709, 0.2656677, 0.1982173],
                      [0.2289746, 0.6917385, 0.0792869],
                      [0.0000000, 0.0451134, 1.0439444]])
PROPHOTO_TO_XYZ_D50 = np.array([[0.7976749, 0.1351917, 0.0313534],
                                [0.2880402, 0.7118741, 0.0000857],
                                [0.0, 0.0, 0.8252100]])
BRADFORD_D50_D65 = np.array([[0.9555766, -0.0230393, 0.0631636],
                             [-0.0282895, 1.0099416, 0.0210077],
                             [0.0122982, -0.0204830, 1.3299098]])
XYZ65_TO_PROPHOTO = np.linalg.inv(PROPHOTO_TO_XYZ_D50) @ np.linalg.inv(BRADFORD_D50_D65)


def oklab_to_prophoto(lab: np.ndarray) -> np.ndarray:
    lms = (lab @ np.linalg.inv(M2).T) ** 3
    return lms @ np.linalg.inv(M1).T @ XYZ65_TO_PROPHOTO.T


def out_to_oklab(rgba16: np.ndarray) -> np.ndarray:
    v = rgba16[..., :3].astype(np.float64) / 65535.0
    lin = np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)
    return np.cbrt(np.maximum(lin @ P3_TO_XYZ.T @ M1.T, 0.0)) @ M2.T


def lch(lab):
    return lab[..., 0], np.hypot(lab[..., 1], lab[..., 2]), np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360.0


def dh(a, b):
    return (a - b + 180.0) % 360.0 - 180.0


class Env:
    """Environment switches the pipeline reads when it is built, for the length of one render."""
    def __init__(self, **kv): self.kv = kv
    def __enter__(self):
        self.saved = {k: os.environ.get(k) for k in self.kv}
        for k, v in self.kv.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v
    def __exit__(self, *exc):
        for k, v in self.saved.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v


def render(engine, image, delta, tier="full", **env):
    with Env(**env):
        s = engine.open(image, dict(BASE, **delta))
        try:
            rgba, _ = s.render(tier)
        finally:
            s.close()
    return rgba


ON = {"SPK_NEGATIVE_HUE": None, "SPK_PRINT_UNFUSED": None}
OFF = {"SPK_NEGATIVE_HUE": "0", "SPK_PRINT_UNFUSED": None}


def chart():
    Ls, Cs, Hs = [0.45, 0.57, 0.70, 0.82], [0.06, 0.10, 0.14, 0.18], list(range(0, 360, 15))
    labs = np.array([[L, C * np.cos(np.radians(h)), C * np.sin(np.radians(h))] for L in Ls for C in Cs for h in Hs])
    rgb = oklab_to_prophoto(labs)
    rows, cols = len(Ls) * len(Cs), len(Hs)
    img = np.ones((rows * PATCH, cols * PATCH, 4), np.float32)
    img[..., :3] = np.repeat(np.repeat(rgb.reshape(rows, cols, 3), PATCH, 0), PATCH, 1)
    return img, labs, (rgb > 0).all(1), rows, cols


def patches(rgba16, rows, cols):
    lab = out_to_oklab(rgba16)
    return lab.reshape(rows, PATCH, cols, PATCH, 3)[:, 10:22, :, 10:22, :].mean(axis=(1, 3)).reshape(-1, 3)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dylib", default=None)
    ap.add_argument("--pairs", default="default", help="'default' (five pairs) or 'all' (every colour negative on every paper)")
    ap.add_argument("--json", default=None)
    args = ap.parse_args()
    engine = spk.Engine(library=args.dylib) if args.dylib else spk.Engine()
    print(engine.build_info)
    failures: list[str] = []
    report: dict = {"build": engine.build_info, "pairs": {}}

    def check(ok: bool, what: str):
        print(("  ok    " if ok else "  FAIL  ") + what)
        if not ok: failures.append(what)

    img, labs, usable, rows, cols = chart()
    _, _, h_in = lch(labs)
    pairs = PAIRS if args.pairs == "default" else [(f, p) for f in ALL_FILMS for p in ALL_PAPERS]
    catalogued = {("kodak_portra_400", "kodak_portra_endura")}   # the table's pair: not this node's
    print(f"hue and lightness, {len(pairs)} pair(s), {int(usable.sum())} patches")
    worst_on, best_off = 0.0, 1e9
    for film, paper in pairs:
        if (film, paper) in catalogued: continue
        d = {"film_stock": film, "print_stock": paper}
        on = patches(render(engine, img, d, **ON), rows, cols)
        off = patches(render(engine, img, d, **OFF), rows, cols)
        L_on, C_on, hue_on = lch(on); L_off, C_off, hue_off = lch(off)
        sel = usable & (C_off > 0.02)
        e_on = float(np.abs(dh(hue_on, h_in))[sel].mean()); e_off = float(np.abs(dh(hue_off, h_in))[sel].mean())
        dL = float(np.abs(L_on - L_off)[usable].max())
        worst_on, best_off = max(worst_on, e_on), min(best_off, e_off)
        report["pairs"][f"{film}|{paper}"] = {"hue_on": e_on, "hue_off": e_off, "dL": dL}
        line = f"{film} -> {paper}: hue {e_on:.2f} deg (optical {e_off:.2f}), |dL| {dL:.4f}"
        if args.pairs == "default" or e_on > HUE_MEAN_MAX or dL > LIGHTNESS_MAX:
            check(e_on <= HUE_MEAN_MAX and dL <= LIGHTNESS_MAX, line)
        elif e_on > HUE_MEAN_MAX or dL > LIGHTNESS_MAX:
            failures.append(line)
    check(worst_on <= HUE_MEAN_MAX, f"every pair's mean hue error is within {HUE_MEAN_MAX} deg (worst {worst_on:.2f})")
    check(best_off >= HUE_OFF_MIN, f"the chart shows the fault with the node off on every pair (best {best_off:.2f} deg, needs >= {HUE_OFF_MIN})")

    print("neutral: a grey ramp is the optical print to the bit")
    evs = np.arange(-7.0, 7.01, 0.5)
    ramp = np.ones((PATCH, len(evs) * PATCH, 4), np.float32)
    for j, ev in enumerate(evs): ramp[:, j * PATCH:(j + 1) * PATCH, :3] = 0.184 * 2.0 ** ev
    for film, paper in PAIRS[:3]:
        d = {"film_stock": film, "print_stock": paper}
        check(np.array_equal(render(engine, ramp, d, **ON), render(engine, ramp, d, **OFF)), f"{film} -> {paper}: 29 greys, -7..+7 EV")

    print("continuity: chroma 0 -> 0.2 through the take-over, four hues")
    n = 512
    for hue in (30.0, 130.0, 250.0, 300.0):
        c = np.linspace(0.0, 0.2, n)
        lab = np.stack([np.full(n, 0.57), c * np.cos(np.radians(hue)), c * np.sin(np.radians(hue))], 1)
        strip = np.ones((8, n, 4), np.float32); strip[..., :3] = oklab_to_prophoto(lab)[None]
        d = {"film_stock": "kodak_gold_200", "print_stock": "kodak_supra_endura"}
        on = out_to_oklab(render(engine, strip, d, **ON))[4]; off = out_to_oklab(render(engine, strip, d, **OFF))[4]
        step_on = float(np.abs(np.diff(on, axis=0)).max()); step_off = float(np.abs(np.diff(off, axis=0)).max())
        check(step_on <= 3.0 * step_off + 1e-4, f"hue {hue:.0f}: largest step {step_on:.5f} (optical {step_off:.5f})")

    print("one print: fused == node by node")
    small = img[:8 * PATCH, :12 * PATCH]
    for d, tag in (({"film_stock": "kodak_gold_200"}, "hue on"), ({"film_stock": "kodak_gold_200", "y_filter_shift": 0.4, "print_exposure": 1.2}, "hue on, filters"),
                   ({"film_stock": "kodak_gold_200", "grain_active": True, "grain_seed": 3, "halation_active": True}, "hue on, grain and halation")):
        check(np.array_equal(render(engine, small, d, **ON), render(engine, small, d, SPK_NEGATIVE_HUE=None, SPK_PRINT_UNFUSED="1")), tag)
    check(np.array_equal(render(engine, small, {}, **OFF), render(engine, small, {}, SPK_NEGATIVE_HUE="0", SPK_PRINT_UNFUSED="1")), "hue off")

    print("not mine: the same bits with the node on and off")
    for d, tag in (({"film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura"}, "the catalogued pair (its table)"),
                   ({"scan_film": True}, "a scanned negative"),
                   ({"film_stock": "fujifilm_provia_100f", "scan_film": True}, "a slide"),
                   ({"digital_intermediate": True}, "the Digital Intermediate")):
        try:
            check(np.array_equal(render(engine, small, d, **ON), render(engine, small, d, **OFF)), tag)
        except spk.EngineError as exc:
            check(False, f"{tag}: {exc}")

    report["failures"] = failures
    if args.json: Path(args.json).write_text(json.dumps(report, indent=1))
    print(f"\n{len(failures)} failure(s)" if failures else "\nall checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
