#!/usr/bin/env python3
"""RFC-028 probe: where the orange mask lives, and what a digital
de-mask-and-invert ("去色罩" then reverse) of the *computed* negative gives.

Every table in RFC-028 §4-§8 comes from this file. It reads the shipped
profiles and constants blob, and it takes the negative from the shipping
engine (`spk_export_di`, the developed film density), so the film half --
spectral sensitivity, halation, curves, DIR couplers, grain -- is the
product's, not a re-derivation.

    PY=../spektrafilm/.venv/bin/python        # needs numpy + colour-science
    $PY rfc/probes/rfc028-demask-probe.py mask        # §4  where the mask is
    $PY rfc/probes/rfc028-demask-probe.py crosstalk   # §5  per-channel is enough?
    $PY rfc/probes/rfc028-demask-probe.py validate    # §6  my scan == engine scan
    $PY rfc/probes/rfc028-demask-probe.py wedge       # §6  inversions on a grey wedge
    $PY rfc/probes/rfc028-demask-probe.py colour      # §7  ColorChecker
    $PY rfc/probes/rfc028-demask-probe.py extras      # §5.2b §6.2b §7.2 §7.3
    $PY rfc/probes/rfc028-demask-probe.py images OUT FRAME.npy...  # §8

Requires `engine/build.sh dylib`. Research only: nothing here ships, and the
no-Python rule for the product is untouched.
"""
from __future__ import annotations

import json
import math
import struct
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
PROFILES = REPO / "engine/resources/profiles"
BLOB = REPO / "engine/resources/spektrafilm_constants.bin"
sys.path.insert(0, str(REPO / "engine/tests"))

MIDGRAY = 0.184
LOG2 = math.log10(2.0)
NEGATIVES = ["kodak_portra_400", "kodak_portra_160", "kodak_portra_800", "kodak_ektar_100",
             "kodak_gold_200", "kodak_ultramax_400", "fujifilm_pro_400h", "fujifilm_c200",
             "kodak_vision3_250d", "kodak_vision3_500t"]
PAPER = "kodak_portra_endura"


# ------------------------------------------------------------------ data --
def read_blob(path=BLOB):
    """The constants blob, as `solve_neutral_profile.py` (RFC-022) reads it."""
    b = path.read_bytes()
    n = struct.unpack("<III", b[4:16])[1]
    fmt, size = "<64sIIIIIIQQ", struct.calcsize("<64sIIIIIIQQ")
    dt = {0: "<f8", 1: "<f4", 2: "<f2", 3: "<i4", 4: "u1"}
    out = {}
    for i in range(n):
        nm, d, nd, a, c, e, f, off, _ = struct.unpack(fmt, b[16 + i * size: 16 + (i + 1) * size])
        dims = [a, c, e, f][:nd]
        out[nm.rstrip(b"\0").decode()] = np.frombuffer(
            b, dt[d], int(np.prod(dims)), off).reshape(dims).astype(np.float64)
    return out


BL = read_blob()
WL = BL["spectral/wavelengths"]
CMFS = BL["colour/cmfs_1931_2deg"]


def profile(stock):
    return json.loads((PROFILES / f"{stock}.json").read_text())


def arr(x):
    a = np.array(x, float)
    a[~np.isfinite(a)] = np.nan
    return a


def illuminant(name):
    if name.startswith("BB"):
        lam = WL * 1e-9
        v = (3.741771e-16 * lam ** -5.0 / np.pi) / np.expm1(1.4388e-2 / (lam * float(name[2:])))
    elif name.startswith("TH-KG3"):
        lam = WL * 1e-9
        v = (3.741771e-16 * lam ** -5.0 / np.pi) / np.expm1(1.4388e-2 / (lam * 3400.0))
        v = v * BL["filters/kg3"] * (BL["filters/lens_canon"] if name.endswith("-L") else 1.0)
    else:
        v = BL[f"colour/sd_illuminant/{name}"].copy()
    return v / v.mean()


def gaussian_bands(peaks, fwhm):
    s = fwhm / 2.3548
    return np.stack([np.exp(-0.5 * ((WL - p) / s) ** 2) for p in peaks], 1)


def camera_ssf():
    import colour
    cam = colour.MSDS_CAMERA_SENSITIVITIES["Nikon 5100 (NPL)"]
    cam = cam.copy().align(colour.SpectralShape(380, 780, 5),
                           extrapolator_kwargs={"method": "Constant", "left": 0, "right": 0})
    return np.nan_to_num(cam.values)


