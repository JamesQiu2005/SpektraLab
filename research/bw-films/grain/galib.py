"""Shared helpers for the B&W films' RMS granularity measurement -- research/grain-all/galib.py with the
paths fixed (frozen dylib, product profiles overlaid) and a neutral probe added (make_bw_probe).

Same read-out method as research/bw-tri-x/grain/glib.py (kept there, not imported, so this folder
re-runs on its own):

  * `res/` is a scratch resources folder: symlinks to the worktree's engine/resources, plus PROBE
    profiles. A probe is the stock's own profile (curves, sub-layer curves, sensitivities, info --
    everything the grain node reads) with `channel_density` replaced by a spectrally FLAT 0.3 in ONE
    channel and `base_density` by a flat 0.5. With `scan_film` the scanner output is then exactly
    10^-(0.5 + 0.3 d_c), so d_c = -log10(out / 10^-0.5) / 0.3 : the density field of one dye record.
  * the scanner's unsharp mask (sigma 0.7 px, amount 0.7, not on the wire) is linear on that output
    and is divided out exactly in the Fourier domain.
  * the base of 0.5 keeps the scan under linear 0.32 (the output stage compresses above ~0.45).
  * the grain node's own blurs (0.65 px; dye clouds when they fire) are NOT removed: they are the
    product, and they are why the 48 um number depends on the pixel pitch.
"""
import json, os, sys
from pathlib import Path
import numpy as np
from scipy.signal import fftconvolve

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]                                 # research/bw-films/grain -> the checkout
ENGINE = REPO / "engine"
SCRATCH = Path("/private/tmp/claude-501/-Volumes-Hanze-Qiu-Documents-Summer-2026-filmify/"
               "44311f6d-ffac-4e15-83c7-752dff45217a/scratchpad/grain")
# A FROZEN copy of the dylib (the one in engine/build was being rebuilt during the study). Override
# with GRAIN_DYLIB / GRAIN_RES to re-run against a current build.
DYLIB = Path(os.environ.get("GRAIN_DYLIB", SCRATCH / "libspektrafilm_engine.dylib"))
RES = Path(os.environ.get("GRAIN_RES", SCRATCH / "res"))
PRODUCT = ENGINE / "resources_product" / "profiles"
BW = ["kodak_tri_x_400", "kodak_tmax_100", "fujifilm_neopan_acros_100_ii", "ilford_hp5_plus_400"]
sys.path.insert(0, str(ENGINE / "tests"))
from spk_ctypes import Engine  # noqa: E402

PROBE_K, PROBE_BASE, UNSHARP = 0.3, 0.5, (0.7, 0.7)
WHITE = 10.0 ** -PROBE_BASE
A48 = np.pi * 24.0 ** 2

# engine/src/core/params.hpp GrainParams defaults (read 2026-10-07; the wire reaches none of them
# but `grain_active`, `grain_sublayers_active`, `grain_amount`)
AREA, SCALE, LAYERS = 0.2, (1.6, 1.6, 3.2), (2.0, 1.0, 0.5)
DMIN, UNI, BLUR, DYE_UM, MIN_SIGMA = 0.03, (0.97, 0.99, 0.97), 0.65, 1.0, 0.4


def build_res():
    """(Re)build the scratch resources folder: symlinks of engine/resources/*, the shipped profiles,
    and the product's B&W profiles laid over them (the overlay of engine/tests/bw_checks.py)."""
    src = ENGINE / "resources"
    (RES / "profiles").mkdir(parents=True, exist_ok=True)
    for f in src.iterdir():
        if f.name != "profiles" and not (RES / f.name).exists():
            os.symlink(f, RES / f.name)
    for d in (src / "profiles", PRODUCT):
        for f in sorted(d.glob("*.json")):
            dst = RES / "profiles" / f.name
            if not dst.is_symlink() and not dst.exists():
                os.symlink(f, dst)
    return list(BW)


def load(stock):
    return json.load(open(RES / "profiles" / f"{stock}.json"))


def make_probes(stock):
    names = []
    for ch in range(3):
        p = load(stock)
        n = len(p["data"]["wavelengths"])
        cd = np.zeros((n, 3)); cd[:, ch] = PROBE_K
        p["data"]["channel_density"] = cd.tolist()
        p["data"]["base_density"] = [PROBE_BASE] * n
        name = f"probe_{stock}_{ch}"
        json.dump(p, open(RES / "profiles" / f"{name}.json", "w"))
        names.append(name)
    return names


