"""Is the probe's read-out linear in film density? Ground truth = the stand-in's own curve."""
import numpy as np
from glib import *
import glib, standin
from scipy.special import ndtr
base, prof = standin.build(3.0)
p = make_probe(base, 1, name="lin_p1")
le = np.array(prof["data"]["log_exposure"]); cur = np.array(prof["data"]["density_curves"])[:, 1]
with Engine(resources=RES) as e:
    W = white_of(e, p)
    lv = np.r_[0.0, np.geomspace(1e-4, 1e5, 19)]
    d = np.array([-np.log10(render_lin(e, p, l, 64, 100.0, grain_active=False)[..., 1].mean() / W) / PROBE_K for l in lv])
    # the curve is known, the exposure scale is not: fit one log-exposure offset on the mid point, check the rest
    net = cur - cur.min()
    off = np.interp(d[11], net, le) - np.log10(lv[11])
    pred = np.interp(np.log10(np.maximum(lv, 1e-12)) + off, le, net)
    for a, b, c in zip(lv, d, pred): print("level %10.4g  d_meas %.4f  d_curve %.4f  diff %+.4f" % (a, b, c, b - c))
    print("offset", off)
