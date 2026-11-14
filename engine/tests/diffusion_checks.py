#!/usr/bin/env python3
"""API-SPEC §21.5: the diffusion filter (柔光镜), native, against its oracle.

    python3 engine/tests/diffusion_checks.py [--base-dylib PATH]

Needs `build.sh dylib`. The oracle is upstream's own file,
`spektrafilm/src/spektrafilm/model/diffusion.py` (read in place, see
`lens_probe.oracle`); without it the oracle checks are reported as SKIP.

What is held, and against what:

1. **Host tables**: p_s, every exponential's lambda and per-channel weight, for
   every family x a grid of strengths, warmths, intensities and sizes, against
   the oracle's `_strength_to_scatter`, `_resolve_family_cfg`, `_expand_group`
   and `_halo_channel_weights`. Bit-exact expected; 1e-12 relative is the bar.
2. **Impulse response**: a point through the lens pass (`spk_lens_probe`,
   linear light), its scattered part K = (out - (1 - p_s) delta) / p_s,
   against the oracle's analytic `diffusion_filter_radial_profile`, as
   encircled energy EE(r) -- the shape the eye sees. Plus the energy: sum K = 1.
3. **Image parity**: the fast path (the Gaussian pyramid and its core FIR,
   2026-11-10) on a linear image against (a) `apply_diffusion_filter_um` (its
   FFT, the PSF sampled on pixel centres and renormalised), (b) the PSF
   integrated over each pixel's cell (`lens_probe.cell_truth`, what the fit
   targets) and (c) the exact path (the 2026-11-09 Gaussian mixture, kept as
   the reference), in 16-bit codes of a display encode (x / (1 + x))^(1/2.2).
4. **Chunks and bands**: an encoded source (decoded, lensed and encoded again
   in one frame, the combine in row chunks) in chunks of several heights
   against one chunk, and against the same pass on the decoded image; RFC-020
   strips with the filter on against the strips of the source filtered first,
   byte for byte.
5. **Off is structural**: `diffusion_filter_active` false (and every other
   field set) renders byte for byte as the base engine (`--base-dylib`, a
   build of b28bedb); no film stage is the lens's, on or off.
6. **Refusals**: an unknown family is refused at the wire; the camera's filter
   renders. (The enlarger's filter, still refused by `Pipeline::build` --
   decision 12 -- has no wire field, so no host can reach it.)

Measured 2026-11-10 (M3 Max, this build): host tables bit-exact in 1,596 of
4,800 configurations, worst 4e-16 relative; images against the oracle mean
1.4-34, p99 13-214, max 186-937 codes (the exact path: 3.8-55, 46-291,
366-859); against the cell-integrated PSF mean 2.4-6.4, p99 29-43, max
286-424 (the exact path 12-33, 125-206, 696-1,030).
"""
import argparse, math, os, sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lens_probe as lp  # noqa: E402
import spk_ctypes as spk  # noqa: E402

failures = 0
FAMILIES = ("glimmerglass", "black_pro_mist", "pro_mist", "cinebloom")
BASE = {"film_stock": "kodak_portra_400", "print_stock": "kodak_supra_endura", "auto_exposure": False,
        "product_defaults": True, "grain_active": False, "glare_active": False}


def check(ok, what, detail=""):
    global failures
    print(("PASS " if ok else "FAIL ") + what + (f" -- {detail}" if detail else ""))
    if not ok:
        failures += 1


def codes(x):
    x = np.maximum(np.asarray(x, np.float64), 0.0)
    return np.round(65535.0 * (x / (1.0 + x)) ** (1 / 2.2))


def code_stats(a, b):
    d = np.abs(codes(a) - codes(b))
    return d.mean(), np.percentile(d, 99), d.max()


# --- 1. host tables ------------------------------------------------------------

