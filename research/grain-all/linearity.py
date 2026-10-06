"""Is RMS linear in grain_amount over the wire range 0..2, and what else does grain_amount change?

  A. flat patch (G record at net D 1.0, and the visual net-1.0 patch), 6 um, both grain paths,
     nine amounts: RMS48 against amount, slope through the origin, worst deviation, mean density.
  B. image detail: node_grain is  out = in + k (grained - in)  and `grained` carries the node's
     0.65 px blur of the PICTURE, so k also scales that blur: detail MTF = 1 - k (1 - G(f)).
     Measured on vertical stripes (period 2, 3, 4, 8 px) in density, amplitude relative to amount 0.

    python linearity.py   -> linearity.json   (needs engine_rms.json from measure_all.py)
"""
import json
import numpy as np
from galib import *

STOCKS = ["kodak_portra_400", "fujifilm_provia_100f", "kodak_tri_x_400"]
AMOUNTS = [0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.71, 2.0]
PX, N = 6.0, 2048
ref = json.load(open(HERE / "engine_rms.json"))
build_res()
out = {}
with Engine(dylib=DYLIB, resources=RES) as e:
    for s in STOCKS:
        probes = [f"probe_{s}_{c}" for c in range(3)]
        vis = Visual(load(s))
        lg, lv = ref[s]["channels"]["G"]["level"], ref[s]["visual"]["net_1.0"]["level"]
        out[s] = {}
        for sub in (True, False):
            rows = []
            for k in AMOUNTS:
                d = density(e, probes[1], lg, N, PX, grain_sublayers_active=sub, grain_amount=k)
                f = np.stack([density(e, p, lv, N, PX, grain_sublayers_active=sub, grain_amount=k) for p in probes], -1)
                dv = -np.log10(aperture_mean(vis.transmittance(f), PX))
                rows.append(dict(amount=k, G_rms48=1000 * aperture_sigma(d, PX), G_mean=float(d.mean()),
                                 visual_rms48=1000 * float(dv.std()), visual_mean_net=float(dv.mean() - vis.dv_min)))
            a = np.array(AMOUNTS)
            res = dict(rows=rows)
            for q in ("G_rms48", "visual_rms48"):
                y = np.array([r[q] for r in rows])
                slope = float((a * y).sum() / (a * a).sum())
                res[q + "_slope"] = slope
                res[q + "_at_1"] = float(y[4])
                res[q + "_worst_rel_dev_from_k_times_value_at_1"] = float(np.max(np.abs(y[1:] / (a[1:] * y[4]) - 1)))
            out[s]["sub" if sub else "single"] = res
            print(s, "sub" if sub else "single", {k: round(v, 4) for k, v in res.items() if k != "rows"},
                  "means", [round(r["G_mean"], 4) for r in rows], flush=True)

    # ---- B: detail
    s = "kodak_portra_400"
    probe = f"probe_{s}_1"
    lo, hi = ref[s]["channels"]["G"]["level"] * 0.5, ref[s]["channels"]["G"]["level"] * 2.0
    n = 1536
    det = []
    for period in (2, 3, 4, 8):
        x = np.arange(n)
        carrier = np.cos(2 * np.pi * x / period)
        frame = np.empty((n, n, 3), np.float32)
        frame[:] = (np.exp(0.5 * (np.log(lo) + np.log(hi)) + 0.5 * (np.log(hi) - np.log(lo)) * carrier))[None, :, None]
        amp = {}
        for k in (0.0, 0.5, 1.0, 1.71, 2.0):
            d = to_density(render_lin(e, probe, frame, PX, grain_amount=k), crop=0)
            c = carrier[None, :] * np.ones((n, 1))
            m = slice(48, n - 48)                      # whole periods of 2,3,4,8 (1440 px)
            amp[k] = float((d[m, m] * c[m, m]).mean() / (c[m, m] ** 2).mean())
        G = float(np.exp(-2 * np.pi ** 2 * BLUR ** 2 / period ** 2))
        row = dict(period_px=period, amplitude_at_0=amp[0.0],
                   measured_ratio={str(k): amp[k] / amp[0.0] for k in amp},
                   predicted_ratio={str(k): 1 - k * (1 - G) for k in amp})
        det.append(row)
        print("detail period", period, "A0 %.4f" % amp[0.0],
              " ".join(f"k={k}: {amp[k] / amp[0.0]:+.3f} (pred {1 - k * (1 - G):+.3f})" for k in amp), flush=True)
    out["detail_mtf_portra_400_G_sublayers"] = det
json.dump(out, open(HERE / "linearity.json", "w"), indent=1)
