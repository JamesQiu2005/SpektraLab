#!/usr/bin/env python3
"""Build SpektraLab colour-film profiles from the curves `digitise.py` read off FUJIFILM's
"Professional Data Guide" (AF3-207U).

    PYTHONPATH=<spektrafilm@9428440>/src:<spektrafilm 0.3.x>/src:<lmfit> \
    python3 engine/tools/fujifilm_data_guide/build_profiles.py --raw RAW --refl REFL --sf-src <spektrafilm@9428440>/src \
        --engine-lib build/linux/engine/spektralab_engine.so --resources build/host-linux-x64/engine \
        --tests-dir engine/tests --scratch SCRATCH --out OUT stock [stock ...]

RAW is digitise.py's output; REFL holds munsell.asc (Zenodo 3269912), otsu.csv (enneract/otsu2018
CommonData/spectrum_m.csv), forest/*.dat (Zenodo 3269920, 390-850 nm) and japan.csv (Zenodo 5217752,
Reflectance_v1-2.csv). The factory is GPL-3.0 and is not vendored: check out spektrafilm at 9428440.

The chain is the one `engine/resources_product/NOTICE.md` describes for the Portra NC/VC profiles:

1. spektrafilm's own profile factory at commit 9428440 (GPL-3.0), unchanged, on the raw curves:
   D-min removed, log exposure anchored (negatives: green D 0.2 over D-min three stops under 0;
   slides: green at the 18 % transmittance density), C/M/Y dyes reconstructed from the sheet's
   midscale neutral and D-min (negatives: `dmid_dmin`, the generic starting dyes, masking couplers
   fitted) or taken as published (slides: Fujifilm draws each dye), densitometer cross-talk unmixed
   (Status M negatives, Status A slides), three normal CDFs per layer, sensitivities balanced to the
   reference illuminant.
2. The shipped profiles' form, by the rules the Portra NC/VC profiles use: each dye at unit
   densitometer density (curves scaled to match), sensitivity tails outside the plotted range as an
   exponential approach (tau 120 nm from the last plotted slope), sensitivities scaled so an sRGB
   18 % grey is exposure 1 (log 0) in every channel through hanatos2025 with no adaptation, the
   hanatos2025 window (erf4; widths held at the Portra NC profiles' 26.4 / 56.0 nm) and surface
   (poly4) fitted to the Otsu, Munsell, UEF forest and Japan natural-object reflectances under the
   reference illuminant, then upstream's grey-ramp correction (negatives: Portra Endura, -2..+6 EV;
   slides: scanned, -1..+2 EV; trustability 1) run through the SpektraLab engine, CDFs refitted and
   mid-grey re-anchored.
"""
from __future__ import annotations

import argparse
import copy
import datetime as _dt
import io
import json
import os
import shutil
import sys
import contextlib
from pathlib import Path

import numpy as np
import scipy.optimize
import scipy.special
import scipy.interpolate

os.environ.setdefault("MPLBACKEND", "Agg")

# spektrafilm @ 9428440 (profiles_factory, spectral_film_lab)
from profiles_factory import factory as F                               # noqa: E402
from spectral_film_lab.engine.density_curves import (                   # noqa: E402
    fit_density_curve, compute_density_curves, compute_density_curves_layers)
from spectral_film_lab.utils.io import load_densitometer_data           # noqa: E402
from profiles_factory.correct import align_midscale_neutral_exposures as align_mid  # noqa: E402

TODAY = _dt.date.today().isoformat()
WINDOW_SIGMAS = (26.4, 56.0)      # erf4 edge widths, as in kodak_portra_160nc.json and its three siblings
TAIL_TAU_NM = 120.0
WL = np.arange(380, 781, 5.0)
TRIM_DYE_400 = {"fujifilm_nexia_400", "fujifilm_nexia_800", "kodak_supra_200", "kodak_supra_400",
                "kodak_royal_supra_400", "kodak_high_definition_400"}


def quiet(fn, *a, **k):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        r = fn(*a, **k)
    return r, buf.getvalue()


# ============================================================================================ stage 1

