#!/usr/bin/env python3
"""`spk_session_hdr_curve` (API-SPEC §19.2): Enable HDR's gain curve, the session's own, held to the
research's model, to the reference `A_H4` tables, and to the session's edits.

    engine/build.sh dylib
    python3 -I engine/tests/hdr_curve_checks.py [--reference <research checkout>] [--json out.json]

PRD/HDR-PORT-PLAN-2026-11-06 D1/D2. For every film x paper the engine prints (each colour negative on
every colour paper, each silver film on the silver paper, as `medium_ramps.py --all-pairs`
enumerates them) and every slide scanned, at product defaults with auto-exposure off -- the wire the
144 reference `A_H4` tables were made on:

  1. **the table's invariants**: 256 finite values, monotone, entry 0 = 0, the last exactly log2 H,
     exactly 0 below the knee, none above log2 H; Ks and rho finite, Ks in [0, log2 H], rho >= 0;
     kappa 1, rho_max 2. rho is reported against rho_max, not held to it: it is Ks's raw slope, which
     `derive` leaves unclamped (its kernel applies clamp(rho, 0, rho_max) per pixel; the
     research measured 2.95 smoothed just below white), and this port keeps that maths to the line;
  2. **the port is the model**: the engine's table equals the research's own `model2.py`
     (`Medium`, `model_A`, `gain_table`, `finish_table`, exec'd from the research checkout as
     `tools/pair_curves.py` does) run on the same session's `spk_scene_latitude` ramp, to 1e-9 --
     plain and eased at +3.5 EV;
  3. **against the reference tables**: the table against the baked `<film>__<paper|scan>__A_H4.json`,
     max and mean |delta log2 gain| per pair, REPORTED. Expected ~0 (profiles byte-identical, the
     probe the same) except where the desktop prints differently: minilab's pairs
     (`resources/minilab/index.json`; the tables were baked with minilab off). A non-minilab pair past 0.01 is
     flagged for a reason;
  4. **the curve follows the session**: on an optical pair (Portra 400 / Supra Endura, the research's own
     print-exposure variant) `print_exposure` x0.5 / x1 / x2 moves the knee, through `spk_set_params`
     on one session (the medium cache re-probes) exactly as a fresh session at that value; on the
     minilab pair `print_exposure` is reported (minilab's calibrated block does not take it, API-SPEC
     §18). **Exp. Comp. does not move the table** (the product: the enlarger is not re-timed, so c only
     moves the frame along one medium, and a pixel of one SDR Y must get one gain): over c = -8 ... +8
     on three pairs (the default minilab pair, a cinema pair, the pair whose knee blew up on the
     reply's axis) the table, gamma0 and the knee's Y are c = 0's to the bit, `knee_ev` and
     `medium_shift_ev` move by -c / +c, and a clip at scene EV x under c is the clip at x + c under 0;
  4b. **a slide's medium is its film's**: Provia 100F scanned, with `scan_hdr_stretch` or the HDR
     rendition's H 4 x1/4, measures the medium (Scene Latitude's boundaries) and the curve it measures
     without them, to the bit;
  5. **clip_ev eases into a plateau (D2)**: the expanded ramp equals the plain one up to clip - 0.75 EV,
     joins it with its slope (C1), is flat from the clip with a vanishing slope into it, and the
     table stays within its invariants; a clip off the model's grid changes nothing;
  6. **refusals**: an unknown key, a headroom of 1, 1.00005 or 17, a Digital Intermediate session, and
     EDR on a print are refused with no curve.

(`hdr_curve_unit`, a C++ driver, holds the model itself on synthetic media no real pair reaches: the
knee inside its bracket, a gamma0 floor, `top` = log2 H.)

Exit 1 on any failure.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent
sys.path.insert(0, str(HERE))
import spk_ctypes as spk  # noqa: E402
import bw_checks  # noqa: E402

# The research tree the reference tables and study data are read from (never written); none by default.
DEFAULT_REFERENCE = Path(os.environ["SPEKTRALAB_HDR_REFERENCE"]) if os.environ.get("SPEKTRALAB_HDR_REFERENCE") else Path("/nonexistent")
BASE = {"auto_exposure": False, "product_defaults": True}
# `medium_ramps.py`'s SILVER, by value.
SILVER = {"print_stock": bw_checks.PAPER, "c_filter_neutral": 0.0, "m_filter_neutral": 0.0,
          "y_filter_neutral": 68.0, "grain_sublayers_active": False}
H = 4.0
MATERIAL = 0.01   # log2 gain: past this on a non-minilab pair, find out why


def profiles() -> dict[str, dict]:
    out = {}
    for d in (ENGINE / "resources" / "profiles", ENGINE / "resources_product" / "profiles"):
        for f in sorted(d.glob("*.json")):
            out[f.stem] = json.loads(f.read_text())
    return out


def resolved(profs, stock):
    d = profs[stock]
    if "derived_from" in d:
        base = profs[d["derived_from"]]
        d = {**base, "info": {**base.get("info", {}), **d.get("info", {})}}
    return d


def pairs(profs):
    """(film, paper or None, wire): `medium_ramps.py --all-pairs`, plus the slides scanned."""
    def info(s):
        return resolved(profs, s).get("info", {})

    def is_paper(s):
        d = resolved(profs, s)
        return d.get("info", {}).get("support") == "paper" or "edr_tone_map" in d.get("data", {})

    silver = lambda s: info(s).get("channel_model") == "bw"
    films = [s for s in profs if not is_paper(s)]
    papers = [s for s in profs if is_paper(s)]
    out = []
    for film in films:
        if info(film).get("type") == "positive":
            out.append((film, None, {"film_stock": film, "scan_film": True}))
            continue
        for p in papers:
            if silver(film) != silver(p):
                continue
            w = {"film_stock": film, **(SILVER if silver(film) else {}), "print_stock": p}
            out.append((film, p, w))
    return out


def load_model(reference: Path, scratch: Path):
    """The research's own model2.py head, exec'd as `tools/pair_curves.py` does: Medium, model_A, gain_table,
    finish_table and the EV grid. None when the checkout is not here."""
    research = reference / "rfc" / "audits" / "hdr-density-2026-11-03" / "research"
    src = research / "model2.py"
    if not src.is_file():
        return None
    data = scratch / "empty_ramps.json"
    data.write_text(json.dumps({"entries": []}))
    saved_argv, saved_out = sys.argv, os.environ.get("OUT")
    sys.argv = [str(src), str(data), "/dev/null"]
    os.environ["OUT"] = str(scratch / "model_out")
    ns: dict = {"__name__": "model2_head"}
    try:
        exec(compile(src.read_text().split("rows = []")[0], str(src), "exec"), ns)
    finally:
        sys.argv = saved_argv
        if saved_out is None:
            os.environ.pop("OUT", None)
        else:
            os.environ["OUT"] = saved_out
    return ns


def model_table(ns, ramp_ev, ramp_y, headroom, clip_ev=None):
    m = ns["Medium"](np.asarray(ramp_ev, float), np.maximum(np.asarray(ramp_y, float), 1e-7))
    ly, _ = ns["model_A"](m, headroom, ns["ev"], clip_ev=clip_ev)
    tab, g, gw = ns["gain_table"](m, ly, ns["ev"])
    return ns["finish_table"](tab, g, gw, m, math.log2(headroom)), ly


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--reference", type=Path, default=DEFAULT_REFERENCE)
    ap.add_argument("--json", type=Path)
    args = ap.parse_args()

    fails: list[str] = []

    def check(ok, what):
        print(("  ok    " if ok else "  FAIL  ") + what)
        if not ok:
            fails.append(what)

    profs = profiles()
    minilab = set(json.loads((ENGINE / "resources" / "minilab" / "index.json").read_text())["pairs"])
    shipped = args.reference / "app" / "SpektraLab" / "Resources" / "HDRCurves"
    tmp = tempfile.TemporaryDirectory()
    scratch = Path(tmp.name)
    ns = load_model(args.reference, scratch)
    if ns is None:
        print(f"note: no reference tree at {args.reference}: checks 2 and 3 are skipped (not passed)")
    res = bw_checks.overlay(tmp.name)
    e = spk.Engine(resources=res)
    img = np.full((64, 64, 3), 0.184, np.float32)
    log2H = math.log2(H)
    tab = np.linspace(-12.0, 0.0, 256)
    rows, report = [], {"pairs": {}}

    print("1-3. every pair the engine prints, at product defaults")
    worst_port = 0.0
    inv_fail: list[str] = []
    rho_over = []
    for film, paper, w in pairs(profs):
        stem = f"{film}__{paper or 'scan'}"
        s = e.open(img, {**BASE, **w})
        try:
            c = s.hdr_curve()
            ce = s.hdr_curve({"clip_ev": 3.5})
            med = s.scene_latitude()["medium"]
        finally:
            s.close()
        g, ks, rho = np.array(c["log2_gain"]), np.array(c["ks"]), np.array(c["rho"])
        bad = []
        if not (len(g) == 256 and np.isfinite(g).all()): bad.append("finite/256")
        if not (np.diff(g) >= 0).all(): bad.append("monotone")
        if g[0] != 0.0: bad.append("entry0")
        if g[-1] != log2H: bad.append("last")
        if (g > log2H).any() or (g < 0).any(): bad.append("range")
        if (g[tab < c["knee_log2_y"]] != 0.0).any(): bad.append("0 below knee")
        if not (np.isfinite(ks).all() and np.isfinite(rho).all()): bad.append("ks/rho finite")
        if (ks < 0).any() or (ks > log2H + 1e-6).any(): bad.append("ks range")
        if (rho < -1e-6).any(): bad.append("rho >= 0")
        if c["kappa"] != 1.0 or c["rho_max"] != 2.0 or c["top"] != log2H: bad.append("constants")
        ge = np.array(ce["log2_gain"])
        if not (np.isfinite(ge).all() and (np.diff(ge) >= 0).all() and ge[0] == 0 and ge[-1] == log2H):
            bad.append("eased table")
        if bad:
            inv_fail.append(f"{stem}: {', '.join(bad)}")
        rho_over.append((float(rho.max()), float((rho > c["rho_max"]).mean()), stem))
        port = port_e = None
        if ns is not None:
            # On the medium's own axis (the reply's + medium_shift_ev; 0 here, at Exp. Comp. 0).
            own = np.asarray(med["ramp_ev"]) + c.get("medium_shift_ev", 0.0)
            ref, _ = model_table(ns, own, med["ramp_y"], H)
            ref_e, _ = model_table(ns, own, med["ramp_y"], H, clip_ev=3.5 + c.get("medium_shift_ev", 0.0))
            port, port_e = float(np.abs(ref - g).max()), float(np.abs(ref_e - ge).max())
            worst_port = max(worst_port, port, port_e)
        mob = shipped / f"{stem}__A_H4.json"
        dmax = dmean = None
        if mob.is_file():
            mg = np.array(json.loads(mob.read_text())["log2_gain"])
            d = np.abs(mg - g)
            dmax, dmean = float(d.max()), float(d.mean())
        is_minilab = paper is not None and f"{film}|{paper}" in minilab
        rows.append((stem, is_minilab, dmax, dmean, c["knee_ev"], c["delta"], c["y_white"], port))
        report["pairs"][stem] = {"minilab": is_minilab, "max_abs_delta_vs_reference": dmax,
                                 "mean_abs_delta_vs_reference": dmean, "knee_ev": c["knee_ev"],
                                 "delta": c["delta"], "gamma0": c["gamma0"], "y_white": c["y_white"],
                                 "rho_max_reached": float(rho.max()), "port_vs_model_max": port,
                                 "port_vs_model_eased_max": port_e}
    check(not inv_fail, f"table invariants on {len(rows)} pairs (plain and eased at +3.5 EV)"
                        + ("" if not inv_fail else ": " + "; ".join(inv_fail[:6])))
    hi = max(rho_over)
    print(f"  info  rho (Ks's raw slope; the kernel clamps it to rho_max = 2): max {hi[0]:.3f} ({hi[2]}); "
          f"{sum(1 for r in rho_over if r[0] > 2.0)} of {len(rho_over)} pairs exceed 2 somewhere, "
          f"at most {100 * max(r[1] for r in rho_over):.1f} % of samples")
    if ns is not None:
        check(worst_port <= 1e-9, f"the engine's table is the research model2.py on the same ramp: worst "
                                  f"|delta| {worst_port:.2e} (plain and eased; <= 1e-9)")

    compared = [r for r in rows if r[2] is not None]
    print(f"\n  against the reference A_H4 tables ({len(compared)} of {len(rows)} pairs have a file):")
    print(f"  {'pair':58s} {'max|d|':>9s} {'mean|d|':>9s} {'knee EV':>8s} {'delta':>6s} {'Y_w':>6s}")
    for stem, ml, dmax, dmean, knee, delta, yw, _ in sorted(rows, key=lambda r: -(r[2] or -1)):
        tag = " (minilab)" if ml else ""
        dm = f"{dmax:9.5f}" if dmax is not None else "    (none)"
        dn = f"{dmean:9.5f}" if dmean is not None else "          "
        print(f"  {stem + tag:58s} {dm} {dn} {knee:+8.3f} {delta:6.3f} {yw:6.3f}")
    material = [r for r in compared if not r[1] and r[2] > MATERIAL]
    print(f"  info  non-minilab pairs past {MATERIAL} log2: {len(material)}"
          + ("" if not material else " -- " + ", ".join(f"{r[0]} {r[2]:.4f}" for r in material)))
    report["material_non_minilab"] = [r[0] for r in material]

    # 4. the curve follows the session
    print("\n4. the curve follows the session")
    optical = {**BASE, "film_stock": "kodak_portra_400", "print_stock": "kodak_supra_endura"}
    s = e.open(img, optical)
    try:
        knees, curves = {}, {}
        for k in (1.0, 0.5, 2.0, 1.0):
            s.set_params({"print_exposure": k})
            c = s.hdr_curve()
            knees.setdefault(k, c["knee_ev"])
            curves.setdefault(k, np.array(c["log2_gain"]))
            if k == 1.0 and len(knees) == 3:
                check(np.array_equal(curves[1.0], np.array(c["log2_gain"])),
                      "print exposure back to x1 on the same session: the x1 curve again, to the bit")
    finally:
        s.close()
    fresh = e.open(img, {**optical, "print_exposure": 2.0})
    try:
        fresh_g = np.array(fresh.hdr_curve()["log2_gain"])
    finally:
        fresh.close()
    print(f"  info  Portra 400 / Supra Endura knee at print exposure x0.5 / x1 / x2: "
          f"{knees[0.5]:+.3f} / {knees[1.0]:+.3f} / {knees[2.0]:+.3f} EV")
    check(abs(knees[2.0] - knees[1.0]) > 0.1 and abs(knees[0.5] - knees[1.0]) > 0.1
          and not np.array_equal(curves[2.0], curves[1.0]),
          "print exposure moves the knee (x0.5 and x2 each > 0.1 EV from x1) and the table")
    check(np.array_equal(curves[2.0], fresh_g),
          "print exposure x2 through spk_set_params = a fresh session at x2, to the bit (the cache follows)")
    # Exp. Comp. in the product is a pure shift along one medium (`medium_probe_params`): the model
    # runs on the medium's own axis, so the table is c = 0's and only the reply's EVs move. (On the
    # reply's axis it read gamma0 and the knee at the scene's mid-grey wherever c put it: the table
    # moved 0.6-1.9 stop, and at c = -6 the knee fell into the paper's toe and lifted every tone.)
    ec_pairs = {"minilab default": {"film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura"},
                "vision3 500t / 2383": {"film_stock": "kodak_vision3_500t", "print_stock": "kodak_2383"},
                "xtra 400 / endura premier": {"film_stock": "fujifilm_xtra_400",
                                              "print_stock": "kodak_endura_premier"}}
    for label, pw in ec_pairs.items():
        s = e.open(img, {**BASE, **pw})
        try:
            ref = s.hdr_curve()
            ref_clip = s.hdr_curve({"clip_ev": 3.0})
            bad = []
            for ec in (-8.0, -6.0, -3.0, -1.0, 1.0, 2.0, 6.0, 8.0):
                s.set_params({"exposure_compensation_ev": ec})
                try:
                    c = s.hdr_curve()
                    cc = s.hdr_curve({"clip_ev": 3.0 - ec})
                except spk.EngineError as err:
                    bad.append(f"c {ec:+g}: refused ({err})")
                    continue
                same = (c["log2_gain"] == ref["log2_gain"] and c["ks"] == ref["ks"] and c["rho"] == ref["rho"]
                        and c["gamma0"] == ref["gamma0"] and c["knee_log2_y"] == ref["knee_log2_y"]
                        and c["delta"] == ref["delta"])
                moved = (abs(c["knee_ev"] - (ref["knee_ev"] - ec)) < 1e-12 and c.get("medium_shift_ev", 0.0) == ec)
                clip = cc["log2_gain"] == ref_clip["log2_gain"] and cc["eased"] == ref_clip["eased"]
                if not (same and moved and clip):
                    d = float(np.abs(np.array(c["log2_gain"]) - np.array(ref["log2_gain"])).max())
                    bad.append(f"c {ec:+g}: table {'=' if same else f'moved {d:.3f}'}, knee_ev "
                               f"{c['knee_ev']:+.4f} (want {ref['knee_ev'] - ec:+.4f}), clip "
                               f"{'=' if clip else 'differs'}")
            s.set_params({"exposure_compensation_ev": 0.0})
            back = s.hdr_curve()
        finally:
            s.close()
        check(not bad and back == ref,
              f"{label}: Exp. Comp. -8 ... +8 leaves the table, gamma0 and the knee's Y at c = 0's (bit), "
              f"knee_ev moves by -c, a scene clip x under c = x + c under 0" + ("" if not bad else ": " + "; ".join(bad[:4])))

    # 4b. a slide's medium is its film's: the HDR scan's fields are an output choice over it.
    print("\n4b. a slide's medium is its film's")
    provia = {**BASE, "film_stock": "fujifilm_provia_100f", "scan_film": True}
    meds, curvs = {}, {}
    for label, extra in (("default", {}), ("stretch", {"scan_hdr_stretch": True}),
                         ("H 4 x1/4", {"scan_hdr_headroom": 4.0, "scan_hdr_output_scale": 0.25}),
                         ("seed 7", {"grain_seed": 7})):
        s = e.open(img, {**provia, **extra})
        try:
            m = s.scene_latitude()["medium"]
            meds[label] = (m["shadow_ev"], m["highlight_ev"], m["ramp_y"])
            curvs[label] = s.hdr_curve()
        finally:
            s.close()
        print(f"  info  Provia 100F scanned, {label}: highlight {meds[label][1]:+.4f} EV, "
              f"knee {curvs[label]['knee_ev']:+.4f} EV")
    check(all(meds[k] == meds["default"] for k in meds),
          "Provia 100F scanned: the stretch, the HDR rendition's H 4 x1/4 and a grain seed leave the "
          "medium (Scene Latitude's boundaries and ramp) as it is, to the bit")
    check(all(curvs[k] == curvs["default"] for k in curvs),
          "and the curve measured on it, to the bit")
    s = e.open(img, {**BASE, "film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura"})
    try:
        k1 = s.hdr_curve()["knee_ev"]
        s.set_params({"print_exposure": 2.0})
        k2 = s.hdr_curve()["knee_ev"]
    finally:
        s.close()
    print(f"  info  minilab pair Portra 400 / Portra Endura knee at x1 / x2: {k1:+.3f} / {k2:+.3f} EV "
          f"(minilab's block does not take print_exposure, API-SPEC §18)")
    report["follow"] = {"supra_knees": {str(k): v for k, v in knees.items()}, "minilab_knees": [k1, k2]}

    # 5. clip_ev: a C1 plateau
    print("\n5. clip_ev eases into a plateau")
    s = e.open(img, optical)
    try:
        plain = s.hdr_curve({"include_ramp": True})
        eased = s.hdr_curve({"include_ramp": True, "clip_ev": 3.5})
        far = s.hdr_curve({"clip_ev": 12.0})
    finally:
        s.close()
    ev = np.array(plain["ramp"]["ev"])
    lp, le = np.array(plain["ramp"]["log2_y_hdr"]), np.array(eased["ramp"]["log2_y_hdr"])
    a, clip = 3.5 - 0.75, 3.5
    step = ev[1] - ev[0]
    below = ev <= a
    # The grid's own sample at the join (the grid's doubles put a and the clip a hair off their
    # decimal values, so the joins are read on one-sided differences at the nearest sample).
    ia, ic = int(np.argmin(np.abs(ev - a))), int(np.argmin(np.abs(ev - clip)))
    sa = np.interp(a, ev, np.gradient(lp, ev))
    left_a, right_a = (le[ia] - le[ia - 1]) / step, (le[ia + 1] - le[ia]) / step
    slope_out = (le[ic] - le[ic - 1]) / step
    check(np.array_equal(lp[below], le[below]), "eased: the ramp is the plain one up to clip - 0.75 EV")
    # C1: the one-sided slopes either side of the join differ by the Hermite's own curvature over one
    # step (sa / 0.75 EV x 0.025 = 0.023 here), where a crease would differ by about sa itself.
    check(abs(right_a - left_a) < 0.05 * max(sa, 0.1) + 0.02,
          f"eased: joins the plain ramp with its slope at clip - 0.75 EV ({left_a:.4f} | {right_a:.4f}, "
          f"plain {sa:.4f}; C1)")
    check(bool((le[ev >= clip] == le[ev >= clip][0]).all()) and abs(slope_out) < 0.02 * max(sa, 1e-3) + 1e-3,
          f"eased: flat from the clip, slope into it {slope_out:.5f} (the plain ramp's there "
          f"{np.interp(clip, ev, np.gradient(lp, ev)):.4f})")
    check(eased["eased"] is True and plain["eased"] is False and eased["clip_ev"] == 3.5,
          "eased: the reply says so (eased, clip_ev)")
    check(far["eased"] is False and np.array_equal(np.array(far["log2_gain"]), np.array(plain["log2_gain"])),
          "a clip past the model's grid (+12 EV) changes nothing")
    gp, ge = np.array(plain["log2_gain"]), np.array(eased["log2_gain"])
    print(f"  info  eased table against plain: max |delta| {np.abs(gp - ge).max():.4f} log2, "
          f"first sample that moves log2 Y {tab[np.argmax(np.abs(gp - ge) > 0)]:+.3f}")

    # 6. refusals
    print("\n6. refusals")
    def refused(wire, req):
        s = e.open(img, {**BASE, **wire})
        try:
            s.hdr_curve(req)
        except spk.EngineError as err:
            return str(err)
        finally:
            s.close()
        return None
    pe = {"film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura"}
    for wire, req, what in ((pe, {"clip": 3.5}, "an unknown key"), (pe, {"headroom": 1.0}, "headroom 1"),
                            (pe, {"headroom": 1.00005}, "headroom 1.00005 (under 1.0001, where top is not log2 H)"),
                            (pe, {"headroom": 17.0}, "headroom 17"),
                            ({**pe, "digital_intermediate": True}, None, "a Digital Intermediate session"),
                            ({**pe, "extended_dynamic_range": True}, None, "EDR on a print")):
        msg = refused(wire, req)
        check(msg is not None, f"refused: {what}" + (f" ({msg})" if msg else ""))

    e.close()
    if args.json:
        args.json.write_text(json.dumps(report, indent=1))
    print(f"\nhdr curve checks: {len(fails)} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