def expected_psf(ref, family, strength, scale, warmth, over):
    if strength <= 0 or scale <= 0:
        return 0.0, []
    p_s = ref._strength_to_scatter(strength, family)
    if p_s <= 0:
        return 0.0, []
    overrides = {k: float(over.get(k, 1.0)) for k in ref._OVERRIDE_KEYS}
    if all(v == 1.0 for v in overrides.values()):
        overrides = None
    cfg = ref._resolve_family_cfg(family, overrides)
    eff = float(cfg.get("halo_warmth_base", 0.0)) + float(warmth)
    scale = max(float(scale), 1e-6)
    cl, cw = ref._expand_group(cfg["core"], kind="core")
    hl, hw = ref._expand_group(cfg["halo"], kind="halo")
    bl, bw = ref._expand_group(cfg["bloom"], kind="bloom")
    hc = ref._halo_channel_weights(hw, eff)
    exps = []
    for lam, w in zip(cl * scale, cw):
        exps.append([lam, cfg["w_c"] * w, cfg["w_c"] * w, cfg["w_c"] * w, 0])
    for k, lam in enumerate(hl * scale):
        exps.append([lam, cfg["w_h"] * hc[0][k], cfg["w_h"] * hc[1][k], cfg["w_h"] * hc[2][k], 1])
    for lam, w in zip(bl * scale, bw):
        exps.append([lam, cfg["w_b"] * w, cfg["w_b"] * w, cfg["w_b"] * w, 2])
    return p_s, exps


def host_tables(ref):
    if ref is None:
        print("SKIP host tables: the oracle (upstream diffusion.py) is not on this machine")
        return
    overs = [{}, {"core_intensity": 2.0, "halo_size": 0.5}, {"bloom_intensity": 0.0, "bloom_size": 3.0},
             {"halo_intensity": 4.0, "core_size": 0.25, "bloom_size": 0.25},
             {"core_intensity": 0.0, "halo_intensity": 0.0, "bloom_intensity": 0.0}]
    n = exact = 0
    worst = 0.0
    for family in FAMILIES:
        for strength in (0.0, 0.05, 0.125, 0.2, 0.25, 0.5, 0.7, 1.0, 1.5, 2.0):
            for warmth in (-1.5, -0.6, 0.0, 0.3, 0.85, 1.5):
                for scale in (0.25, 1.0, 2.7, 4.0):
                    for over in overs:
                        wire = {"diffusion_filter_active": True, "diffusion_filter_family": family,
                                "diffusion_filter_strength": strength, "diffusion_filter_spatial_scale": scale,
                                "diffusion_filter_halo_warmth": warmth}
                        wire.update({"diffusion_filter_" + k: v for k, v in over.items()})
                        got = lp.psf(wire)
                        p_s, exps = expected_psf(ref, family, strength, scale, warmth, over)
                        a = np.array([got["p_s"]] + [v for e in got["exps"] for v in e], np.float64)
                        b = np.array([p_s] + [v for e in exps for v in e], np.float64)
                        n += 1
                        if a.shape != b.shape:
                            worst = math.inf
                            continue
                        rel = np.abs(a - b) / np.maximum(np.abs(b), 1e-300)
                        worst = max(worst, float(rel.max()))
                        exact += int(np.array_equal(a, b))
    check(worst <= 1e-12, "host tables = the oracle's (p_s, lambdas, per-channel weights)",
          f"{n} configurations, {exact} bit-exact, worst relative {worst:.2e}")


# --- 2. impulse response and energy ------------------------------------------------