def install_raw(raw: Path, stock: str, positive: bool, sf_src: Path, guide_offset: bool = True):
    """The factory reads its raw curves as package data; give it this film's folder."""
    kind = "positive" if positive else "negative"
    dst = sf_src / "spectral_film_lab" / "data" / "film" / kind / stock
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)
    names = (["dye_density_c", "dye_density_m", "dye_density_y"] if positive else ["dye_density_min", "dye_density_mid"])
    if not positive and (raw / stock / "dye_density_c.csv").exists():
        names += ["dye_density_c", "dye_density_m", "dye_density_y"]      # the sheet's own dyes (Kodak publishes them)
    for n in names + [f"log_sensitivity_{c}" for c in "rgb"] + [f"density_curve_{c}" for c in "rgb"]:
        shutil.copy(raw / stock / f"{n}.csv", dst / f"{n}.csv")
    if positive and guide_offset:
        # AF3-207U draws each slide dye 0.005-0.064 above zero where it absorbs nothing: yellow and magenta beyond
        # 650 nm read min(Y, M) > 0, where spektrafilm's source sheet for Velvia 100 reads 0.00. That constant is
        # subtracted from all three curves, which are renormalised to peak 1. Checked on two independent references:
        # Velvia 100 from the guide scans at C* 43.5 uncorrected, 46.2 corrected, against 46.0 from spektrafilm's raw
        # data and 45.1 shipped; Provia 100F corrected 36.0 against 36.5 shipped.
        wl_o = np.arange(650, 701, 5.0)
        yy, mm = (np.interp(wl_o, *np.loadtxt(dst / f"dye_density_{c}.csv", delimiter=",")[np.argsort(np.loadtxt(dst / f"dye_density_{c}.csv", delimiter=",")[:, 0])].T,
                            left=np.nan, right=np.nan) for c in "ym")
        v = np.where(np.isnan(yy), mm, np.where(np.isnan(mm), yy, np.minimum(yy, mm)))
        dye_offset = float(np.nanmean(v)) if np.isfinite(v).any() else 0.0
        for n in names:
            a = np.loadtxt(dst / f"{n}.csv", delimiter=",")
            a = a[np.argsort(a[:, 0])]
            y_ = a[:, 1] - dye_offset
            np.savetxt(dst / f"{n}.csv", np.column_stack([a[:, 0], y_ / y_.max()]), delimiter=",", fmt="%.6f")
        (dst / "dye_offset.txt").write_text(f"{dye_offset:.5f}\n")
        # A slide's dye is drawn only where Fujifilm drew it (Velvia 50's yellow stops at 600 nm, on its
        # baseline). The factory's loader leaves NaN outside a curve, and a densitometer sum that skips
        # those wavelengths reads as density (2.0 of yellow under Status A red). Hold each end value out
        # to 380 and 750 nm: ASSUMED, at the dye's own drawn baseline.
        for n in names:
            a = np.loadtxt(dst / f"{n}.csv", delimiter=",")
            lo = np.arange(380.0, a[0, 0] - 2.4, 5.0)
            hi = np.arange(np.ceil((a[-1, 0] + 2.5) / 5) * 5, 750.1, 5.0)
            a = np.vstack([np.column_stack([lo, np.full(len(lo), a[0, 1])]), a,
                           np.column_stack([hi, np.full(len(hi), a[-1, 1])])])
            np.savetxt(dst / f"{n}.csv", a, delimiter=",", fmt="%.6f")
    if not positive:
        # the factory reads C/M/Y starting dyes from the donor ('generic_a') and only min/mid from here
        pass
    shutil.copy(raw / stock / "info.txt", dst / "info.txt")
    if stock in TRIM_DYE_400:
        # Nexia 400 and 800: the sheet draws midscale and D-min down to ~385 nm, where the factory's
        # dmid_dmin scattering term, -log10(1 - s400 (400/wl)^4), is undefined for the fitted s400 and
        # lmfit drops residuals mid-fit. The points below 400 nm are left out (recorded in metadata).
        for n in names:
            a = np.loadtxt(dst / f"{n}.csv", delimiter=",")
            np.savetxt(dst / f"{n}.csv", a[a[:, 0] >= 400.0], delimiter=",", fmt="%.6f")


def cdf_fit(le, dc, kind):
    p = np.zeros((3, 9))
    for i in range(3):
        p[i] = fit_density_curve(le, dc[:, i], kind)
    return p


args_sf_src_global = "."


def factory(stock, sheet, ref_ill):
    positive = sheet["positive"]
    kind = "positive" if positive else "negative"
    dens = "status_A" if positive else "status_M"
    log = {}
    if positive:
        p, out = quiet(F.create_profile, stock=stock, name=sheet["name"], type="positive", densitometer=dens,
                       reference_illuminant=ref_ill, log_sensitivity_density_over_min=1.0)
        raw = copy.deepcopy(p)
        p, _ = quiet(F.remove_density_min, p)
        p, _ = quiet(F.adjust_log_exposure, p)
        sheet_curves = p.data.density_curves.copy()          # Status A over D-min, on the anchored axis
        p, _ = quiet(F.unmix_density, p)
        unmixed = p.data.density_curves.copy()
        p, _ = quiet(F.replace_fitted_density_curves, p)
        p, _ = quiet(F.balance_sensitivity, p)
        p, _ = quiet(F.replace_fitted_density_curves, p)
        log["dye_model"] = "published C/M/Y spectral dye densities (normalised to peak 1.0, 'separated light')"
        off_f = Path(args_sf_src_global) / "spectral_film_lab" / "data" / "film" / "positive" / stock / "dye_offset.txt"
        if off_f.exists():
            log["dye_offset_removed"] = float(off_f.read_text())
    else:
        p, out = quiet(F.create_profile, stock=stock, name=sheet["name"], type="negative", densitometer=dens,
                       dye_density_cmy_donor=sheet.get("dye_donor", "generic_a"), reference_illuminant=ref_ill,
                       log_sensitivity_density_over_min=1.0)
        raw = copy.deepcopy(p)
        p, _ = quiet(F.remove_density_min, p)
        p, _ = quiet(F.adjust_log_exposure, p)
        sheet_curves = p.data.density_curves.copy()
        p, _ = quiet(F.reconstruct_dye_density, p, control_plot=False, model="dmid_dmin")
        dd = p.data.dye_density
        # how well the reconstructed dyes + D-min reproduce the sheet's midscale neutral
        coeff = F.find_midscale_neutral_coefficients(dd)
        sim = np.nansum(dd[:, :3] * coeff, axis=1) + dd[:, 3]
        sel = ~np.isnan(raw.data.dye_density[:, 4])
        log["dye_mid_residual_rms_D"] = float(np.sqrt(np.nanmean((sim - raw.data.dye_density[:, 4])[sel] ** 2)))
        log["dye_mid_residual_max_D"] = float(np.nanmax(np.abs(sim - raw.data.dye_density[:, 4])[sel]))
        p, _ = quiet(F.unmix_density, p)
        unmixed = p.data.density_curves.copy()
        p, _ = quiet(F.replace_fitted_density_curves, p)
        p, _ = quiet(F.balance_sensitivity, p)
        p, _ = quiet(F.replace_fitted_density_curves, p)
        log["dye_model"] = ("dmid_dmin (" + ("the sheet's own C/M/Y as starting dyes" if sheet.get("dye_donor", "generic_a") is None
                                             else "generic_a starting dyes") + ", masking couplers fitted)")
        align = os.environ.get("ALIGN_MID", "none")
        if align != "none":
            # upstream's make_profiles row for Fujifilm Pro 400H ('mid') / C200 ('green'): each layer's curve
            # moved so it reaches the sheet's midscale-neutral amount at one exposure
            p, _ = quiet(align_mid, p, None if align == "mid" else align)
            p, _ = quiet(F.replace_fitted_density_curves, p)
        log["align_midscale_neutral"] = align
    # CDF residual against the unmixed sheet curves where the sheet has data (before balance shifts)
    le = raw.data.log_exposure
    prm = cdf_fit(le, unmixed, kind)
    fitted = compute_density_curves(le, prm, kind)
    sel = ~np.isnan(unmixed).any(axis=1)
    log["cdf_residual_rms_D"] = float(np.sqrt(np.mean((fitted - unmixed)[sel] ** 2)))
    log["cdf_residual_max_D"] = float(np.max(np.abs(fitted - unmixed)[sel]))
    log["sheet_curve_range_logH"] = [float(le[sel].min()), float(le[sel].max())]
    return p, raw, log


