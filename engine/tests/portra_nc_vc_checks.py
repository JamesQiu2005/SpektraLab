#!/usr/bin/env python3
"""Portra 160NC, 160VC, 400NC, 400VC: the product's own colour negatives (E-190), end to end.

    python3 engine/tests/portra_nc_vc_checks.py [--dylib PATH]

Needs only `build.sh dylib` and numpy. The four profiles and their packs are the product's
(`engine/resources_product/`) and nothing installs them, so this overlays them on `engine/resources/`
in a scratch folder (as `bw_checks.py` does) and points the engine there. What is checked, and how
each one can fail:

  profiles      each loads and opens a session on every colour paper.
  packs         `solve("filter_pack")` answers the row in `neutral_print_filters_colour.json` on every
                paper (an engine that does not read the file answers the defaults: the red run), and
                18 % grey prints neutral through it.
  merge         spektrafilm's own rows are unchanged by the file (Portra 400 on every paper), and no
                silver film gains a row (the host sends those per grade).
  print hue     the print stage's colour correction (`core/negative_hue.hpp`) holds on all 32 pairs at
                `negative_hue_checks.py`'s bars, and the chart shows the fault with it off.
  edge          the 135 edge's DX code reads back as the film's (1275 / 1275 / 1277 / 1277) with its
                frame number, and the blocks after the name are drawn for these four only.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes as spk  # noqa: E402
import negative_hue_checks as nh  # noqa: E402
from overscan_checks import decode_dx, frame  # noqa: E402

ENGINE = Path(__file__).resolve().parents[1]
FILMS = {"kodak_portra_160nc": 1275, "kodak_portra_160vc": 1275, "kodak_portra_400nc": 1277, "kodak_portra_400vc": 1277}
PAPERS = nh.ALL_PAPERS
QUIET = {"grain_active": False, "glare_active": False, "halation_active": False, "auto_exposure": False,
         "input_cctf_decoding": False, "input_color_space": "sRGB", "output_color_space": "sRGB",
         "output_cctf_encoding": False}


def overlay(tmp: str) -> Path:
    """engine/resources with the product's profiles and its colour packs laid over it, by symlink."""
    res = Path(tmp) / "resources"
    (res / "profiles").mkdir(parents=True)
    for f in (ENGINE / "resources").iterdir():
        if f.name != "profiles":
            os.symlink(f, res / f.name)
    for d in (ENGINE / "resources" / "profiles", ENGINE / "resources_product" / "profiles"):
        for f in d.glob("*.json"):
            os.symlink(f, res / "profiles" / f.name)
    os.symlink(ENGINE / "resources_product" / "neutral_print_filters_colour.json", res / "neutral_print_filters_colour.json")
    return res


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dylib", default=None)
    args = ap.parse_args()
    failures: list[str] = []

    def check(ok: bool, what: str) -> None:
        print(("  ok    " if ok else "  FAIL  ") + what)
        if not ok:
            failures.append(what)

    colour = json.loads((ENGINE / "resources_product" / "neutral_print_filters_colour.json").read_text())
    base = json.loads((ENGINE / "resources" / "neutral_print_filters.json").read_text())
    with tempfile.TemporaryDirectory() as tmp:
        res = overlay(tmp)
        e = spk.Engine(library=args.dylib, resources=res) if args.dylib else spk.Engine(resources=res)
        print(e.build_info)
        grey = np.full((8, 8, 3), 0.184, np.float32)

        print("profiles and packs")
        for film in FILMS:
            for paper in PAPERS:
                s = e.open(grey, dict(QUIET, film_stock=film, print_stock=paper))
                try:
                    solved = s.solve("filter_pack")["solved_params"]
                    want = colour[paper]["TH-KG3"][film]
                    got = [solved["c_filter_neutral"], solved["m_filter_neutral"], solved["y_filter_neutral"]]
                    ok_pack = np.allclose(got, want, atol=1e-9)
                    s.set_params({"c_filter_neutral": got[0], "m_filter_neutral": got[1], "y_filter_neutral": got[2]})
                    rgba, _ = s.render("full")
                finally:
                    s.close()
                v = rgba[2:-2, 2:-2, :3].astype(np.float64).mean((0, 1)) / 65535.0
                spread = float(v.max() - v.min())
                check(ok_pack and spread < 0.004,
                      f"{film} -> {paper}: pack {np.round(got, 2).tolist()}, 18 % grey prints {np.round(v, 4).tolist()}")

        print("merge: spektrafilm's rows and the silver films")
        for paper in PAPERS:
            s = e.open(grey, dict(QUIET, film_stock="kodak_portra_400", print_stock=paper))
            try:
                solved = s.solve("filter_pack")["solved_params"]
            finally:
                s.close()
            want = base[paper]["TH-KG3"]["kodak_portra_400"]
            got = [solved["c_filter_neutral"], solved["m_filter_neutral"], solved["y_filter_neutral"]]
            check(np.allclose(got, want, atol=1e-9), f"kodak_portra_400 -> {paper}: still spektrafilm's row")
        silver = [f for f in ("kodak_tri_x_400", "kodak_tmax_100", "fujifilm_neopan_acros_100_ii", "ilford_hp5_plus_400")]
        check(not any(f in rows for by_ill in colour.values() for rows in by_ill.values() for f in silver),
              "no silver film has a row in the colour file")
        check(set(colour) <= set(base) and all(set(colour[p]) <= set(base[p]) for p in colour)
              and not any(f in base[p][i] for p in colour for i in colour[p] for f in colour[p][i]),
              "the colour file names only spektrafilm's papers and illuminants, and no film spektrafilm's table has")

        print("print hue: the print stage's correction on every pair")
        img, labs, usable, rows, cols = nh.chart()
        _, _, h_in = nh.lch(labs)
        worst_on, best_off, worst_dl = 0.0, 1e9, 0.0
        for film in FILMS:
            for paper in PAPERS:
                d = {"film_stock": film, "print_stock": paper}
                on = nh.patches(nh.render(e, img, d, **nh.ON), rows, cols)
                off = nh.patches(nh.render(e, img, d, **nh.OFF), rows, cols)
                _, _, hue_on = nh.lch(on); _, c_off, hue_off = nh.lch(off)
                sel = usable & (c_off > 0.02)
                e_on = float(np.abs(nh.dh(hue_on, h_in))[sel].mean())
                e_off = float(np.abs(nh.dh(hue_off, h_in))[sel].mean())
                dl = float(np.abs(on[:, 0] - off[:, 0])[usable].max())
                worst_on, best_off, worst_dl = max(worst_on, e_on), min(best_off, e_off), max(worst_dl, dl)
                if paper == "kodak_portra_endura" or e_on > nh.HUE_MEAN_MAX or dl > nh.LIGHTNESS_MAX:
                    check(e_on <= nh.HUE_MEAN_MAX and dl <= nh.LIGHTNESS_MAX,
                          f"{film} -> {paper}: hue {e_on:.2f} deg (optical {e_off:.2f}), |dL| {dl:.4f}")
        check(worst_on <= nh.HUE_MEAN_MAX and worst_dl <= nh.LIGHTNESS_MAX,
              f"32 pairs: worst mean hue {worst_on:.2f} deg (bar {nh.HUE_MEAN_MAX}), worst |dL| {worst_dl:.4f}")
        check(best_off >= nh.HUE_OFF_MIN, f"the chart shows the fault with the correction off (best {best_off:.2f} deg)")

        print("edge: DX read back, the blocks after the name")
        img135 = frame(1200, 800)
        def edge(film, text):
            p = {"film_stock": film, "print_stock": "kodak_portra_endura", "grain_active": False, "glare_active": False,
                 "auto_exposure": False, "overscan_active": True, "overscan_format": "135", "overscan_edge_text": text}
            s = e.open(img135, p)
            try:
                rgba, _ = s.render("live")
            finally:
                s.close()
            return rgba, None
        for film, dx in FILMS.items():
            rgba, geo = edge(film, "KODAK " + film[-5:].upper())
            got = decode_dx(rgba, 36.25 / 1200)              # the 135 gate's long edge over the frame (overscan_checks)
            check(got is not None and got[0] == dx and got[3], f"{film}: DX {got} reads back {dx}")
        top = lambda rgba: (rgba[: rgba.shape[0] // 20, :, :3].astype(float).mean(-1) > 0.5 * 65535).sum()
        a, _ = edge("kodak_portra_160nc", "KODAK 160NC")
        b, _ = edge("kodak_portra_160", "KODAK 160NC")
        check(top(a) > top(b) * 1.08, f"the blocks are drawn after 160NC's name (top band ink {top(a)} against {top(b)} on Portra 160)")
        e.close()

    print(f"{len(failures)} failure(s)")
    for f in failures:
        print("  -", f)
    return len(failures)


if __name__ == "__main__":
    sys.exit(main())