# A "scanner" is light x sensor per channel (81 x 3), R G B column order.
# Status M and the LED scanner are stylised: Gaussians at the stated peaks.
# ISO 5-3 Status M peaks are ~645/530/445 nm; the LED widths are typical of
# narrow-band RGB film-scanning light sources, not any one product.
def scanners():
    paper = profile(PAPER)
    # log_sensitivity columns are R, G, B and channel_density columns C, M, Y in
    # every profile (checked by peak wavelength), so channel m pairs with dye m.
    psens = np.nan_to_num(10.0 ** arr(paper["data"]["log_sensitivity"]))
    return {
        "status_m": gaussian_bands([645, 530, 445], 30.0),
        "led_rgb": gaussian_bands([630, 525, 450], 22.0),
        "camera_d50": camera_ssf() * illuminant("D50")[:, None],
        "printing": psens * illuminant(paper["info"]["reference_illuminant"])[:, None],
    }


class Negative:
    """One film's spectral density model: D(λ) = base(λ) + Σ_k cmy_k ε_k(λ)."""

    def __init__(self, stock):
        p = profile(stock)
        self.stock, self.p = stock, p
        chd, base = arr(p["data"]["channel_density"]), arr(p["data"]["base_density"])
        # `prepare_spectral_constants`: a wavelength with any NaN is dropped from
        # the integral altogether (its weight is zeroed), not read as density 0.
        self.valid = np.isfinite(base) & np.isfinite(chd).all(1)
        self.chd = np.where(self.valid[:, None], chd, 0.0)                # 81 x 3, C M Y
        self.base = np.where(self.valid, base, 0.0)
        self.logsens = arr(p["data"]["log_sensitivity"])

    def spectral_density(self, cmy, base=True):
        cmy = np.atleast_2d(cmy)
        d = cmy @ self.chd.T
        return d + self.base[None, :] if base else d

    def read(self, cmy, scanner, mode):
        """Channel densities a scanner reads, three ways of treating the base.

        mode "raw":      -log10 T_m, base and all (what the sensor sees)
        mode "channel":  raw minus the base's own raw reading (NLP / Cineon /
                         negadoctor: divide each channel by the film base)
        mode "spectral": the base removed wavelength by wavelength before the
                         integral -- possible only because the base is known
        """
        w = scanner * self.valid[:, None]
        w = w / w.sum(0, keepdims=True)
        if mode == "spectral":
            t = 10.0 ** -self.spectral_density(cmy, base=False)
            return -np.log10(t @ w)
        raw = -np.log10((10.0 ** -self.spectral_density(cmy)) @ w)
        if mode == "raw":
            return raw
        base = -np.log10((10.0 ** -self.base[None, :]) @ w)
        return raw - base


# ------------------------------------------------------------- engine ----
BASE_DELTA = {"auto_exposure": False, "exposure_compensation_ev": 0.0,
              "grain_active": False, "glare_active": False,
              "output_cctf_encoding": False, "output_color_space": "ProPhoto RGB",
              "input_color_space": "ProPhoto RGB", "input_cctf_decoding": False}


def engine():
    from spk_ctypes import Engine
    return Engine()


def film_density(eng, img, delta):
    """The developed negative, from `spk_export_di`: layer densities above Dmin."""
    ax = BL[f"print_lut_axes/{PAPER}"]
    lo, hi = ax[:, 0], ax[:, -1]
    sess = eng.open(np.ascontiguousarray(img, np.float32),
                    {**BASE_DELTA, "print_stock": PAPER, **delta})
    di, info = sess.export_di()
    v = di[..., :3].astype(np.float64) / 65535.0
    sess.close()
    return lo + v * (hi - lo)


def render(eng, img, delta, tier="full"):
    sess = eng.open(np.ascontiguousarray(img, np.float32), {**BASE_DELTA, **delta})
    rgba, _ = sess.render(tier)
    sess.close()
    return rgba[..., :3].astype(np.float64) / 65535.0


def patch_means(img, rows, cols, size):
    k = size // 4
    out = []
    for r in range(rows):
        for c in range(cols):
            t = img[r * size + k:(r + 1) * size - k, c * size + k:(c + 1) * size - k]
            out.append(t.reshape(-1, 3).mean(0))
    return np.array(out)


def wedge_image(stops, size=24):
    img = np.zeros((size, size * len(stops), 3), np.float32)
    for i, s in enumerate(stops):
        img[:, i * size:(i + 1) * size] = MIDGRAY * 2.0 ** s
    return img


# ------------------------------------------------------------- colour ----
M_PP = BL["colour/cs/ProPhoto RGB/matrix_XYZ_to_RGB"]