# ============================================================================================ stage 2

def unit_densitometer(p):
    """Each dye at unit densitometer density; curves (and so the image) unchanged."""
    dd = p.data.dye_density
    dst = load_densitometer_data(type=p.info.densitometer)
    M = F.compute_densitometer_crosstalk_matrix(dst, dd[:, :3])
    k = np.diag(M).copy()
    dd[:, :3] = dd[:, :3] / k
    p.data.density_curves = p.data.density_curves * k
    return k


def sensitivity_tails(ls):
    """Outside the plotted range: an exponential approach from the last plotted slope (tau 120 nm),
    falling away from the band in every case."""
    out = ls.copy()
    for c in range(3):
        y = ls[:, c]
        ok = np.where(np.isfinite(y))[0]
        i0, i1 = ok[0], ok[-1]
        def slope(a, b):
            return (y[b] - y[a]) / (WL[b] - WL[a])
        # right tail
        s = slope(max(i1 - 3, i0), i1)
        s = min(s, -0.01)
        for i in range(i1 + 1, len(WL)):
            d = WL[i] - WL[i1]
            out[i, c] = y[i1] + s * TAIL_TAU_NM * (1 - np.exp(-d / TAIL_TAU_NM))
        s = slope(i0, min(i0 + 3, i1))
        s = max(s, 0.01)
        for i in range(0, i0):
            d = WL[i0] - WL[i]
            out[i, c] = y[i0] - s * TAIL_TAU_NM * (1 - np.exp(-d / TAIL_TAU_NM))
    return out


class Hanatos:
    """hanatos2025 through spektrafilm 0.3.x's own functions (the code the engine ports)."""

    def __init__(self, ref_ill):
        from spektrafilm.utils import spectral_upsampling as su
        from spektrafilm.model.illuminants import standard_illuminant
        from spektrafilm.config import STANDARD_OBSERVER_CMFS
        self.su = su
        self.ill = np.asarray(standard_illuminant(ref_ill), float)
        self.cmfs = np.asarray(STANDARD_OBSERVER_CMFS[:], float)
        self.ref = ref_ill
        lut = su.HANATOS2025_SPECTRA_LUT
        v = np.linspace(0, 1, lut.shape[0])
        self.interp = scipy.interpolate.RegularGridInterpolator((v, v), lut)

    def grey_raw(self, sens):
        rgb = np.array([0.184, 0.184, 0.184])
        tc, b = self.su._rgb_to_tc_b(rgb, color_space="sRGB", apply_cctf_decoding=False, reference_illuminant=self.ref)
        spec = self.interp(tc[None, :])[0] * b
        return spec @ sens

    def prepare(self, refl):
        """refl: (N, 81) reflectances. Light under the reference illuminant, its tc and b."""
        light = refl * self.ill[None, :]
        xyz = light @ self.cmfs
        b = xyz.sum(1)
        xy = xyz[:, :2] / b[:, None]
        tc = self.su._tri2quad(xy)
        spec = self.interp(tc)
        white = self.ill @ self.cmfs
        self.samples = dict(light=light, tc=tc, b=b / white.sum(), spec=spec)
        tcw = self.su._tri2quad((white[:2] / white.sum())[None, :])
        self.white = dict(light=self.ill[None, :], tc=tcw, b=np.array([1.0]), spec=self.interp(tcw))
        self.centre = self.su._tri2quad(np.array(self.su._illuminant_to_xy(self.ref)))

    def window(self, prm):
        return self.su.eval_erf4_spectral_bandpass(np.asarray(prm, float))

    def predict(self, sens, wprm, surf, which):
        S = self.samples if which == "s" else self.white
        w = self.window(wprm) if wprm is not None else np.ones_like(sens)
        if wprm is not None:
            norm = (sens * self.ill[:, None] * w).sum(0) / (sens * self.ill[:, None]).sum(0)
            w = w / norm
        raw = (S["spec"] @ (sens * w)) * S["b"][:, None]
        if surf is not None:
            corr = np.zeros_like(raw)
            for c in range(3):
                z = self.su.poly2d_deg4(S["tc"], np.concatenate([[0.0], surf[c]]), center_tc=tuple(self.centre))
                corr[:, c] = self.su.hanika_sigmoid(z, self.su._HANATOS2025_MAX_CORRECTION_STOPS)
            raw = raw * 2.0 ** corr
        return raw

    def truth(self, sens, which):
        S = self.samples if which == "s" else self.white
        return S["light"] @ sens

    def err_stops(self, sens, wprm, surf, weights):
        p = self.predict(sens, wprm, surf, "s") / self.predict(sens, wprm, surf, "w")
        t = self.truth(sens, "s") / self.truth(sens, "w")
        e = np.log2(np.clip(p, 1e-9, None) / np.clip(t, 1e-9, None))
        return e * np.sqrt(weights)[:, None]

    def fit(self, sens, weights, w0):
        def rms(e):
            return float(np.sqrt(np.mean(e ** 2) / np.mean(weights)))
        e0 = self.err_stops(sens, None, None, weights)
        s_uv, s_ir = WINDOW_SIGMAS
        res_w = lambda x: self.err_stops(sens, [x[0], s_uv, x[1], s_ir], None, weights).ravel()
        fw = scipy.optimize.least_squares(res_w, w0, bounds=([380, 560], [470, 780]))
        wprm = [float(fw.x[0]), s_uv, float(fw.x[1]), s_ir]
        e1 = self.err_stops(sens, wprm, None, weights)
        res_s = lambda x: self.err_stops(sens, wprm, x.reshape(3, 14), weights).ravel()
        fs = scipy.optimize.least_squares(res_s, np.zeros(42), x_scale=1.0)
        surf = fs.x.reshape(3, 14)
        e2 = self.err_stops(sens, wprm, surf, weights)
        return wprm, np.concatenate([np.zeros((3, 1)), surf], axis=1), {
            "rms_stops_no_adaptation": rms(e0), "rms_stops_window": rms(e1), "rms_stops_window_surface": rms(e2)}


