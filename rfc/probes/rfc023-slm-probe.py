# rfc023-slm-probe.py -- RFC-023 §15: drive the SHIPPING engine through the C
# ABI, apply the Scene Latitude curve to the scene-linear frame in numpy, and
# render both through the same pipeline.
#
# Analysis only; nothing in the build or the app runs it (CLAUDE.md: no Python
# at build or run time). The point of doing it this way is that no engine code
# had to change to measure the design: `spk_open` already takes a scene-linear
# float32 (H, W, 3), and §12.2 proves a pre-upsample per-pixel scalar is the
# same function as the node would be.
#
#   swiftc -O rfc/probes/rfc023-decode-raw.swift -o /tmp/decode
#   /tmp/decode frame.NEF /tmp/scene.f32 2048      # prints "W H"
#   then: load_scene, center_weighted_ev, apply_slm2, Engine().open(...).render()
#
# `center_weighted_ev` reproduces `Pipeline::legacy_exposure_ev`; it was checked
# against the engine's own auto-exposure render (max 157 counts of 65535, which
# is under the engine's own render-to-render spread).
import sys, math, zlib, struct, json
import numpy as np
sys.path.insert(0, "/Users/xiaojinqiu/Documents/Summer 2026/filmify/engine/tests")
from spk_ctypes import Engine

MIDGRAY = 0.184
# Y row of linear-ProPhoto(D50) -> XYZ, the same numbers ImageDecoder builds the
# colour space from and the engine's rgb_to_xyz_ae_ row 1.
YROW = np.array([0.2880402, 0.7118741, 0.0000857], dtype=np.float64)

def load_scene(path, w, h):
    a = np.fromfile(path, dtype=np.float32).reshape(h, w, 3)
    return a

def luminance(rgb):
    return rgb.astype(np.float64) @ YROW

def stride_sample(img):
    """`Pipeline::exposure_sample_y`: step = ceil(max(h,w)/256), take every step-th."""
    h, w = img.shape[:2]
    n = max(h, w)
    step = int(math.ceil(n / 256.0)) if n > 256 else 1
    return img[::step, ::step]

def center_weighted_ev(img):
    s = stride_sample(img)
    Y = luminance(s)
    sh, sw = Y.shape
    m_edge = float(max(sh, sw))
    norm_h, norm_w = sh / m_edge, sw / m_edge
    sigma = 0.2
    xs = (np.arange(sw) / sw - 0.5) * norm_w
    ys = (np.arange(sh) / sh - 0.5) * norm_h
    wgt = np.exp(-(xs[None, :] ** 2 + ys[:, None] ** 2) / (2 * sigma * sigma))
    exposure = (float((Y * wgt).sum() / wgt.sum())) / MIDGRAY
    return -math.log2(exposure)

# --- the RFC-023 curve -----------------------------------------------------

def g_m(D, H, m):
    D = np.maximum(D, 0.0)
    return D * H / (H ** m + D ** m) ** (1.0 / m)

def solve_K(a, C, N, m):
    """knee K so that f(a) = a - N with ceiling C. f(a) is decreasing in K."""
    t = a - N
    if N <= 0: return None
    if t >= C: raise ValueError(f"pull-back {N:.2f} lands at {t:.2f}, past the boundary {C:.2f}")
    K1 = t - math.sqrt((a - t) * (C - t))
    if abs(m - 1.0) < 1e-12: return K1
    lo, hi = K1 - 60.0, min(t, C) - 1e-9
    for _ in range(300):
        mid = 0.5 * (lo + hi)
        if mid + g_m(np.array(a - mid), C - mid, m) > t: hi = mid
        else: lo = mid
    return 0.5 * (lo + hi)

def delta_ev(E, Kh, Hh, Ks, Hs, m):
    """f(E) - E, vectorised. Exactly 0.0 inside the core."""
    d = np.zeros_like(E)
    hi = E > Kh
    if hi.any():
        D = E[hi] - Kh
        d[hi] = g_m(D, Hh, m) - D
    lo = E < Ks
    if lo.any():
        D = Ks - E[lo]
        d[lo] = D - g_m(D, Hs, m)
    return d

def apply_slm(rgb_metered, Kh, Hh, Ks, Hs, m, ev_film=0.0):
    """The node, in numpy: scalar norm -> EV -> delta -> gain -> RGB.
    Input is already at the metered exposure (E = 0 is mid-grey)."""
    n = luminance(np.maximum(rgb_metered, 0.0))
    floor = MIDGRAY * 2.0 ** -24
    bad = ~np.isfinite(n) | (n <= 0)
    E = np.log2(np.maximum(n, floor) / MIDGRAY)
    Ep = np.clip(E + ev_film, -24.0, 24.0)
    d = delta_ev(Ep, Kh, Hh, Ks, Hs, m)
    k = np.exp2(d + ev_film)
    k[bad] = 1.0
    return (rgb_metered * k[..., None]).astype(np.float32), E

