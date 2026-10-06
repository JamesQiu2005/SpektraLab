"""Sanity: probe works, white level, grain-off flatness, seed repeatability across sessions."""
import numpy as np
from glib import *

names = [make_probe("kodak_portra_400", c) for c in range(3)]
with Engine(resources=RES) as e:
    print(e.build_info)
    W = [white_of(e, n) for n in names]
    print("white", W, "expected", 10 ** -PROBE_BASE)
    for lvl in (0.0, 0.05, 0.184, 0.5, 2.0):
        row = []
        for c, n in enumerate(names):
            o = render_lin(e, n, lvl, 128, 50.0, grain_active=False)
            row.append((-np.log10(o[..., 1].mean() / W[c]) / PROBE_K, o[..., 1].std(), np.ptp(o.mean((0, 1)))))
        print(lvl, " ".join("d=%.4f sd=%.1e rgbspread=%.1e" % r for r in row))
    a = density(e, names[1], 0.184, 1024, 6.0, W[1])
    b = density(e, names[1], 0.184, 1024, 6.0, W[1])
    print("grain on: mean %.4f sd %.4f | second session same realisation? corr=%.4f" % (a.mean(), a.std(), np.corrcoef(a.ravel(), b.ravel())[0, 1]))
with Engine(resources=RES) as e:
    c = density(e, names[1], 0.184, 1024, 6.0, W[1])
    print("fresh ENGINE, first render: corr with first =%.4f" % np.corrcoef(a.ravel(), c.ravel())[0, 1])