def load_reflectances(d: Path):
    sets = {}
    m = np.loadtxt(d / "munsell.asc").reshape(1269, 421)        # 380..800 nm, 1 nm
    sets["munsell"] = np.array([np.interp(WL, np.arange(380, 801), r) for r in m])
    o = np.genfromtxt(d / "otsu.csv", delimiter=",", skip_header=1)[:, 1:]   # 380..730, 10 nm
    wl_o = np.arange(380, 731, 10)
    sets["otsu2018"] = np.array([np.interp(WL, wl_o, r) for r in o])
    fr = []
    for f in sorted((d / "forest").glob("*.dat")):
        v = np.loadtxt(f).ravel()
        v = v.reshape(-1, 93)                                       # 390..850, 5 nm (README)
        fr.append(v)
    fr = np.vstack(fr)
    sets["uef_forest"] = np.array([np.interp(WL, np.arange(390, 851, 5), r) for r in fr])
    import csv
    rows = []
    with open(d / "japan.csv", encoding="utf-8-sig") as fh:
        rd = csv.reader(fh)
        head = next(rd)
        wcols = [i for i, h in enumerate(head) if h.strip().split(" ")[0].replace("[nm]", "").strip().isdigit()]
        wl_j = np.array([float(head[i].split(" ")[0].replace("[nm]", "")) for i in wcols])
        for r in rd:
            try:
                rows.append([float(r[i]) for i in wcols])
            except (ValueError, IndexError):
                pass
    j = np.array(rows)
    sets["japan_natural"] = np.array([np.interp(WL, wl_j, r) for r in j])
    allr, wts = [], []
    for k, v in sets.items():
        v = np.clip(v, 0, 1.5)
        allr.append(v)
        wts.append(np.full(len(v), 1.0 / len(v)))                  # each set weighs the same
    return np.vstack(allr), np.concatenate(wts) * 1000.0, {k: len(v) for k, v in sets.items()}


# ============================================================================================ JSON

def nanlist(a):
    """Nested lists with NaN as null, as the product's other profiles store it."""
    a = np.asarray(a, float)
    if a.ndim > 1:
        return [nanlist(x) for x in a]
    return [None if not np.isfinite(v) else float(v) for v in a]


def to_json(p, prm, kind, wprm, surf):
    dd = p.data.dye_density
    le = np.asarray(p.data.log_exposure, float)
    return {
        "wavelengths": WL.tolist(),
        "log_sensitivity": nanlist(p.data.log_sensitivity),
        "hanatos2025_adaptation_window_params": [float(v) for v in wprm],
        "hanatos2025_adaptation_surface_params": nanlist(surf),
        "channel_density": nanlist(dd[:, :3]),
        "base_density": nanlist(dd[:, 3]),
        "midscale_neutral_density": nanlist(dd[:, 4]),
        "log_exposure": le.tolist(),
        "density_curves": nanlist(compute_density_curves(le, prm, kind)),
        "density_curves_layers": nanlist(compute_density_curves_layers(le, prm, kind)),
        "density_curves_model": {"model_type": "cdfs", "centers": nanlist(prm[:, 0:3]),
                                 "amplitudes": nanlist(prm[:, 3:6]), "sigmas": nanlist(prm[:, 6:9])},
    }


# ============================================================================================ engine

QUIET = {"grain_active": False, "glare_active": False, "halation_active": False, "auto_exposure": False,
         "input_cctf_decoding": False, "input_color_space": "sRGB", "output_color_space": "sRGB",
         "output_cctf_encoding": False}