def xyz_to_lab(xyz, white):
    t = xyz / white
    f = np.where(t > (6 / 29) ** 3, np.cbrt(np.maximum(t, 0)), t / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]),
                     200 * (f[..., 1] - f[..., 2])], -1)


def prophoto_to_lab(rgb):
    xyz = rgb @ np.linalg.inv(M_PP).T
    return xyz_to_lab(xyz, np.linalg.inv(M_PP) @ np.ones(3))


def de2000(a, b):
    import colour
    return colour.delta_E(a, b, method="CIE 2000")


def lch(lab):
    return np.stack([lab[..., 0], np.hypot(lab[..., 1], lab[..., 2]),
                     np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360], -1)


def colorchecker_prophoto():
    """BabelColor average reflectances under D50, as linear ProPhoto (D50 white)."""
    import colour
    sds = colour.SDS_COLOURCHECKERS["BabelColor Average"]
    d50 = BL["colour/sd_illuminant/D50"]
    k = 1.0 / (d50 @ CMFS[:, 1])
    names, rgb = [], []
    for name, sd in sds.items():
        r = np.nan_to_num(sd.copy().align(colour.SpectralShape(380, 780, 5),
                                          extrapolator_kwargs={"method": "Constant"}).values)
        xyz = k * (r * d50) @ CMFS
        names.append(name)
        rgb.append(M_PP @ xyz)
    return names, np.array(rgb)


# ----------------------------------------------------------- inversion ---
class Inversion:
    """Deterministic de-mask + invert, built from a neutral wedge of this film.

    Everything NLP estimates from the picture is read off the model instead:
    the base (exact, spectral), each channel's contrast, and where mid grey
    sits (the metered exposure puts it at stop 0).
    """

    def __init__(self, neg, scanner, stops, cmy_wedge, mode="spectral"):
        self.neg, self.scanner, self.mode = neg, scanner, mode
        self.stops = np.asarray(stops, float)
        self.D = neg.read(cmy_wedge, scanner, mode)            # n x 3, R G B channel order
        i0 = int(np.argmin(np.abs(self.stops)))
        self.D0 = self.D[i0].copy()
        core = (self.stops >= -2.0) & (self.stops <= 2.0)
        x = self.stops[core] * LOG2
        self.gamma = np.array([np.polyfit(x, self.D[core, m], 1)[0] for m in range(3)])

    # every method returns a linear positive with mid grey at MIDGRAY
    def cineon(self, D):
        g = self.gamma.mean()
        return MIDGRAY * 10.0 ** ((D - self.D0) / g)

    def per_channel(self, D):
        return MIDGRAY * 10.0 ** ((D - self.D0) / self.gamma)

    def _stop_of(self, m, D):
        # a channel's density -> the stop that produced it on the neutral wedge;
        # extrapolated linearly past the wedge's ends
        x, y = self.D[:, m], self.stops
        s = np.interp(D, x, y)
        lo, hi = D < x[0], D > x[-1]
        s = np.where(lo, y[0] + (D - x[0]) / (x[1] - x[0]) * (y[1] - y[0]), s)
        s = np.where(hi, y[-1] + (D - x[-1]) / (x[-1] - x[-2]) * (y[-1] - y[-2]), s)
        return s

    def film_terms(self, D):
        return MIDGRAY * 2.0 ** np.stack([self._stop_of(m, D[..., m]) for m in range(3)], -1)

    def curve_kept(self, D):
        """Every channel put on the green channel's own curve, then reversed with
        green's gamma: neutral exact, and the tone is the film's (toe, shoulder)."""
        s = np.stack([self._stop_of(m, D[..., m]) for m in range(3)], -1)
        dg = np.interp(s, self.stops, self.D[:, 1])
        dg = np.where(s > self.stops[-1], self.D[-1, 1] + (s - self.stops[-1]) *
                      (self.D[-1, 1] - self.D[-2, 1]) / (self.stops[-1] - self.stops[-2]), dg)
        dg = np.where(s < self.stops[0], self.D[0, 1] + (s - self.stops[0]) *
                      (self.D[1, 1] - self.D[0, 1]) / (self.stops[1] - self.stops[0]), dg)
        return MIDGRAY * 10.0 ** ((dg - self.D0[1]) / self.gamma[1])


def inside(xy, poly):
    """Even-odd point-in-polygon, vectorised."""
    x, y = xy[:, 0], xy[:, 1]
    res = np.zeros(len(xy), bool)
    for (x0, y0), (x1, y1) in zip(poly, np.roll(poly, -1, 0)):
        cross = ((y0 > y) != (y1 > y)) & (x < (x1 - x0) * (y - y0) / (y1 - y0 + 1e-30) + x0)
        res ^= cross
    return res


