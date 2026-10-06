"""The analytic model (research/rms-granularity.md), extended with the node's 0.65 px blur and
the exact circular aperture, so it can be compared with a render number for number."""
import numpy as np
from scipy.signal import fftconvolve
from glib import disc_kernel, A48

AREA, SCALE, LAYERS = 0.2, (1.6, 1.6, 3.2), (2.0, 1.0, 0.5)
DMIN, UNI, BLUR = 0.03, (0.97, 0.99, 0.97), 0.65


def gauss2(s):
    r = int(np.ceil(4 * s)) + 1
    x = np.arange(-r, r + 1)
    g = np.exp(-x ** 2 / (2 * s * s)); g /= g.sum()
    return np.outer(g, g)


def kernel_gain(px_um, diam_um=48.0, blur=BLUR):
    """(per-pixel sigma factor after the node's blur, aperture sigma factor) for unit white noise."""
    g = gauss2(blur) if blur > 0 else np.ones((1, 1))
    k = fftconvolve(disc_kernel(diam_um / px_um), g)
    return float(np.sqrt((g ** 2).sum())), float(np.sqrt((k ** 2).sum()))


def var_sublayers(prof, ch, d_net, px_um, area=AREA):
    """White per-pixel variance on the sub-layer path at net density d_net in channel ch."""
    D = prof["data"]
    cur = np.array(D["density_curves"], float)[:, ch]
    lay = np.array(D["density_curves_layers"], float)[:, :, ch]
    net = cur - np.nanmin(cur)
    order = np.argsort(net)
    x = np.interp(d_net, net[order], np.arange(len(net))[order])
    dl = np.array([np.interp(x, np.arange(len(net)), lay[:, sl]) for sl in range(3)])
    dmaxl = np.nanmax(lay, axis=0)
    frac = dmaxl / dmaxl.sum()
    dminl = frac * DMIN
    dmaxl = dmaxl + dminl
    v = 0.0
    for sl in range(3):
        n = px_um ** 2 * frac[sl] / (area * SCALE[ch] * LAYERS[sl])
        dd = dl[sl] + dminl[sl]
        v += dd * (dmaxl[sl] / n) * (1 - UNI[ch] * dd / dmaxl[sl])
    return v


def var_simple(dmax_net, ch, d_net, px_um, area=AREA, uni=None):
    """White per-pixel variance on the single-layer path (grain_sublayers_active = false)."""
    u = UNI[ch] if uni is None else uni
    n = px_um ** 2 / (area * SCALE[ch])
    dd, dm = d_net + DMIN, dmax_net + DMIN
    return dd * (dm / n) * (1 - u * dd / dm)


def rms_from_var(v, px_um):
    """Selwyn: x1000 sigma through 48 um, ignoring the blur (the old analytic number)."""
    return 1000 * np.sqrt(v * px_um ** 2 / A48)