class EngineLoop:
    def __init__(self, lib, resources, tests_dir, scratch):
        sys.path.insert(0, str(tests_dir))
        import spk_ctypes as spk
        self.res = Path(scratch) / "resources"
        # kept between runs: profiles built earlier stay beside the staged ones
        (self.res / "profiles").mkdir(parents=True, exist_ok=True)
        for f in Path(resources).iterdir():
            if f.name != "profiles" and not (self.res / f.name).exists():
                os.symlink(f.resolve(), self.res / f.name)
        for f in (Path(resources) / "profiles").glob("*.json"):
            if not (self.res / "profiles" / f.name).exists():
                os.symlink(f.resolve(), self.res / "profiles" / f.name)
        self.e = spk.Engine(library=lib, resources=self.res)
        self.grey = np.full((8, 8, 3), 0.184, np.float32)

    def put(self, stock, doc):
        path = self.res / "profiles" / f"{stock}.json"
        if path.is_symlink():
            path.unlink()
        path.write_text(json.dumps(doc))

    def pack(self, film, paper):
        import packfit
        return packfit.fit_pack(self.e, film, paper)

    def ramp(self, film, paper, evs, scan, pack=None):
        p = dict(QUIET, film_stock=film)
        if scan:
            p.update(scan_film=True, print_stock="kodak_portra_endura")
        else:
            p.update(print_stock=paper, c_filter_neutral=pack[0][0], m_filter_neutral=pack[0][1],
                     y_filter_neutral=pack[0][2], print_exposure=pack[1])
        s = self.e.open(self.grey, p)
        try:
            out = []
            for ev in evs:
                s.set_params({"exposure_compensation_ev": float(ev)})
                rgba, _ = s.render("full")
                out.append(rgba[2:-2, 2:-2, :3].astype(np.float64).mean((0, 1)) / 65535.0)
        finally:
            s.close()
        return np.array(out)


def shift_scale(p0, prm, kind, scale, shift):
    """upstream's apply_scale_shift_stretch_density_curves on the CDF model: amplitudes scaled,
    centres moved (the same as scaling and shifting the curve)."""
    q = prm.copy()
    for c in range(3):
        q[c, 3:6] *= scale[c]
        q[c, 0:3] += shift[c]
    return q


def anchor(le, prm, kind, M):
    """Mid grey at log exposure 0 (upstream's adjust_log_exposure): negatives put green's D 0.2 over
    D-min three stops under 0; slides put green's 18 % transmittance density at 0. Both read in
    densitometer density (M: the dyes' cross-talk), as the factory does before it unmixes."""
    dc = compute_density_curves(le, prm, kind) @ np.asarray(M).T
    g = dc[:, 1] - np.nanmin(dc[:, 1])
    if kind == "negative":
        x = np.interp(0.2, g, le) + np.log10(2 ** 3)
    else:
        x = np.interp(-np.log10(1 / 0.184), -g, le)
    q = prm.copy()
    q[:, 0:3] -= x
    return q, float(x)


def build(stock, raw: Path, args, eng: EngineLoop, refl, wts, refl_counts):
    sheet = json.loads((raw / stock / "sheet.json").read_text())
    sheet["stock"] = stock
    positive = sheet["positive"]
    kind = "positive" if positive else "negative"
    tungsten = sheet.get("tungsten", "Tungsten" in sheet.get("subtitle", "") or "Tungsten" in sheet.get("title", ""))
    paper = sheet.get("ramp_paper", "kodak_portra_endura")
    ref_ill = "T" if tungsten else "D55"
    global args_sf_src_global
    args_sf_src_global = args.sf_src
    # the dye-offset correction belongs to the Fujifilm guide's slide sheets only (they carry `printed_page`)
    install_raw(raw, stock, positive, Path(args.sf_src), guide_offset="printed_page" in sheet)
    p, rawp, log = factory(stock, sheet, ref_ill)

    k = unit_densitometer(p)
    log["densitometer_normalisation"] = k.tolist()

    # tails, then the level: sRGB 18 % grey -> exposure 1 in each channel
    ls = sensitivity_tails(np.asarray(p.data.log_sensitivity, float))
    h = Hanatos(ref_ill)
    raw_grey = h.grey_raw(10 ** ls)
    ls = ls - np.log10(raw_grey)[None, :]
    log["grey_level_per_channel_log10"] = (-np.log10(raw_grey)).round(4).tolist()
    p.data.log_sensitivity = ls

    # midscale neutral for slides: the dyes at the anchored mid grey over the base
    le = np.asarray(p.data.log_exposure, float)
    prm = cdf_fit(le, p.data.density_curves, kind)
    if positive:
        d0 = compute_density_curves(np.array([0.0]), prm, kind)[0]
        p.data.dye_density[:, 4] = np.nansum(p.data.dye_density[:, :3] * d0, axis=1) + p.data.dye_density[:, 3]
        p.data.dye_density[np.isnan(p.data.dye_density[:, :3]).all(axis=1), 4] = np.nan

    # hanatos2025 window + surface
    h.prepare(refl)
    wprm, surf, hlog = h.fit(10 ** ls, wts, [410.0, 640.0])
    log["hanatos2025"] = dict(hlog, reflectance_sets=refl_counts)

    info = {
        "stock": stock, "name": sheet["name"], "type": kind, "support": "film", "stage": "filming",
        "use": "still", "antihalation": "strong",
        "target_print": None if positive else sheet.get("target_print", "fujifilm_crystal_archive_typeii"),
        "channel_model": "color", "densitometer": "status_A" if positive else "status_M",
        "log_sensitivity_density_over_min": float(sheet.get("sensitivity_density_over_min") or 1.0),
        "reference_illuminant": ref_ill, "viewing_illuminant": "D50",
    }

    # grey-ramp correction through the engine
    evs = [-1, 0, 1, 2] if positive else [-2, -1, 0, 1, 2, 3, 4, 5, 6]
    # upstream's make_profiles rows for its three Fujifilm negatives (Pro 400H, X-Tra 400, C200) use 0.3;
    # on the Pro 400H sheet it reproduces the shipped profile closest (dE2000 1.9 against 2.6 at 1.0)
    trust = float(os.environ.get("TRUST", sheet.get("trust", "1.0" if positive else "0.3")))
    M = F.compute_densitometer_crosstalk_matrix(load_densitometer_data(type=p.info.densitometer), p.data.dye_density[:, :3])
    log["densitometer_crosstalk"] = np.round(M, 4).tolist()
    prm, _ = anchor(le, prm, kind, M)

    def doc_for(q):
        return {"info": info, "data": to_json(p, q, kind, wprm, surf), "metadata": {}}

    pack = None
    if not positive:
        # upstream fits the print filters once, on the uncorrected film, then fits the ramp with them
        eng.put(stock, doc_for(prm))
        pack = eng.pack(stock, paper)

    def residual(x):
        # the shifts ride on 1 so the finite-difference step is not zero (scipy's step is relative)
        q = shift_scale(None, prm, kind, x[0:3], [x[3] - 1, 0.0, x[4] - 1])
        eng.put(stock, doc_for(q))
        g = eng.ramp(stock, paper, evs, positive, pack)
        if positive:
            m = g.mean(axis=1, keepdims=True)
            r = (g - m) / m * 0.184
        else:
            r = g - 0.184
        return np.concatenate([r.ravel(), 2.0 * (np.asarray(x[0:3]) - 1) * trust])

    r0 = residual(np.array([1, 1, 1, 1, 1.0]))
    # a 1e-3 step in log exposure moves a 16-bit render by less than its own quantum: step 1e-2
    fit = scipy.optimize.least_squares(residual, [1, 1, 1, 1, 1.0], diff_step=1e-2, max_nfev=80)
    x = fit.x.copy()
    x[3:5] -= 1
    log["grey_ramp"] = {"paper": None if positive else paper, "scanned": positive, "ev": evs,
                        "trustability": trust, "print_pack_portra_endura": None if pack is None else [round(v, 3) for v in pack[0]] + [round(pack[1], 4)],
                        "density_scale": x[0:3].round(4).tolist(),
                        "log_exposure_shift_r_b": [round(float(x[3]), 4), round(float(x[4]), 4)],
                        "rms_before": float(np.sqrt(np.mean(r0[:-3] ** 2))),
                        "rms_after": float(np.sqrt(np.mean(fit.fun[:-3] ** 2)))}
    prm = shift_scale(None, prm, kind, x[0:3], [x[3], 0.0, x[4]])
    # refit (the model is the curve) and re-anchor mid grey
    dc = compute_density_curves(le, prm, kind)
    prm = cdf_fit(le, dc, kind)
    prm, moved = anchor(le, prm, kind, M)
    log["reanchor_logH"] = moved
    if positive:
        # A slide is anchored by what the engine does with it: an sRGB 18 % grey scans back at 18 %
        # (mean of the three channels), as spektrafilm's shipped slides do (0.181-0.190 through this engine).
        def scan_err(t):
            q = prm.copy(); q[:, 0:3] += t
            eng.put(stock, doc_for(q))
            return float(eng.ramp(stock, None, [0], True)[0].mean()) - 0.184
        t = scipy.optimize.brentq(scan_err, -2.5, 2.5, xtol=1e-4)
        prm[:, 0:3] += t
        log["scan_anchor_logH"] = float(t)
    doc = doc_for(prm)
    doc["metadata"] = metadata(sheet, log, ref_ill, positive)
    eng.put(stock, doc)
    return doc


