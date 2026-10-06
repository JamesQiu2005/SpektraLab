"""Shared helpers: render a flat patch through the BUILT engine and recover the negative's
density field of one grain channel.

Method (no engine change, no tap needed):
  * a scratch copy of engine/resources (./res) gets PROBE profiles: the stock's curves, layers and
    sensitivities untouched (so the grain model sees exactly what it sees in the product), but
    `channel_density` replaced by a spectrally FLAT 0.5 in ONE channel and 0 in the others, and
    `base_density` a flat 0.1. With `scan_film` the scanner then outputs  W * 10^-(0.5 d_c)
    exactly (a flat spectrum has no colour maths), so d_c = -2 log10(out / W).
  * the scanner's unsharp mask (0.7 px, amount 0.7, not on the wire) is linear on that output and
    is removed exactly in the Fourier domain:  H(f) = 1 + a (1 - exp(-2 pi^2 s^2 f^2)).
  * the grain node's own 0.65 px blur is NOT removed: it is part of the model.
"""
import json, os, sys
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
REPO = Path("/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify")
RES = HERE / "res"
sys.path.insert(0, str(REPO / "engine/tests"))
from spk_ctypes import Engine  # noqa: E402

PROBE_K = 0.3      # scan density per unit film density
PROBE_BASE = 0.5   # keeps the scan below 0.32: the output stage compresses values above ~0.45 (t0b)
UNSHARP = (0.7, 0.7)
A48 = np.pi * 24.0 ** 2


def load(stock):
    return json.load(open(RES / "profiles" / f"{stock}.json"))


def save(name, prof):
    json.dump(prof, open(RES / "profiles" / f"{name}.json", "w"))


def make_probe(src, ch, name=None, mutate=None):
    """Probe profile reading channel `ch` (0,1,2) of stock `src`; or ch='sum' -> all three at K/3."""
    p = load(src) if isinstance(src, str) else json.loads(json.dumps(src))
    d = p["data"]
    n = len(d["wavelengths"])
    cd = np.zeros((n, 3))
    if ch == "sum":
        cd[:, :] = PROBE_K / 3.0
    else:
        cd[:, ch] = PROBE_K
    d["channel_density"] = cd.tolist()
    d["base_density"] = [PROBE_BASE] * n
    if mutate:
        mutate(p)
    name = name or f"probe_{p['info']['stock']}_{ch}"
    save(name, p)
    return name


BASE_DELTA = {
    "auto_exposure": False, "scan_film": True, "output_cctf_encoding": False,
    "halation_active": False, "dir_couplers_active": False, "glare_active": False,
    "scanner_white_correction": False, "scanner_black_correction": False,
    "scanner_lens_blur": 0.0, "lens_blur_um": 0.0, "extended_dynamic_range": False,
}


def render_lin(engine, stock, level, n, px_um, **extra):
    """Linear scanner output, (n, n) float64 (the three output channels are equal; G is taken)."""
    frame = np.full((n, n, 3), level, dtype=np.float32)
    delta = dict(BASE_DELTA, film_stock=stock, film_format_mm=px_um * n / 1000.0)
    delta.update(extra)
    with engine.open(frame, delta) as s:
        rgba, _ = s.render("full")
    out = rgba[..., :3].astype(np.float64) / 65535.0
    return out


def deunsharp(img):
    s, a = UNSHARP
    fy = np.fft.fftfreq(img.shape[0])[:, None]
    fx = np.fft.fftfreq(img.shape[1])[None, :]
    H = 1.0 + a * (1.0 - np.exp(-2 * np.pi ** 2 * s ** 2 * (fx ** 2 + fy ** 2)))
    return np.real(np.fft.ifft2(np.fft.fft2(img) / H))


def density(engine, stock, level, n, px_um, white, crop=16, **extra):
    """Film density (normalised = net of base+fog) of the probed channel, (n-2crop)^2."""
    out = render_lin(engine, stock, level, n, px_um, **extra)[..., 1]
    lin = deunsharp(out)
    lin = np.maximum(lin, 1e-6)
    d = -np.log10(lin / white) / PROBE_K
    return d[crop:-crop, crop:-crop]


def white_of(engine=None, stock=None, **_):
    """The scanner's output at film density 0. It is exactly 10^-PROBE_BASE (the scan is normalised
    to the illuminant): verified by t0b_linearity.py / t0c_k.py -- with this white the read-out
    reproduces the stand-in's own curve to 1e-4 and its Dmax at three probe gains. NOT a render of a
    black frame: level 0 renders 0.696 whatever the probe gain (a zero-exposure special case)."""
    return 10.0 ** -PROBE_BASE


def disc_kernel(diam_px, ss=15):
    """Area-weighted (anti-aliased) circular aperture, sums to 1."""
    r = diam_px / 2.0
    half = int(np.ceil(r)) + 1
    m = 2 * half + 1
    c = (np.arange(m * ss) + 0.5) / ss - m / 2.0
    yy, xx = np.meshgrid(c, c, indexing="ij")
    fine = (xx ** 2 + yy ** 2 <= r * r).astype(float)
    k = fine.reshape(m, ss, m, ss).mean(axis=(1, 3))
    return k / k.sum()


def aperture_sigma(d, px_um, diam_um=48.0):
    """sigma of the density read through a circular aperture (valid region only)."""
    from scipy.signal import fftconvolve
    k = disc_kernel(diam_um / px_um)
    f = fftconvolve(d - d.mean(), k, mode="valid")
    return float(f.std())


def nps_radial(d, px_um, nbins=48):
    """Radially averaged noise power spectrum W(f) in D^2 um^2, f in cycles/mm.
    Normalised so that W(0) = sigma_A^2 * A for a large aperture (Selwyn constant)."""
    x = d - d.mean()
    n0, n1 = x.shape
    P = np.abs(np.fft.fft2(x)) ** 2 / (n0 * n1) * px_um ** 2
    fy = np.fft.fftfreq(n0, px_um * 1e-3)[:, None]
    fx = np.fft.fftfreq(n1, px_um * 1e-3)[None, :]
    fr = np.hypot(fx, fy)
    fmax = 0.5 / (px_um * 1e-3)
    edges = np.linspace(0, fmax, nbins + 1)
    idx = np.digitize(fr.ravel(), edges) - 1
    ok = (idx >= 0) & (idx < nbins)
    num = np.bincount(idx[ok], P.ravel()[ok], nbins)
    cnt = np.bincount(idx[ok], minlength=nbins)
    return 0.5 * (edges[1:] + edges[:-1]), num / np.maximum(cnt, 1)
