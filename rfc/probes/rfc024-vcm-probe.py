# rfc024-vcm-probe.py -- RFC-024: drive the engine with the virtual contrast
# mask through the C ABI, on one real frame, and check the gates §9.3 names.
#
# Analysis only; nothing in the build or the app runs it. Needs numpy (the
# fork's .venv), the worktree's dylib (`engine/build.sh dylib`), and a decoded
# frame:
#
#   swiftc -O rfc/probes/rfc023-decode-raw.swift -o $T/decode
#   $T/decode frame.NEF $T/scene.f32 2400                     # prints "W H"
#   python rfc/probes/rfc024-vcm-probe.py $T/scene.f32 W H OUTDIR [BASELINE_DYLIB]
#
# BASELINE_DYLIB is a build of the tree *before* RFC-024 (with its own
# ../resources beside it); the bypass gate compares against it byte for byte.
import json, math, os, sys, subprocess
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(HERE / "engine" / "tests"))
sys.path.insert(0, str(HERE / "rfc" / "probes"))
from spk_ctypes import Engine

import importlib.util
_spec = importlib.util.spec_from_file_location("slm", HERE / "rfc" / "probes" / "rfc023-slm-probe.py")
slm = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(slm)

# ProPhoto (D50) -> XYZ, and Lab under D50.
M = np.array([[0.7976749, 0.1351917, 0.0313534],
              [0.2880402, 0.7118741, 0.0000857],
              [0.0000000, 0.0000000, 0.8252100]])
WP = np.array([0.9642, 1.0, 0.8249])

def to_lab(rgba16):
    lin = slm.romm_decode(rgba16[:, :, :3].astype(np.float64) / 65535.0)
    xyz = lin @ M.T / WP
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(xyz), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    L = 116 * f[..., 1] - 16
    a = 500 * (f[..., 0] - f[..., 1])
    b = 200 * (f[..., 1] - f[..., 2])
    return np.stack([L, a, b], -1)

def blur(img, sigma):
    r = int(math.ceil(3 * sigma))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2); k /= k.sum()
    pad = np.pad(img, ((r, r), (r, r)), mode="reflect")
    tmp = np.apply_along_axis(lambda v: np.convolve(v, k, "valid"), 1, pad)
    return np.apply_along_axis(lambda v: np.convolve(v, k, "valid"), 0, tmp)

def texture(L, sigma=1.5):
    """Fine-scale modulation: |L - blur(L)|, a band-pass at a few pixels."""
    return np.abs(L - blur(L, sigma))

# The engine's result is ProPhoto RGB, gamma-1.8 encoded. A PNG carries no
# profile here, so every viewer reads it as sRGB -- writing the codes as they
# are (RFC-023's `result_to_rgb8`) shows a wrong tone and wrong colours. Convert
# properly: ROMM decode -> XYZ D50 -> Bradford D65 -> sRGB.
BRAD = np.array([[0.9555766, -0.0230393, 0.0631636], [-0.0282895, 1.0099416, 0.0210077],
                 [0.0122982, -0.0204830, 1.3299098]])
XYZ2SRGB = np.array([[3.2404542, -1.5371385, -0.4985314], [-0.9692660, 1.8760108, 0.0415560],
                     [0.0556434, -0.2040259, 1.0572252]])

def to_srgb8(rgba16):
    lin = slm.romm_decode(rgba16[:, :, :3].astype(np.float64) / 65535.0)
    s = np.clip(lin @ (XYZ2SRGB @ BRAD @ M).T, 0, 1)
    e = np.where(s <= 0.0031308, 12.92 * s, 1.055 * s ** (1 / 2.4) - 0.055)
    return (e * 255 + 0.5).astype(np.uint8)

def png(path, rgba16):
    slm.write_png(str(path), to_srgb8(rgba16))

BASE = {"auto_exposure": True, "grain_active": False}   # grain off: numbers, not realisations