def film_to_xyz_matrix(neg, white_xyz):
    """A 3x3 from the film's own white-balanced exposures to XYZ, least squares
    over the Hanatos spectra (the engine's own upsampling set) that fall inside
    Pointer's gamut of real surface colours, with the neutral pinned:
    M @ [1,1,1] = white. Not fitted to any chart. The LUT spans the whole
    spectral locus, and near-monochromatic spectra no 3x3 can fit would
    otherwise dominate the fit (rms 0.77 with them, see RFC-028 §7)."""
    from colour.models import CCS_POINTER_GAMUT_BOUNDARY
    spectra = BL["hanatos/spectra_lut"].reshape(-1, 81)
    sens = np.nan_to_num(10.0 ** neg.logsens)                  # R G B columns
    E = spectra @ sens
    X = spectra @ CMFS
    xy = X[:, :2] / X.sum(1, keepdims=True)
    ok = np.isfinite(E).all(1) & np.isfinite(X).all(1) & (X[:, 1] > 1e-6) & (E > 0).all(1)
    ok &= inside(xy, np.asarray(CCS_POINTER_GAMUT_BOUNDARY))
    E, X = E[ok], X[ok]
    s = 1.0 / X[:, 1]
    E, X = E * s[:, None], X * s[:, None]
    ref = illuminant(neg.p["info"]["reference_illuminant"])
    E_white = ref @ sens
    E = E / E_white[None, :]                    # neutral (ref illuminant) -> 1,1,1
    X_white = ref @ CMFS
    X = X / X_white[1]
    # adapt ref-illuminant XYZ to the output white (von Kries on the CAT02 cone space)
    cat = BL["colour/cat/CAT02"]
    lms_s, lms_d = cat @ (X_white / X_white[1]), cat @ white_xyz
    A = np.linalg.inv(cat) @ np.diag(lms_d / lms_s) @ cat
    X = X @ A.T
    # constrained least squares: M = M0 + correction keeping M @ 1 = white
    M = np.linalg.lstsq(E, X, rcond=None)[0].T
    one = np.ones(3)
    r = white_xyz - M @ one
    M = M + np.outer(r, one) / 3.0
    for _ in range(50):   # project: refit the residual with the constraint held
        R = X - E @ M.T
        dM = np.linalg.lstsq(E, R, rcond=None)[0].T
        dM = dM - np.outer(dM @ one, one) / 3.0
        M = M + dM
        if np.abs(dM).max() < 1e-12:
            break
    err = X - E @ M.T
    return M, float(np.sqrt((err ** 2).mean()) / np.sqrt((X ** 2).mean()))


# ------------------------------------------------------------- reports ---
def cmd_mask():
    sc = scanners()
    print("§4.1  The orange mask is base_density. Its reading in each scanner (density):")
    print(f"{'film':22s} {'status M  R/G/B':>18s} {'camera R/G/B':>18s} {'printing R/G/B':>18s}")
    for stock in NEGATIVES:
        n = Negative(stock)
        row = []
        for key in ("status_m", "camera_d50", "printing"):
            b = n.read(np.zeros(3), sc[key], "raw")[0]
            row.append("/".join(f"{v:.2f}" for v in b))
        print(f"{stock:22s} {row[0]:>18s} {row[1]:>18s} {row[2]:>18s}")
    print("\n§4.2  The image-dependent half of the mask is already inside the dye spectra.")
    print("      Unwanted absorption of each net dye, as a fraction of its own peak:")
    print(f"{'film':22s} {'C in blue':>10s} {'C in green':>11s} {'M in blue':>10s} {'M in red':>9s} "
          f"{'Y in green':>11s} {'most negative':>14s}")
    band = lambda lo, hi: (WL >= lo) & (WL < hi)
    B, G, R = band(420, 490), band(510, 570), band(610, 690)
    for stock in NEGATIVES:
        n = Negative(stock)
        c, m, y = (n.chd[:, k] / n.chd[:, k].max() for k in range(3))
        print(f"{stock:22s} {c[B].mean():10.3f} {c[G].mean():11.3f} {m[B].mean():10.3f} "
              f"{m[R].mean():9.3f} {y[G].mean():11.3f} {n.chd.min():14.3f}")


