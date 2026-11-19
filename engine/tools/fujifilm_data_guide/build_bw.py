#!/usr/bin/env python3
"""Black-and-white film profiles from digitise_bw.py's curves, in the form of the product's Tri-X 400,
T-Max 100, HP5 Plus and Neopan 100 Acros II profiles (their `metadata.tags` are the method):

    PYTHONPATH=<spektrafilm 0.3.x>/src:<this dir> python build_bw.py RAW_BW SHEETS.json OUT_DIR [stock ...]

  log_sensitivity  the sheet's curve on 380-780 nm (5 nm), held below its first point, a log-linear tail
                   above its last (the slope of its last 10 nm, at most -0.02 dex/nm); one curve written into
                   all three channels; scaled so an sRGB 18 % grey under D55 gives raw exposure 1 (hanatos2025
                   upsampling, as the engine does).
  density_curves   the sheet's curve less its own base+fog (its floor), on log exposure -3..4 (256 points):
                   flat toe below the plotted range, a straight line at the curve's last slope above it into a
                   ceiling of gross D 3.0 (or the highest density the sheet plots, if higher).
                   Several development times on one chart: the time the spec names is interpolated between the
                   two plotted times around it (linear in time at each log exposure).
  log exposure 0   absolute axes (lux-s): log10(0.8 / ISO) + 1.0. Relative axes (HARMAN): one log unit above
                   the curve's own speed point (D = base+fog + 0.1), i.e. the film is taken to have exactly its
                   rated speed.
  layers           three normal CDFs fitted to the curve; each layer is its CDF's share of the curve (the
                   layers add up to the curve exactly).
  base, midscale   base+fog flat at every wavelength; midscale neutral = base + density at log exposure 0.
  channel density  neutral silver, 1/3 per channel (XP2 Super's dye image is taken as neutral: no spectrum).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import scipy.optimize
from scipy.stats import norm

WL = np.arange(380.0, 781.0, 5.0)
LE = np.linspace(-3.0, 4.0, 256)


def L(p):
    a = np.loadtxt(p, delimiter=",")
    return a[np.argsort(a[:, 0])]


def sensitivity(curve):
    w, y = curve[:, 0], curve[:, 1]
    out = np.interp(WL, w, y)
    hi = w.max()
    tail = w >= hi - 10.0
    s = np.polyfit(w[tail], y[tail], 1)[0] if tail.sum() >= 3 else (y[-1] - y[-2]) / (w[-1] - w[-2])
    s = min(float(s), -0.02)
    up = WL > hi
    out[up] = y[-1] + s * (WL[up] - hi)
    return out, s, float(w.min()), float(hi)


def grey_scale(ls):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import scipy.interpolate
    from spektrafilm.utils import spectral_upsampling as su
    lut = su.HANATOS2025_SPECTRA_LUT
    v = np.linspace(0, 1, lut.shape[0])
    it = scipy.interpolate.RegularGridInterpolator((v, v), lut)
    tc, b = su._rgb_to_tc_b(np.array([0.184] * 3), color_space="sRGB", apply_cctf_decoding=False, reference_illuminant="D55")
    spec = it(tc[None, :])[0] * b
    return float(spec @ 10 ** ls)


def char_curve(raw, spec):
    c = spec["char"]
    if (raw / "density_curve.csv").exists():
        return L(raw / "density_curve.csv"), "the one curve the sheet plots"
    times = sorted(c["times"])
    t = float(c["use_time"])
    k = int(np.searchsorted(times, t))
    k = min(max(k, 1), len(times) - 1)
    t0, t1 = times[k - 1], times[k]
    a, b = L(raw / f"density_curve_{t0}.csv"), L(raw / f"density_curve_{t1}.csv")
    x = np.linspace(max(a[0, 0], b[0, 0]), min(a[-1, 0], b[-1, 0]), 400)
    f = (t - t0) / (t1 - t0)
    y = (1 - f) * np.interp(x, a[:, 0], a[:, 1]) + f * np.interp(x, b[:, 0], b[:, 1])
    return np.column_stack([x, y]), f"{t:g} min, interpolated between the plotted {t0:g} and {t1:g} min curves"


def time_for_ci(raw, ci):
    a = L(raw / "contrast_index.csv")       # (time, CI)
    return float(np.interp(ci, a[:, 1], a[:, 0]))


def build(stock, raw: Path, spec: dict):
    sheet = json.loads((raw / "sheet.json").read_text())
    sc = L(raw / "log_sensitivity.csv")
    if spec.get("divide_blackbody"):
        # a spectrogram to a black body (FUJIFILM's "to Daylight (5400K)"): the source divided out, as Acros II
        T = float(spec["divide_blackbody"])
        bb = lambda w: 1.0 / (w * 1e-9) ** 5 / (np.exp(1.4388e-2 / (w * 1e-9 * T)) - 1)
        sc = np.column_stack([sc[:, 0], sc[:, 1] - np.log10(bb(sc[:, 0]) / bb(560.0))])
    ls_raw, slope, w0, w1 = sensitivity(sc)
    ls = ls_raw - np.log10(grey_scale(ls_raw))
    assert abs(grey_scale(ls) - 1) < 1e-9
    c = spec["char"]
    if "ci" in spec and "use_ci" in c:
        c["use_time"] = round(time_for_ci(raw, c["use_ci"]), 2)
    curve, which = char_curve(raw, spec)
    x, d = curve[:, 0], curve[:, 1]
    bf = float(d[: max(3, len(d) // 20)].min())
    net = d - bf
    if spec.get("relative_axis"):
        i = np.argmax(net >= 0.1)
        x01 = float(np.interp(0.1, net[max(i - 1, 0):i + 1], x[max(i - 1, 0):i + 1]))
        origin = x01 + 1.0
        anchor = (f"ASSUMED: the sheet's exposure axis is relative. 0 = one log unit above the curve's own D = base+fog + 0.1 "
                  f"point, i.e. the film is taken to have exactly its rated speed (ISO {spec['iso']}: "
                  f"log10(0.8/{spec['iso']})+1.0 = {np.log10(0.8 / spec['iso']) + 1:.3f} log lux-s)")
    else:
        origin = float(np.log10(0.8 / spec["iso"]) + 1.0)
        anchor = f"SHEET ISO {spec['iso']} + LIT: 0 = log10(0.8/{spec['iso']})+1.0 = {origin:.3f} log lux-s"
    xr = x - origin
    top = x[-1]
    hi = xr >= xr[-1] - 0.3
    s_hi = float(np.polyfit(xr[hi], net[hi], 1)[0])
    s_hi = max(s_hi, 0.0)
    ceiling = max(3.0, float(d.max()))
    out = np.interp(LE, xr, net)
    up = LE > xr[-1]
    out[up] = np.minimum(net[-1] + s_hi * (LE[up] - xr[-1]), ceiling - bf)
    out[LE < xr[0]] = net[0]
    out = np.maximum.accumulate(np.maximum(out, 0.0))

    def model(p):
        a, cc, s = p[0:3], p[3:6], p[6:9]
        return np.array([a[i] * norm.cdf((LE - cc[i]) / s[i]) for i in range(3)])

    p0 = np.r_[[out[-1] * 0.2, out[-1] * 0.4, out[-1] * 0.4], [-0.5, 0.6, 2.6], [0.45, 0.8, 1.2]]
    lo = np.r_[[0] * 3, [-4] * 3, [0.05] * 3]
    hi_b = np.r_[[5] * 3, [6] * 3, [3] * 3]
    # several starts (a sharp toe, Pan F Plus, needs a narrow first layer)
    best = None
    for c0 in ([-0.5, 0.6, 2.6], [-1.0, 0.0, 1.5], [-0.2, 0.8, 2.0], [-1.5, -0.5, 1.0], [0.0, 1.0, 3.0]):
        for s0 in ([0.45, 0.8, 1.2], [0.2, 0.5, 1.0], [0.3, 0.6, 0.9]):
            q = np.r_[p0[:3], c0, s0]
            rr = scipy.optimize.least_squares(lambda p: model(p).sum(0) - out, q, bounds=(lo, hi_b))
            if best is None or np.abs(rr.fun).max() < np.abs(best.fun).max():
                best = rr
    r = best
    comp = model(r.x)
    fit_err = float(np.abs(comp.sum(0) - out).max())
    share = comp / np.maximum(comp.sum(0), 1e-12)
    layers = share * out[None, :]
    layers[:, out <= 0] = 0
    mid = bf + float(np.interp(0.0, LE, out))
    tri = lambda v: [[float(t)] * 3 for t in v]
    order = np.argsort(r.x[3:6])
    a, cc, s = r.x[0:3][order], r.x[3:6][order], r.x[6:9][order]
    layers = layers[order]
    data = {
        "wavelengths": WL.tolist(),
        "log_sensitivity": tri(ls),
        "channel_density": [[1 / 3] * 3 for _ in WL],
        "base_density": [bf] * len(WL),
        "midscale_neutral_density": [mid] * len(WL),
        "log_exposure": LE.tolist(),
        "density_curves": tri(out),
        "density_curves_layers": [[[float(layers[j, i])] * 3 for j in range(3)] for i in range(len(LE))],
        "density_curves_model": {"model_type": "cdfs", "centers": [cc.tolist()] * 3, "amplitudes": [a.tolist()] * 3,
                                 "sigmas": [s.tolist()] * 3},
    }
    gamma = float(np.polyfit(xr[(net > 0.3) & (net < 1.5)], net[(net > 0.3) & (net < 1.5)], 1)[0]) if ((net > 0.3) & (net < 1.5)).sum() > 3 else float("nan")
    src = spec["source"]
    tags = {
        "log_sensitivity": (f"SHEET {w0:.0f}-{w1:.0f} nm: {spec['sens_note']}; ASSUMED held below {w0:.0f} nm, "
                            f"ASSUMED log-linear tail {slope:.4f} dex/nm above {w1:.0f} nm; scale MEASURED so grey 0.184 -> raw 1"),
        "density_curves": (f"SHEET for log_exposure {xr[0]:.2f}..{xr[-1]:.2f} ({spec['dev_note']}: {which}; slope 0.3-1.5 over "
                           f"base+fog {gamma:.3f}); ASSUMED flat toe below, ASSUMED straight line slope {s_hi:.3f} into a "
                           f"ceiling of gross D {ceiling:.1f} above"),
        "log_exposure_anchor": anchor,
        "base_density": f"SHEET level {bf:.3f} (base+fog), ASSUMED spectrally flat",
        "channel_density": spec.get("channel_note", "ASSUMED: neutral silver, 1/3 per channel at every wavelength"),
        "hanatos2025_adaptation": "omitted on purpose (no fitted window/surface)",
        "density_curves_layers": f"ASSUMED: three-CDF fit of the curve (max fit error {fit_err:.4f} D), no sheet data on emulsion sub-layers",
    }
    doc = {
        "metadata": {
            "version": "research-2026-11-19", "created": "2026-11-19",
            "datasource": src,
            "tags": tags,
            "digitisation": {"sens_axes": sheet["sens_axes"], "char_axes": sheet["char_axes"]},
            "builder": "engine/tools/fujifilm_data_guide/digitise_bw.py + build_bw.py",
            "copyright": "SpektraLab product data. Not a spektrafilm profile; no array is derived from one.",
            "license": f"Built from {spec['publisher_short']}. See engine/resources_product/NOTICE.md.",
        },
        "info": {
            "stock": stock, "name": spec["name"], "type": "negative", "support": "film", "stage": "filming",
            "use": spec.get("use", "still"), "antihalation": spec.get("antihalation", "weak"),
            "target_print": "ilford_multigrade_iv_rc", "channel_model": "bw", "densitometer": "diffuse_visual",
            "log_sensitivity_density_over_min": spec.get("sens_density", 0.3), "reference_illuminant": "D55",
            "viewing_illuminant": "D50",
        },
        "data": data,
    }
    return doc, {"stock": stock, "bf": round(bf, 3), "mid": round(mid, 3), "slope_tail": round(slope, 4),
                 "gamma": round(gamma, 3), "fit_err": round(fit_err, 4), "le_range": [round(xr[0], 2), round(xr[-1], 2)],
                 "use_time": c.get("use_time")}


def main():
    raw, specs, out = Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text()), Path(sys.argv[3])
    want = set(sys.argv[4:])
    out.mkdir(parents=True, exist_ok=True)
    for s in specs:
        if want and s["stock"] not in want:
            continue
        doc, log = build(s["stock"], raw / s["stock"], s)
        (out / f"{s['stock']}.json").write_text(json.dumps(doc, indent=1))
        print(json.dumps(log))


if __name__ == "__main__":
    main()