def impulse(ref):
    pitch, N = 8.0, 1601            # 8 um/px; the frame 12.8 mm across
    c = N // 2
    img = np.zeros((N, N, 3), np.float32)
    img[c, c] = 100.0   # a lamp: see the energy check below
    yy, xx = np.mgrid[0:N, 0:N]
    rr = np.hypot(yy - c, xx - c)
    for family in FAMILIES:
        p = {"diffusion_filter_active": True, "diffusion_filter_family": family, "diffusion_filter_strength": 1.0}
        out = lp.run(img, p, pitch).astype(np.float64) / 100.0
        p_s = lp.psf(p)["p_s"]
        K = out.copy()
        K[c, c] -= 1.0 - p_s
        K /= p_s
        # energy, where the PSF is inside the frame: the bloom of a wide family
        # runs past this frame's edge (8 lambda_max is 7.6 mm for cinebloom)
        tot = K.sum(axis=(0, 1))
        if ref is None:
            print(f"SKIP [{family}] impulse vs radial profile: no oracle")
            continue
        r_um = np.linspace(0, 6400, 64001)
        prof = ref.diffusion_filter_radial_profile(r_um, family=family)["total_per_channel"]   # (3, R) 1/um^2
        ee_an = np.cumsum(2 * np.pi * r_um * prof * (r_um[1] - r_um[0]), axis=1)
        # From 3 px: inside that, a pixel's whole energy counted at its centre's
        # radius is the binning's error, not the PSF's. To 400 px: past that the
        # widest blooms leave this frame, where the native grid replicates its
        # edge (as halation's does) and the oracle reflects -- the frame's
        # energy is printed below, not held.
        radii = np.array([3, 6, 12, 25, 50, 100, 200, 400])
        worst = 0.0
        rows = []
        for ch in range(3):
            order = np.argsort(rr, axis=None)
            cum = np.cumsum(K[..., ch].ravel()[order])
            rs = rr.ravel()[order]
            ee_n = np.interp(radii, rs, cum)
            ee_a = np.interp(radii * pitch, r_um, ee_an[ch])
            worst = max(worst, float(np.abs(ee_n - ee_a).max()))
            rows.append(ee_n - ee_a)
        detail = "EE(native) - EE(oracle) at r = " + ", ".join(f"{r:g}" for r in radii) + " px (G): " + \
                 " ".join(f"{v:+.4f}" for v in rows[1]) + f"; energy in the frame {tot[1]:.5f} vs oracle " \
                 f"{np.interp(c * pitch, r_um, ee_an[1]):.5f}"
        check(worst <= 0.02, f"[{family}] impulse response = the oracle's radial profile, encircled energy within 0.02",
              f"worst {worst:.4f}; {detail}")
    # energy with the whole PSF inside the frame: 40 um/px, black pro mist and
    # cinebloom at a quarter of their size
    # A lamp (100 x mid grey's 0.18 x 5): the pyramid's levels are fp16, and a
    # unit point spread over a 128 px level is 6e-5 a sample, half's smallest
    # normal -- a picture's light is not that faint, a test's point is. The
    # levels' edges keep light nearly, not exactly (lens.cpp `kMinLevelPx`):
    # 3e-4 is the bar.
    for family, scale in (("black_pro_mist", 1.0), ("cinebloom", 0.25), ("pro_mist", 0.5)):
        img = np.zeros((1201, 1201, 3), np.float32)
        img[600, 600] = 100.0
        out = lp.run(img, {"diffusion_filter_active": True, "diffusion_filter_family": family,
                           "diffusion_filter_strength": 2.0, "diffusion_filter_spatial_scale": scale}, 40.0)
        tot = out.astype(np.float64).sum(axis=(0, 1)) / 100.0
        check(np.abs(tot - 1).max() <= 3e-4, f"[{family} x{scale}] energy: sum out / sum in = 1 within 3e-4, per channel",
              " ".join(f"{t - 1:+.2e}" for t in tot))


# --- 3. image parity -------------------------------------------------------------