def cmd_crosstalk():
    sc = scanners()
    print("§5.1  Channel density per unit layer density (base removed spectrally).")
    print("      Row = channel read, column = the layer that formed dye. Off-diagonals")
    print("      are what a per-channel inversion cannot undo.\n")
    for stock in ["kodak_portra_400", "kodak_ektar_100", "kodak_vision3_250d"]:
        n = Negative(stock)
        for key, s in sc.items():
            A = np.stack([n.read(np.eye(3)[k] * 1.0, s, "spectral")[0] for k in range(3)], 1)
            off = A / np.diag(A)[:, None]
            print(f"{stock:20s} {key:11s} R<-C,M,Y {off[0,0]:.2f} {off[0,1]:+.3f} {off[0,2]:+.3f} | "
                  f"G<-C,M,Y {off[1,0]:+.3f} {off[1,1]:.2f} {off[1,2]:+.3f} | "
                  f"B<-C,M,Y {off[2,0]:+.3f} {off[2,1]:+.3f} {off[2,2]:.2f}")
        print()
    print("§5.2  Dividing by the base per channel vs removing it per wavelength.")
    print("      Max |difference| in channel density over cmy in [0, 2.5]^3 (11^3 grid):")
    g = np.linspace(0, 2.5, 11)
    grid = np.stack(np.meshgrid(g, g, g, indexing="ij"), -1).reshape(-1, 3)
    for stock in ["kodak_portra_400", "kodak_ektar_100", "fujifilm_pro_400h", "kodak_vision3_250d"]:
        n = Negative(stock)
        out = []
        for key, s in sc.items():
            d = np.abs(n.read(grid, s, "channel") - n.read(grid, s, "spectral")).max(0)
            out.append(f"{key} " + "/".join(f"{v:.3f}" for v in d))
        print(f"  {stock:20s} " + "   ".join(out))


def cmd_validate():
    """My spectral read is the engine's: the scan_film render against my integral
    of the same negative, under the film's viewing illuminant with the CMFs."""
    eng = engine()
    stops = np.arange(-6, 6.01, 1.0)
    img = wedge_image(stops)
    for stock in ["kodak_portra_400", "kodak_ektar_100"]:
        cmy = patch_means(film_density(eng, img, {"film_stock": stock}), 1, len(stops), 24)
        out = patch_means(render(eng, img, {"film_stock": stock, "scan_film": True}), 1, len(stops), 24)
        n = Negative(stock)
        vi = illuminant(n.p["info"]["viewing_illuminant"])
        w = vi[:, None] * CMFS * n.valid[:, None] / (vi @ CMFS[:, 1])
        xyz = (10.0 ** -n.spectral_density(cmy)) @ w
        # the engine adapts to the illuminant's white with CAT02 before ProPhoto
        white = vi @ CMFS / (vi @ CMFS[:, 1])
        cat = BL["colour/cat/CAT02"]
        d50 = BL["colour/sd_illuminant/D50"] @ CMFS
        d50 = d50 / d50[1]
        A = np.linalg.inv(cat) @ np.diag((cat @ d50) / (cat @ white)) @ cat
        mine = xyz @ A.T @ M_PP.T
        print(f"{stock:20s} max |engine scan_film - my integral| = {np.abs(mine - out).max():.2e} "
              f"(engine range {out.min():.3f}..{out.max():.3f})")


def wedge(eng, stock, stops):
    img = wedge_image(stops)
    return patch_means(film_density(eng, img, {"film_stock": stock}), 1, len(stops), 24)


def cmd_wedge():
    eng = engine()
    sc = scanners()
    stops = np.arange(-8, 8.01, 0.25)
    print("§6.1  Neutral wedge through the engine, read by each scanner (base removed).")
    print(f"{'film':20s} {'scanner':11s} {'gamma R/G/B':>17s} {'D at grey R/G/B':>17s} "
          f"{'responds (stops)':>17s}")
    results = {}
    for stock in ["kodak_portra_400", "kodak_ektar_100", "kodak_gold_200", "fujifilm_pro_400h",
                  "kodak_vision3_250d"]:
        cmy = wedge(eng, stock, stops)
        n = Negative(stock)
        for key in ("status_m", "led_rgb", "camera_d50", "printing"):
            inv = Inversion(n, sc[key], stops, cmy)
            slope = np.gradient(inv.D[:, 1], stops * LOG2)
            live = stops[slope > 0.1 * slope.max()]
            print(f"{stock:20s} {key:11s} {'/'.join(f'{g:.3f}' for g in inv.gamma):>17s} "
                  f"{'/'.join(f'{d:.2f}' for d in inv.D0):>17s} "
                  f"{live.min():+6.2f}..{live.max():+5.2f}")
            results[(stock, key)] = inv
    print("\n§6.2  Four ways to reverse the de-masked negative. Grey error = worst")
    print("      |log2(R/G)|, |log2(B/G)| over the wedge where the film responds, in")
    print("      stops; tone = output stops over mid grey at input -6, -3, +3, +6.")
    for stock in ["kodak_portra_400", "kodak_ektar_100", "kodak_gold_200", "fujifilm_pro_400h",
                  "kodak_vision3_250d"]:
        inv = results[(stock, "status_m")]
        slope = np.gradient(inv.D[:, 1], stops * LOG2)
        live = slope > 0.1 * slope.max()
        for name in ("cineon", "per_channel", "curve_kept", "film_terms"):
            P = getattr(inv, name)(inv.D)
            rg = np.abs(np.log2(P[live, 0] / P[live, 1])).max()
            bg = np.abs(np.log2(P[live, 2] / P[live, 1])).max()
            tone = [np.log2(P[np.argmin(np.abs(stops - s)), 1] / MIDGRAY) for s in (-6, -3, 3, 6)]
            print(f"  {stock:20s} {name:12s} grey error {max(rg, bg):6.3f} stops   tone "
                  + " ".join(f"{t:+6.2f}" for t in tone))
    return results