def make_bw_probe(stock, src=None):
    """The B&W negative itself, made readable: the profile's neutral 1/3-per-channel columns scaled to
    a flat PROBE_K/3 each, base a flat PROBE_BASE. The scan is 10^-(0.5 + 0.3 * mean(d_r, d_g, d_b)),
    so to_density() returns the film's net density field (what a densitometer reads), in ONE render."""
    p = json.load(open(src)) if src else load(stock)
    n = len(p["data"]["wavelengths"])
    p["data"]["channel_density"] = np.full((n, 3), PROBE_K / 3).tolist()
    p["data"]["base_density"] = [PROBE_BASE] * n
    name = f"probe_{stock}_bw"
    json.dump(p, open(RES / "profiles" / f"{name}.json", "w"))
    return name


BASE_DELTA = {
    "auto_exposure": False, "scan_film": True, "output_cctf_encoding": False,
    "halation_active": False, "dir_couplers_active": False, "glare_active": False,
    "scanner_white_correction": False, "scanner_black_correction": False,
    "scanner_lens_blur": 0.0, "lens_blur_um": 0.0, "extended_dynamic_range": False,
}


def render_lin(engine, stock, frame, px_um, **extra):
    """Linear scanner output (G) for an (n, n, 3) or scalar-level frame of long edge n."""
    n = frame.shape[0]
    delta = dict(BASE_DELTA, film_stock=stock, film_format_mm=px_um * n / 1000.0)
    delta.update(extra)
    with engine.open(frame, delta) as s:
        rgba, _ = s.render("full")
    return rgba[..., 1].astype(np.float64) / 65535.0


def flat(level, n):
    return np.full((n, n, 3), level, dtype=np.float32)


def deunsharp(img):
    s, a = UNSHARP
    fy = np.fft.fftfreq(img.shape[0])[:, None]
    fx = np.fft.fftfreq(img.shape[1])[None, :]
    H = 1.0 + a * (1.0 - np.exp(-2 * np.pi ** 2 * s ** 2 * (fx ** 2 + fy ** 2)))
    return np.real(np.fft.ifft2(np.fft.fft2(img) / H))


def to_density(out, crop=16):
    lin = np.maximum(deunsharp(out), 1e-6)
    d = -np.log10(lin / WHITE) / PROBE_K
    return d[crop:-crop, crop:-crop] if crop else d


def density(engine, probe, level, n, px_um, **extra):
    """Net (normalised) density field of the probed channel, (n-32)^2, float64."""
    return to_density(render_lin(engine, probe, flat(level, n), px_um, **extra))


def mean_density(engine, probe, level, **extra):
    """Grain-off density of a flat patch (64 px, the pitch is irrelevant without grain)."""
    out = render_lin(engine, probe, flat(level, 64), 100.0, grain_active=False, **extra)
    return float(-np.log10(out.mean() / WHITE) / PROBE_K)


def disc_kernel(diam_px, ss=15):
    """Area-weighted circular aperture, sums to 1."""
    r = diam_px / 2.0
    half = int(np.ceil(r)) + 1
    m = 2 * half + 1
    c = (np.arange(m * ss) + 0.5) / ss - m / 2.0
    yy, xx = np.meshgrid(c, c, indexing="ij")
    k = (xx ** 2 + yy ** 2 <= r * r).astype(float).reshape(m, ss, m, ss).mean(axis=(1, 3))
    return k / k.sum()


def aperture_mean(field, px_um, diam_um=48.0):
    return fftconvolve(field, disc_kernel(diam_um / px_um), mode="valid")


def aperture_sigma(d, px_um, diam_um=48.0):
    return float(aperture_mean(d - d.mean(), px_um, diam_um).std())


# ---------------------------------------------------------------- analytic model
def gauss2(s):
    if s <= 0:
        return np.ones((1, 1))
    r = int(np.ceil(5 * s)) + 1
    x = np.arange(-r, r + 1)
    g = np.exp(-x ** 2 / (2 * s * s)); g /= g.sum()
    return np.outer(g, g)


_gain = {}
def aperture_gain(px_um, sigma_px):
    """sigma through the 48 um disc of unit white noise blurred by a Gaussian of sigma_px."""
    key = (px_um, round(float(sigma_px), 4))
    if key not in _gain:
        k = fftconvolve(disc_kernel(48.0 / px_um), gauss2(sigma_px))
        _gain[key] = float(np.sqrt((k ** 2).sum()))
    return _gain[key]