# --- output ----------------------------------------------------------------

def write_png(path, rgb8):
    h, w, _ = rgb8.shape
    raw = b"".join(b"\x00" + rgb8[y].tobytes() for y in range(h))
    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6))
           + chunk(b"IEND", b""))
    open(path, "wb").write(png)

def result_to_rgb8(res):
    """SpkResult rgba16 -> uint8 RGB. The engine returns display-encoded 16-bit."""
    return (res[:, :, :3] >> 8).astype(np.uint8)

def romm_decode(enc):
    """ProPhoto/ROMM cctf decoding: linear below 16*Et, gamma 1.8 above."""
    enc = np.asarray(enc, dtype=np.float64)
    Et16 = 16.0 / 512.0
    return np.where(enc < Et16, enc / 16.0, np.power(np.maximum(enc, 0.0), 1.8))

def result_linear_Y(rgba16):
    enc = rgba16[:, :, :3].astype(np.float64) / 65535.0
    return luminance(romm_decode(enc))

def probe_medium(engine, delta, ev_lo=-12.0, ev_hi=12.0, n=512, h=16):
    """RFC-023 §8.1: a neutral ramp through the real pipeline."""
    E = np.linspace(ev_lo, ev_hi, n)
    col = (MIDGRAY * 2.0 ** E).astype(np.float32)
    img = np.repeat(col[None, :, None], 3, axis=2)
    img = np.repeat(img, h, axis=0).astype(np.float32)
    d = dict(delta); d.update({"auto_exposure": False, "grain_active": False})
    ses = engine.open(img, d)
    res, _ = ses.render("full")
    ses.close()
    Y = result_linear_Y(res).mean(axis=0)     # average the rows
    return E, Y

def iso_range(E, Y, hi_frac=0.90, lo_delta_density=0.04):
    """ISO 6846-style boundaries on the probe: the highlight end is where the
    output reaches `hi_frac` of the way from its own black to its own white;
    the shadow end is `lo_delta_density` in density above black."""
    Yb, Yw = float(np.min(Y)), float(np.max(Y))
    def cross(target, rising=True):
        for i in range(len(E) - 1):
            a, b = Y[i], Y[i + 1]
            if (a - target) * (b - target) <= 0 and b != a:
                t = (target - a) / (b - a)
                return float(E[i] + t * (E[i + 1] - E[i]))
        return None
    t_hi = Yb + hi_frac * (Yw - Yb)
    t_lo = Yb + (Yw - Yb) * (10 ** (-lo_delta_density) ** 0 * 0)  # placeholder
    # density above black: D = -log10(Y/Yw); black sits at D_max. 0.04 above black:
    t_lo = Yw * 10 ** (-( -math.log10(max(Yb, 1e-12) / Yw) - lo_delta_density))
    return cross(t_lo), cross(t_hi), Yb, Yw

def norm_of(rgb, kind="Y"):
    c = np.maximum(rgb.astype(np.float64), 0.0)
    if kind == "Y":     return luminance(c)
    if kind == "max":   return c.max(axis=2)
    if kind == "mean":  return c.mean(axis=2)
    if kind == "power": return (c**3).sum(2) / np.maximum((c**2).sum(2), 1e-30)
    raise ValueError(kind)

def apply_slm2(rgb_metered, Kh, Hh, Ks, Hs, m, ev_film=0.0,
               kind="Y", max_lift=None, lift_m=2.0):
    """As apply_slm, plus a norm choice and a bounded shadow lift.

    `max_lift` (stops) bounds the delta through the SAME smooth-min, so the
    curve keeps a continuous derivative and simply relaxes to slope 1 once the
    gain reaches the limit."""
    n = norm_of(rgb_metered, kind)
    floor = MIDGRAY * 2.0 ** -24
    bad = ~np.isfinite(n) | (n <= 0)
    E = np.log2(np.maximum(n, floor) / MIDGRAY)
    Ep = np.clip(E + ev_film, -24.0, 24.0)
    d = delta_ev(Ep, Kh, Hh, Ks, Hs, m)
    if max_lift is not None:
        up = d > 0
        d[up] = g_m(d[up], float(max_lift), lift_m)      # smooth-min with the limit
    k = np.exp2(d + ev_film)
    k[bad] = 1.0
    return (rgb_metered * k[..., None]).astype(np.float32), k
