#!/usr/bin/env python3
"""Turn digitise_cine.py's sheets into build_profiles.py inputs.

    PYTHONPATH=<spektrafilm@9428440>/src python prep_cine.py RAW_CINE SHEETS.json RAW_BUILD stock [stock ...]

Adds the settings the builder reads (cine: print target and grey-ramp paper Kodak 2383, upstream's Vision3
trustability 0.3, own dyes where the sheet publishes them, the sensitivity's density level read off the sheet).

A sheet that publishes the three dyes but no midscale neutral or D-min curve (Kodak's VISION 5274/5246/5277/5279
sheets) gets both DERIVED from its own data, tagged in metadata:
  D-min:    the D-min spectrum of a sibling sheet that has one (DONOR), scaled per Status M band so its Status M
            densities equal this film's own D-min (the floor of its own characteristic curves);
  midscale: that D-min plus this film's own dyes in the amounts whose Status M densities equal its own
            characteristic curves at mid grey (green D 0.2 over D-min, three stops up: the factory's anchor).
"""
from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path

import numpy as np
import pymupdf
from spectral_film_lab.utils.io import load_densitometer_data
from spectral_film_lab.config import SPECTRAL_SHAPE

WL = SPECTRAL_SHAPE.wavelengths
GENERIC_START = {"kodak_vision_500t_5263"}
DONOR = {"kodak_vision_250d": "kodak_vision_500t_5263", "kodak_vision_320t": "kodak_vision_500t_5263",
         "kodak_vision_500t": "kodak_vision_500t_5263", "kodak_vision_200t": "kodak_vision_500t_5263",
         "kodak_vision_800t": "kodak_vision_500t_5263"}


def L(p):
    a = np.loadtxt(p, delimiter=",")
    return a[np.argsort(a[:, 0])]


def on_wl(a):
    return np.interp(WL, a[:, 0], a[:, 1], left=np.nan, right=np.nan)


def status_m(spec_density):
    """Status M densities of a spectral density (NaN treated as no density, as the factory does)."""
    r = load_densitometer_data(type="status_M")
    t = 10 ** (-np.nan_to_num(spec_density))
    return -np.log10((r * t[:, None]).sum(0) / r.sum(0))


def density_level(pdf, default):
    t = "".join(p.get_text() for p in pymupdf.open(pdf))
    m = re.search(r"D\s*=\s*([0-9.]+)\s*>\s*D-?min", t) or re.search(r"Density\s*:?\s*([0-9.]+)\s*above\s*(?:D-?min|minimum)", t, re.I)
    return float(m.group(1)) if m else default


def derive_min_mid(raw, stock, donor):
    d_min = L(raw / donor / "dye_density_min.csv")
    don_curves = {c: L(raw / donor / f"density_curve_{c}.csv") for c in "rgb"}
    own_curves = {c: L(raw / stock / f"density_curve_{c}.csv") for c in "rgb"}
    dmin_don = np.array([don_curves[c][:, 1].min() for c in "rgb"])
    dmin_own = np.array([own_curves[c][:, 1].min() for c in "rgb"])
    # per-band scale, interpolated across the Status M peaks (R 650, G 540, B 440), held beyond
    scale = np.interp(WL, [440, 540, 650], (dmin_own / dmin_don)[::-1])
    dmin = on_wl(d_min) * scale
    # mid grey on the film's own curves: green D 0.2 over D-min, three stops up
    g = own_curves["g"]
    le_speed = np.interp(0.2, g[:, 1] - g[:, 1].min(), g[:, 0])
    le_mid = le_speed + np.log10(8)
    net = np.array([np.interp(le_mid, own_curves[c][:, 0], own_curves[c][:, 1]) for c in "rgb"]) - dmin_own
    dyes = np.column_stack([on_wl(L(raw / stock / f"dye_density_{c}.csv")) for c in "cmy"])
    # Status M (R, G, B) of unit amounts of C, M, Y
    M = np.column_stack([status_m(dyes[:, j]) for j in range(3)])
    amounts = np.linalg.solve(M, net)
    mid = dmin + np.nansum(dyes * amounts, axis=1)
    mid[np.isnan(dmin) | np.all(np.isnan(dyes), axis=1)] = np.nan
    ok = ~np.isnan(mid) & ~np.isnan(dmin)
    info = {"donor": donor, "dmin_status_m_own": dmin_own.round(3).tolist(), "dmin_status_m_donor": dmin_don.round(3).tolist(),
            "mid_log_exposure": round(float(le_mid), 3), "mid_net_status_m": net.round(3).tolist(),
            "mid_dye_amounts_cmy": amounts.round(3).tolist()}
    return np.column_stack([WL[ok], dmin[ok]]), np.column_stack([WL[ok], mid[ok]]), info