def test_image(w, h, seed=7):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    img = 0.02 + 0.3 * (x / w)[..., None] * np.array([1.0, 0.8, 0.6]) + 0.1 * (y / h)[..., None]
    img[h // 2 - 40:h // 2 + 40, w // 4:w // 4 + 120] = 3.0          # a lit window
    img[:, 3 * w // 4:] *= 0.2                                      # a dark side, a hard edge
    for _ in range(60):
        img[rng.integers(10, h - 10), rng.integers(10, w - 10)] = rng.uniform(5, 200)
    return (img * np.exp(0.1 * rng.standard_normal((h, w, 1)))).astype(np.float32)


class DF:   # what `apply_diffusion_filter_um` reads off its argument
    def __init__(self, **kw):
        self.active = True; self.filter_family = "black_pro_mist"; self.strength = 0.5
        self.spatial_scale = 1.0; self.halo_warmth = 0.0
        for k in ref_keys():
            setattr(self, k, 1.0)
        self.__dict__.update(kw)


def ref_keys():
    return ("core_intensity", "halo_intensity", "bloom_intensity", "core_size", "halo_size", "bloom_size")


def image_parity(ref):
    if ref is None:
        print("SKIP image parity: no oracle")
        return
    worst = {"fast": 0.0, "exact": 0.0}
    # At a fine pitch (6-8 um/px; 48 MP 35 mm is 4.3), with each family
    # scaled so the oracle's 8 lambda_max kernel fits in its min(H, W) / 2
    # (beyond it the oracle truncates and renormalises its PSF). Not at a
    # coarse pitch: there the oracle samples a sub-pixel exponential on pixel
    # centres, and its renormalisation moves weight into core and halo -- at
    # 60 um/px that is a mean of 140 codes against any continuous kernel.
    N = 1400
    img = test_image(N, N)
    m = (slice(150, N - 150), slice(150, N - 150))   # the oracle reflects at the edge, the native replicates
    for family, pitch, scale in (("glimmerglass", 6.0, 1.0), ("black_pro_mist", 6.0, 0.75),
                                 ("pro_mist", 8.0, 0.5), ("cinebloom", 8.0, 0.3)):
        for strength in (0.25, 1.0, 2.0):
            want = ref.apply_diffusion_filter_um(img.astype(np.float64),
                                                 DF(filter_family=family, strength=strength, spatial_scale=scale), pitch)
            p = {"diffusion_filter_active": True, "diffusion_filter_family": family,
                 "diffusion_filter_strength": strength, "diffusion_filter_spatial_scale": scale}
            got = lp.run(img, p, pitch)
            exact = lp.run(img, p, pitch, exact=True)
            mean, p99, mx = code_stats(got[m], want[m])
            em = code_stats(exact[m], want[m])
            check(mean <= 40 and p99 <= 260 and mx <= 1000,
                  f"[{family} x{scale}, {pitch:g} um/px, strength {strength:g}] image = apply_diffusion_filter_um's",
                  f"codes of 65,535: mean {mean:.2f}, p99 {p99:.0f}, max {mx:.0f} "
                  f"(the exact path: {em[0]:.2f}, {em[1]:.0f}, {em[2]:.0f})")
            if strength == 2.0:
                truth = lp.cell_truth(img, p, pitch)
                tm, te = code_stats(got[m], truth[m]), code_stats(exact[m], truth[m])
                fe = code_stats(got[m], exact[m])
                check(tm[0] <= 10 and tm[1] <= 60 and tm[2] <= 600,
                      f"[{family} x{scale}, {pitch:g} um/px, strength 2] image = the PSF integrated over each cell",
                      f"mean {tm[0]:.2f}, p99 {tm[1]:.0f}, max {tm[2]:.0f} (the exact path: {te[0]:.2f}, "
                      f"{te[1]:.0f}, {te[2]:.0f}); fast against exact: {fe[0]:.2f}, {fe[1]:.0f}, {fe[2]:.0f}")


# --- 4. bands ------------------------------------------------------------------------

def srgb_encode(x):
    x = np.asarray(x, np.float64)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.maximum(x, 0) ** (1 / 2.4) - 0.055)


def srgb_decode(v):
    v = np.asarray(v, np.float64)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def chunks_probe():
    """An encoded source: decoded into the pass's one frame, the combine in row
    chunks written back in place, encoded again."""
    lin = np.minimum(test_image(1500, 1000, seed=3), 1.0)        # an sRGB file's range
    enc = srgb_encode(lin).astype(np.float32)
    for family, pitch in (("black_pro_mist", 4.34), ("cinebloom", 4.34), ("glimmerglass", 24.0)):
        p = {"diffusion_filter_active": True, "diffusion_filter_family": family, "diffusion_filter_strength": 1.5,
             "input_cctf_decoding": True, "input_color_space": "sRGB"}
        one = lp.run(enc, p, pitch, chunk_rows=4096)
        lin_p = {k: v for k, v in p.items() if not k.startswith("input_")}
        lin_out = lp.run(srgb_decode(enc).astype(np.float32), lin_p, pitch)
        # In linear light, relative: the decode here and the GPU's differ in a
        # float's last bit, which can turn the rounding of an fp16 pyramid
        # sample (its 11 bits; the scattered light is up to half a pixel's) --
        # 2.5e-4 of the pixel at most, a few 16-bit codes of the encoded value.
        rel = np.abs(srgb_decode(one) - lin_out) / np.maximum(lin_out, 1e-3)
        d = np.abs(np.round(65535 * np.clip(one, 0, 1)) - np.round(65535 * np.clip(srgb_encode(lin_out), 0, 1)))
        check(rel.max() <= 5e-4, f"[{family} {pitch} um/px] an encoded source: decoded, lensed, encoded again",
              f"max {rel.max():.1e} of the linear value, {d.max():.0f} 16-bit codes of the encoded one")
        for rows in (64, 200, 336):
            b = lp.run(enc, p, pitch, chunk_rows=rows)
            check(np.array_equal(b, one), f"[{family} {pitch} um/px] the in-place combine in {rows}-row chunks = in one, byte for byte")


def bands_engine():
    """RFC-020's strips with the filter on. The filter is a pass on the source,
    so a striped render with it on is the striped render of the source
    filtered first, byte for byte."""
    w, h = 1500, 1000
    img = test_image(w, h, seed=5)
    e = spk.Engine()
    try:
        for family in ("black_pro_mist", "cinebloom"):
            f = {"diffusion_filter_active": True, "diffusion_filter_family": family, "diffusion_filter_strength": 1.0}
            pre = lp.run(img, f, 36.0 * 1000.0 / w)
            st = dict(BASE, film_format_mm=36.0, halation_active=True, striped=True, strip_rows=128)
            s = e.open(img, dict(st, **f)); a, _ = s.render("full"); s.close()
            s = e.open(pre, st); b, _ = s.render("full"); s.close()
            check(np.array_equal(a, b), f"[strips, {family}] the filter = the source filtered first, byte for byte",
                  f"max {np.abs(a.astype(np.int64) - b.astype(np.int64)).max()}")
    finally:
        e.close()


# --- 5. off is structural, 6. refusals ----------------------------------------------

def structural(base_dylib):
    img = test_image(900, 600, seed=9)
    off = {"diffusion_filter_active": False, "diffusion_filter_family": "cinebloom",
           "diffusion_filter_strength": 2.0, "diffusion_filter_halo_size": 3.0}
    for device in (None,):   # one profile: the whole render
        e = spk.Engine()
        try:
            s = e.open(img, dict(BASE, **off)); a, _ = s.render("full"); prog = s.progress(); s.close()
            s = e.open(img, BASE); b, _ = s.render("full"); s.close()
            check(np.array_equal(a, b), f"[{'banded' if device else 'whole'}] filter off with its fields set = not sent, byte for byte")
            s = e.open(img, dict(BASE, striped=True, strip_rows=100, **off)); s.render("full"); st = s.progress(); s.close()
            names = [x["name"] for seg in st.get("strip_segments", []) for x in seg["stages"]]
            s = e.open(img, dict(BASE, striped=True, strip_rows=100, diffusion_filter_active=True)); s.render("full")
            on = [x["name"] for seg in s.progress().get("strip_segments", []) for x in seg["stages"]]; s.close()
            check(names == on and "film_boost" in names and not any("lens" in n for n in on),
                  "the film plan is the same with the filter on: the lens is a pass on the source", str(on))
        finally:
            e.close()
        if base_dylib:
            eb = spk.Engine(dylib=Path(base_dylib))
            try:
                s = eb.open(img, BASE); c, _ = s.render("full"); s.close()
                check(np.array_equal(b, c), f"[{'banded' if device else 'whole'}] off = the base engine ({base_dylib}), byte for byte")
            finally:
                eb.close()
        else:
            print("SKIP off = the base engine: no --base-dylib")
    e = spk.Engine()
    try:
        try:
            s = e.open(img, dict(BASE, diffusion_filter_active=True, diffusion_filter_family="nonsense"))
            s.close(); check(False, "an unknown family is refused")
        except spk.EngineError as x:
            check("nonsense" in str(x), "an unknown family is refused", str(x)[:90])
        s = e.open(img, dict(BASE, diffusion_filter_active=True)); o, _ = s.render("full"); s.close()
        check(not np.array_equal(o, b), "the camera's filter renders (the refusal is lifted)")
    finally:
        e.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-dylib", default=os.environ.get("SPK_BASE_DYLIB"))
    args = ap.parse_args()
    ref = lp.oracle()
    host_tables(ref)
    impulse(ref)
    image_parity(ref)
    chunks_probe()
    bands_engine()
    structural(args.base_dylib)
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