def cmd_colour():
    eng = engine()
    sc = scanners()
    names, pp = colorchecker_prophoto()
    size = 32
    img = np.zeros((4 * size, 6 * size, 3), np.float32)
    for i, v in enumerate(pp):
        r, c = divmod(i, 6)
        img[r * size:(r + 1) * size, c * size:(c + 1) * size] = v
    ref = prophoto_to_lab(pp)
    stops = np.arange(-8, 8.01, 0.25)
    white = np.linalg.inv(M_PP) @ np.ones(3)
    print("§7  ColorChecker (BabelColor average, D50). Mean / max ΔE00 against the")
    print("    colorimetric chart, mean chroma ratio (chromatic patches), mean |hue shift|.")
    print("    Grey patch n5 is anchored to its own L* in every row, so ΔE is colour, not exposure.\n")
    for stock in ["kodak_portra_400", "kodak_ektar_100", "kodak_gold_200", "fujifilm_pro_400h"]:
        n = Negative(stock)
        cmy_p = patch_means(film_density(eng, img, {"film_stock": stock}), 4, 6, size)
        cmy_w = wedge(eng, stock, stops)
        M, fit = film_to_xyz_matrix(n, white)
        rows = {}
        pr = patch_means(render(eng, img, {"film_stock": stock, "print_stock": PAPER}), 4, 6, size)
        rows["print (Portra Endura)"] = pr
        for key in ("status_m", "camera_d50", "printing"):
            inv = Inversion(n, sc[key], stops, cmy_w)
            D = n.read(cmy_p, sc[key], "spectral")
            for meth in ("curve_kept", "film_terms"):
                P = getattr(inv, meth)(D)
                rows[f"scan {key} {meth}"] = (P @ M.T) @ M_PP.T
        rows["camera linear (reference)"] = pp
        chroma = np.array([i for i in range(18)])
        print(f"  {stock}   film->XYZ matrix fit rms {fit:.3f}")
        for label, rgb in rows.items():
            lab = prophoto_to_lab(np.maximum(rgb, 1e-9))
            # anchor grey: scale so n5 (index 21) has the reference L*
            k = 1.0
            for _ in range(30):
                lab = prophoto_to_lab(np.maximum(rgb * k, 1e-9))
                k *= 2.0 ** ((ref[21, 0] - lab[21, 0]) / 30.0)
            d = de2000(lab, ref)
            L1, L0 = lch(lab), lch(ref)
            cr = (L1[chroma, 1] / L0[chroma, 1]).mean()
            dh = np.abs((L1[chroma, 2] - L0[chroma, 2] + 180) % 360 - 180).mean()
            print(f"    {label:34s} ΔE00 {d.mean():5.2f} / {d.max():5.2f}   chroma x{cr:4.2f}   "
                  f"|Δh| {dh:4.1f}°")
        print()


def srgb_encode(rgb_pp):
    M = BL["colour/cs/sRGB/matrix_XYZ_to_RGB"] @ np.linalg.inv(M_PP)
    # D50 -> D65, CAT02
    cat = BL["colour/cat/CAT02"]
    d50 = np.linalg.inv(M_PP) @ np.ones(3)
    d65 = BL["colour/sd_illuminant/D65"] @ CMFS
    d65 = d65 / d65[1]
    A = np.linalg.inv(cat) @ np.diag((cat @ d65) / (cat @ d50)) @ cat
    M = BL["colour/cs/sRGB/matrix_XYZ_to_RGB"] @ A @ np.linalg.inv(M_PP)
    x = np.clip(rgb_pp @ M.T, 0, 1)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - 0.055)