def model_channel(prof, ch, d_net, px_um, sublayers, amount=1.0):
    """Model RMS x1000 (48 um) of channel ch at net density d_net: grain_realise + layer_draw, with
    the node's blurs. Returns (rms_with_blur, rms_selwyn_no_blur)."""
    D = prof["data"]
    cur = np.array(D["density_curves"], float)[:, ch]
    net = cur - np.nanmin(cur)
    if not sublayers:
        dm = float(np.nanmax(net)) + DMIN
        dd = d_net + DMIN
        n = px_um ** 2 / (AREA * SCALE[ch])
        v = dd * dm / n * (1 - UNI[ch] * dd / dm)
        s = BLUR if BLUR > MIN_SIGMA else 0.0
        return (1000 * amount * np.sqrt(v) * aperture_gain(px_um, s),
                1000 * amount * np.sqrt(v * px_um ** 2 / A48))
    lay = np.array(D["density_curves_layers"], float)[:, :, ch]       # (K, sl)
    axis = -net if prof["info"]["type"] == "positive" else net
    q = -d_net if prof["info"]["type"] == "positive" else d_net
    dl = np.array([np.interp(q, axis, lay[:, sl]) for sl in range(3)])
    dmaxl = np.nanmax(lay, axis=0)
    frac = dmaxl / dmaxl.sum()
    dminl = frac * DMIN
    dmaxl = dmaxl + dminl
    var_ap, var_white = 0.0, 0.0
    for sl in range(3):
        n = px_um ** 2 * frac[sl] / (AREA * SCALE[ch] * LAYERS[sl])
        od = dmaxl[sl] / n
        dd = float(np.clip((dl[sl] + dminl[sl]) / dmaxl[sl], 1e-6, 1 - 1e-6)) * dmaxl[sl]
        v = dd * od * (1 - UNI[ch] * dd / dmaxl[sl])
        sp = DYE_UM * np.sqrt(od)                 # the engine compares this number with 0.4 as pixels
        sp = sp if sp > MIN_SIGMA else 0.0
        var_ap += v * aperture_gain(px_um, np.hypot(BLUR, sp)) ** 2
        var_white += v
    return 1000 * amount * np.sqrt(var_ap), 1000 * amount * np.sqrt(var_white * px_um ** 2 / A48)


# ---------------------------------------------------------------- visual density
def visual_weights(wl):
    """ISO 5-3 visual density spectral product: CIE illuminant A (2856 K Planckian) x V(lambda),
    normalised to sum 1 on the profile's wavelength grid."""
    import colour
    v = colour.SDS_LEFS["CIE 1924 Photopic Standard Observer"]
    V = np.array([v[w] for w in wl])
    lam = np.asarray(wl) * 1e-9
    SA = lam ** -5 / (np.exp(1.4388e-2 / (lam * 2856.0)) - 1)
    w = SA * V
    return w / w.sum()


class Visual:
    """Visual density of the film from its three dye amounts, with the film's own spectra exactly as
    the engine assembles them: D(lambda) = base_density + sum_c d_c * channel_density_c (wavelengths
    where either is NaN carry no density and, here, no weight)."""
    def __init__(self, prof):
        D = prof["data"]
        wl = np.array(D["wavelengths"], float)
        cd = np.array(D["channel_density"], float)
        base = np.array(D["base_density"], float)
        ok = ~(np.isnan(cd).any(axis=1) | np.isnan(base))
        w = visual_weights(wl) * ok
        self.w = (w / w.sum())[ok]
        self.cd = cd[ok]
        self.base = base[ok]
        self.lost_weight = float(1 - (visual_weights(wl) * ok).sum())
        self.dv_min = float(self.dv(np.zeros(3)))

    def transmittance(self, d):
        """d (..., 3) -> visual transmittance (...)."""
        d = np.asarray(d, np.float32)
        out = np.empty(d.shape[:-1], np.float64)
        flat_d = d.reshape(-1, 3)
        o = out.reshape(-1)
        cd = self.cd.astype(np.float32); base = self.base.astype(np.float32); w = self.w.astype(np.float32)
        for i in range(0, len(flat_d), 1 << 18):
            spec = flat_d[i:i + (1 << 18)] @ cd.T + base
            o[i:i + (1 << 18)] = np.power(np.float32(10.0), -spec) @ w
        return out

    def dv(self, d):
        return -np.log10(self.transmittance(np.asarray(d, float)))

    def gradient(self, d, eps=1e-3):
        d = np.asarray(d, float)
        return np.array([(self.dv(d + eps * np.eye(3)[c]) - self.dv(d - eps * np.eye(3)[c])) / (2 * eps)
                         for c in range(3)])
