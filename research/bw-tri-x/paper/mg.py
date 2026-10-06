"""Shared model for the ILFORD MULTIGRADE IV RC feasibility profile.

Python replica of the engine's print exposure (engine/src/core/printing.cpp, spectral.cpp) -- used ONLY to
fit; every number in the report is re-measured on engine renders (measure_*.py).

Three emulsions in the three paper channels:  S_i(lambda) = B(lambda) + g_i * G(lambda)
  B = blue (native halide) part of the sheet's one sensitivity curve, shared by all three   [split ASSUMED]
  G = green (dye-sensitised) part; g_1 = 1, g_2, g_3 < 1 fitted                               [FITTED]
Each emulsion develops to neutral silver; its curve is A_i * shape(x), shape = sum of 3 normal cdfs.
"""
import os, json, numpy as np
from scipy.special import erf, ndtr
H = os.path.dirname(os.path.abspath(__file__))
WL = np.arange(380, 781, 5.0)
LAMP = np.genfromtxt(H + '/csv/illuminant_TH-KG3.csv', delimiter=',', skip_header=1)[:, 1]
GRADES = ['00', '0', '1', '2', '3', '4', '5']
SHEET_R = dict(zip(GRADES, [180, 160, 130, 110, 90, 60, 40]))
DMAX = 2.22                         # SHEET (raster): plateau 2.215 (left chart) / 2.230 (right chart)

def dichroics():
    """custom_dichroic_filters: columns C, M, Y"""
    y = erf((WL - 516.0) / 12.0)
    m = np.where(WL <= 550.0, -erf((WL - 500.0) / 8.0), erf((WL - 610.0) / 8.0))
    c = -erf((WL - 607.0) / 8.0)
    return np.stack([c, m, y], 1) / 2 + 0.5
DICH = dichroics()

def enlarger(cmy):
    t = 10.0 ** (-np.asarray(cmy, float) / 100.0)
    return LAMP * np.prod(1.0 - (1.0 - DICH) * (1.0 - t), axis=1)

def sheet_sensitivity():
    return np.genfromtxt(H + '/csv/spectral_sensitivity_5nm.csv', delimiter=',', skip_header=1)[:, 1]

def split_blue_green(edge=485.0, width=12.0, knee=455.0):
    """B follows the sheet curve up to its minimum between the two humps (~455 nm), then falls on an
    erf edge (ASSUMED: the native halide cut-off); G is what is left."""
    h = sheet_sensitivity()
    hk = float(np.interp(knee, WL, h))
    fall = 0.5 * (1 - erf((WL - edge) / width)); fall = fall / float(np.interp(knee, WL, fall))
    B = np.where(WL <= knee, h, np.minimum(h, hk * fall))
    G = np.clip(h - B, 0, None)
    return B, G

def sensitivities(g, edge=485.0, width=12.0):
    B, G = split_blue_green(edge, width)
    return np.stack([B + gi * G for gi in g], 1)

def channel_logx(S, cmy):
    """per-emulsion log exposure after the engine's normalisation (geometric mean over channels = 0).
    The Tri-X negative is spectrally flat, so its density only shifts all three together."""
    raw = (enlarger(cmy)[:, None] * S).sum(0)
    lx = np.log10(raw)
    return lx - lx.mean(), lx.mean()

def shape(x, cen, sig, w):
    return sum(wi * ndtr((x - c) / s) for c, s, wi in zip(cen, sig, w))

def paper_density(x, dx, A, cen, sig, w):
    """x: common log exposure (engine axis, 0 = geomean at the film's mid-grey, print_exposure 1)."""
    return sum(A[i] * shape(x + dx[i], cen[i], sig[i], w[i]) for i in range(3))

def pack(t):
    """one signed number -> (C, M, Y): negative = yellow only (soft), positive = magenta only (hard)"""
    return (0.0, max(t, 0.0), max(-t, 0.0))

def iso_range(x, D, dmax=None):
    """ISO 6846 log exposure range x100: from 0.04 over base to 90 % of (Dmax - base). D over base, rising in x."""
    dmax = D.max() if dmax is None else dmax
    return 100.0 * (np.interp(0.9 * dmax, D, x) - np.interp(0.04, D, x))

def sheet_curves():
    a = np.genfromtxt(H + '/csv/char_curves_grid.csv', delimiter=',', skip_header=1)
    return a[:, 0], {g: a[:, 1 + i] for i, g in enumerate(GRADES)}