def metadata(sheet, log, ref_ill, positive):
    if sheet.get("cine"):
        return metadata_cine(sheet, log, ref_ill)
    pg = sheet["printed_page"]
    ax = {k: {a: (None if sheet[k][a] is None else
                  ({"relative_decade_pt": round(sheet[k][a]["decade_pt"], 3)} if sheet[k][a].get("relative") else
                   {"labels": sheet[k][a]["n_labels"], "residual_max": round(sheet[k][a]["residual_max"], 4)}))
              for a in "xy"} for k in ("axes_sensitivity", "axes_dye", "axes_characteristic")}
    dens = "Status A" if positive else "Status M"
    proc = sheet.get("process")
    if positive:
        method = ("spektrafilm's profile factory (9428440, GPL-3.0): D-min removed (and laid in as base), green at the 18 % "
                  "transmittance density put at log exposure 0, Status A unmixed through the published C/M/Y dyes, three "
                  "normal CDFs per layer, " + ref_ill + " balance; then the shipped profiles' form reproduced from them: each "
                  "dye at unit Status A density, sensitivity tails as an exponential approach (tau 120 nm), an sRGB 18 % grey at "
                  "log exposure 0 through hanatos2025 (adaptation off), hanatos2025 window (erf4, widths 26.4/56.0 nm as the "
                  "Portra NC/VC product profiles) + surface (poly4) fitted to Otsu, Munsell, UEF forest and Japan natural-object "
                  "reflectances under " + ref_ill + ", upstream's positive grey-ramp correction (scanned, -1..+2 EV, trustability "
                  "1) run through the SpektraLab engine, CDFs refitted, mid grey re-anchored.")
    else:
        method = ("spektrafilm's profile factory (9428440, GPL-3.0): D-min removed, speed point (green D 0.2) three stops "
                  "under 0, C/M/Y dyes reconstructed from midscale neutral and D-min (dmid_dmin, generic starting dyes, "
                  "masking couplers fitted), Status M unmixed, three normal CDFs per layer, " + ref_ill + " balance; then the "
                  "shipped profiles' form reproduced from them: each dye at unit Status M density, sensitivity tails as an "
                  "exponential approach (tau 120 nm), an sRGB 18 % grey at log exposure 0 through hanatos2025 (adaptation off), "
                  "hanatos2025 window (erf4, widths 26.4/56.0 nm as the Portra NC/VC product profiles) + surface (poly4) fitted "
                  "to Otsu, Munsell, UEF forest and Japan natural-object reflectances under " + ref_ill + ", upstream's grey-ramp "
                  "correction (Portra Endura, -2..+6 EV, trustability 1) run through the SpektraLab engine, CDFs refitted, mid "
                  "grey re-anchored.")
    tags = {
        "log_sensitivity": "SHEET inside the plotted range (" + ("absolute log axis" if positive else
                           "relative axis: one grid interval = one decade, the sheet's '1.0' bar") +
                           "); ASSUMED tails (exponential approach); level FITTED (sRGB 18 % grey -> 0)",
        "density_curves": f"SHEET ({dens}, unmixed), FITTED (3 CDFs per layer, grey-ramp scale/shift); ASSUMED beyond the plotted exposures (the CDFs' own toe and shoulder)",
        "channel_density": ("SHEET (C/M/Y spectral dye density, 'separated light', peak 1.0) less the sheet's constant offset "
                            f"({log.get('dye_offset_removed', 0):.3f}: min(Y, M) at 650-700 nm), rescaled to unit Status A density"
                            if positive else "FITTED to the sheet's midscale neutral minus D-min (dmid_dmin model)"),
        "base_density": ("FITTED (the characteristic curves' D-min, smoothed across the Status A peaks)" if positive
                         else "SHEET (D-min curve; none outside the plotted range)"),
        "midscale_neutral_density": ("DERIVED (the dyes at mid grey over the base)" if positive
                                     else "SHEET (midscale neutral curve; none outside the plotted range)"),
        "hanatos2025_adaptation": "FITTED (reflectance sets above; window widths held at the Portra NC/VC product profiles')",
        "info": ("SHEET: process " + str(proc) + ", " + sheet.get("subtitle", "") +
                 "; ASSUMED antihalation strong, " + ref_ill + " reference, " +
                 ("no print (scanned)" if positive else "target print Crystal Archive Type II")),
    }
    if sheet["stock"] in TRIM_DYE_400:
        tags["midscale_neutral_density"] += "; the sheet's points below 400 nm left out (the factory's scattering term is undefined there)"
    if sheet.get("characteristic_hidden_fill"):
        tags["density_curves"] += ("; where the sheet draws one line for coinciding records, the hidden records take that line "
                                   "(fraction of the plotted range: " + json.dumps(sheet["characteristic_hidden_fill"]) + ")")
    if sheet.get("extra_dashed_sensitivity"):
        tags["fourth_layer"] = ("SHEET draws a fourth, cyan-sensitive layer (dashed; Fujifilm's 4th colour layer). NOT MODELLED: "
                                "the schema has three channels; its interlayer effect is not represented.")
    return {
        "version": "spektralab-" + TODAY,
        "created": TODAY,
        "datasource": (f"FUJIFILM PROFESSIONAL DATA GUIDE, publication AF3-207U (FUJIFILM, 2005), p. {pg}: "
                       f"{sheet['title'].strip()}, {sheet.get('subtitle','').strip()}; spectral sensitivity (density "
                       f"{sheet.get('sensitivity_density_over_min')} over D-min), characteristic curves ({dens}, {proc}), "
                       + ("spectral dye density (C/M/Y)" if positive else "spectral dye density (midscale neutral and D-min)")
                       + ", digitised from the PDF's vector paths"),
        "copyright": "SpektraLab product data. Not a spektrafilm profile; no array is read from one.",
        "license": "Built from FUJIFILM publication AF3-207U. See engine/resources_product/NOTICE.md.",
        "method": method,
        "tags": tags,
        "digitisation": {"axes": ax, "rms_granularity_sheet": sheet.get("rms_granularity"),
                         "labels_note": "axis residual = largest gap between a tick label's value and the line fitted through the grid lines it labels"},
        "fit_residuals": log,
    }