def main():
    scene_path, w, h, outdir = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4])
    baseline = Path(sys.argv[5]) if len(sys.argv) > 5 else None
    outdir.mkdir(parents=True, exist_ok=True)
    scene = slm.load_scene(scene_path, w, h)
    report = {}

    eng = Engine()
    ses = eng.open(scene, BASE)
    straight, r0 = ses.render("full")

    # --- gate 1: exact bypass -----------------------------------------------
    if baseline:
        beng = Engine(dylib=baseline)
        bses = beng.open(scene, BASE)
        old, _ = bses.render("full")
        bses.close(); beng.close()
        report["bypass_vs_pre_rfc_build"] = bool(np.array_equal(old, straight))
    ses.set_params({"contrast_mask_active": True, "contrast_mask_highlights": 0.0,
                    "contrast_mask_shadows": 0.0})
    zero, _ = ses.render("full", reprint=True)
    report["bypass_active_zero_amounts"] = bool(np.array_equal(zero, straight))

    # --- the arms -----------------------------------------------------------
    def arm(delta, env=None):
        if env: os.environ.update(env)
        try:
            ses.set_params(delta)
            img, res = ses.render("full", reprint=True)
        finally:
            for k in (env or {}): os.environ.pop(k, None)
        return img, res

    amt = {"contrast_mask_active": True, "contrast_mask_highlights": 1.5,
           "contrast_mask_shadows": 1.5, "contrast_mask_core": 1.0}
    os.environ["SPEKTRAFILM_MASK_DUMP"] = str(outdir / "mask_guided.bin")
    # The guided base is research-only since 2026-09-24: `SPEKTRAFILM_MASK_GUIDED`.
    guided, rg = arm({**amt, "contrast_mask_scale": 0.03}, env={"SPEKTRAFILM_MASK_GUIDED": "1"})
    os.environ["SPEKTRAFILM_MASK_DUMP"] = str(outdir / "mask_gauss.bin")
    gauss, _ = arm({**amt, "contrast_mask_scale": 0.03})
    os.environ.pop("SPEKTRAFILM_MASK_DUMP")
    point, _ = arm(amt, env={"SPEKTRAFILM_MASK_POINTWISE": "1"})
    # the deliberately-too-much control: a wide Gaussian at full strength
    over, _ = arm({"contrast_mask_active": True, "contrast_mask_highlights": 3.0,
                   "contrast_mask_shadows": 3.0, "contrast_mask_core": 0.25,
                   "contrast_mask_scale": 0.12})
    report["negative_was_cached_on_mask_edit"] = bool(rg.negative_was_cached)

    # --- gate: striped == un-striped with the mask on ---------------------------
    os.environ["SPEKTRAFILM_MASK_GUIDED"] = "1"
    ses.set_params({**amt, "contrast_mask_scale": 0.03,
                    "striped": True, "strip_rows": 97})
    striped, _ = ses.render("full", reprint=True)
    ses.set_params({"striped": False, "strip_rows": 0})
    report["striped_equals_unstriped"] = bool(np.array_equal(striped, guided))
    report["striped_max_abs_diff"] = int(np.abs(striped.astype(int) - guided.astype(int)).max())

    # --- gate: live tier and full tier derive the same field -----------------
    live_masked, _ = ses.render("live", reprint=True)
    ses.set_params({"contrast_mask_active": False})
    live_straight, _ = ses.render("live", reprint=True)
    ses.close(); eng.close()

    # --- measurement ----------------------------------------------------------
    labs = {k: to_lab(v) for k, v in
            dict(straight=straight, guided=guided, gauss=gauss, point=point, over=over).items()}
    L0 = labs["straight"][..., 0]
    regions = {
        "print_highlights (L*>80)": L0 > 80,
        "print_shadows (L*<25)": L0 < 25,
        "midtones (40<L*<60)": (L0 > 40) & (L0 < 60),
    }
    tex = {k: texture(v[..., 0]) for k, v in labs.items()}
    rows = {}
    for name, m in regions.items():
        row = {"fraction": float(m.mean())}
        for k, lab in labs.items():
            C = np.hypot(lab[..., 1], lab[..., 2])
            row[k] = {"L_median": round(float(np.median(lab[..., 0][m])), 2),
                      "texture_mean": round(float(tex[k][m].mean()), 4),
                      "chroma_median": round(float(np.median(C[m])), 2)}
        rows[name] = row
    report["regions"] = rows
    # global: how much of the frame sits at the paper's ends
    for k, lab in labs.items():
        L = lab[..., 0]
        report.setdefault("ends", {})[k] = {"L>95": round(float((L > 95).mean()), 4),
                                            "L<8": round(float((L < 8).mean()), 4),
                                            "L_p1": round(float(np.percentile(L, 1)), 2),
                                            "L_p99": round(float(np.percentile(L, 99)), 2)}
    # halo / overshoot: along strong edges in the straight print, how far does
    # each arm's L* move away from straight in a ring *next to* the edge
    gy, gx = np.gradient(blur(L0, 1.0))
    edge = np.hypot(gx, gy) > 6.0
    ring = (blur(edge.astype(float), 6.0) > 0.02) & ~(blur(edge.astype(float), 1.0) > 0.02)
    for k, lab in labs.items():
        d = lab[..., 0] - L0
        report.setdefault("near_edge_ring_dL_p99_abs", {})[k] = round(float(np.percentile(np.abs(d[ring]), 99)), 2)
        report.setdefault("frame_dL_p99_abs", {})[k] = round(float(np.percentile(np.abs(d), 99)), 2)

    # tier consistency: live masked vs live straight change, against full
    Lls, Llm = to_lab(live_straight)[..., 0], to_lab(live_masked)[..., 0]
    report["live_tier_dL_median_in_highlights"] = round(float(np.median((Llm - Lls)[Lls > 80])), 2)
    report["full_tier_dL_median_in_highlights"] = round(float(np.median((labs['guided'][..., 0] - L0)[L0 > 80])), 2)
    report["live_tier_dL_median_in_shadows"] = round(float(np.median((Llm - Lls)[Lls < 25])), 2)
    report["full_tier_dL_median_in_shadows"] = round(float(np.median((labs['guided'][..., 0] - L0)[L0 < 25])), 2)

    for k, v in dict(straight=straight, guided=guided, gauss=gauss, point=point, over=over).items():
        png(outdir / f"{k}.png", v)
    # the mask field itself, as a picture: delta in stops, grey = 0
    for name in ("guided", "gauss"):
        raw = np.fromfile(outdir / f"mask_{name}.bin", dtype=np.uint8)
        gw, gh = np.frombuffer(raw[:8].tobytes(), dtype=np.uint32)
        planes = np.frombuffer(raw[8:].tobytes(), dtype=np.float32).reshape(3, gh, gw)
        d = planes[2]
        report.setdefault("delta_stops", {})[name] = {"min": round(float(d.min()), 3),
                                                      "max": round(float(d.max()), 3),
                                                      "frac_nonzero": round(float((d != 0).mean()), 3)}
        v = np.clip(128 + d * 60, 0, 255).astype(np.uint8)
        slm.write_png(str(outdir / f"delta_{name}.png"), np.repeat(v[..., None], 3, -1))
    json.dump(report, open(outdir / "report.json", "w"), indent=2)
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()