def display(rgb_pp, knee=1.5, room=1.0):
    """A placeholder display rendering, *not* a proposal: identity to `knee`
    stops over mid grey, then RFC-023's m=2 smooth-min on max(RGB), hue kept."""
    peak = np.max(rgb_pp, -1, keepdims=True)
    e = np.log2(np.maximum(peak, 1e-9) / MIDGRAY)
    d = np.maximum(e - knee, 0.0)
    f = np.where(e > knee, knee + d * room / np.sqrt(room ** 2 + d ** 2), e)
    return srgb_encode(rgb_pp * (MIDGRAY * 2.0 ** f / np.maximum(peak, 1e-9)))


def cmd_images(outdir, frames):
    import OpenImageIO as oiio
    eng = engine()
    sc = scanners()
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    stock, key = "kodak_portra_400", "printing"
    n = Negative(stock)
    stops = np.arange(-8, 8.01, 0.25)
    inv = Inversion(n, sc[key], stops, wedge(eng, stock, stops))
    white = np.linalg.inv(M_PP) @ np.ones(3)
    M, _ = film_to_xyz_matrix(n, white)
    film = {"film_stock": stock, "auto_exposure": True, "grain_active": True}

    def save(name, rgb01):
        oiio.ImageBuf(np.ascontiguousarray((np.clip(rgb01, 0, 1) * 255 + 0.5).astype(np.uint8))) \
            .write(str(outdir / name))

    for path in frames:
        img = np.load(path).astype(np.float32)
        f = int(math.ceil(max(img.shape[:2]) / 1800))
        if f > 1:   # box-average to <= 1800 px: a research render, not an export
            h, w = img.shape[0] // f * f, img.shape[1] // f * f
            img = img[:h, :w].reshape(h // f, f, w // f, f, 3).mean((1, 3)).astype(np.float32)
        stem = Path(path).stem.replace("_lin", "")
        cmy = film_density(eng, img, film)
        neg_scan = render(eng, img, {**film, "scan_film": True})
        pr = render(eng, img, {**film, "print_stock": PAPER, "output_color_space": "sRGB",
                               "output_cctf_encoding": True})
        # the de-masked negative, shown as a light table would: base removed per wavelength
        n_vi = illuminant(n.p["info"]["viewing_illuminant"])
        w = n_vi[:, None] * CMFS / (n_vi @ CMFS[:, 1])
        demasked_xyz = (10.0 ** -n.spectral_density(cmy.reshape(-1, 3), base=False)) @ w
        demasked = (demasked_xyz @ M_PP.T).reshape(img.shape)
        D = n.read(cmy.reshape(-1, 3), sc[key], "spectral")
        pos_curve = ((inv.curve_kept(D) @ M.T) @ M_PP.T).reshape(img.shape)
        pos_terms = ((inv.film_terms(D) @ M.T) @ M_PP.T).reshape(img.shape)
        # metering: the engine's auto exposure put the frame's own grey at stop 0,
        # so mid grey is already MIDGRAY in the positives; the camera input is not
        # metered, so give it the same meter the engine used (its log-mean luminance)
        cam = img * (MIDGRAY / np.exp(np.log(np.maximum(img[..., 1], 1e-6)).mean()))
        save(f"{stem}_0_camera.jpg", display(cam))
        save(f"{stem}_1_negative.jpg", srgb_encode(neg_scan))
        save(f"{stem}_2_demasked_negative.jpg", srgb_encode(demasked / demasked.max() * 0.9))
        save(f"{stem}_3_scan_curve_kept.jpg", display(pos_curve))
        save(f"{stem}_4_scan_film_terms.jpg", display(pos_terms))
        save(f"{stem}_5_print.jpg", pr)
        print(stem, "written")



def cmd_extras():
    """§5.2 over the densities a real negative reaches; §6.2 inside ±4 stops;
    §7.2 how much of the scan's chroma is the DIR couplers."""
    eng = engine()
    sc = scanners()
    stops = np.arange(-8, 8.01, 0.25)
    print("§5.2b  Base removal per channel vs per wavelength, over the wedge -6..+6 stops")
    print("       and the ColorChecker at 0 EV (max |Δ density| R/G/B):")
    names, pp = colorchecker_prophoto()
    size = 32
    chart = np.zeros((4 * size, 6 * size, 3), np.float32)
    for i, v in enumerate(pp):
        r, c = divmod(i, 6)
        chart[r * size:(r + 1) * size, c * size:(c + 1) * size] = v
    for stock in ["kodak_portra_400", "kodak_ektar_100", "fujifilm_pro_400h", "kodak_vision3_250d"]:
        n = Negative(stock)
        cmy = np.vstack([wedge(eng, stock, stops)[(stops >= -6) & (stops <= 6)],
                         patch_means(film_density(eng, chart, {"film_stock": stock}), 4, 6, size)])
        out = []
        for key, s in sc.items():
            d = np.abs(n.read(cmy, s, "channel") - n.read(cmy, s, "spectral")).max(0)
            out.append(f"{key} " + "/".join(f"{v:.3f}" for v in d))
        print(f"  {stock:20s} max cmy {cmy.max():.2f}   " + "   ".join(out))

    print("\n§6.2b  Grey error inside -4..+4 stops (printing density):")
    for stock in ["kodak_portra_400", "kodak_ektar_100", "kodak_gold_200", "fujifilm_pro_400h",
                  "kodak_vision3_250d"]:
        n = Negative(stock)
        for key in ("status_m", "printing"):
            inv = Inversion(n, sc[key], stops, wedge(eng, stock, stops))
            live = (stops >= -4) & (stops <= 4)
            errs = []
            for name in ("cineon", "per_channel"):
                P = getattr(inv, name)(inv.D)
                errs.append(max(np.abs(np.log2(P[live, 0] / P[live, 1])).max(),
                                np.abs(np.log2(P[live, 2] / P[live, 1])).max()))
            print(f"  {stock:20s} {key:9s} cineon {errs[0]:.3f}   per-channel {errs[1]:.3f} stops")

    print("\n§7.2  Chroma of the printing-density scan with the DIR couplers on and off:")
    ref = prophoto_to_lab(pp)
    white = np.linalg.inv(M_PP) @ np.ones(3)
    for stock in ["kodak_portra_400", "kodak_ektar_100"]:
        n = Negative(stock)
        M, _ = film_to_xyz_matrix(n, white)
        for dir_on in (True, False):
            d = {"film_stock": stock, "dir_couplers_active": dir_on}
            cmy_w = patch_means(film_density(eng, wedge_image(stops), d), 1, len(stops), 24)
            inv = Inversion(n, sc["printing"], stops, cmy_w)
            cmy = patch_means(film_density(eng, chart, d), 4, 6, size)
            rgb = (inv.curve_kept(n.read(cmy, sc["printing"], "spectral")) @ M.T) @ M_PP.T
            lab = lch(prophoto_to_lab(np.maximum(rgb, 1e-9)))
            cr = (lab[:18, 1] / lch(ref)[:18, 1]).mean()
            print(f"  {stock:20s} DIR {'on ' if dir_on else 'off'}  chroma x{cr:.2f}")
        pr_on = patch_means(render(eng, chart, {"film_stock": stock, "print_stock": PAPER}), 4, 6, size)
        pr_off = patch_means(render(eng, chart, {"film_stock": stock, "print_stock": PAPER,
                                                 "dir_couplers_active": False}), 4, 6, size)
        for label, rgb in (("print DIR on ", pr_on), ("print DIR off", pr_off)):
            lab = lch(prophoto_to_lab(np.maximum(rgb, 1e-9)))
            print(f"  {stock:20s} {label} chroma x{(lab[:18, 1] / lch(ref)[:18, 1]).mean():.2f}")

    print("\n§7.3  Per-patch hue shift (degrees) of the printing-density scan and the print,")
    print("      Portra 400, the patches a viewer judges first:")
    n = Negative("kodak_portra_400")
    M, _ = film_to_xyz_matrix(n, white)
    inv = Inversion(n, sc["printing"], stops, wedge(eng, "kodak_portra_400", stops))
    cmy = patch_means(film_density(eng, chart, {"film_stock": "kodak_portra_400"}), 4, 6, size)
    scan = lch(prophoto_to_lab(np.maximum((inv.curve_kept(n.read(cmy, sc["printing"], "spectral"))
                                           @ M.T) @ M_PP.T, 1e-9)))
    pr = lch(prophoto_to_lab(np.maximum(patch_means(render(eng, chart, {
        "film_stock": "kodak_portra_400", "print_stock": PAPER}), 4, 6, size), 1e-9)))
    L0 = lch(ref)
    for i in (0, 1, 2, 3, 12, 13, 14, 15, 17):
        dh = lambda x: (x[i, 2] - L0[i, 2] + 180) % 360 - 180
        print(f"  {names[i]:16s} scan {dh(scan):+6.1f}  C x{scan[i,1]/L0[i,1]:.2f}   "
              f"print {dh(pr):+6.1f}  C x{pr[i,1]/L0[i,1]:.2f}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "mask"
    if cmd == "images":
        cmd_images(sys.argv[2], sys.argv[3:])
    else:
        globals()[f"cmd_{cmd}"]()
