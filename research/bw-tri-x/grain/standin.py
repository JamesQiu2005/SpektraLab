"""STAND-IN B&W negative profile (NOT Tri-X data): kodak_portra_400 with the three channels made
identical. Only what the grain node reads matters here: the curve's saturation Dmax and, on the
sub-layer path, how the density is split between three sub-layers.

ASSUMED curve: three normal CDFs in log exposure (centres -0.9 / 0.5 / 1.9, sigma 0.75), each a third
of Dmax -- a long straight line (gamma ~ Dmax/4.2 per decade) with no shoulder inside the pictorial range,
saturating at Dmax only at the top of the table. sl 0 is the fast component (the engine's
particle_scale_layers[0] = 2.0 is the fast layer's)."""
import json
import numpy as np
from scipy.special import ndtr
from glib import load, save

CENTRES, SIGMA = (-0.9, 0.5, 1.9), 0.75


def build(dmax, name=None, src="kodak_portra_400", split=(1 / 3, 1 / 3, 1 / 3)):
    p = load(src)
    d = p["data"]
    le = np.array(d["log_exposure"], float)
    lay = np.stack([dmax * split[i] * ndtr((le - CENTRES[i]) / SIGMA) for i in range(3)], axis=1)  # (K, sl)
    cur = lay.sum(axis=1)
    d["density_curves"] = np.repeat(cur[:, None], 3, axis=1).tolist()
    d["density_curves_layers"] = np.repeat(lay[:, :, None], 3, axis=2).tolist()   # [k][sl][ch]
    ls = np.array(d["log_sensitivity"], float)
    d["log_sensitivity"] = np.repeat(ls[:, 1:2], 3, axis=1).tolist()
    d.pop("density_curves_model", None)
    p["info"]["channel_model"] = "bw"
    p["info"]["name"] = f"STAND-IN bw Dmax {dmax}"
    name = name or f"bw_standin_{str(dmax).replace('.', 'p')}"
    save(name, p)
    return name, p
