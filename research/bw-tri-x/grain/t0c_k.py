import numpy as np
from glib import *
import glib, standin
base, prof = standin.build(3.0)
with Engine(resources=RES) as e:
    for K in (0.5, 0.25, 0.1):
        glib.PROBE_K = K
        p = make_probe(base, 1, name=f"lin_k{int(K*100)}")
        W = white_of(e, p)
        lv = [0.01, 0.1, 1, 10, 100, 1e4]
        o = [render_lin(e, p, l, 64, 100.0, grain_active=False)[..., 1].mean() for l in lv]
        print(K, "W", W, " ".join("%.4f" % (-np.log10(x / W) / K) for x in o), " raw", " ".join("%.5f" % x for x in o))
