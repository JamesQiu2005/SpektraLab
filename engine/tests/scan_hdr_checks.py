#!/usr/bin/env python3
"""`scan_hdr` (core/scan_hdr.hpp): a slide's HDR scan per dye layer, held against today's scan and the study.

    engine/build.sh dylib
    python3 -I engine/tests/scan_hdr_checks.py [--reference <research checkout>] [--json out.json]

2026-11-06, with the engine hunk it holds (PRD/HDR-PORT-PLAN-2026-11-06 D4). The engine has no
device policy (no `device=`), and the study's data stay outside this repository (`--reference`, or
SPEKTRALAB_HDR_REFERENCE; read, never written).

On the macOS dylib, the study's ramps (`rfc/audits/hdr-density-2026-11-03/
slides`, seven ramps of 128 steps from -4 to +7 EV, linear Display P3 out), for the four slides:

  1. **today's scan is today's**: with no `scan_hdr_*` field the picture is the one a session without them
     renders, to the bit (the fields' defaults are a bypass);
  2. **below the knee, byte for byte**: the stretched SDR rendition (`scan_hdr_stretch`) equals today's
     scan on every ramp step below its reach of the first layer's knee (couplers off: the DIR couplers
     diffuse in space, so on a ramp a step takes its brighter neighbours' correction) and on flat fields
     at -2 ... 0 EV with the couplers on; the HDR rendition at H = 4 / output scale 1/4 over the stretch,
     the map's own measure, is within 1/40 stop of no gain there;
  3. **the clear base lands where it was put**: today's clear base out is the study's Y_white; the
     engine's own report (`spk_progress`'s `scan_hdr`) has the knees within 0.1 stop of the study's
     (it takes mid-grey at log10 H = 0, the study probed it) and the clear base at its target, untinted;
  4. **the study's result holds in the scan**: on the neutral at H = 2, mid-grey within 1 % of today's,
     the separation of +1.5 ... +3.5 EV at least the study's after-scan rendition's less 0.15 stop; and
     the stretched SDR picture's hue drift at +2 and +3 EV no worse than today's (the colour gain);
  5. **one grain across two renders**: with grain on and one `grain_seed`, two renders are one picture
     and the stretch is today's on a flat field below the knee, to the bit.
Prints a table of the in-scan rendition against the study's after-scan one (the difference is the dyes'
cross-talk, HANDOFF §6.2). Exit 1 on any failure.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import spk_ctypes as spk  # noqa: E402

# The research tree the reference tables and study data are read from (never written); none by default.
DEFAULT_REFERENCE = Path(os.environ["SPEKTRALAB_HDR_REFERENCE"]) if os.environ.get("SPEKTRALAB_HDR_REFERENCE") else Path("/nonexistent")
STUDY_REL = Path("rfc") / "audits" / "hdr-density-2026-11-03" / "slides" / "data"
FILMS = ["fujifilm_velvia_100", "kodak_kodachrome_64", "fujifilm_provia_100f", "kodak_ektachrome_100"]
N, STEP_PX, ROWS = 128, 4, 16
EV = np.linspace(-4.0, 7.0, N)
MID = 0.184
QUIET = {"grain_active": False, "grain_sublayers_active": False, "halation_active": False,
         "glare_active": False, "contrast_mask_active": False, "overscan_active": False,
         "date_imprint_active": False, "scene_latitude_active": False}
WIRE = {"auto_exposure": False, "product_defaults": True, "scan_film": True,
        "output_color_space": "Display P3", "output_cctf_encoding": False,
        "input_color_space": "sRGB", "input_cctf_decoding": False}
P3_Y = np.array([0.2289746, 0.6917385, 0.0792869])
P3_TO_XYZ = np.array([[0.4865709486, 0.2656676932, 0.1982172852],
                      [0.2289745641, 0.6917385218, 0.0792869141],
                      [0.0, 0.0451133819, 1.0439443689]])
M1 = np.array([[0.8189330101, 0.3618667424, -0.1288597137],
               [0.0329845436, 0.9293118715, 0.0361456387],
               [0.0482003018, 0.2643662691, 0.6338517070]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
               [1.9779984951, -2.4285922050, 0.4505937099],
               [0.0259040371, 0.7827717662, -0.8086757660]])
SRGB_Y = np.array([0.2126, 0.7152, 0.0722])
# The study's after-scan rendition at H = 2 (slides/REPORT.md's table): separation of +1.5 ... +3.5 EV in
# stops, and the mean hue drift at +3 EV in Oklab degrees -- today's (r1) and the per-layer one (r2).
STUDY_H2 = {"fujifilm_velvia_100": (0.28, 0.99, 22.2, 10.5), "kodak_kodachrome_64": (0.45, 1.14, 41.9, 21.4),
            "fujifilm_provia_100f": (0.38, 1.28, 11.6, 9.6), "kodak_ektachrome_100": (0.48, 1.33, 10.4, 7.1)}
COLOURS = {"red": (1, 0, 0), "yellow": (1, 1, 0), "green": (0, 1, 0),
           "cyan": (0, 1, 1), "blue": (0, 0, 1), "magenta": (1, 0, 1)}


def ramps():
    out = {"neutral": np.array([MID] * 3)}
    for k, c in COLOURS.items():
        c = np.array(c, float)
        c = c * (MID / (c @ SRGB_Y))
        out[k] = 0.5 * c + 0.5 * MID
    return {k: (v[None, :] * 2.0 ** EV[:, None]) for k, v in out.items()}


def frame(rs):
    rows = []
    for v in rs.values():
        row = np.repeat(v, STEP_PX, axis=0)
        rows.append(np.tile(row[None], (ROWS, 1, 1)))
    return np.concatenate(rows, 0).astype(np.float32)


def steps(rgba16):
    """(ramps, N, 3) of the 16-bit codes in the middle of each step, as they came."""
    out = []
    for r in range(len(COLOURS) + 1):
        blk = rgba16[r * ROWS + ROWS // 2, :, :3]
        out.append(np.array([blk[i * STEP_PX + 1] for i in range(N)]))
    return np.array(out)


def oklab(rgb_p3):
    lms = np.cbrt(np.einsum("ij,...j->...i", M1 @ P3_TO_XYZ, np.maximum(rgb_p3, 0)))
    return np.einsum("ij,...j->...i", M2, lms)


def hue_drift(lin, at_ev):
    """Mean over the six colours of |delta hue| (Oklab degrees) at `at_ev` against 0 EV."""
    i0, i1 = np.argmin(np.abs(EV)), np.argmin(np.abs(EV - at_ev))
    d = []
    for r in range(1, 7):
        a0, a1 = oklab(lin[r, i0]), oklab(lin[r, i1])
        h0, h1 = np.degrees(np.arctan2(a0[2], a0[1])), np.degrees(np.arctan2(a1[2], a1[1]))
        d.append(abs((h1 - h0 + 180) % 360 - 180))
    return float(np.mean(d))


def separation(lin):
    y = lin[0] @ P3_Y
    a, b = np.argmin(np.abs(EV - 1.5)), np.argmin(np.abs(EV - 3.5))
    return float(np.log2(y[b] / y[a]))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", type=Path)
    ap.add_argument("--reference", type=Path, default=DEFAULT_REFERENCE)
    args = ap.parse_args()
    study_file = args.reference / STUDY_REL / "slides_run.json"
    if not study_file.is_file():
        print(f"scan_hdr checks: the study's {study_file} is not here (--reference): not run")
        return 1
    study = json.loads(study_file.read_text())
    rs = ramps()
    img = frame(rs)
    e = spk.Engine()
    fails: list[str] = []
    report: dict = {}

    def check(ok, what):
        print(("  ok    " if ok else "  FAIL  ") + what)
        if not ok:
            fails.append(what)

    def render(film, **extra):
        s = e.open(img, {**WIRE, **QUIET, "film_stock": film, **extra})
        try:
            rgba, _ = s.render("full")
            prog = s.progress()
        finally:
            s.close()
        return steps(rgba), prog

    def flat_render(film, flat, **extra):
        s = e.open(flat, {**WIRE, **QUIET, "film_stock": film, **extra})
        try:
            rgba, _ = s.render("full")
        finally:
            s.close()
        return rgba

    for film in FILMS:
        print(film)
        st = study["films"][film]
        today, p_today = render(film)
        bare, _ = render(film, scan_hdr_headroom=0.0, scan_hdr_stretch=False, scan_hdr_output_scale=1.0)
        sdr, p_sdr = render(film, scan_hdr_stretch=True)
        h4, p_h4 = render(film, scan_hdr_headroom=4.0, scan_hdr_output_scale=0.25)
        h2, p_h2 = render(film, scan_hdr_headroom=2.0, scan_hdr_output_scale=0.5)
        check("scan_hdr" not in p_today and np.array_equal(today, bare),
              "with the fields at their defaults the scan is today's, to the bit")
        hs, h4r = p_sdr["scan_hdr"], p_h4["scan_hdr"]
        knees = np.array(hs["knee_stops"])
        study_knees = np.array([l["knee_log10H"] for l in st["models"]["H2"]["layers"]]) / np.log10(2)
        # Below the first knee, byte for byte. Two ways, because the DIR couplers diffuse in space: on the
        # ramps a step a stop under the knee sits ~60 px from steps above it and takes their correction
        # (physical -- the shoulder's own neighbourhood), so the ramps are held with the couplers off,
        # each ramp from its own reach (a saturated ramp's layer runs ahead of its EV, the blue one's by
        # ~2.9 stops), and flat fields are held with them on.
        ahead = np.log2(np.array([v[np.argmin(np.abs(EV))].max() for v in rs.values()]) / MID)
        below = (EV[None, :] + ahead[:, None]) <= knees.min() - 0.25          # (ramps, N)
        nc = {"dir_couplers_active": False}
        today_nc, _ = render(film, **nc)
        sdr_nc, _ = render(film, scan_hdr_stretch=True, **nc)
        h4_nc, _ = render(film, scan_hdr_headroom=4.0, scan_hdr_output_scale=0.25, **nc)
        same = all(np.array_equal(sdr_nc[r, below[r]], today_nc[r, below[r]]) for r in range(len(rs)))
        first = next((float(EV[i]) for i in range(N) if not np.array_equal(sdr_nc[0, i], today_nc[0, i])), None)
        check(same, f"stretch, couplers off: byte-identical to today's on every ramp below its reach of the first "
                    f"knee less 1/4 stop (the neutral's first difference at {first:+.2f} EV; knees "
                    f"{', '.join(f'{k:+.2f}' for k in knees)} stops)")
        flats = {}
        for ev in (-2.0, -1.0, -0.5, 0.0):
            flat = np.full((64, 96, 3), MID * 2.0 ** ev, np.float32)
            flats[ev] = [flat_render(film, flat), flat_render(film, flat, scan_hdr_stretch=True),
                         flat_render(film, flat, scan_hdr_headroom=4.0, scan_hdr_output_scale=0.25)]
        check(all(np.array_equal(v[0], v[1]) for v in flats.values()),
              "stretch, couplers on: flat fields at -2, -1, -1/2 and 0 EV byte-identical to today's")
        # The map's own measure below the knee: log2 of the HDR rendition's luminance over the SDR one's --
        # every ramp (couplers off), from -3 EV (deeper, x 1/4 is a few 16-bit codes), and the flats.
        y_h4 = (h4_nc.astype(np.float64) / 65535.0 * 4.0) @ P3_Y
        y_sdr = (sdr_nc.astype(np.float64) / 65535.0) @ P3_Y
        deep = below & (EV[None, :] >= -3.0)
        worst = (0.0, "", 0.0)
        for r, name in enumerate(rs):
            if not deep[r].any():
                continue
            g = np.abs(np.log2(y_h4[r, deep[r]] / y_sdr[r, deep[r]]))
            if g.max() > worst[0]:
                worst = (float(g.max()), name, float(EV[deep[r]][np.argmax(g)]))
        g_flat = max(abs(np.log2(((v[2][..., :3].astype(np.float64) / 65535.0 * 4.0) @ P3_Y).mean()
                                 / ((v[1][..., :3].astype(np.float64) / 65535.0) @ P3_Y).mean())) for v in flats.values())
        # 1/40 stop on the ramps: the worst is at about -3 EV, where the rendition at x 1/4 is a few 16-bit
        # codes (quantisation, not a gain); about 3 codes of an 8-bit map at most.
        check(worst[0] <= 0.025 and g_flat <= 0.005,
              f"H 4 over the stretch below the knee: |log2 gain| {worst[0]:.4f} on the ramps (worst {worst[1]} at "
              f"{worst[2]:+.2f} EV; <= 0.025), {g_flat:.4f} on the flats (<= 0.005)")
        y_today_white = float((today[0, -1] / 65535.0) @ P3_Y)
        check(abs(y_today_white / st["y_white"] - 1) < 0.01,
              f"today's clear base {y_today_white:.4f} out (study {st['y_white']:.4f}); "
              f"the scan's own, before the output's roll-off, {hs['y_white']:.4f}")
        # The study read each layer's mid-grey by probe (+0.011 to -0.028 log10 H); the engine takes 0.
        check(np.abs(knees - study_knees).max() < 0.1,
              f"knees within 0.1 stop of the study's ({np.abs(knees - study_knees).max():.3f})")
        for p, name in ((hs, "stretch"), (h4r, "H 4"), (p_h2["scan_hdr"], "H 2")):
            check(abs(p["y_reached"] / p["y_target"] - 1) < 1e-3 and p["tint"] < 1e-6,
                  f"{name}: the clear base at its target {p['y_target']:.4f} untinted (reached {p['y_reached']:.4f}, "
                  f"headroom {p['headroom']:.3f}, lifts {', '.join(f'{v:.3f}' for v in p['lift_density'])} density)")
        lin_today = today / 65535.0
        lin_h2 = h2 / 65535.0 * 2.0
        lin_sdr = sdr / 65535.0
        lin_h4 = h4 / 65535.0 * 4.0
        i0 = np.argmin(np.abs(EV))
        mg_today, mg_h2 = lin_today[0, i0] @ P3_Y, lin_h2[0, i0] @ P3_Y
        check(abs(mg_h2 / mg_today - 1) < 0.01, f"H 2: mid-grey {mg_h2:.4f} against today's {mg_today:.4f}")
        sep = {"today": separation(lin_today), "sdr": separation(lin_sdr), "h2": separation(lin_h2),
               "h4": separation(lin_h4)}
        drift = {k: hue_drift(v, 3.0) for k, v in (("today", lin_today), ("sdr", lin_sdr), ("h2", lin_h2), ("h4", lin_h4))}
        drift2 = {k: hue_drift(v, 2.0) for k, v in (("today", lin_today), ("sdr", lin_sdr), ("h2", lin_h2), ("h4", lin_h4))}
        r1_sep, ref_sep, r1_drift, ref_drift = STUDY_H2[film]
        check(sep["h2"] >= ref_sep - 0.15,
              f"H 2: separation {sep['h2']:.2f} stop (study's after-scan {ref_sep:.2f}; today {sep['today']:.2f}, study's {r1_sep:.2f})")
        # The colour gain is the SDR base's (the map is one channel, v1: the screen lifts the base's own
        # colour), so the stretch is held to it; the HDR rendition's hue is reported, not held -- its
        # +3 EV pixels are near white, where a hue is the white's tint (HANDOFF §6.3).
        check(drift["sdr"] <= drift["today"] + 0.5 and drift2["sdr"] <= drift2["today"] + 0.5,
              f"stretch: hue drift at +2 / +3 EV {drift2['sdr']:.1f} / {drift['sdr']:.1f} against today's "
              f"{drift2['today']:.1f} / {drift['today']:.1f} degrees (H 2 {drift2['h2']:.1f} / {drift['h2']:.1f}, "
              f"H 4 {drift2['h4']:.1f} / {drift['h4']:.1f}; study: today {r1_drift:.1f}, after-scan H 2 {ref_drift:.1f} at +3)")
        report[film] = {"knee_stops": knees.tolist(), "study_knee_stops": study_knees.tolist(),
                        "first_difference_ev": first, "separation": sep, "hue_drift_3ev": drift, "hue_drift_2ev": drift2,
                        "study_separation_h2": ref_sep, "study_hue_drift_h2_3ev": ref_drift,
                        "stretch": hs, "h4": h4r, "h2": p_h2["scan_hdr"]}

        # 5. one grain across two renders
        grain = {"grain_active": True, "grain_sublayers_active": True, "grain_seed": 12345}
        g_today, _ = render(film, **grain)
        g_today2, _ = render(film, **grain)
        check(np.array_equal(g_today, g_today2), "grain: one seed, one picture")
        flat = np.full((64, 96, 3), MID * 0.5, np.float32)
        check(np.array_equal(flat_render(film, flat, **grain), flat_render(film, flat, scan_hdr_stretch=True, **grain)),
              "grain: a flat field at -1 EV, the stretch is today's to the bit under one seed")
    e.close()
    if args.json:
        args.json.write_text(json.dumps(report, indent=1, default=float))
    print(f"scan_hdr checks: {len(fails)} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
