"""MEASURED RMS granularity of kodak_portra_400 per channel at net D = 1.0 vs the analytic model,
plus the inter-channel correlation of the grain (same realisation read through three probes)."""
import json, sys
import numpy as np
from glib import *
import model as M

STOCK = sys.argv[1] if len(sys.argv) > 1 else "kodak_portra_400"
PX, N = 6.0, 1024
prof = load(STOCK)
names = [make_probe(STOCK, c) for c in range(3)]
res = {}
with Engine(resources=RES) as e:
    W = [white_of(e, n) for n in names]
    levels = np.geomspace(0.02, 40, 28)
    fields = {}
    for c, n in enumerate(names):
        dd = np.array([-np.log10(render_lin(e, n, l, 64, 100.0, grain_active=False)[..., 1].mean() / W[c]) / PROBE_K
                       for l in levels])
        lvl = float(np.exp(np.interp(1.0, dd, np.log(levels))))
        d0 = -np.log10(render_lin(e, n, lvl, 64, 100.0, grain_active=False)[..., 1].mean() / W[c]) / PROBE_K
        d = density(e, n, lvl, N, PX, W[c])
        sp = d.std(); sa = aperture_sigma(d, PX)
        v = M.var_sublayers(prof, c, d0, PX)
        gp, ga = M.kernel_gain(PX)
        res["RGB"[c]] = dict(level=lvl, d_grain_off=d0, d_mean=float(d.mean()),
                             sigma_px=float(sp), sigma_px_model=float(np.sqrt(v) * gp),
                             rms48=1000 * sa, rms48_model=1000 * float(np.sqrt(v) * ga),
                             rms48_selwyn_noblur=float(M.rms_from_var(v, PX)))
        print("RGB"[c], json.dumps(res["RGB"[c]]))
    # correlation: one level, three probes, same seed
    for lvl in (0.184, 1.0):
        f = [density(e, n, lvl, N, PX, W[c]) for c, n in enumerate(names)]
        x = np.stack([a.ravel() - a.mean() for a in f])
        cc = np.corrcoef(x)
        print("level", lvl, "mean d", [round(float(a.mean()), 3) for a in f], "corr RG RB GB: %.4f %.4f %.4f" % (cc[0, 1], cc[0, 2], cc[1, 2]),
              " (1 sigma of r for independent fields ~ %.4f after the blur)" % (1 / np.sqrt(x.shape[1] / (4 * np.pi * 0.65 ** 2))))
        res[f"corr_level_{lvl}"] = [float(cc[0, 1]), float(cc[0, 2]), float(cc[1, 2])]
json.dump(res, open(HERE / f"out_t1_{STOCK}.json", "w"), indent=1)