STILL = False


def main():
    global STILL
    if "--still" in sys.argv:
        sys.argv.remove("--still")
        STILL = True
    raw, specs, out = Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text()), Path(sys.argv[3])
    by = {s["stock"]: s for s in specs}
    for stock in sys.argv[4:]:
        spec = by[stock]
        sheet = json.loads((raw / stock / "sheet.json").read_text())
        dst = out / stock
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(raw / stock, dst)
        own_dyes = (raw / stock / "dye_density_c.csv").exists() and stock not in GENERIC_START
        if stock in GENERIC_START:
            # the sheet publishes C/M/Y, but starting from them the factory's dmid_dmin fit misses the sheet's own
            # midscale neutral (RMS 0.10 D, grey ramp 0.05); from its generic starting dyes it fits (0.04 D, 0.006)
            for c in "cmy":
                (dst / f"dye_density_{c}.csv").unlink(missing_ok=True)
            sheet.setdefault("extra_tags", {})["dyes"] = ("the sheet's published C/M/Y were tried as starting dyes and missed its "
                                                          "midscale neutral (0.10 D RMS); the generic starting dyes used instead")
        fuji = stock.startswith("fujifilm_")
        still = STILL
        sheet.update({
            "positive": False, "cine": True, "tungsten": spec["tungsten"],
            # still negatives: upstream's Kodak still rows (Portra Endura, trustability 1); cine: its Vision3 rows (2383, 0.3)
            "ramp_paper": "kodak_portra_endura" if still else "kodak_2383",
            "target_print": "kodak_portra_endura" if still else "kodak_2383", "trust": "1.0" if still else "0.3",
            "process": "C-41" if still else "ECN-2", "dye_donor": None if own_dyes else "generic_a",
            "sensitivity_density_over_min": density_level(spec["pdf"], 0.4 if fuji else 0.2),
        })
        if not sheet.get("mid_min_published"):
            if stock not in DONOR:
                raise SystemExit(f"{stock}: no midscale/D-min and no donor")
            mn, md, info = derive_min_mid(raw, stock, DONOR[stock])
            np.savetxt(dst / "dye_density_min.csv", mn, delimiter=",", fmt="%.6f")
            np.savetxt(dst / "dye_density_mid.csv", md, delimiter=",", fmt="%.6f")
            dn = by[DONOR[stock]]["name"]
            sheet["min_tag"] = (f"DERIVED: the sheet publishes no D-min curve; {dn}'s (same generation) spectral shape scaled per "
                                f"Status M band to this film's own D-min {info['dmin_status_m_own']}")
            sheet["mid_tag"] = ("DERIVED: the sheet publishes no midscale neutral; that D-min plus the sheet's own C/M/Y dyes in "
                                f"amounts {info['mid_dye_amounts_cmy']} whose Status M densities equal its own characteristic "
                                f"curves at mid grey (net {info['mid_net_status_m']})")
            sheet["derived_min_mid"] = info
        (dst / "sheet.json").write_text(json.dumps(sheet, indent=1, default=float))
        print(stock, "dyes", "own" if own_dyes else "generic", "D", sheet["sensitivity_density_over_min"],
              "derived" if "derived_min_mid" in sheet else "published", sheet.get("derived_min_mid", ""))


if __name__ == "__main__":
    main()
