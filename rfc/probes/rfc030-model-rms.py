"""RMS granularity the engine's grain model implies, per film and channel.

Formulas are grain_realise (pipeline.cpp) + layer_draw (spk_common.h):
  X ~ Poisson(n p / sat), value = X * (dmax/n) * sat, p = d/dmax, sat = 1 - p u
  => mean d, variance d * (dmax/n) * (1 - u d/dmax),  n = px^2 * frac / area
Variance through an aperture A is the per-pixel variance * px^2 / A (white field;
the 0.65 px grain blur is far below a 48 um aperture at any export tier).
"""
import json, glob, os
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
import numpy as np
AREA, SCALE, LAYERS = 0.2, (1.6, 1.6, 3.2), (2.0, 1.0, 0.5)
DMIN, UNI = (0.03,) * 3, (0.97, 0.99, 0.97)
A = np.pi * 24.0 ** 2            # 48 um circular aperture, um^2

def film(path, target=1.0):
    p = json.load(open(path)); d = p["data"]
    if p["info"]["stage"] != "filming": return None
    cur = np.array(d["density_curves"], float)            # (K,3)
    lay = np.array(d["density_curves_layers"], float)     # (K,sl,ch)
    out = []
    for ch in range(3):
        dmaxl = np.nanmax(lay[:, :, ch], axis=0)
        frac = dmaxl / dmaxl.sum()
        dminl = frac * DMIN[ch]; dmaxl = dmaxl + dminl
        c = cur[:, ch]; ok = ~np.isnan(c)
        net = c - np.nanmin(c)
        k = int(np.nanargmin(np.abs(net - target)))
        var = 0.0
        for sl in range(3):
            a = AREA * SCALE[ch] * LAYERS[sl]
            dd = lay[k, sl, ch] + dminl[sl]
            var += dd * (dmaxl[sl] * a / frac[sl]) * (1 - UNI[ch] * dd / dmaxl[sl])
        out.append((1000 * np.sqrt(var / A), net[k], np.nanmax(net), lay[k, :, ch].sum() - c[k]))
    return p["info"]["type"], out

print(f"{'film':28s} {'type':9s}  RMS x1000 at net D=1.0 (R G B)   Dmax(net)        layer-sum err")
for f in sorted(glob.glob(str(ROOT / "engine/resources/profiles/*.json"))):
    r = film(f)
    if not r: continue
    t, o = r
    print(f"{os.path.basename(f)[:-5]:28s} {t:9s}  " + " ".join(f"{x[0]:5.1f}" for x in o)
          + "      " + " ".join(f"{x[2]:4.2f}" for x in o) + "   " + " ".join(f"{x[3]:+.3f}" for x in o))

# Monte Carlo of layer_draw to check the variance formula
rng = np.random.default_rng(0)
dmax, n, u, dd = 2.5, 40.0, 0.97, 1.0
p_ = dd / dmax; sat = 1 - p_ * u
x = rng.poisson(n / sat * p_, 2_000_000) * (dmax / n * sat)
print("MC mean %.4f var %.5f | formula var %.5f" % (x.mean(), x.var(), dd * dmax / n * (1 - u * dd / dmax)))