def metadata_cine(sheet, log, ref_ill):
    if sheet.get("positive"):
        return metadata_slide(sheet, log, ref_ill)
    ch = sheet["charts"]
    ax = {k: {a: {"residual_max": round(ch[k][a]["residual_max"], 4), "source": ch[k][a]["source"]} for a in "xy"} for k in ch}
    own = sheet.get("dye_donor", "generic_a") is None
    tags = {
        "log_sensitivity": f"SHEET inside the plotted range (density {sheet['sensitivity_density_over_min']} over D-min); ASSUMED tails "
                           "(exponential approach); level FITTED (sRGB 18 % grey -> 0)",
        "density_curves": "SHEET (Status M, unmixed), FITTED (3 CDFs per layer, grey-ramp scale/shift on " + sheet["ramp_paper"] +
                          "); ASSUMED beyond the plotted exposures",
        "channel_density": ("FITTED to the sheet's midscale neutral minus D-min, starting from the sheet's own C/M/Y dyes" if own
                            else "FITTED to the sheet's midscale neutral minus D-min (dmid_dmin, generic starting dyes)"),
        "base_density": sheet.get("min_tag", "SHEET (D-min curve; none outside the plotted range)"),
        "midscale_neutral_density": sheet.get("mid_tag", "SHEET (midscale neutral curve; none outside the plotted range)"),
        "hanatos2025_adaptation": "FITTED (reflectance sets; window widths held at the Portra NC/VC product profiles')",
        "info": f"SHEET: {sheet.get('process', 'ECN-2')}, {'tungsten' if sheet['tungsten'] else 'daylight'} balance; ASSUMED antihalation "
                f"strong{' (rem-jet)' if sheet.get('process', 'ECN-2') == 'ECN-2' else ''}, {ref_ill} reference, target print {sheet['target_print']}",
    }
    for k, v in sheet.get("extra_tags", {}).items():
        tags[k] = v
    return {
        "version": "spektralab-" + TODAY, "created": TODAY,
        "datasource": sheet["source"] + f": spectral sensitivity, characteristic curves (Status M, {sheet.get('process', 'ECN-2')}) and spectral dye density, "
                      "digitised from the PDF's vector paths",
        "copyright": "SpektraLab product data. Not a spektrafilm profile; no array is read from one.",
        "license": "Built from the manufacturer's published data sheet. See engine/resources_product/NOTICE.md.",
        "method": ("spektrafilm's profile factory (9428440, GPL-3.0): D-min removed, speed point (green D 0.2) three stops under 0, "
                   "C/M/Y dyes reconstructed from midscale neutral and D-min (dmid_dmin" + (", the sheet's own dyes as start" if own else
                   ", generic starting dyes") + ", masking couplers fitted), Status M unmixed, three normal CDFs per layer, "
                   f"{ref_ill} balance; then the shipped profiles' form reproduced from them as for the Portra NC/VC and Fujifilm "
                   f"AF3-207U product profiles, with upstream's grey-ramp correction on {sheet['ramp_paper']} (-2..+6 EV, trustability "
                   f"{sheet.get('trust', 0.3)}, upstream's setting for its {'Kodak still' if sheet.get('process') == 'C-41' else 'Vision3'} rows) "
                   "run through the SpektraLab engine."),
        "tags": tags,
        "digitisation": {"axes": ax},
        "fit_residuals": log,
    }


def metadata_slide(sheet, log, ref_ill):
    ch = sheet.get("charts", {})
    ax = {k: {a: {"residual_max": round(ch[k][a]["residual_max"], 4), "source": ch[k][a]["source"]} for a in "xy"} for k in ch}
    tags = {
        "log_sensitivity": f"SHEET inside the plotted range (density {sheet.get('sensitivity_density_over_min', 1.0)} over D-min); "
                           "ASSUMED tails (exponential approach); level FITTED (sRGB 18 % grey -> 0)",
        "density_curves": "SHEET (Status A, unmixed through the published dyes), FITTED (3 CDFs per layer, grey-ramp scale/shift, "
                          "scanned); ASSUMED beyond the plotted exposures",
        "channel_density": "SHEET (C/M/Y spectral dye density as published, normalised by the maker to a visual neutral of 1.0), "
                           "rescaled to unit Status A density",
        "base_density": "FITTED (the characteristic curves' D-min, smoothed across the Status A peaks)",
        "midscale_neutral_density": "DERIVED (the dyes at mid grey over the base)",
        "hanatos2025_adaptation": "FITTED (reflectance sets; window widths held at the Portra NC/VC product profiles')",
        "info": f"SHEET: {sheet.get('process', 'E-6')}, {'tungsten' if sheet.get('tungsten') else 'daylight'} balance; "
                f"ASSUMED antihalation strong, {ref_ill} reference, no print (scanned)",
    }
    for k, v in sheet.get("extra_tags", {}).items():
        tags[k] = v
    return {
        "version": "spektralab-" + TODAY, "created": TODAY,
        "datasource": sheet["source"] + ": spectral sensitivity, characteristic curves (Status A) and spectral dye density, "
                      "digitised from the PDF's vector paths",
        "copyright": "SpektraLab product data. Not a spektrafilm profile; no array is read from one.",
        "license": "Built from the manufacturer's published data sheet. See engine/resources_product/NOTICE.md.",
        "method": ("spektrafilm's profile factory (9428440, GPL-3.0): D-min removed (and laid in as base), green at the 18 % "
                   "transmittance density put at log exposure 0, Status A unmixed through the published C/M/Y dyes, three normal "
                   f"CDFs per layer, {ref_ill} balance; then the shipped profiles' form as for the Fujifilm AF3-207U slides "
                   "(unit Status A dyes, exponential sensitivity tails, hanatos2025 window + surface, upstream's positive grey-ramp "
                   "correction scanned -1..+2 EV trustability 1 through the SpektraLab engine, CDFs refitted, anchored so an sRGB "
                   "18 % grey scans at 18 %)."),
        "tags": tags,
        "digitisation": {"axes": ax},
        "fit_residuals": log,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--refl", required=True)
    ap.add_argument("--sf-src", required=True)
    ap.add_argument("--engine-lib", required=True)
    ap.add_argument("--resources", required=True)
    ap.add_argument("--tests-dir", required=True)
    ap.add_argument("--scratch", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("stocks", nargs="+")
    args = ap.parse_args()
    raw = Path(args.raw)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    refl, wts, counts = load_reflectances(Path(args.refl))
    eng = EngineLoop(args.engine_lib, args.resources, Path(args.tests_dir), args.scratch)
    for stock in args.stocks:
        try:
            doc = build(stock, raw, args, eng, refl, wts, counts)
        except Exception as ex:  # noqa: BLE001  one film's failure is reported, the batch goes on
            print(f"{stock}: FAILED {type(ex).__name__}: {ex}", flush=True)
            continue
        doc = {"metadata": doc["metadata"], "info": doc["info"], "data": doc["data"]}
        (out / f"{stock}.json").write_text(json.dumps(doc, indent=1))
        r = doc["metadata"]["fit_residuals"]
        print(f"{stock}: cdf rms {r['cdf_residual_rms_D']:.4f} D, dye mid rms {r.get('dye_mid_residual_rms_D', float('nan')):.4f}, "
              f"hanatos {r['hanatos2025']['rms_stops_no_adaptation']:.3f}/{r['hanatos2025']['rms_stops_window']:.3f}/"
              f"{r['hanatos2025']['rms_stops_window_surface']:.3f} st, ramp {r['grey_ramp']['rms_before']:.4f}->{r['grey_ramp']['rms_after']:.4f}",
              flush=True)


if __name__ == "__main__":
    main()
